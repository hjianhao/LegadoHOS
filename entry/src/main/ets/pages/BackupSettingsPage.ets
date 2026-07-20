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
import { AppTheme } from '../theme/AppTheme';
import { UiUtil } from '../util/UiUtil';
import { BackupService } from '../service/BackupService';
import { WebDavService, WebDavConfig } from '../service/WebDavService';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ThemeColors } from '../theme/ThemeColors';
import { AppTitleBar } from '../components/common/AppTitleBar';

// PersistentStorage 持久化 WebDAV 设置
PersistentStorage.persistProp('webdav_url', 'https://dav.jianguoyun.com/dav/');
PersistentStorage.persistProp('webdav_user', '');
PersistentStorage.persistProp('webdav_path', 'legadohos');
PersistentStorage.persistProp('webdav_auto_sync', false);
PersistentStorage.persistProp('webdav_sync_progress', true);
PersistentStorage.persistProp('webdav_sync_progress_plus', false);

@Entry
@Component
export struct BackupSettingsPage {
  @StorageLink('webdav_url') webDavUrl: string = 'https://dav.jianguoyun.com/dav/';
  @StorageLink('webdav_user') webDavUser: string = '';
  @State webDavPwd: string = '';
  @StorageLink('webdav_path') webDavPath: string = 'legadohos';
  @StorageLink('webdav_auto_sync') webDavAutoSync: boolean = false;
  @StorageLink('webdav_sync_progress') syncProgress: boolean = true;
  @StorageLink('webdav_sync_progress_plus') syncProgressPlus: boolean = false;

  @StorageLink('isDark') isDark: boolean = false;
  @State isBusy: boolean = false;
  @State statusText: string = '';
  @State backupNames: string[] = [];
  @State manualBackupName: string = '';

  aboutToAppear(): void {
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
    UiUtil.showToast(this.getUIContext(), { message: msg, duration: 1500 });
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
      await BackupService.backupToLocal(this.getUIContext().getHostContext()!);
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
      const result = await BackupService.restoreFromLocal(this.getUIContext().getHostContext()!);
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
      AppTitleBar({ title: $r('app.string.ui_dddaeefb0e'), onBack: () => { UiUtil.back(this.getUIContext()); } })

      Scroll() {
        Column() {
          if (this.statusText) {
            Text(this.statusText).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
              .width('100%').padding({ left: 16, right: 16, bottom: 8 })
          }
          if (this.isBusy) {
            LoadingProgress().width(30).height(30).color(ThemeColors.primary(this.isDark)).margin({ bottom: 8 })
          }

          // ===== WebDAV 配置 =====
          this.buildSection('🌩 WebDAV 云端配置')
          TextInput({ placeholder: $r('app.string.ui_2eb291f695'), text: this.webDavUrl })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUrl = v; })
          TextInput({ placeholder: $r('app.string.ui_a1aaf352cb'), text: this.webDavUser })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUser = v; })
          TextInput({ placeholder: $r('app.string.ui_c839a8ff17'), text: this.webDavPwd })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .type(InputType.Password)
            .onChange((v: string) => { this.webDavPwd = v; this.savePassword(v); })
          TextInput({ placeholder: $r('app.string.ui_5aa328deb8'), text: this.webDavPath })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavPath = v; })
          Row() {
            Text($r('app.string.ui_220e7111f6')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.webDavAutoSync })
              .onChange((v: boolean) => { this.webDavAutoSync = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 6 })
          Row() {
            Text($r('app.string.ui_64c9bc1502')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.syncProgress })
              .onChange((v: boolean) => { this.syncProgress = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
          Row() {
            Text($r('app.string.ui_c0fba8a4d5')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            Toggle({ type: ToggleType.Switch, isOn: this.syncProgressPlus })
              .onChange((v: boolean) => { this.syncProgressPlus = v; })
          }.width('100%').padding({ left: 16, right: 16, top: 2, bottom: 6 })

          Button($r('app.string.ui_721d1ee6c8')).fontSize(14).height(40).width('100%')
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .margin({ bottom: 6 }).onClick(() => { this.testConnection(); })

          // ===== 本地备份 =====
          this.buildSection('💾 本地备份')
          this.buildButton('备份到本地文件', ThemeColors.primary(this.isDark), () => { this.backupToLocal(); })
          this.buildButton('从本地文件恢复（选 ZIP）', ThemeColors.warning(this.isDark), () => { this.restoreFromLocal(); })

          // ===== 云端备份 =====
          this.buildSection('☁ 云端备份')
          this.buildButton('备份到云端', ThemeColors.primary(this.isDark), () => { this.backupToCloud(); })
          Button($r('app.string.ui_b75af5b178')).fontSize(14).height(44).width('100%')
            .backgroundColor(ThemeColors.warning(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .margin({ bottom: 6 }).onClick(async () => {
              await this.listCloudBackups();
              // 备份列表已显示在下方，用户点击具体条目恢复
            })

          Text($r('app.string.ui_18fb6a0eb7')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%').margin({ top: 8, bottom: 4 })
          Row() {
            TextInput({ placeholder: $r('app.string.ui_598dd1606f'), text: this.manualBackupName })
              .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .layoutWeight(1)
              .onChange((v: string) => { this.manualBackupName = v; })
            Blank().width(8)
            Button($r('app.string.ui_79748ca1c6')).fontSize(13).height(40).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(8)
              .onClick(() => {
                const name = this.manualBackupName.trim();
                if (name) this.restoreFromCloud(name);
                else this.showToast('请输入备份文件名');
              })
          }.width('100%')

          if (this.backupNames.length > 0) {
            this.buildSection('可用备份')
            ForEach(this.backupNames, (name: string) => {
              Text(name).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
                .padding({ left: 16, top: 6, bottom: 6 })
                .width('100%').onClick(() => { this.restoreFromCloud(name); })
            }, (name: string) => name)
          }

          Divider().height(30).color(ThemeColors.transparent())
        }.width('100%').padding(16)
      }.layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  buildSection(title: string) {
    Text(title).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(15).fontWeight(FontWeight.Bold)
      .width('100%').margin({ top: 16, bottom: 8 })
  }

  @Builder
  buildButton(label: string, color: string, onClick: () => void) {
    Button(label).fontSize(14).height(44).width('100%')
      .backgroundColor(color).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
      .margin({ bottom: 6 }).onClick(onClick)
  }
}
