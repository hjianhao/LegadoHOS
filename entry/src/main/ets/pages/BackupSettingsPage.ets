/**
 * 备份与恢复设置页
 *
 * 功能：
 * - WebDAV 云端配置（服务器、账号、密码、路径）
 * - 本地备份/恢复（通过文件选择器）
 * - 云端备份/恢复（通过 WebDAV）
 *
 * 持久化：使用 PersistentStorage 跨重启持久化
 */
import promptAction from '@ohos.promptAction';
import { AppTheme } from '../theme/AppTheme';
import { UiUtil } from '../util/UiUtil';
import { BackupService } from '../service/BackupService';
import { WebDavService, WebDavConfig } from '../service/WebDavService';
import { SettingsStore } from '../data/preferences/SettingsStore';

// PersistentStorage 持久化 WebDAV 设置
PersistentStorage.persistProp('webdav_url', 'https://dav.jianguoyun.com/dav/');
PersistentStorage.persistProp('webdav_user', '');
PersistentStorage.persistProp('webdav_path', 'legadohos');
PersistentStorage.persistProp('webdav_auto_sync', false);
PersistentStorage.persistProp('webdav_sync_progress', true);
PersistentStorage.persistProp('webdav_sync_progress_plus', false);

@Entry
@Component
struct BackupSettingsPage {
  @StorageLink('webdav_url') webDavUrl: string = 'https://dav.jianguoyun.com/dav/';
  @StorageLink('webdav_user') webDavUser: string = '';
  @State webDavPwd: string = '';
  @StorageLink('webdav_path') webDavPath: string = 'legadohos';
  @StorageLink('webdav_auto_sync') webDavAutoSync: boolean = false;
  @StorageLink('webdav_sync_progress') syncProgress: boolean = true;
  @StorageLink('webdav_sync_progress_plus') syncProgressPlus: boolean = false;

