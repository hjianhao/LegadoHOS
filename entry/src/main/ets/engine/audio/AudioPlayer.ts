/**
 * 音频播放器引擎
 * 基于 @ohos.multimedia.media AVPlayer 实现
 *
 * 支持: 在线/本地音频播放、进度追踪、变速、音量控制
 */
import media from '@ohos.multimedia.media';
import { fileIo } from '@ohos.file.fs';

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
          this.duration_ = this.avPlayer_!.duration;
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
      // 设置播放源（支持 http/https/file）
      this.avPlayer_.url = track.url;

      // 准备（触发 stateChange → prepared）
      await this.avPlayer_.prepare();

      // 应用已设置的音量、速度
      this.avPlayer_.volume = this.volume_;
      this.avPlayer_.speed = this.speed_;

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
      this.avPlayer_.seek(timeMs, (err) => {
        if (err) console.error('[AudioPlayer] Seek failed:', err);
      });
    }
  }

  /**
   * 设置播放速度 0.5x ~ 3.0x
   */
  setSpeed(speed: number): void {
    this.speed_ = Math.max(0.5, Math.min(3.0, speed));
    if (this.avPlayer_) {
      this.avPlayer_.speed = this.speed_;
    }
  }

  /**
   * 设置音量 0.0 ~ 1.0
   */
  setVolume(vol: number): void {
    this.volume_ = Math.max(0, Math.min(1, vol));
    if (this.avPlayer_) {
      this.avPlayer_.volume = this.volume_;
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
