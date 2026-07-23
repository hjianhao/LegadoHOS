/**
 * 主 UIAbility
 *
 * 负责应用生命周期管理：
 * - onCreate: 启动数据库和主题初始化
 * - onWindowStageCreate: 加载首页
 */
import UIAbility from '@ohos.app.ability.UIAbility';
import { Want, AbilityConstant, Configuration } from '@kit.AbilityKit';
import Window from '@ohos.window';
import display from '@ohos.display';
import { AppDatabase } from '../data/database/AppDatabase';
import { AppTheme } from '../theme/AppTheme';
import { GlobalConfig } from '../data/preferences/GlobalConfig';
import { WebDavService } from '../service/WebDavService';
import { BackupService } from '../service/BackupService';
import { BackupConfig } from '../service/backup/BackupConfig';
import { CookieStore } from '../util/CookieStore';
import { LoginInfoStore } from '../util/LoginInfoStore';
import { ShareImportService } from '../service/ShareImportService';
import { WindowLayout } from '../util/WindowLayout';
import { ensureCloudProvidersRegistered } from '../service/cloud/CloudProviderBootstrap';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { AppContextHolder } from '../util/AppContext';
import { CloudLocalFileStore } from '../service/cloud/CloudLocalFileStore';

export default class MainAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[MainAbility] onCreate');
    // 通过「打开方式/分享」冷启动：解析文件并广播给页面
    ShareImportService.handleWant(want, this.context);
    // 提前启动异步初始化
    this.initServices();
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[MainAbility] onNewWant');
    // 应用已运行时再收到「打开方式/分享」
    ShareImportService.handleWant(want, this.context);
  }

  private async initServices(): Promise<void> {
    // 全局 Context，供云端下载/本地书路径使用
    AppContextHolder.set(this.context);
    // 读取当前系统色模式，传递给 AppTheme 初始化
    let systemDark = false;
    try {
      // UIAbilityContext.config.colorMode — 0=DARK, 1=LIGHT
      const cfg: Configuration = this.context.config;
      if (cfg !== undefined && cfg !== null) {
        systemDark = cfg.colorMode === 0;
      }
    } catch (_e) {
      console.warn('[MainAbility] unable to read system color mode');
    }
    try {
      await AppDatabase.getInstance().init(this.context);
      console.info('[MainAbility] Database initialized');
    } catch (err) {
      console.error('[MainAbility] Database init failed:', err);
    }
    try {
      await AppTheme.getInstance().init(this.context, systemDark);
      console.info('[MainAbility] Theme initialized');
    } catch (err) {
      console.warn('[MainAbility] Theme init failed:', err);
    }
    try {
      await GlobalConfig.getInstance().load();
      console.info('[MainAbility] GlobalConfig loaded');
    } catch (err) {
      console.warn('[MainAbility] GlobalConfig load failed:', err);
    }
    try {
      await CookieStore.getInstance().init(this.context);
      await LoginInfoStore.getInstance().init(this.context);
      // 2026-07 之前的优书网登录可能在 Preferences 中留下明文密码。
      // 新版只保存 Cookie 会话，启动时立即清理旧凭据。
      await LoginInfoStore.getInstance().remove('https://www.youshu.me');
      console.info('[MainAbility] CookieStore/LoginInfoStore initialized');
    } catch (err) {
      console.warn('[MainAbility] Cookie/LoginInfo store init failed:', err);
    }
    // 启动时恢复 WebDav 配置（进度同步的前提）
    try {
      await WebDavService.getInstance().initFromStorage(this.context);
    } catch (err) {
      console.warn('[MainAbility] WebDav config restore failed:', err);
    }
    // 云端书库凭证存储（独立 Preferences，需 Context）
    try {
      await SettingsStore.getInstance().init(this.context);
      await CloudCredentialStore.getInstance().init(this.context);
      console.info('[MainAbility] CloudCredentialStore initialized');
    } catch (err) {
      console.warn('[MainAbility] CloudCredentialStore init failed:', err);
    }
    // 注册云端书库 Provider（WebDAV）
    try {
      ensureCloudProvidersRegistered();
    } catch (err) {
      console.warn('[MainAbility] Cloud providers register failed:', err);
    }
    // 清理云端下载残留临时文件
    try {
      CloudLocalFileStore.getInstance().ensureDirs();
      CloudLocalFileStore.getInstance().cleanupStaleTempFiles();
    } catch (err) {
      console.warn('[MainAbility] CloudLocalFileStore cleanup failed:', err);
    }
    // 启动时批量同步云端阅读进度
    this.syncProgressFromCloud();
    // 启动检测云端是否有更新备份
    this.checkNewCloudBackupOnLaunch();
  }

  private checkNewCloudBackupOnLaunch(): void {
    try {
      BackupConfig.ensurePersistentProps();
      BackupService.checkNewCloudBackup()
        .then((info) => {
          if (!info) return;
          console.info('[MainAbility] newer cloud backup found:', info.name, info.lastModified);
          // 通过 AppStorage 广播，设置页/书架可弹确认；此处先记日志避免强打断
          AppStorage.setOrCreate<string>('pending_cloud_backup_name', info.name);
          AppStorage.setOrCreate<number>('pending_cloud_backup_flag', Date.now());
        })
        .catch((e: Error) => console.warn('[MainAbility] check new backup failed:', e.message));
    } catch (e) {
      console.warn('[MainAbility] check new backup error:', (e as Error).message);
    }
  }

  /** 从云端批量下载所有在架书籍的阅读进度 */
  private syncProgressFromCloud(): void {
    try {
      // 启动时先注册 PersistentStorage 键，避免 webdav_sync_progress 为 undefined
      WebDavService.ensurePersistentProps();
      if (!WebDavService.isProgressSyncEnabled()) {
        console.info('[MainAbility] Cloud progress sync disabled');
        return;
      }
      if (!WebDavService.getInstance().isConfigured()) {
        console.info('[MainAbility] Cloud progress sync skipped: WebDAV not configured');
        return;
      }
      WebDavService.getInstance().downloadAllBookProgress()
        .then((updated: number) => {
          console.info('[MainAbility] Cloud progress sync done, updated=' + updated);
          if (updated > 0) {
            // 通知书架刷新
            const cur = AppStorage.get<number>('shelfRefreshCounter') || 0;
            AppStorage.setOrCreate<number>('shelfRefreshCounter', cur + 1);
          }
        })
        .catch((e: Error) => console.warn('[MainAbility] Cloud progress sync failed:', e.message));
    } catch (e) {
      console.warn('[MainAbility] Cloud progress sync error:', (e as Error).message);
    }
  }

  onDestroy(): void {
    console.info('[MainAbility] onDestroy');
    try {
      BackupService.autoBack().catch((e: Error) => console.warn('[MainAbility] autoBack onDestroy:', e.message));
    } catch (_e) { /* ignore */ }
  }

  onWindowStageCreate(windowStage: Window.WindowStage): void {
    console.info('[MainAbility] onWindowStageCreate');
    try {
      AppStorage.setOrCreate<object>('abilityContext', this.context);
      WindowLayout.ensureAppStorageKeys();
      // 先 display 再 window，保证首帧前 AppStorage 已是宽屏
      this.applyDisplaySize();
      this.bindWindowLayout(windowStage);
      windowStage.loadContent('pages/MainPage');
    } catch (err) {
      console.error('[MainAbility] loadContent failed:', err);
    }
  }

  /**
   * 从主窗口同步宽高到 WindowLayout，并监听旋转/分屏。
   * 日志中真机平板 window rect 为 2800x1840 px @ density≈2.5 → ~1120vp（应走宽屏）。
   */
  private bindWindowLayout(windowStage: Window.WindowStage): void {
    try {
      // API 12+：同步取主窗口
      const win: Window.Window = windowStage.getMainWindowSync();
      this.applyWindowSize(win);
      try {
        win.on('windowSizeChange', (size: Size) => {
          // windowSizeChange 回调单位为 px
          WindowLayout.updateFromPx(size.width, size.height, this.readDensity());
        });
      } catch (e) {
        console.warn('[MainAbility] windowSizeChange subscribe failed:', e);
      }
      return;
    } catch (e1) {
      console.warn('[MainAbility] getMainWindowSync failed:', e1);
    }
    // 回退 Promise 接口
    try {
      windowStage.getMainWindow().then((win: Window.Window) => {
        this.applyWindowSize(win);
        try {
          win.on('windowSizeChange', (size: Size) => {
            WindowLayout.updateFromPx(size.width, size.height, this.readDensity());
          });
        } catch (_e) {
          // ignore
        }
      }).catch((e: Error) => {
        console.warn('[MainAbility] getMainWindow failed:', e?.message ?? e);
        this.applyDisplaySize();
      });
    } catch (e2) {
      console.warn('[MainAbility] bindWindowLayout fallback display:', e2);
      this.applyDisplaySize();
    }
  }

  private applyWindowSize(win: Window.Window): void {
    try {
      const rect = win.getWindowProperties().windowRect;
      const density = this.readDensity();
      console.info('[MainAbility] windowRect px=' + rect.width + 'x' + rect.height +
        ' density=' + density);
      WindowLayout.updateFromPx(rect.width, rect.height, density);
    } catch (e) {
      console.warn('[MainAbility] applyWindowSize failed:', e);
      this.applyDisplaySize();
    }
  }

  private applyDisplaySize(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels > 0 ? d.densityPixels : 1;
      console.info('[MainAbility] display px=' + d.width + 'x' + d.height +
        ' density=' + density);
      WindowLayout.updateFromPx(d.width, d.height, density);
    } catch (e) {
      console.warn('[MainAbility] applyDisplaySize failed:', e);
    }
  }

  private readDensity(): number {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.densityPixels > 0.1) {
        return d.densityPixels;
      }
    } catch (_e) {
      // ignore
    }
    return 2.5;
  }

  onWindowStageDestroy(): void {
    console.info('[MainAbility] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[MainAbility] onForeground');
    this.syncProgressFromCloud();
  }

  onBackground(): void {
    console.info('[MainAbility] onBackground');
    // 对齐安卓：生命周期机会点触发自动备份（24h 节流）
    try {
      BackupService.autoBack()
        .then((did) => {
          if (did) console.info('[MainAbility] autoBack uploaded');
        })
        .catch((e: Error) => console.warn('[MainAbility] autoBack failed:', e.message));
    } catch (e) {
      console.warn('[MainAbility] autoBack error:', (e as Error).message);
    }
  }

  /** 系统色模式切换时自动更新 */
  onConfigurationUpdate(newConfig: Configuration): void {
    console.info('[MainAbility] onConfigurationUpdate colorMode=', newConfig.colorMode);
    // HarmonyOS: 0=DARK, 1=LIGHT
    AppTheme.getInstance().onSystemColorChange(newConfig.colorMode ?? 1);
  }
}
