/**
 * 音频播放器引擎
 * 基于 @ohos.multimedia.media AVPlayer 实现
 *
 * 支持: 在线/本地音频播放、进度追踪、变速、音量控制
 */
import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';

export enum PlayState {
  IDLE = 'idle',
  INITIALIZED = 'initialized',
  PREPARED = 'prepared',
  PLAYING = 'playing',
  PAUSED = 'paused',
  STOPPED = 'stopped',
  ERROR = 'error',
}

export interface AudioTrack {
  title: string;
  artist: string;
  url: string;          // 支持 http/https 和 file://
  duration: number;     // 秒（从元数据获取后更新）
  coverUrl: string;
}

interface ParsedAudioUrl {
  url: string;
  headers: Record<string, string>;
}

/**
 * Legado 音频书源允许把请求头附在 URL 后：
 *   https://cdn.example/a.mp3,{"headers":{"Referer":"..."}}
 * AVPlayer 不能把这个扩展串当作 URL，播放前必须拆开并交给 MediaSource。
 */
function parseAudioUrl(value: string): ParsedAudioUrl {
  const raw = (value || '').trim();
  // JSON.stringify(headers) 本身可能含逗号（念音的 Referer + User-Agent 就是
  // 这种情况），不能用最后一个逗号切分。逐个尝试“逗号后的 JSON”并验证
  // headers 字段，既能保留 URL 查询参数中的逗号，也兼容多请求头。
  let comma = raw.indexOf(',');
  while (comma > 0) {
    const suffix = raw.substring(comma + 1).trim();
    if (suffix.startsWith('{')) {
      try {
        const parsed: Object = JSON.parse(suffix);
        const candidate = (parsed as Record<string, Object>)['headers'];
        if (candidate && typeof candidate === 'object') {
          const headers: Record<string, string> = {};
          Object.keys(candidate as Record<string, Object>).forEach((key: string): void => {
            const item = (candidate as Record<string, Object>)[key];
            if (item !== undefined && item !== null) headers[key] = String(item);
          });
          return { url: raw.substring(0, comma).trim(), headers: headers };
        }
      } catch (_e) {
        // 可能是 URL 中的普通逗号，继续尝试后续位置。
      }
    }
    comma = raw.indexOf(',', comma + 1);
  }
  return { url: raw, headers: {} };
}

export class AudioPlayer {
  private avPlayer_: media.AVPlayer | null = null;
  // MediaSource 需要由 JS 层保持引用到当前曲目结束；否则后台切换/GC 时
  // 原生对象可能提前析构，导致网络音频在息屏后停止供数。
  private mediaSource_: media.MediaSource | null = null;
  private initPromise_: Promise<void> | null = null;
  // AVPlayer 的状态回调是异步的，播放/切源操作必须串行执行，否则第二次
  // prepare 可能在第一次操作仍处于 idle/prepared 切换过程中发起。
  private playQueue_: Promise<void> = Promise.resolve();
  private state_: PlayState = PlayState.IDLE;
  private currentTrack_: AudioTrack | null = null;
  private position_: number = 0;
  private duration_: number = 0;
  private volume_: number = 1.0;
  private speed_: number = 1.0;
  // 音频焦点被其他应用临时抢占时，记录原本正在播放的状态；焦点恢复后
  // 仅在窗口内自动 play，避免把用户手动暂停误恢复。
  private interruptionActive_: boolean = false;
  private interruptionStartedAt_: number = 0;
  private autoResumeEligible_: boolean = false;
  private autoResumeTimer_: number = -1;
  private interruptionGeneration_: number = 0;
  private wasPlayingBeforeInterruption_: boolean = false;
  private resumeInProgress_: boolean = false;
  private static readonly AUTO_RESUME_WINDOW_MS = 60 * 1000;
  // 耳机/外接音频设备断开属于设备路由变化，不应被当作临时焦点中断自动恢复。
  private routingManager_: audio.AudioRoutingManager | null = null;
  private deviceChangeCb_: ((action: audio.DeviceChangeAction) => void) | null = null;
  private outputWasHeadset_: boolean = false;

