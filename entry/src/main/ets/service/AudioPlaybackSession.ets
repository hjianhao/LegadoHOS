/**
 * 有声书媒体会话。
 *
 * AVPlayer 只负责解码和播放，不会自动把章节标题、播放状态和进度同步到
 * 系统播控中心；这里用进程级 AVSession 补上这层桥接。会话不绑定阅读页，
 * 因此离开 AudioReadPage 后仍能继续更新后台媒体通知。
 */
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { bundleManager, wantAgent, common } from '@kit.AbilityKit';
import { AudioPlayer, AudioTrack, PlayState } from '../engine/audio/AudioPlayer';

export class AudioPlaybackSession {
  private session_: avSession.AVSession | null = null;
  private createPromise_: Promise<void> | null = null;
  private player_: AudioPlayer | null = null;
  private track_: AudioTrack | null = null;
  private trackKey_: string = '';
  private assetSerial_: number = 0;
  private position_: number = 0;
  private duration_: number = 0;
  private speed_: number = 1;
  private state_: PlayState = PlayState.IDLE;
  private metadataDuration_: number = -1;
  private lastPublishedState_: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_INITIAL;
  private lastPublishedPosition_: number = -1;
  private lastPublishedAt_: number = 0;
  // UIAbility 的连续任务必须由播放器自己持有；仅声明 audioPlayback 或激活
  // AVSession 不足以阻止息屏后的进程回收。
  private backgroundContext_: common.UIAbilityContext | null = null;
  private backgroundTaskId_: number = -1;
  private backgroundTaskActive_: boolean = false;
  private backgroundTaskStartPromise_: Promise<void> | null = null;
  private backgroundTaskStopPromise_: Promise<void> | null = null;
  private backgroundWantAgent_: object | null = null;
  private backgroundCallbacksRegistered_: boolean = false;
  // setAVPlaybackState 可能在系统服务繁忙时超过 500ms；只保留最新快照，
  // 避免 timeUpdate 回调不断堆积 IPC 请求。
  private pendingPlayback_: avSession.AVPlaybackState | null = null;
  private playbackUpdatePromise_: Promise<void> | null = null;
  private static readonly POSITION_UPDATE_INTERVAL_MS: number = 2000;

  /** 在页面出现时提供上下文；会话已存在时只做一次状态同步。 */
  async attach(context: Context, player?: AudioPlayer): Promise<void> {
    this.backgroundContext_ = context as common.UIAbilityContext;
    if (player) this.player_ = player;
    if (this.session_) {
      this.sync_();
      return;
    }
    if (this.createPromise_) {
      await this.createPromise_;
      return;
    }
    const promise = this.create_(context);
    this.createPromise_ = promise;
    try {
      await promise;
    } finally {
      if (this.createPromise_ === promise) this.createPromise_ = null;
    }
  }

  setTrack(track: AudioTrack): void {
    const key = track.url + '\n' + track.title + '\n' + track.artist;
    if (key !== this.trackKey_) {
      this.trackKey_ = key;
      this.assetSerial_++;
      this.position_ = 0;
      this.duration_ = 0;
      this.metadataDuration_ = -1;
    }
    this.track_ = track;
    if (track.duration > 0) this.duration_ = track.duration;
    this.updateMetadata_();
    this.publishPlayback_(this.state_, true);
  }

  updatePlayback(state: PlayState, position: number, duration: number, speed: number): void {
    this.state_ = state;
    this.position_ = Math.max(0, position || 0);
    if (duration > 0) this.duration_ = duration;
    if (speed > 0) this.speed_ = speed;
    this.updateMetadata_();
    this.publishPlayback_(state, false);
    if (state === PlayState.PLAYING) {
      this.ensureBackgroundTask_();
    } else if (state === PlayState.PAUSED || state === PlayState.STOPPED ||
      state === PlayState.ERROR || state === PlayState.IDLE) {
      this.stopBackgroundTask();
    }
  }

  /** 当前是否仍在播放音频书，用于 Ability 生命周期中的备份判断。 */
  isPlaying(): boolean {
    return this.state_ === PlayState.PLAYING;
  }

  /**
   * 申请音频书专属持续后台任务。
   * 错误只记录日志，不阻断正常播放；设备不支持时仍允许用户前台使用。
   */
  async startBackgroundTask(context: Context): Promise<void> {
    this.backgroundContext_ = context as common.UIAbilityContext;
    if (this.backgroundTaskStopPromise_) {
      await this.backgroundTaskStopPromise_;
    }
    if (this.backgroundTaskActive_) return;
    if (this.backgroundTaskStartPromise_) {
      await this.backgroundTaskStartPromise_;
      return;
    }
    const startPromise = this.startBackgroundTaskInternal_(this.backgroundContext_);
    this.backgroundTaskStartPromise_ = startPromise;
    try {
      await startPromise;
    } finally {
      if (this.backgroundTaskStartPromise_ === startPromise) this.backgroundTaskStartPromise_ = null;
    }
  }

