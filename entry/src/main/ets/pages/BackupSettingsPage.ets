/**
 * 备份与恢复设置页
 *
 * 功能：
 * - WebDAV 云端配置（服务器、账号、密码、路径）
 * - 本地备份/恢复（通过文件选择器）
 * - 云端备份/恢复（通过 WebDAV）
 * - 恢复忽略选项
 */
import promptAction from '@ohos.promptAction';
import { AppTheme } from '../theme/AppTheme';
import { UiUtil } from '../util/UiUtil';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { BackupService, ImportResult } from '../service/BackupService';
import { WebDavService, WebDavConfig } from '../service/WebDavService';
import router from '@ohos.router';

@Entry
@Component
struct BackupSettingsPage {
  @State isDark: boolean = false;

  // ---- WebDAV 配置 ----
  @State webDavUrl: string = 'https://dav.jianguoyun.com/dav/';
  @State webDavUser: string = '';
  @State webDavPwd: string = '';
  @State webDavPath: string = 'legado';
  @State webDavAutoSync: boolean = false;
  @State webDavConnected: boolean = false;

  // ---- 状态 ----
  @State isBusy: boolean = false;
  @State statusText: string = '';
  @State backupNames: string[] = [];

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.initSettings_();
  }

  private async initSettings_(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      this.webDavUrl = await s.get('webdav_url', 'https://dav.jianguoyun.com/dav/');
      this.webDavUser = await s.get('webdav_user', '');
      this.webDavPwd = await s.getWebDavPassword();
      this.webDavPath = await s.get('webdav_path', 'legadohos');
      this.webDavAutoSync = await s.get('webdav_auto_sync', false);
    } catch (_) { /* ignore */ }
  }

  private async saveSetting_(key: string, value: Object): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      await s.put(key, value);
    } catch (_) { /* ignore */ }
  }

  private async savePassword_(pwd: string): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      await s.setWebDavPassword(pwd);
    } catch (_) { /* ignore */ }
  }

  private applyWebDavConfig(): void {
    const cfg: WebDavConfig = {
      serverUrl: this.webDavUrl,
      username: this.webDavUser,
      password: this.webDavPwd,
      path: this.webDavPath,
      autoSync: this.webDavAutoSync,
      syncInterval: 60,
    };
    WebDavService.getInstance().configure(cfg);
  }

  // ---- 操作 ----

  private showToast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1500 });
  }

  private async testConnection(): Promise<void> {
    this.isBusy = true;
    this.statusText = '测试连接中...';
    this.applyWebDavConfig();
    try {
      const ok = await WebDavService.getInstance().testConnection();
      this.webDavConnected = ok;
      this.statusText = ok ? '连接成功 ✓' : '连接失败 ✗';
      if (ok) this.showToast('WebDAV 连接成功');
      else this.showToast('连接失败，请检查配置');
    } catch (err) {
      this.statusText = '连接失败: ' + (err as Error).message;
      this.showToast('连接失败');
    }
    this.isBusy = false;
  }

  private async backupToLocal(): Promise<void> {
    this.isBusy = true;
    this.statusText = '导出备份...';
    try {
      await BackupService.backupToLocal();
      this.statusText = '备份已保存 ✓';
      this.showToast('本地备份成功');
    } catch (err) {
      this.statusText = '备份失败: ' + (err as Error).message;
      this.showToast('备份失败');
    }
    this.isBusy = false;
  }

  private async restoreFromLocal(): Promise<void> {
    this.isBusy = true;
    this.statusText = '恢复中...';
    try {
      const result = await BackupService.restoreFromLocal();
      if (result) {
        this.statusText = `恢复完成: ${result.books} 本书, ${result.sources} 个书源`;
        this.showToast('恢复成功');
      } else {
        this.statusText = '已取消';
      }
    } catch (err) {
      this.statusText = '恢复失败: ' + (err as Error).message;
      this.showToast('恢复失败');
    }
    this.isBusy = false;
  }

  private async backupToCloud(): Promise<void> {
    this.isBusy = true;
    this.statusText = '上传备份到云端...';
    this.applyWebDavConfig();
    try {
      const name = await BackupService.backupToWebDav();
      this.statusText = `已上传: ${name} ✓`;
      this.showToast('云端备份成功');
    } catch (err) {
      this.statusText = '上传失败: ' + (err as Error).message;
      this.showToast('上传失败');
    }
    this.isBusy = false;
  }

  private async listCloudBackups(): Promise<void> {
    this.isBusy = true;
    this.statusText = '加载云端备份列表...';
    this.applyWebDavConfig();
    try {
      const files = await WebDavService.getInstance().listBackups();
      this.backupNames = files.map(f => f.name);
      this.statusText = `找到 ${files.length} 个云端备份`;
      if (files.length === 0) this.showToast('云端无备份文件');
    } catch (err) {
      this.statusText = '加载失败: ' + (err as Error).message;
    }
    this.isBusy = false;
  }

  private async restoreFromCloud(name: string): Promise<void> {
    this.isBusy = true;
    this.statusText = '从云端恢复...';
    this.applyWebDavConfig();
    try {
      const result = await BackupService.restoreFromWebDav(name);
      this.statusText = `恢复完成: ${result.books} 本书, ${result.sources} 个书源`;
      this.showToast('云端恢复成功');
    } catch (err) {
      this.statusText = '恢复失败: ' + (err as Error).message;
      this.showToast('恢复失败');
    }
    this.isBusy = false;
  }

  build() {
    Column() {
      // 顶部导航
      Row() {
        Text('< 返回').fontSize(16).fontColor('#0078D7').padding({ right: 12 })
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text('备份与恢复').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
      }.padding(16).width('100%')

      Scroll() {
        Column() {
          // 状态提示
          if (this.statusText) {
            Text(this.statusText).fontSize(13).fontColor('#888')
              .width('100%').padding({ left: 16, right: 16, bottom: 8 })
          }
          if (this.isBusy) {
            LoadingProgress().width(30).height(30).color('#0078D7').margin({ bottom: 8 })
          }

          // ===== WebDAV 配置 =====
          this.buildSection('🌩 WebDAV 云端配置')
          TextInput({ placeholder: '服务器地址', text: this.webDavUrl })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUrl = v; this.saveSetting_('webdav_url', v); })
          TextInput({ placeholder: '用户名', text: this.webDavUser })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUser = v; this.saveSetting_('webdav_user', v); })
          TextInput({ placeholder: '密码', text: this.webDavPwd })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .type(InputType.Password)
            .onChange((v: string) => { this.webDavPwd = v; this.savePassword_(v); })
          TextInput({ placeholder: '路径前缀', text: this.webDavPath })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavPath = v; this.saveSetting_('webdav_path', v); })
          Row() {
            Text('自动同步').fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.webDavAutoSync })
              .onChange((v) => { this.webDavAutoSync = v; this.saveSetting_('webdav_auto_sync', v); })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 6 })

          Button('测试 WebDAV 连接').fontSize(14).height(40).width('100%')
            .backgroundColor(this.webDavConnected ? '#4CAF50' : '#0078D7').fontColor('#FFF').borderRadius(8)
            .margin({ bottom: 6 }).onClick(() => { this.testConnection(); })

          // ===== 本地备份 =====
          this.buildSection('💾 本地备份')
          this.buildButton('备份到本地文件', '#0078D7', () => { this.backupToLocal(); })
          this.buildButton('从本地文件恢复（选 ZIP）', '#FF9800', () => { this.restoreFromLocal(); })

          // ===== 云端备份 =====
          this.buildSection('☁ 云端备份')
          this.buildButton('备份到云端', '#0078D7', () => { this.backupToCloud(); })

          Column() {
            Text('从云端恢复').fontSize(14).fontColor('#FF9800')
              .height(44).width('100%').textAlign(TextAlign.Center)
          }
          .borderRadius(8).width('100%').margin({ bottom: 6 })
          .backgroundColor(this.isDark ? '#333' : '#F0F0F0')
          .onClick(async () => {
            await this.listCloudBackups();
            if (this.backupNames.length > 0) {
              // 选择第一个备份恢复（简化版本）
              await this.restoreFromCloud(this.backupNames[this.backupNames.length - 1]);
            }
          })

          // 云端备份列表
          if (this.backupNames.length > 0) {
            this.buildSection('📋 可用备份')
            ForEach(this.backupNames, (name: string) => {
              Text(name).fontSize(13).fontColor('#0078D7')
                .padding({ left: 16, top: 6, bottom: 6 })
                .width('100%').onClick(() => { this.restoreFromCloud(name); })
            }, (name: string) => name)
          }

          // 底部间距
          Divider().height(30).color('transparent')
        }.width('100%').padding(16)
      }.layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  @Builder
  buildSection(title: string) {
    Text(title).fontSize(15).fontWeight(FontWeight.Bold)
      .width('100%').margin({ top: 16, bottom: 8 })
  }

  @Builder
  buildInput(label: string, value: string, onChange: (v: string) => void) {
    TextInput({ placeholder: label, text: value })
      .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
      .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
      .width('100%').margin({ bottom: 6 })
      .onChange(onChange)
  }

  @Builder
  buildButton(label: string, color: string, onClick: () => void) {
    Button(label).fontSize(14).height(44).width('100%')
      .backgroundColor(color).fontColor('#FFF').borderRadius(8)
      .margin({ bottom: 6 }).onClick(onClick)
  }
}
