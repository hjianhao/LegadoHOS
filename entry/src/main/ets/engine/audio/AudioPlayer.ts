/**
 * 音频播放器引擎
 * 基于 @ohos.multimedia.media AVPlayer 实现
 *
 * 支持: 在线/本地音频播放、进度追踪、变速、音量控制
 */
import media from '@ohos.multimedia.media';

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
  private state_: PlayState = PlayState.IDLE;
  private currentTrack_: AudioTrack | null = null;
  private position_: number = 0;
  private duration_: number = 0;
  private volume_: number = 1.0;
  private speed_: number = 1.0;

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

    try {
      this.avPlayer_ = await media.createAVPlayer();
      this.setupListeners();
      console.info('[AudioPlayer] AVPlayer created');
    } catch (err) {
      console.error('[AudioPlayer] Init failed:', err);
      this.state_ = PlayState.ERROR;
    }
  }

  /**
   * 注册 AVPlayer 事件监听
   */
  private setupListeners(): void {
    if (!this.avPlayer_) return;

    this.avPlayer_.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      console.info(`[AudioPlayer] State: ${state}`);
      switch (state) {
        case 'initialized':
          this.state_ = PlayState.INITIALIZED;
          break;
        case 'prepared':
          this.state_ = PlayState.PREPARED;
          // AVPlayer.duration 的单位是毫秒，AudioPlayer 对外统一使用秒。
          this.duration_ = Math.floor(this.avPlayer_!.duration / 1000);
          this.avPlayer_!.play();
          break;
        case 'playing':
          this.state_ = PlayState.PLAYING;
          break;
        case 'paused':
          this.state_ = PlayState.PAUSED;
          break;
        case 'stopped':
          this.state_ = PlayState.STOPPED;
          break;
        case 'error':
          this.state_ = PlayState.ERROR;
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

    this.avPlayer_.on('error', (err) => {
      console.error('[AudioPlayer] Error:', err);
      this.state_ = PlayState.ERROR;
      this.onError_?.(String(err));
    });
  }

  /**
   * 播放音频
   */
  async play(track: AudioTrack): Promise<void> {
    if (!this.avPlayer_) await this.init();
    if (!this.avPlayer_) throw new Error('AVPlayer not initialized');

    this.currentTrack_ = track;

    try {
      // 切换章节时必须先回到 idle，否则 AVPlayer 会拒绝重新设置源。
      if (this.state_ !== PlayState.IDLE && this.state_ !== PlayState.INITIALIZED) {
        try { await this.avPlayer_.stop(); } catch (_e) { /* already stopped */ }
        try { await this.avPlayer_.reset(); } catch (_e) { /* some devices reset implicitly */ }
      }

      const parsed = parseAudioUrl(track.url);
      // MediaSource 支持将 Referer/User-Agent 等请求头传给网络音频；没有头时
      // 仍走同一 API，避免把 Legado 的扩展串误传给底层播放器。
      if (/^file:\/\//i.test(parsed.url)) {
        this.avPlayer_.url = parsed.url;
      } else {
        const mediaSource = media.createMediaSourceWithUrl(parsed.url, parsed.headers);
        try {
          await this.avPlayer_.setMediaSource(mediaSource);
        } catch (sourceError) {
          // 少数旧系统只支持 url 属性；没有请求头时可以安全降级。
          if (Object.keys(parsed.headers).length > 0) throw sourceError;
          this.avPlayer_.url = parsed.url;
        }
      }

      // 准备（触发 stateChange → prepared）
      await this.avPlayer_.prepare();

      // 应用已设置的音量、速度
      this.avPlayer_.setVolume(this.volume_);
      this.applySpeed_();

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
    if (this.avPlayer_ && this.state_ === PlayState.PLAYING) {
      await this.avPlayer_.pause();
    }
  }

  /**
   * 恢复
   */
  async resume(): Promise<void> {
    if (this.avPlayer_ && this.state_ === PlayState.PAUSED) {
      await this.avPlayer_.play();
    }
  }

  /**
   * 停止
   */
  async stop(): Promise<void> {
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
    if (this.avPlayer_) {
      // 移除所有监听
      this.avPlayer_.off('stateChange');
      this.avPlayer_.off('timeUpdate');
      this.avPlayer_.off('endOfStream');
      this.avPlayer_.off('error');

      await this.avPlayer_.release();
      this.avPlayer_ = null;
    }
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
