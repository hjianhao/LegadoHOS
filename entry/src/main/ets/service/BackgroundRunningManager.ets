import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import bundleManager from '@ohos.bundle.bundleManager';
import notificationManager from '@ohos.notificationManager';
import { common } from '@kit.AbilityKit';

interface ProgressSnapshot {
  title: string;
  done: number;
  total: number;
}

/** Shares the single continuous data-transfer lease between long-running services. */
export class BackgroundRunningManager {
  private static holders_: Set<string> = new Set();
  /** Only one UIAbility-level continuous task is needed for all app transfers. */
  private static startPromise_: Promise<void> | null = null;
  private static context_: common.Context | null = null;
  private static notificationId_: number = -1;
  private static continuousTaskId_: number = -1;
  private static running_: boolean = false;
  private static progressTimer_: number = -1;
  private static lastProgress_: ProgressSnapshot = {
    title: '离线缓存', done: 0, total: 1,
  };
  private static callbacksRegistered_: boolean = false;

  static async acquire(context: common.Context, owner: string): Promise<void> {
    if (!owner || BackgroundRunningManager.holders_.has(owner)) return;
    BackgroundRunningManager.holders_.add(owner);

    // A second cache/source-check task may arrive while the first request is
    // still waiting for the system service. It must wait for the same request;
    // otherwise it can start downloading before the keep-alive lease exists.
    if (BackgroundRunningManager.startPromise_) {
      try {
        await BackgroundRunningManager.startPromise_;
      } catch (error) {
        BackgroundRunningManager.holders_.delete(owner);
        throw new Error(BackgroundRunningManager.errorText_(error));
      }
      return;
    }
    if (BackgroundRunningManager.holders_.size > 1) return;

    BackgroundRunningManager.context_ = context;
    const startPromise = BackgroundRunningManager.start_(context);
    BackgroundRunningManager.startPromise_ = startPromise;
    try {
      await startPromise;
    } catch (error) {
      BackgroundRunningManager.holders_.delete(owner);
      BackgroundRunningManager.context_ = null;
      throw new Error(BackgroundRunningManager.errorText_(error));
    } finally {
      BackgroundRunningManager.startPromise_ = null;
    }
  }

  static async release(context: common.Context, owner: string): Promise<void> {
    BackgroundRunningManager.holders_.delete(owner);
    if (BackgroundRunningManager.holders_.size > 0) return;
    // If the start call is still in flight, let it finish before stopping. A
    // stop issued too early can race the system service and leave a stale task.
    if (BackgroundRunningManager.startPromise_) {
      try { await BackgroundRunningManager.startPromise_; } catch (_e) { return; }
    }
    try {
      const stopContext = BackgroundRunningManager.context_ || context;
      if (BackgroundRunningManager.running_ && BackgroundRunningManager.continuousTaskId_ >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(
          stopContext, BackgroundRunningManager.continuousTaskId_);
      } else if (BackgroundRunningManager.running_) {
        await backgroundTaskManager.stopBackgroundRunning(stopContext);
      }
    } catch (error) {
      console.warn('[BackgroundRunningManager] stop failed:', BackgroundRunningManager.errorText_(error));
    } finally {
      BackgroundRunningManager.context_ = null;
      BackgroundRunningManager.notificationId_ = -1;
      BackgroundRunningManager.continuousTaskId_ = -1;
      BackgroundRunningManager.running_ = false;
      BackgroundRunningManager.stopProgressHeartbeat_();
    }
  }

  /**
   * Update the system-owned live-view notification returned by
   * startBackgroundRunning(). For DATA_TRANSFER this is part of the contract:
   * publishing an unrelated normal notification does not count as progress.
   */
  static reportProgress(title: string, done: number, total: number): void {
    const id = BackgroundRunningManager.notificationId_;
    if (id < 0) return;
    const safeTotal = Math.max(1, total);
    const percent = Math.max(0, Math.min(100, Math.round(done * 100 / safeTotal)));
    const text = `${done}/${total} 章`;
    BackgroundRunningManager.lastProgress_ = { title: title || '离线缓存', done, total };
    BackgroundRunningManager.publishProgress_(id, title || '离线缓存', text, percent);
  }

