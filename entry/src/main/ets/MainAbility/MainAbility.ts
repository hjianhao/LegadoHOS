/**
 * 主 UIAbility
 *
 * 负责应用生命周期管理：
 * - onCreate: 启动数据库和主题初始化
 * - onWindowStageCreate: 加载首页
 */
import UIAbility from '@ohos.app.ability.UIAbility';
import Window from '@ohos.window';
import { AppDatabase } from '../data/database/AppDatabase';
import { AppTheme } from '../theme/AppTheme';
import { GlobalConfig } from '../data/preferences/GlobalConfig';
import { WebDavService } from '../service/WebDavService';

export default class MainAbility extends UIAbility {
  onCreate(want, launchParam): void {
    console.info('[MainAbility] onCreate');
    // 提前启动异步初始化
    this.initServices();
  }

  private async initServices(): Promise<void> {
    try {
      await AppDatabase.getInstance().init(this.context);
      console.info('[MainAbility] Database initialized');
    } catch (err) {
      console.error('[MainAbility] Database init failed:', err);
    }
    try {
      await AppTheme.getInstance().loadSaved();
      console.info('[MainAbility] Theme loaded');
    } catch (err) {
      console.warn('[MainAbility] Theme load failed:', err);
    }
    try {
      await GlobalConfig.getInstance().load();
      console.info('[MainAbility] GlobalConfig loaded');
    } catch (err) {
      console.warn('[MainAbility] GlobalConfig load failed:', err);
    }
    // 启动时批量同步云端阅读进度
    this.syncProgressFromCloud();
  }

  /** 从云端批量下载所有在架书籍的阅读进度 */
  private syncProgressFromCloud(): void {
    try {
      const syncOn = AppStorage.get<boolean>('webdav_sync_progress');
      if (syncOn !== true) return;
      if (!WebDavService.getInstance().isConfigured()) return;
      WebDavService.getInstance().downloadAllBookProgress()
        .then(() => console.info('[MainAbility] Cloud progress sync done'))
        .catch((e: Error) => console.warn('[MainAbility] Cloud progress sync failed:', e.message));
    } catch (e) {
      console.warn('[MainAbility] Cloud progress sync error:', (e as Error).message);
    }
  }

  onDestroy(): void {
    console.info('[MainAbility] onDestroy');
  }

  onWindowStageCreate(windowStage: Window.WindowStage): void {
    console.info('[MainAbility] onWindowStageCreate');
    try {
      windowStage.loadContent('pages/MainPage');
    } catch (err) {
      console.error('[MainAbility] loadContent failed:', err);
    }
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
  }
}