  // 回调
  private onStateChange_: ((state: PlayState) => void) | null = null;
  private onProgress_: ((current: number, total: number) => void) | null = null;
  private onCompletion_: (() => void) | null = null;
  private onError_: ((err: string) => void) | null = null;

  get state(): PlayState { return this.state_; }
  get currentTrack(): AudioTrack | null { return this.currentTrack_; }
  get position(): number { return this.position_; }
  get duration(): number { return this.duration_; }
  get volume(): number { return this.volume_; }
  get speed(): number { return this.speed_; }

  set onStateChange(cb: (state: PlayState) => void) { this.onStateChange_ = cb; }
  set onProgress(cb: (current: number, total: number) => void) { this.onProgress_ = cb; }
  set onCompletion(cb: () => void) { this.onCompletion_ = cb; }
  set onError(cb: (err: string) => void) { this.onError_ = cb; }

  private applySpeed_(): void {
    if (!this.avPlayer_) return;
    // AVPlayer API 12 使用 PlaybackSpeed 枚举（不是任意 number）。
    const modes: Record<string, media.PlaybackSpeed> = {
      '0.5': media.PlaybackSpeed.SPEED_FORWARD_0_50_X,
      '0.75': media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
      '1': media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
      '1.25': media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
      '1.5': media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
      '1.75': media.PlaybackSpeed.SPEED_FORWARD_1_75_X,
      '2': media.PlaybackSpeed.SPEED_FORWARD_2_00_X,
      '3': media.PlaybackSpeed.SPEED_FORWARD_3_00_X,
    };
    const key = Object.keys(modes).find((item: string): boolean => Math.abs(Number(item) - this.speed_) < 0.01);
    this.avPlayer_.setSpeed(key ? modes[key] : media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
  }

  /**
   * 初始化 AVPlayer
   */
  async init(): Promise<void> {
    if (this.avPlayer_) return;
    if (this.initPromise_) return await this.initPromise_;

    this.initPromise_ = (async (): Promise<void> => {
      try {
        this.avPlayer_ = await media.createAVPlayer();
        this.setupListeners();
        this.registerDeviceChangeListener_();
        console.info('[AudioPlayer] AVPlayer created');
      } catch (err) {
        console.error('[AudioPlayer] Init failed:', err);
        this.state_ = PlayState.ERROR;
        throw err;
      } finally {
        this.initPromise_ = null;
      }
    })();
    return await this.initPromise_;
  }

  /**
   * 等待 AVPlayer 的真实状态，而不是依赖可能尚未到达的 stateChange 回调。
   * 设置 MediaSource 后状态切换是异步的，立即 prepare 会在 idle 状态下被系统拒绝。
   */
  private async waitForNativeState_(expected: media.AVPlayerState, timeoutMs: number = 5000): Promise<void> {
    const player = this.avPlayer_;
    if (!player) throw new Error('AVPlayer not initialized');
    const deadline = Date.now() + timeoutMs;
    while (player.state !== expected) {
      if (player.state === 'error') throw new Error('AVPlayer entered error state');
      if (Date.now() >= deadline) {
        throw new Error('AVPlayer state timeout: expected ' + expected + ', got ' + player.state);
      }
      // AVPlayer 的 off('stateChange', listener) 会清除该事件的全部回调，
      // 包括 setupListeners 注册的长期回调，因此这里用轮询等待而不增删监听器。
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 50);
      });
    }
  }

  private async resetForNewTrack_(): Promise<void> {
    const player = this.avPlayer_;
    if (!player) return;
    const nativeState = player.state;
    if (nativeState === 'released') {
      this.avPlayer_ = null;
      await this.init();
      return;
    }
    if (nativeState === 'idle') return;

    // stop 只允许在 prepared/playing/paused/completed 状态调用；initialized、
    // stopped、error 状态直接 reset 即可。
    if (nativeState === 'prepared' || nativeState === 'playing' ||
      nativeState === 'paused' || nativeState === 'completed') {
      try { await player.stop(); } catch (_e) { /* 状态可能已在回调中变化 */ }
    }
    try { await player.reset(); } catch (_e) { /* 某些系统在错误状态会自动复位 */ }
    await this.waitForNativeState_('idle');
  }

  /**
   * 注册 AVPlayer 事件监听
   */
  private setupListeners(): void {
    if (!this.avPlayer_) return;

    this.avPlayer_.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      console.info(`[AudioPlayer] State: ${state}`);
      const previousState = this.state_;
      switch (state) {
        case 'idle':
          this.state_ = PlayState.IDLE;
          break;
        case 'initialized':
          this.state_ = PlayState.INITIALIZED;
          break;
        case 'prepared':
          this.state_ = PlayState.PREPARED;
          // AVPlayer.duration 的单位是毫秒，AudioPlayer 对外统一使用秒。
          this.duration_ = Math.floor(this.avPlayer_!.duration / 1000);
          break;
        case 'playing':
          this.state_ = PlayState.PLAYING;
          this.wasPlayingBeforeInterruption_ = true;
          break;
        case 'paused':
          this.state_ = PlayState.PAUSED;
          if (!this.interruptionActive_ && previousState !== PlayState.PLAYING) {
            this.wasPlayingBeforeInterruption_ = false;
          }
          break;
        case 'stopped':
          this.state_ = PlayState.STOPPED;
          this.wasPlayingBeforeInterruption_ = false;
          break;
        case 'completed':
          // completed 之后仍需调用 play 才能重播；对外按停止态处理，下一次
          // 点击播放会重新加载当前章节，避免 UI 继续显示“暂停”。
          this.state_ = PlayState.STOPPED;
          this.wasPlayingBeforeInterruption_ = false;
          break;
        case 'released':
          this.state_ = PlayState.IDLE;
          this.wasPlayingBeforeInterruption_ = false;
          break;
        case 'error':
          this.state_ = PlayState.ERROR;
          this.wasPlayingBeforeInterruption_ = false;
          break;
      }
      this.onStateChange_?.(this.state_);
    });

    this.avPlayer_.on('timeUpdate', (time: number) => {
      this.position_ = Math.floor(time / 1000); // ms → s
      this.onProgress_?.(this.position_, this.duration_);
    });

    this.avPlayer_.on('endOfStream', () => {
      console.info('[AudioPlayer] Playback completed');
      this.onCompletion_?.();
    });

    this.avPlayer_.on('audioInterrupt', (event: audio.InterruptEvent) => {
      console.info('[AudioPlayer] Audio interrupt: event=' + event.eventType +
        ', force=' + event.forceType + ', hint=' + event.hintType +
        ', state=' + this.state_);
      this.handleAudioInterrupt_(event);
    });

    this.avPlayer_.on('error', (err) => {
      console.error('[AudioPlayer] Error:', err);
      this.state_ = PlayState.ERROR;
      this.wasPlayingBeforeInterruption_ = false;
      this.onError_?.(String(err));
    });
  }

  /** 处理 AVPlayer 的音频焦点中断，恢复策略与朗读 AudioRenderer 保持一致。 */
  private handleAudioInterrupt_(event: audio.InterruptEvent): void {
    if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        // STOP 代表永久失去焦点，交给用户重新点击播放。
        this.clearInterruptionState_();
        if (this.state_ === PlayState.PLAYING || this.state_ === PlayState.PAUSED) {
          this.state_ = PlayState.STOPPED;
          this.onStateChange_?.(this.state_);
        }
        return;
      }
      if (event.hintType !== audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        (this.state_ !== PlayState.PLAYING && !this.wasPlayingBeforeInterruption_)) return;

      this.interruptionGeneration_++;
      this.interruptionActive_ = true;
      this.interruptionStartedAt_ = Date.now();
      this.autoResumeEligible_ = true;
      this.scheduleAutoResumeExpiry_();

      // FORCE/PAUSE 已由系统暂停；SHARE/PAUSE 需要应用自行暂停。
      this.state_ = PlayState.PAUSED;
      this.onStateChange_?.(this.state_);
      if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE && this.avPlayer_) {
        this.avPlayer_.pause().catch((e: Error) => {
          console.warn('[AudioPlayer] pause for shared audio interrupt failed: ' + e.message);
        });
      }
      return;
    }

    if (event.eventType !== audio.InterruptType.INTERRUPT_TYPE_END ||
      event.hintType !== audio.InterruptHint.INTERRUPT_HINT_RESUME ||
      !this.interruptionActive_ || !this.autoResumeEligible_) return;

    const elapsed = Date.now() - this.interruptionStartedAt_;
    if (elapsed > AudioPlayer.AUTO_RESUME_WINDOW_MS) {
      console.info('[AudioPlayer] audio focus restored after auto-resume window: ' + elapsed + 'ms');
      this.clearInterruptionState_();
      return;
    }

    this.interruptionActive_ = false;
    this.autoResumeEligible_ = false;
    this.wasPlayingBeforeInterruption_ = false;
    this.cancelAutoResumeTimer_();
    console.info('[AudioPlayer] audio focus restored, auto resume after ' + elapsed + 'ms');
    this.resume().catch((e: Error) => {
      console.warn('[AudioPlayer] auto resume failed: ' + e.message);
    });
  }

  private scheduleAutoResumeExpiry_(): void {
    this.cancelAutoResumeTimer_();
    const generation = this.interruptionGeneration_;
    this.autoResumeTimer_ = setTimeout((): void => {
      this.autoResumeTimer_ = -1;
      if (generation !== this.interruptionGeneration_ || !this.interruptionActive_) return;
      this.autoResumeEligible_ = false;
      console.info('[AudioPlayer] audio interruption exceeded auto-resume window');
    }, AudioPlayer.AUTO_RESUME_WINDOW_MS);
  }

  private cancelAutoResumeTimer_(): void {
    if (this.autoResumeTimer_ >= 0) {
      clearTimeout(this.autoResumeTimer_);
      this.autoResumeTimer_ = -1;
    }
  }

  private clearInterruptionState_(): void {
    this.interruptionGeneration_++;
    this.interruptionActive_ = false;
    this.interruptionStartedAt_ = 0;
    this.autoResumeEligible_ = false;
    this.wasPlayingBeforeInterruption_ = false;
    this.cancelAutoResumeTimer_();
  }

  // ---- 输出设备断开自动暂停 ----

  private registerDeviceChangeListener_(): void {
    if (this.deviceChangeCb_) return;
    try {
      const routing = audio.getAudioManager().getRoutingManager();
      const cb: (action: audio.DeviceChangeAction) => void = (action: audio.DeviceChangeAction) => {
        this.handleDeviceChange_(action);
      };
      routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, cb);
      this.routingManager_ = routing;
      this.deviceChangeCb_ = cb;
      this.outputWasHeadset_ = this.isCurrentOutputHeadset_();
      console.info('[AudioPlayer] deviceChange listener registered');
    } catch (e) {
      console.warn('[AudioPlayer] register deviceChange listener failed: ' + (e as Error).message);
      this.routingManager_ = null;
      this.deviceChangeCb_ = null;
    }
  }

  private unregisterDeviceChangeListener_(): void {
    if (!this.routingManager_ || !this.deviceChangeCb_) return;
    try {
      this.routingManager_.off('deviceChange', this.deviceChangeCb_);
    } catch (e) {
      console.warn('[AudioPlayer] unregister deviceChange listener failed: ' + (e as Error).message);
    }
    this.routingManager_ = null;
    this.deviceChangeCb_ = null;
    this.outputWasHeadset_ = false;
  }

  private handleDeviceChange_(action: audio.DeviceChangeAction): void {
    const wasHeadset = this.outputWasHeadset_;
    const nowHeadset = this.isCurrentOutputHeadset_();
    this.outputWasHeadset_ = nowHeadset;
    if (action.type !== audio.DeviceChangeType.DISCONNECT || !wasHeadset || nowHeadset) return;

    // 设备断开时不允许后续的 audioInterrupt END/RESUME 把声音恢复到扬声器。
    const shouldPause = this.state_ === PlayState.PLAYING || this.interruptionActive_;
    if (!shouldPause) return;
    console.info('[AudioPlayer] headset output disconnected, auto pause');
    this.clearInterruptionState_();
    if (this.state_ === PlayState.PLAYING) {
      // 先同步切到暂停态，避免异步 pause() 完成前到达的旧 BEGIN/PAUSE
      // 又把这次设备断开误判为可自动恢复的焦点中断。
      this.state_ = PlayState.PAUSED;
      this.onStateChange_?.(this.state_);
      this.avPlayer_?.pause().catch((e: Error) => {
        console.warn('[AudioPlayer] pause for device disconnect failed: ' + e.message);
      });
    } else {
      // 系统可能已经先将 AVPlayer 置为 paused；同步通知页面，但保持不可自动恢复。
      this.onStateChange_?.(PlayState.PAUSED);
    }
  }

  private isCurrentOutputHeadset_(): boolean {
    try {
      const routing = this.routingManager_ ?? audio.getAudioManager().getRoutingManager();
      const preferred = routing.getPreferredOutputDeviceForRendererInfoSync({
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0,
      });
      if (preferred.length > 0) return this.containsHeadsetDevice_(preferred);
      return this.containsHeadsetDevice_(routing.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG));
    } catch (e) {
      console.warn('[AudioPlayer] query output devices failed: ' + (e as Error).message);
    }
    return false;
  }

  private containsHeadsetDevice_(devices: audio.AudioDeviceDescriptors): boolean {
    for (let i = 0; i < devices.length; i++) {
      const type = devices[i].deviceType;
      if (type === audio.DeviceType.BLUETOOTH_SCO || type === audio.DeviceType.BLUETOOTH_A2DP ||
        type === audio.DeviceType.WIRED_HEADSET || type === audio.DeviceType.WIRED_HEADPHONES ||
        type === audio.DeviceType.USB_HEADSET) return true;
    }
    return false;
  }

  /**
   * 播放音频
   */
  async play(track: AudioTrack): Promise<void> {
    const run = this.playQueue_.then(() => this.playInternal_(track), () => this.playInternal_(track));
    this.playQueue_ = run.then((): void => {}, (): void => {});
    return await run;
  }

  private async playInternal_(track: AudioTrack): Promise<void> {
    if (!this.avPlayer_) await this.init();
    if (!this.avPlayer_) throw new Error('AVPlayer not initialized');

    this.clearInterruptionState_();
    this.currentTrack_ = track;

    try {
      await this.resetForNewTrack_();
      if (!this.avPlayer_) throw new Error('AVPlayer not initialized');

      const parsed = parseAudioUrl(track.url);
      const hasHeaders = Object.keys(parsed.headers).length > 0;
      // 普通 URL 直接设置 url，由系统切换到 initialized。只有确实带有
      // Legado 请求头扩展时才使用 MediaSource；setMediaSource 的状态切换是
      // 异步的，下面统一等待 initialized 后再 prepare。
      this.mediaSource_ = null;
      if (/^file:\/\//i.test(parsed.url) || !hasHeaders) {
        this.avPlayer_.url = parsed.url;
      } else {
        this.mediaSource_ = media.createMediaSourceWithUrl(parsed.url, parsed.headers);
        await this.avPlayer_.setMediaSource(this.mediaSource_);
      }
      await this.waitForNativeState_('initialized');

      // 有声书使用 AUDIOBOOK 流类型，系统才能按朗读/听书策略正确分配音频焦点。
      // 该属性必须在 initialized 状态、prepare 之前设置。
      try {
        this.avPlayer_.audioRendererInfo = {
          usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
          rendererFlags: 0,
        };
        // audioRendererInfo 生效后再取一次实际路由，覆盖播放器创建时尚未准备好的情况。
        this.outputWasHeadset_ = this.isCurrentOutputHeadset_();
      } catch (e) {
        console.warn('[AudioPlayer] set audiobook renderer info failed: ' + (e as Error).message);
      }

      await this.avPlayer_.prepare();
      await this.waitForNativeState_('prepared');

      // SHARE_MODE 下焦点恢复会回调 RESUME，由本类主动 play()，实现短时中断自动恢复。
      try {
        this.avPlayer_.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
      } catch (e) {
        console.warn('[AudioPlayer] set interrupt mode failed: ' + (e as Error).message);
      }

      // 应用已设置的音量、速度，并显式启动播放。播放不能放在
      // stateChange 回调中，否则会与 prepare 的 Promise 产生重入竞态。
      this.avPlayer_.setVolume(this.volume_);
      this.applySpeed_();
      await this.avPlayer_.play();

      console.info(`[AudioPlayer] Playing: ${track.title} (${track.url})`);
    } catch (err) {
      console.error('[AudioPlayer] Play failed:', err);
      this.state_ = PlayState.ERROR;
      this.onError_?.(String(err));
      throw err;
    }
  }

  /**
   * 暂停
   */
  async pause(): Promise<void> {
    // 用户主动暂停后，忽略稍后到达的旧 RESUME 事件。
    this.clearInterruptionState_();
    if (this.avPlayer_ && this.state_ === PlayState.PLAYING) {
      await this.avPlayer_.pause();
    }
  }

  /**
   * 恢复
   */
  async resume(): Promise<void> {
    if (this.avPlayer_ && this.state_ === PlayState.PAUSED) {
      if (this.interruptionActive_) {
        console.info('[AudioPlayer] resume deferred while audio focus is interrupted');
        return;
      }
      if (this.resumeInProgress_) return;
      this.resumeInProgress_ = true;
      try {
        await this.avPlayer_.play();
      } finally {
        this.resumeInProgress_ = false;
      }
    }
  }

  /**
   * 停止
   */
  async stop(): Promise<void> {
    this.clearInterruptionState_();
    if (this.avPlayer_ && (this.state_ === PlayState.PLAYING || this.state_ === PlayState.PAUSED)) {
      await this.avPlayer_.stop();
      this.position_ = 0;
    }
  }

  /**
   * 跳转到指定位置（毫秒）
   */
  async seek(timeMs: number): Promise<void> {
    if (this.avPlayer_ && this.state_ !== PlayState.IDLE) {
      this.avPlayer_.seek(timeMs);
    }
  }

  /**
   * 设置播放速度 0.5x ~ 3.0x
   */
  setSpeed(speed: number): void {
    this.speed_ = Math.max(0.5, Math.min(3.0, speed));
    if (this.avPlayer_) {
      this.applySpeed_();
    }
  }

  /**
   * 设置音量 0.0 ~ 1.0
   */
  setVolume(vol: number): void {
    this.volume_ = Math.max(0, Math.min(1, vol));
    if (this.avPlayer_) {
      this.avPlayer_.setVolume(this.volume_);
    }
  }

  /**
   * 释放播放器资源
   */
  async destroy(): Promise<void> {
    this.clearInterruptionState_();
    this.unregisterDeviceChangeListener_();
    if (this.avPlayer_) {
      // 移除所有监听
      this.avPlayer_.off('stateChange');
      this.avPlayer_.off('timeUpdate');
      this.avPlayer_.off('endOfStream');
      this.avPlayer_.off('audioInterrupt');
      this.avPlayer_.off('error');

      await this.avPlayer_.release();
      this.avPlayer_ = null;
    }
    this.mediaSource_ = null;
    this.state_ = PlayState.IDLE;
    this.currentTrack_ = null;
    this.position_ = 0;
    this.duration_ = 0;
    console.info('[AudioPlayer] Destroyed');
  }
}

/**
 * 应用级播放器实例。
 *
 * Android Legado 由 AudioPlayService 持有播放器，因此离开阅读页后播放不会
 * 被新页面创建的第二个播放器打断。HOS 当前没有单独的 ServiceExtensionAbility，
 * 先用进程级单例保持同样的切页行为；MainAbility 的 audioPlayback 后台模式负责
 * 允许音频在页面离开后继续播放。
 */
export const globalAudioPlayer: AudioPlayer = new AudioPlayer();