  /** 停止音频书自己的任务，不影响缓存/源检查的数据传输任务。 */
  async stopBackgroundTask(): Promise<void> {
    if (this.backgroundTaskStopPromise_) {
      await this.backgroundTaskStopPromise_;
      return;
    }
    if (this.backgroundTaskStartPromise_) {
      try { await this.backgroundTaskStartPromise_; } catch (_) { return; }
    }
    if (!this.backgroundTaskActive_) return;
    const stopPromise = this.stopBackgroundTaskInternal_();
    this.backgroundTaskStopPromise_ = stopPromise;
    try {
      await stopPromise;
    } finally {
      if (this.backgroundTaskStopPromise_ === stopPromise) this.backgroundTaskStopPromise_ = null;
    }
  }

  private ensureBackgroundTask_(): void {
    const context = this.backgroundContext_;
    if (!context || this.backgroundTaskActive_ || this.backgroundTaskStartPromise_) return;
    this.startBackgroundTask(context).catch((e: Error) => {
      console.warn('[AudioSession] background task start failed: ' + e.message);
    });
  }

  private async startBackgroundTaskInternal_(context: common.UIAbilityContext | null): Promise<void> {
    if (!context || this.backgroundTaskActive_) return;
    try {
      if (!this.backgroundWantAgent_) {
        const info = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        this.backgroundWantAgent_ = await wantAgent.getWantAgent({
          wants: [{ bundleName: info.name, abilityName: 'MainAbility' }],
          operationType: wantAgent.OperationType.START_ABILITIES,
          requestCode: 2200,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
        });
      }
      const agent = this.backgroundWantAgent_;
      if (!agent) throw new Error('创建音频后台任务所需的 WantAgent 为空');
      const taskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      taskRequest.backgroundTaskModes = [
        backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD,
      ];
      taskRequest.backgroundTaskSubmodes = [
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_AVSESSION_AUDIO_PLAYBACK,
      ];
      taskRequest.wantAgent = agent;
      taskRequest.combinedTaskNotification = false;
      const result = await backgroundTaskManager.startBackgroundRunning(context, taskRequest);
      this.backgroundTaskId_ = result.continuousTaskId ?? -1;
      this.backgroundTaskActive_ = true;
      this.registerBackgroundCallbacks_();
      console.info('[AudioSession] background task started, taskId=' + this.backgroundTaskId_ +
        ', notificationId=' + result.notificationId);
    } catch (e) {
      console.warn('[AudioSession] background task unavailable: ' + this.errorText_(e));
    }
  }

  private async stopBackgroundTaskInternal_(): Promise<void> {
    const context = this.backgroundContext_;
    const taskId = this.backgroundTaskId_;
    if (!context) {
      this.backgroundTaskActive_ = false;
      this.backgroundTaskId_ = -1;
      return;
    }
    try {
      if (taskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(context, taskId);
      } else {
        // API 21+ 始终返回 taskId；没有 taskId 时不调用“停止全部任务”，
        // 避免误停 BookCacheService/SourceCheckService 的 DATA_TRANSFER 任务。
        console.warn('[AudioSession] background task has no taskId; skip stop');
      }
      console.info('[AudioSession] background task stopped, taskId=' + taskId);
    } catch (e) {
      console.warn('[AudioSession] background task stop failed: ' + this.errorText_(e));
    } finally {
      this.backgroundTaskActive_ = false;
      this.backgroundTaskId_ = -1;
    }
  }

