import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';

/** Shares the single continuous data-transfer lease between long-running services. */
export class BackgroundRunningManager {
  private static holders_: Set<string> = new Set();

  static async acquire(context: common.Context, owner: string): Promise<void> {
    if (!owner || BackgroundRunningManager.holders_.has(owner)) return;
    const shouldStart = BackgroundRunningManager.holders_.size === 0;
    BackgroundRunningManager.holders_.add(owner);
    if (!shouldStart) return;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'io.hjianhao.aireader', abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
      });
      await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
    } catch (error) {
      BackgroundRunningManager.holders_.delete(owner);
      throw new Error(String(error));
    }
  }

  static async release(context: common.Context, owner: string): Promise<void> {
    BackgroundRunningManager.holders_.delete(owner);
    if (BackgroundRunningManager.holders_.size > 0) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      console.warn('[BackgroundRunningManager] stop failed:', JSON.stringify(error));
    }
  }
}
