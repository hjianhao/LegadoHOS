/**
 * 备份与恢复设置页
 *
 * - WebDAV 云端配置
 * - 本地/云端备份恢复
 * - 自动备份、检测新备份、仅最新、设备名、恢复忽略
 */
import { UiUtil } from '../util/UiUtil';
import { BackupService, ImportResult, RestoreIgnoreConfig } from '../service/BackupService';
import { WebDavService } from '../service/WebDavService';
import { BackupConfig, BackupSyncMode } from '../service/backup/BackupConfig';
import { ThemeColors } from '../theme/ThemeColors';
import { AppTitleBar } from '../components/common/AppTitleBar';
import { WindowLayout } from '../util/WindowLayout';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { common } from '@kit.AbilityKit';

// PersistentStorage 持久化 WebDAV / 备份设置
PersistentStorage.persistProp('webdav_url', 'https://dav.jianguoyun.com/dav/');
PersistentStorage.persistProp('webdav_user', '');
PersistentStorage.persistProp('webdav_password', '');
PersistentStorage.persistProp('webdav_path', 'legado');
PersistentStorage.persistProp('webdav_auto_sync', false);
PersistentStorage.persistProp('webdav_sync_progress', true);
PersistentStorage.persistProp('webdav_sync_progress_plus', false);
BackupConfig.ensurePersistentProps();

@Entry
@Component
export struct BackupSettingsPage {
  @StorageLink('webdav_url') webDavUrl: string = 'https://dav.jianguoyun.com/dav/';
  @StorageLink('webdav_user') webDavUser: string = '';
  @StorageLink('webdav_password') webDavPwd: string = '';
  @StorageLink('webdav_path') webDavPath: string = 'legado';
  @StorageLink('webdav_auto_sync') webDavAutoSync: boolean = false;
  @StorageLink('webdav_sync_progress') syncProgress: boolean = true;
  @StorageLink('webdav_sync_progress_plus') syncProgressPlus: boolean = false;

  @StorageLink('backup_device_name') deviceName: string = '';
  @State autoDeviceName: string = '';
  @StorageLink('backup_only_latest') onlyLatest: boolean = true;
  @StorageLink('backup_auto') autoBackup: boolean = true;
  @StorageLink('backup_auto_check_new') autoCheckNew: boolean = true;
  @StorageLink('backup_sync_mode') syncMode: string = 'both';

  @StorageLink('isDark') isDark: boolean = false;
  @State isBusy: boolean = false;
  @State statusText: string = '';
  @State backupNames: string[] = [];
  @State manualBackupName: string = '';
  @State showIgnorePanel: boolean = false;
  @State ignoreLocalBook: boolean = false;
  @State ignoreReadConfig: boolean = false;
  @State ignoreThemeMode: boolean = false;
  @State ignoreThemeConfig: boolean = false;
  @State ignoreBookshelfLayout: boolean = false;
  @State ignoreShowRss: boolean = false;
  @State ignoreThreadCount: boolean = false;
  @State ignoreCoverConfig: boolean = false;

  aboutToAppear(): void {
    BackupConfig.ensurePersistentProps();
    WebDavService.ensurePersistentProps();
    this.autoDeviceName = BackupConfig.detectSystemDeviceName();
    this.loadIgnore_();
    this.hydratePasswordFromSecureStore_();
  }

  private loadIgnore_(): void {
    const ig = BackupConfig.getIgnoreConfig();
    this.ignoreLocalBook = ig.localBook;
    this.ignoreReadConfig = ig.readConfig;
    this.ignoreThemeMode = ig.themeMode;
    this.ignoreThemeConfig = ig.themeConfig;
    this.ignoreBookshelfLayout = ig.bookshelfLayout;
    this.ignoreShowRss = ig.showRss;
    this.ignoreThreadCount = ig.threadCount;
    this.ignoreCoverConfig = ig.coverConfig;
  }

  private currentIgnore_(): RestoreIgnoreConfig {
    return {
      localBook: this.ignoreLocalBook,
      readConfig: this.ignoreReadConfig,
      themeMode: this.ignoreThemeMode,
      themeConfig: this.ignoreThemeConfig,
      bookshelfLayout: this.ignoreBookshelfLayout,
      showRss: this.ignoreShowRss,
      threadCount: this.ignoreThreadCount,
      coverConfig: this.ignoreCoverConfig,
    };
  }

  private saveIgnore_(): void {
    BackupConfig.saveIgnoreConfig(this.currentIgnore_());
  }