  private registerBackgroundCallbacks_(): void {
    if (this.backgroundCallbacksRegistered_) return;
    this.backgroundCallbacksRegistered_ = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          if (info.id !== this.backgroundTaskId_) return;
          this.backgroundTaskActive_ = false;
          this.backgroundTaskId_ = -1;
          console.warn('[AudioSession] background task cancelled: reason=' + info.reason);
        });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          if (info.continuousTaskId !== this.backgroundTaskId_) return;
          console.warn('[AudioSession] background task suspended: reason=' + info.suspendReason);
        });
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
          if (info.id === this.backgroundTaskId_) {
            console.info('[AudioSession] background task active: id=' + info.id);
          }
        });
    } catch (e) {
      console.warn('[AudioSession] background callbacks unavailable: ' + this.errorText_(e));
    }
  }

  private errorText_(error: Object): string {
    const value = error as Record<string, Object>;
    return 'code=' + String(value['code'] ?? '') + ' message=' + String(value['message'] ?? error);
  }

  private async create_(context: Context): Promise<void> {
    try {
      const session = await avSession.createAVSession(context, 'legado_audio', 'audio');
      this.session_ = session;
      // 播控中心点击媒体卡片时回到主 Ability；WantAgent 创建失败不影响会话本身。
      try {
        const info = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: info.name, abilityName: 'MainAbility' }],
          operationType: wantAgent.OperationType.START_ABILITIES,
          requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
        });
        await session.setLaunchAbility(agent);
      } catch (e) {
        console.warn('[AudioSession] launch agent unavailable: ' + (e as Error).message);
      }
      // 支持通知中的播放、暂停和停止按钮，实际状态仍以 AVPlayer 回调为准。
      session.on('play', () => {
        const player = this.player_;
        if (player && player.state === PlayState.PAUSED) player.resume().catch(() => {});
      });
      session.on('pause', () => {
        const player = this.player_;
        if (player && player.state === PlayState.PLAYING) player.pause().catch(() => {});
      });
      session.on('stop', () => {
        const player = this.player_;
        if (player) player.stop().catch(() => {});
      });
      await session.activate();
      this.sync_();
      console.info('[AudioSession] activated');
    } catch (e) {
      this.session_ = null;
      console.warn('[AudioSession] create failed: ' + (e as Error).message);
      throw new Error((e as Error).message || String(e));
    }
  }

  private sync_(): void {
    this.updateMetadata_();
    this.publishPlayback_(this.state_, true);
  }

  private updateMetadata_(): void {
    const session = this.session_;
    const track = this.track_;
    if (!session || !track) return;
    const durationMs = Math.max(0, Math.floor((this.duration_ || track.duration || 0) * 1000));
    if (durationMs === this.metadataDuration_ && this.metadataDuration_ >= 0) return;
    const metadata: avSession.AVMetadata = {
      assetId: 'legado_audio_' + this.assetSerial_,
      title: track.title || '有声书',
      artist: track.artist || 'Legado HOS',
    };
    if (durationMs > 0) metadata.duration = durationMs;
    this.metadataDuration_ = durationMs;
    session.setAVMetadata(metadata).catch((e: Error) => {
      console.warn('[AudioSession] metadata update failed: ' + e.message);
    });
  }

  private publishPlayback_(state: PlayState, force: boolean): void {
    const session = this.session_;
    if (!session) return;
    let playbackState = avSession.PlaybackState.PLAYBACK_STATE_INITIAL;
    if (state === PlayState.PLAYING) playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    else if (state === PlayState.PAUSED) playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    else if (state === PlayState.STOPPED || state === PlayState.ERROR) {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_STOP;
    } else if (state === PlayState.INITIALIZED || state === PlayState.PREPARED) {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }
    const now = Date.now();
    const elapsedMs = Math.max(0, Math.floor(this.position_ * 1000));
    if (!force && playbackState === this.lastPublishedState_ &&
      Math.abs(elapsedMs - this.lastPublishedPosition_) < AudioPlaybackSession.POSITION_UPDATE_INTERVAL_MS &&
      now - this.lastPublishedAt_ < AudioPlaybackSession.POSITION_UPDATE_INTERVAL_MS) {
      return;
    }
    const playback: avSession.AVPlaybackState = {
      state: playbackState,
      speed: this.speed_,
      position: { elapsedTime: elapsedMs, updateTime: now },
    };
    this.lastPublishedState_ = playbackState;
    this.lastPublishedPosition_ = elapsedMs;
    this.lastPublishedAt_ = now;
    this.pendingPlayback_ = playback;
    this.flushPlaybackUpdate_();
  }

  private flushPlaybackUpdate_(): void {
    if (this.playbackUpdatePromise_ || !this.pendingPlayback_) return;
    const session = this.session_;
    if (!session) {
      this.pendingPlayback_ = null;
      return;
    }
    const playback = this.pendingPlayback_;
    this.pendingPlayback_ = null;
    let request: Promise<void>;
    try {
      request = session.setAVPlaybackState(playback);
    } catch (e) {
      console.warn('[AudioSession] playback update failed: ' + this.errorText_(e));
      return;
    }
    this.playbackUpdatePromise_ = request;
    request.catch((e: Error) => {
      console.warn('[AudioSession] playback update failed: ' + e.message);
    }).finally(() => {
      this.playbackUpdatePromise_ = null;
      this.flushPlaybackUpdate_();
    });
  }
}

export const globalAudioPlaybackSession: AudioPlaybackSession = new AudioPlaybackSession();
