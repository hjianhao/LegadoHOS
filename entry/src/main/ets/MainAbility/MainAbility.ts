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
  }

  onDestroy(): void {
    console.info('[MainAbility] onDestroy');
  }

  onWindowStageCreate(windowStage: Window.WindowStage): void {
    console.info('[MainAbility] onWindowStageCreate');
    windowStage.loadContent('pages/MainPage');
  }

  onWindowStageDestroy(): void {
    console.info('[MainAbility] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[MainAbility] onForeground');
  }

  onBackground(): void {
    console.info('[MainAbility] onBackground');
  }
}