  private async hydratePasswordFromSecureStore_(): Promise<void> {
    try {
      if (this.webDavPwd) {
        this.applyWebDavConfig();
        return;
      }
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.Context;
      const s = SettingsStore.getInstance();
      if (ctx) await s.init(ctx);
      const pwd = await s.getWebDavPassword();
      if (pwd) {
        this.webDavPwd = pwd;
      }
      this.applyWebDavConfig();
    } catch (e) {
      console.warn('[BackupSettings] hydrate password failed:', (e as Error).message);
    }
  }

  private applyWebDavConfig(): void {
    const user = AppStorage.get<string>('webdav_user') || this.webDavUser || '';
    const url = AppStorage.get<string>('webdav_url') || this.webDavUrl || 'https://dav.jianguoyun.com/dav/';
    const path = AppStorage.get<string>('webdav_path') || this.webDavPath || 'legado';
    const autoSync = AppStorage.get<boolean>('webdav_auto_sync') ?? this.webDavAutoSync;
    const pwd = AppStorage.get<string>('webdav_password') || this.webDavPwd || '';
    WebDavService.getInstance().configure({
      serverUrl: url,
      username: user,
      password: pwd,
      path: path,
      autoSync: autoSync,
      syncInterval: 60,
    });
  }

  private async persistWebDavPassword_(): Promise<void> {
    const pwd = AppStorage.get<string>('webdav_password') || this.webDavPwd || '';
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.Context;
      const s = SettingsStore.getInstance();
      if (ctx) {
        await s.init(ctx);
      }
      await s.setWebDavPassword(pwd);
    } catch (e) {
      console.warn('[BackupSettings] save webdav password failed:', (e as Error).message);
    }
    this.applyWebDavConfig();
  }

  private showToast(msg: string): void {
    UiUtil.showToast(this.getUIContext(), { message: msg, duration: 1500 });
  }

  private formatResult(result: ImportResult): string {
    let msg = `恢复完成(${result.format}): 书${result.books} 源${result.sources} 规则${result.rules}` +
      ` 分组${result.groups} 书签${result.bookmarks} RSS${result.rss}`;
    if (result.cloudSources > 0) {
      msg += ` 云书库${result.cloudSources}`;
    }
    msg += ` 跳过${result.skipped}`;
    if (result.errors.length > 0) {
      msg += ` 错误${result.errors.length}`;
    }
    if (result.cloudSourcesNeedPassword > 0) {
      msg += `（${result.cloudSourcesNeedPassword} 个云端书库需重新填写密码）`;
    }
    return msg;
  }

  private notifyCloudCredentialIfNeeded_(result: ImportResult): void {
    if (result.cloudSourcesNeedPassword > 0) {
      this.showToast(`有 ${result.cloudSourcesNeedPassword} 个云端书库需重新填写密码（我的→云端书库管理）`);
    }
  }

  private async testConnection(): Promise<void> {
    this.isBusy = true;
    this.statusText = '测试连接中...';
    await this.persistWebDavPassword_();
    try {
      const ok = await WebDavService.getInstance().testConnection();
      this.statusText = ok ? '连接成功 ✓' : '连接失败 ✗';
      this.showToast(ok ? 'WebDAV 连接成功' : '连接失败，请检查配置');
    } catch (err) {
      this.statusText = '连接失败: ' + (err as Error).message;
      this.showToast('连接失败');
    }
    this.isBusy = false;
  }

  private async backupToLocal(): Promise<void> {
    this.isBusy = true;
    this.statusText = '导出本地备份...';
    try {
      const name = await BackupService.backupToLocal(this.getUIContext().getHostContext()!);
      this.statusText = `本地备份已保存: ${name} ✓`;
      this.showToast('本地备份成功');
    } catch (err) {
      this.statusText = '备份失败: ' + (err as Error).message;
      this.showToast('备份失败');
    }
    this.isBusy = false;
  }

  private async restoreFromLocal(): Promise<void> {
    this.isBusy = true;
    this.statusText = '从本地恢复...';
    this.saveIgnore_();
    try {
      const result = await BackupService.restoreFromLocal(
        this.getUIContext().getHostContext()!,
        this.currentIgnore_()
      );
      if (result) {
        this.statusText = this.formatResult(result);
        this.showToast('恢复成功');
        this.notifyCloudCredentialIfNeeded_(result);
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
    await this.persistWebDavPassword_();
    try {
      const name = await BackupService.backupToWebDav();
      this.statusText = `已上传: ${name} ✓`;
      this.showToast('云端备份成功');
      await this.listCloudBackups(false);
    } catch (err) {
      this.statusText = '上传失败: ' + (err as Error).message;
      this.showToast('上传失败');
    }
    this.isBusy = false;
  }

  private async backupBoth(): Promise<void> {
    this.isBusy = true;
    this.statusText = '本地+云端备份中...';
    await this.persistWebDavPassword_();
    try {
      const name = await BackupService.backupByMode(this.getUIContext().getHostContext()!, 'both');
      this.statusText = `备份完成: ${name} ✓`;
      this.showToast('备份完成');
      await this.listCloudBackups(false);
    } catch (err) {
      this.statusText = '备份失败: ' + (err as Error).message;
      this.showToast('备份失败');
    }
    this.isBusy = false;
  }

  private async listCloudBackups(showStatus: boolean = true): Promise<void> {
    if (showStatus) {
      this.isBusy = true;
      this.statusText = '加载云端备份列表...';
    }
    await this.persistWebDavPassword_();
    try {
      const files = await WebDavService.getInstance().listBackups();
      this.backupNames = files.map(f => f.name);
      if (showStatus) {
        this.statusText = files.length > 0 ? `找到 ${files.length} 个云端备份` : '未找到备份文件';
        if (files.length === 0) this.showToast('云端暂无备份文件（可手动输入文件名恢复）');
      }
    } catch (err) {
      if (showStatus) this.statusText = '加载失败: ' + (err as Error).message;
    }
    if (showStatus) this.isBusy = false;
  }

  private async restoreFromCloud(name: string): Promise<void> {
    this.isBusy = true;
    this.statusText = `从云端恢复: ${name} ...`;
    this.saveIgnore_();
    await this.persistWebDavPassword_();
    try {
      const result = await BackupService.restoreFromWebDav(name, this.currentIgnore_());
      this.statusText = this.formatResult(result);
      this.showToast('云端恢复成功');
      this.notifyCloudCredentialIfNeeded_(result);
    } catch (err) {
      console.error('[BackupSettings] restoreFromCloud failed:', (err as Error).message);
      this.statusText = '恢复失败: ' + (err as Error).message;
      this.showToast('恢复失败');
    }
    this.isBusy = false;
  }

  private modeLabel(): string {
    if (this.syncMode === 'local') return '仅本地';
    if (this.syncMode === 'webdav') return '仅云端';
    return '本地+云端';
  }

  private cycleMode(): void {
    const next: BackupSyncMode =
      this.syncMode === 'both' ? 'local' : (this.syncMode === 'local' ? 'webdav' : 'both');
    this.syncMode = next;
    BackupConfig.setBackupSyncMode(next);
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
          this.buildSection('WebDAV 云端配置')
          TextInput({ placeholder: '服务器地址', text: this.webDavUrl })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUrl = v; this.applyWebDavConfig(); })
          TextInput({ placeholder: '账号', text: this.webDavUser })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavUser = v; this.applyWebDavConfig(); })
          TextInput({ placeholder: '密码', text: this.webDavPwd })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .type(InputType.Password)
            .onChange((v: string) => {
              this.webDavPwd = v;
              this.persistWebDavPassword_();
            })
          TextInput({ placeholder: '目录（默认 legado）', text: this.webDavPath })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 6 })
            .onChange((v: string) => { this.webDavPath = v; this.applyWebDavConfig(); })
          Text('设备名（默认自动获取，可手动覆盖）')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%').margin({ bottom: 4 })
          TextInput({
            placeholder: this.autoDeviceName ? ('自动: ' + this.autoDeviceName) : '自动获取设备名',
            text: this.deviceName
          })
            .height(48).fontSize(14).borderRadius(12).padding({ left: 12 })
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').margin({ bottom: 4 })
            .onChange((v: string) => {
              this.deviceName = v;
              BackupConfig.setDeviceName(v);
            })
          Row() {
            Text(this.deviceName.trim().length > 0
              ? ('当前使用手动名: ' + this.deviceName.trim())
              : ('当前自动: ' + (this.autoDeviceName || 'harmony')))
              .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
              .layoutWeight(1)
            if (this.deviceName.trim().length > 0) {
              Button('恢复自动').fontSize(12).height(28)
                .backgroundColor(ThemeColors.outlineVariant(this.isDark))
                .fontColor(ThemeColors.primary(this.isDark))
                .onClick(() => {
                  this.deviceName = '';
                  BackupConfig.clearManualDeviceName();
                  this.autoDeviceName = BackupConfig.detectSystemDeviceName();
                })
            }
          }.width('100%').padding({ left: 4, right: 4, bottom: 6 })

          this.buildToggleRow('自动备份（24小时）', this.autoBackup, (v: boolean) => {
            this.autoBackup = v;
            this.webDavAutoSync = v;
            BackupConfig.setAutoBackup(v);
          })
          this.buildToggleRow('启动检测云端新备份', this.autoCheckNew, (v: boolean) => {
            this.autoCheckNew = v;
            BackupConfig.setAutoCheckNewBackup(v);
          })
          this.buildToggleRow('仅保留最新本地备份名', this.onlyLatest, (v: boolean) => {
            this.onlyLatest = v;
            BackupConfig.setOnlyLatestBackup(v);
          })
          this.buildToggleRow('同步阅读进度', this.syncProgress, (v: boolean) => {
            this.syncProgress = v;
          })
          this.buildToggleRow('增强进度同步', this.syncProgressPlus, (v: boolean) => {
            this.syncProgressPlus = v;
          })

          Row() {
            Text('备份模式：' + this.modeLabel())
              .fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14)
              .layoutWeight(1)
            Button('切换').fontSize(13).height(32)
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .fontColor(ThemeColors.primary(this.isDark))
              .onClick(() => { this.cycleMode(); })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 6 })

          Button('测试连接').fontSize(14).height(40).width('100%')
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .margin({ bottom: 6 }).onClick(() => { this.testConnection(); })

          // ===== 本地备份 =====
          this.buildSection('本地备份')
          this.buildButton('备份到本地文件', ThemeColors.primary(this.isDark), () => { this.backupToLocal(); })
          this.buildButton('从本地文件恢复（选 ZIP）', ThemeColors.warning(this.isDark), () => { this.restoreFromLocal(); })

          // ===== 云端备份 =====
          this.buildSection('云端备份')
          this.buildButton('备份到云端', ThemeColors.primary(this.isDark), () => { this.backupToCloud(); })
          this.buildButton('本地+云端备份', ThemeColors.primary(this.isDark), () => { this.backupBoth(); })
          this.buildButton('加载云端备份列表', ThemeColors.warning(this.isDark), () => { this.listCloudBackups(); })

          Text('也可手动输入备份文件名恢复')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%').margin({ top: 8, bottom: 4 })
          Row() {
            TextInput({ placeholder: 'backup2026-07-22.zip', text: this.manualBackupName })
              .height(40).fontSize(14).borderRadius(8).padding({ left: 12 })
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .layoutWeight(1)
              .onChange((v: string) => { this.manualBackupName = v; })
            Blank().width(8)
            Button('恢复').fontSize(13).height(40).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(8)
              .onClick(() => {
                const name = this.manualBackupName.trim();
                if (name) this.restoreFromCloud(name);
                else this.showToast('请输入备份文件名');
              })
          }.width('100%')

          if (this.backupNames.length > 0) {
            this.buildSection('可用备份（点击恢复）')
            ForEach(this.backupNames, (name: string) => {
              Text(name).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
                .padding({ left: 16, top: 6, bottom: 6 })
                .width('100%').onClick(() => { this.restoreFromCloud(name); })
            }, (name: string) => name)
          }

          // ===== 恢复忽略 =====
          this.buildSection('恢复忽略项')
          Text('本地书默认策略：仅当本机文件路径仍存在时才恢复；文件不在则自动跳过。')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%').margin({ bottom: 4 })
          this.buildToggleRow('显示忽略设置', this.showIgnorePanel, (v: boolean) => {
            this.showIgnorePanel = v;
          })
          if (this.showIgnorePanel) {
            this.buildToggleRow('始终忽略本地书（即使文件仍在）', this.ignoreLocalBook, (v: boolean) => {
              this.ignoreLocalBook = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略阅读配置', this.ignoreReadConfig, (v: boolean) => {
              this.ignoreReadConfig = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略主题模式', this.ignoreThemeMode, (v: boolean) => {
              this.ignoreThemeMode = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略主题配置', this.ignoreThemeConfig, (v: boolean) => {
              this.ignoreThemeConfig = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略封面配置', this.ignoreCoverConfig, (v: boolean) => {
              this.ignoreCoverConfig = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略书架布局', this.ignoreBookshelfLayout, (v: boolean) => {
              this.ignoreBookshelfLayout = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略 RSS 显示', this.ignoreShowRss, (v: boolean) => {
              this.ignoreShowRss = v; this.saveIgnore_();
            })
            this.buildToggleRow('忽略线程数', this.ignoreThreadCount, (v: boolean) => {
              this.ignoreThreadCount = v; this.saveIgnore_();
            })
          }

          Text('说明：鸿蒙设备之间完整恢复；与安卓为书/源/分组/书签/规则/RSS/进度等核心子集兼容。')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%').margin({ top: 12, bottom: 20 })

          Divider().height(30).color(ThemeColors.transparent())
        }.width('100%').padding(16)
        .constraintSize({ maxWidth: WindowLayout.isWide ? 640 : Number.MAX_SAFE_INTEGER })
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

  @Builder
  buildToggleRow(label: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}
