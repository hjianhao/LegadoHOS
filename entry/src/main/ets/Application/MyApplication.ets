/**
 * 应用入口 — AbilityStage
 *
 * HarmonyOS NEXT 阶段模型入口。
 * 所有初始化异常被捕获，不阻塞 UI 加载。
 */
import AbilityStage from '@ohos.app.ability.AbilityStage';
import { AppDatabase } from '../data/database/AppDatabase';
import { AppTheme } from '../theme/AppTheme';

export default class MyApplication extends AbilityStage {
  onCreate(): void {
    console.info('[LegadoHOS] AbilityStage onCreate');

    // 异步初始化各模块（不阻塞 UI）
    this.initDatabase();
    this.initTheme();
  }

  private async initDatabase(): Promise<void> {
    try {
      console.info('[LegadoHOS] Initializing database...');
      await AppDatabase.getInstance().init(this.context);
      console.info('[LegadoHOS] Database ready');
    } catch (err) {
      console.error('[LegadoHOS] Database init failed:', err);
    }
  }

  private async initTheme(): Promise<void> {
    try {
      await AppTheme.getInstance().loadSaved(this.context);
      console.info('[LegadoHOS] Theme loaded');
    } catch (err) {
      console.warn('[LegadoHOS] Theme load failed:', err);
    }
  }

  onDestroy(): void {
    console.info('[LegadoHOS] AbilityStage onDestroy');
  }
}