  @State isDark: boolean = false;
  @State isBusy: boolean = false;
  @State statusText: string = '';
  @State backupNames: string[] = [];
  @State manualBackupName: string = '';

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    // 从 SettingsStore 加载加密的密码
    this.loadPassword();
  }

  private async loadPassword(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      try { await s.init(UiUtil.getHostContext(this.getUIContext())); } catch (_) {}
      this.webDavPwd = await s.getWebDavPassword();
    } catch (_) { /* ignore */ }
  }

  private async savePassword(pwd: string): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      try { await s.init(UiUtil.getHostContext(this.getUIContext())); } catch (_) {}
      await s.setWebDavPassword(pwd);
    } catch (_) { /* ignore */ }
  }

  private applyWebDavConfig(): void {
    // 直接从 AppStorage 读取（避免 @StorageLink 同步延迟问题）
    const user = AppStorage.get<string>('webdav_user') || this.webDavUser || '';
    const url = AppStorage.get<string>('webdav_url') || this.webDavUrl || 'https://dav.jianguoyun.com/dav/';
    const path = AppStorage.get<string>('webdav_path') || this.webDavPath || 'legadohos';
    const autoSync = AppStorage.get<boolean>('webdav_auto_sync') ?? this.webDavAutoSync;
    WebDavService.getInstance().configure({
      serverUrl: url,
      username: user,
      password: this.webDavPwd,
      path: path,
      autoSync: autoSync,
      syncInterval: 60,
    });
  }

  private showToast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1500 });
  }

  private async testConnection(): Promise<void> {
    this.isBusy = true;
    this.statusText = '测试连接中...';
    this.applyWebDavConfig();
    try {
      const ok = await WebDavService.getInstance().testConnection();
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

  /**
   * 通过 WebDAV PROPFIND 获取云端备份文件列表
   */
  private async listCloudBackups(): Promise<void> {
    this.isBusy = true;
    this.statusText = '加载云端备份列表...';
    this.applyWebDavConfig();
    try {
      const files = await WebDavService.getInstance().listBackups();
      this.backupNames = files.map(f => f.name);
      this.statusText = files.length > 0 ? `找到 ${files.length} 个云端备份` : '未找到备份文件';
      if (files.length === 0) this.showToast('云端暂无备份文件（可手动输入文件名恢复）');
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
      console.error('[BackupSettings] restoreFromCloud failed:', (err as Error).message);
      this.statusText = '恢复失败: ' + (err as Error).message;
      this.showToast('恢复失败');
    }
    this.isBusy = false;
  }

  build() {
    Column() {
      Row() {
        Text('< 返回').fontSize(16).fontColor('#0078D7').padding({ right: 12 })
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text('备份与恢复').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
      }.padding(16).width('100%')

      Scroll() {
        Column() {
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
            .onChange((v: string) => { this.webDavUrl = v; })
          TextInput({ placeholder: '用户名', text: this.webDavUser })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUser = v; })
          TextInput({ placeholder: '密码', text: this.webDavPwd })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .type(InputType.Password)
            .onChange((v: string) => { this.webDavPwd = v; this.savePassword(v); })
          TextInput({ placeholder: '路径前缀', text: this.webDavPath })
            .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
            .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavPath = v; })
          Row() {
            Text('自动同步').fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.webDavAutoSync })
              .onChange((v: boolean) => { this.webDavAutoSync = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 6 })
          Row() {
            Text('同步阅读进度').fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.syncProgress })
              .onChange((v: boolean) => { this.syncProgress = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
          Row() {
            Text('增强同步').fontSize(12).fontColor('#888')
            Toggle({ type: ToggleType.Switch, isOn: this.syncProgressPlus })
              .onChange((v: boolean) => { this.syncProgressPlus = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 2, bottom: 6 })

          Button('测试 WebDAV 连接').fontSize(14).height(40).width('100%')
            .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(8)
            .margin({ bottom: 6 }).onClick(() => { this.testConnection(); })

          // ===== 本地备份 =====
          this.buildSection('💾 本地备份')
          this.buildButton('备份到本地文件', '#0078D7', () => { this.backupToLocal(); })
          this.buildButton('从本地文件恢复（选 ZIP）', '#FF9800', () => { this.restoreFromLocal(); })

          // ===== 云端备份 =====
          this.buildSection('☁ 云端备份')
          this.buildButton('备份到云端', '#0078D7', () => { this.backupToCloud(); })
          Button('从云端恢复').fontSize(14).height(44).width('100%')
            .backgroundColor('#FF9800').fontColor('#FFF').borderRadius(8)
            .margin({ bottom: 6 }).onClick(async () => {
              await this.listCloudBackups();
              // 备份列表已显示在下方，用户点击具体条目恢复
            })

          Text('手动输入备份文件名（跨设备恢复时使用）').fontSize(12).fontColor('#888')
            .width('100%').margin({ top: 8, bottom: 4 })
          Row() {
            TextInput({ placeholder: '如 backup_2026-07-03.zip', text: this.manualBackupName })
              .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
              .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
              .layoutWeight(1)
              .onChange((v: string) => { this.manualBackupName = v; })
            Blank().width(8)
            Button('恢复').fontSize(13).height(40).fontColor('#0078D7')
              .backgroundColor(this.isDark ? '#444' : '#E0E0E0').borderRadius(8)
              .onClick(() => {
                const name = this.manualBackupName.trim();
                if (name) this.restoreFromCloud(name);
                else this.showToast('请输入备份文件名');
              })
          }.width('100%')

          if (this.backupNames.length > 0) {
            this.buildSection('📋 可用备份')
            ForEach(this.backupNames, (name: string) => {
              Text(name).fontSize(13).fontColor('#0078D7')
                .padding({ left: 16, top: 6, bottom: 6 })
                .width('100%').onClick(() => { this.restoreFromCloud(name); })
            }, (name: string) => name)
          }

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
  buildButton(label: string, color: string, onClick: () => void) {
    Button(label).fontSize(14).height(44).width('100%')
      .backgroundColor(color).fontColor('#FFF').borderRadius(8)
      .margin({ bottom: 6 }).onClick(onClick)
  }
}