  private static publishProgress_(id: number, title: string, text: string, percent: number): void {
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: 8,
          title: title || '离线缓存',
          text: text,
          progress: { maxValue: 100, currentValue: percent, isPercentage: true },
        },
      },
      template: {
        name: 'downloadTemplate',
        data: { title: title || '离线缓存', fileName: text, progressValue: percent },
      },
      updateOnly: true,
    };
    notificationManager.publish(request).catch((error: Error) => {
      console.warn('[BackgroundRunningManager] progress notification failed:',
        BackgroundRunningManager.errorText_(error));
    });
  }

  private static async start_(context: common.Context): Promise<void> {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: bundleInfo.name, abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 2100,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      });
      // API 21+ request form explicitly declares the LIVE_VIEW submode. This
      // is required for DATA_TRANSFER progress updates.
      const taskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      taskRequest.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      taskRequest.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      taskRequest.wantAgent = agent;
      taskRequest.combinedTaskNotification = false;
      const result = await backgroundTaskManager.startBackgroundRunning(context, taskRequest);
      BackgroundRunningManager.notificationId_ = result.notificationId;
      BackgroundRunningManager.continuousTaskId_ = result.continuousTaskId ?? -1;
      BackgroundRunningManager.running_ = true;
      BackgroundRunningManager.lastProgress_ = { title: '离线缓存', done: 0, total: 1 };
      BackgroundRunningManager.registerCallbacks_();
      console.info('[BackgroundRunningManager] started: notificationId=' +
        result.notificationId + ' continuousTaskId=' + (result.continuousTaskId ?? -1));
      BackgroundRunningManager.reportProgress('离线缓存', 0, 1);
      BackgroundRunningManager.startProgressHeartbeat_();
    } catch (error) {
      console.error('[BackgroundRunningManager] start failed:',
        BackgroundRunningManager.errorText_(error));
      throw new Error(BackgroundRunningManager.errorText_(error));
    }
  }

  private static startProgressHeartbeat_(): void {
    BackgroundRunningManager.stopProgressHeartbeat_();
    // DATA_TRANSFER tasks must publish progress periodically. Five minutes is
    // comfortably below the system's ten-minute no-update cancellation limit.
    BackgroundRunningManager.progressTimer_ = setInterval((): void => {
      if (!BackgroundRunningManager.running_ || BackgroundRunningManager.notificationId_ < 0) return;
      const p = BackgroundRunningManager.lastProgress_;
      const total = Math.max(1, p.total);
      const percent = Math.max(0, Math.min(100, Math.round(p.done * 100 / total)));
      BackgroundRunningManager.publishProgress_(BackgroundRunningManager.notificationId_,
        p.title, `${p.done}/${p.total} 章`, percent);
    }, 5 * 60 * 1000);
  }

  private static stopProgressHeartbeat_(): void {
    if (BackgroundRunningManager.progressTimer_ >= 0) {
      clearInterval(BackgroundRunningManager.progressTimer_);
      BackgroundRunningManager.progressTimer_ = -1;
    }
  }

  private static registerCallbacks_(): void {
    if (BackgroundRunningManager.callbacksRegistered_) return;
    BackgroundRunningManager.callbacksRegistered_ = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          const detailed = info.detailedReason === undefined ? '' :
            ' detailedReason=' + info.detailedReason;
          console.warn('[BackgroundRunningManager] task cancelled: id=' + info.id +
            ' reason=' + info.reason + detailed);
        });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          console.warn('[BackgroundRunningManager] task suspended: id=' + info.continuousTaskId +
            ' reason=' + info.suspendReason);
        });
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
          console.info('[BackgroundRunningManager] task active: id=' + info.id);
        });
    } catch (error) {
      // Event APIs are API 15/20+. Keep task startup usable when callback
      // registration is unavailable on a particular device image.
      console.warn('[BackgroundRunningManager] callback registration failed:',
        BackgroundRunningManager.errorText_(error));
    }
  }

  private static errorText_(error: Object): string {
    const value = error as Record<string, Object>;
    const code = value['code'];
    const message = value['message'];
    if (code !== undefined || message !== undefined) {
      return 'code=' + String(code ?? '') + ' message=' + String(message ?? '');
    }
    return String(error);
  }
}
