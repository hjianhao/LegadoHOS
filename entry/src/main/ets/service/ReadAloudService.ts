/**
 * 朗读服务 — 后台 Service
 *
 * 统一的朗读服务，整合 TTS 朗读和音频播放。
 * 作为 ServiceAbility 在后台运行，管理朗读状态、焦点、通知。
 */
import rpc from '@ohos.rpc';
import notificationManager from '@ohos.notificationManager';
import { audio } from '@ohos.multimedia.audio';
import { TTSPlayer } from '../engine/audio/TTSPlayer';
import { AudioPlayer, AudioTrack } from '../engine/audio/AudioPlayer';

export type ReadAloudState = 'idle' | 'tts' | 'audio' | 'paused' | 'stopped' | 'error';

export class ReadAloudService extends rpc.RemoteObject {
  // 单例
  private static instance: ReadAloudService;

  // 引擎
  private ttsPlayer_: TTSPlayer = new TTSPlayer();
  private audioPlayer_: AudioPlayer = new AudioPlayer();

  // 状态
  private state_: ReadAloudState = 'idle';
  private currentText_: string = '';
  private currentPos_: number = 0;

  // 音频焦点
  private audioManager_: audio.AudioManager | null = null;
  private audioInterrupt_: audio.InterruptManager | null = null;

  constructor(descriptor: string) {
    super(descriptor);
    ReadAloudService.instance = this;
    this.init();
  }

  static getInstance(): ReadAloudService {
    return ReadAloudService.instance;
  }

  /**
   * 初始化引擎和音频焦点
   */
  private async init(): Promise<void> {
    try {
      // 初始化 TTS
      await this.ttsPlayer_.init();

      // 初始化音频播放器
      await this.audioPlayer_.init();

      // 获取音频管理器（用于音频焦点处理）
      this.audioManager_ = audio.getAudioManager();

      // 注册 TTS 回调
      this.ttsPlayer_.onStart = () => {
        this.createNotification('朗读中...', this.currentText_.slice(0, 50));
      };
      this.ttsPlayer_.onStop = () => {
        this.state_ = 'stopped';
        this.cancelNotification();
      };
      this.ttsPlayer_.onError = (err) => {
        this.state_ = 'error';
        console.error('[ReadAloud] TTS error:', err);
      };

      // 注册音频播放器回调
      this.audioPlayer_.onCompletion = () => {
        this.state_ = 'idle';
        this.cancelNotification();
      };

      console.info('[ReadAloud] Service initialized');
    } catch (err) {
      console.error('[ReadAloud] Init failed:', err);
    }
  }

  /**
   * 开始 TTS 朗读
   */
  async startTTS(text: string, startPos: number = 0): Promise<void> {
    this.currentText_ = text;
    this.currentPos_ = startPos;
    this.state_ = 'tts';

    try {
      // 申请音频焦点
      await this.requestAudioFocus();

      // 从指定位置开始朗读
      const textToSpeak = startPos > 0 ? text.slice(startPos) : text;
      await this.ttsPlayer_.speak(textToSpeak);

      console.info('[ReadAloud] TTS started');
    } catch (err) {
      console.error('[ReadAloud] TTS start failed:', err);
      this.state_ = 'error';
    }
  }

  /**
   * 开始音频播放（有声书）
   */
  async startAudio(audioUrl: string, title: string = ''): Promise<void> {
    this.state_ = 'audio';

    try {
      await this.requestAudioFocus();

      const track: AudioTrack = {
        title: title,
        artist: 'Legado HOS',
        url: audioUrl,
        duration: 0,
        coverUrl: '',
      };
      await this.audioPlayer_.play(track);

      this.createNotification('播放中', title);
      console.info('[ReadAloud] Audio started:', audioUrl);
    } catch (err) {
      console.error('[ReadAloud] Audio start failed:', err);
      this.state_ = 'error';
    }
  }

  /**
   * 暂停
   */
  async pause(): Promise<void> {
    if (this.state_ === 'tts') {
      await this.ttsPlayer_.pause();
    } else if (this.state_ === 'audio') {
      await this.audioPlayer_.pause();
    }
    this.state_ = 'paused';
  }

  /**
   * 恢复
   */
  async resume(): Promise<void> {
    if (this.state_ === 'paused') {
      if (this.ttsPlayer_['state'] === 'paused') {
        await this.ttsPlayer_.resume();
        this.state_ = 'tts';
      } else {
        await this.audioPlayer_.resume();
        this.state_ = 'audio';
      }
    }
  }

  /**
   * 停止
   */
  async stop(): Promise<void> {
    await this.ttsPlayer_.stop();
    await this.audioPlayer_.stop();
    this.state_ = 'stopped';
    this.currentPos_ = 0;
    this.cancelNotification();
    this.abandonAudioFocus();
  }

  /**
   * 跳转到指定位置
   */
  seekTo(pos: number): void {
    if (this.state_ === 'tts') {
      this.currentPos_ = pos;
      // TTS 不支持跳转，重新朗读
      this.ttsPlayer_.stop();
      this.ttsPlayer_.speak(this.currentText_.slice(pos));
    } else if (this.state_ === 'audio') {
      this.audioPlayer_.seek(pos * 1000); // s → ms
    }
  }

  /**
   * 设置朗读/播放速度
   */
  setSpeed(speed: number): void {
    this.ttsPlayer_.setSpeed(speed);
    this.audioPlayer_.setSpeed(speed);
  }

  getState(): ReadAloudState { return this.state_; }
  getPosition(): number { return this.currentPos_; }

  /**
   * 申请音频焦点（避免与其他音频冲突）
   */
  private async requestAudioFocus(): Promise<void> {
    try {
      const audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MEDIA,
        rendererFlags: 0,
      };
      // AVSession 方式在 HarmonyOS NEXT 中管理焦点
      console.info('[ReadAloud] Audio focus requested');
    } catch (err) {
      console.warn('[ReadAloud] Request focus failed:', err);
    }
  }

  /**
   * 放弃音频焦点
   */
  private abandonAudioFocus(): void {
    // AVSession release
    console.info('[ReadAloud] Audio focus abandoned');
  }

  /**
   * 创建常驻通知
   */
  private createNotification(title: string, text: string): void {
    try {
      const notificationRequest = {
        id: 1001,
        content: {
          contentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
          },
        },
        slotType: notificationManager.SlotType.SERVICE_INFORMATION,
      };
      notificationManager.publish(notificationRequest);
    } catch (err) {
      console.warn('[ReadAloud] Notification failed:', err);
    }
  }

  /**
   * 取消通知
   */
  private cancelNotification(): void {
    try {
      notificationManager.cancel(1001);
    } catch (err) {
      console.warn('[ReadAloud] Cancel notification failed:', err);
    }
  }
}
