/**
 * TTS 语音合成播放器
 * 基于 @ohos.speech.tts 实现
 *
 * 支持: 文本朗读、语速调节、暂停/恢复、队列管理
 */
import tts from '@ohos.speech.tts';

export type TtsState = 'idle' | 'speaking' | 'paused' | 'stopped' | 'error';

export interface TtsOptions {
  text: string;
  speed?: number;       // 0.5 ~ 2.0, 默认 1.0
  pitch?: number;       // 0.5 ~ 2.0, 默认 1.0
  volume?: number;      // 0.0 ~ 1.0, 默认 1.0
  queueMode?: number;   // 0=立即打断, 1=追加到队列
}

export class TTSPlayer {
  private ttsEngine_: tts.TtsEngine | null = null;
  private state_: TtsState = 'idle';
  private speed_: number = 1.0;

  private onStart_: (() => void) | null = null;
  private onStop_: (() => void) | null = null;
  private onPause_: (() => void) | null = null;
  private onResume_: (() => void) | null = null;
  private onError_: ((err: string) => void) | null = null;

  get state(): TtsState { return this.state_; }

  set onStart(cb: () => void) { this.onStart_ = cb; }
  set onStop(cb: () => void) { this.onStop_ = cb; }
  set onError(cb: (err: string) => void) { this.onError_ = cb; }

  /**
   * 初始化 TTS 引擎
   */
  async init(): Promise<void> {
    if (this.ttsEngine_) return;

    try {
      // 创建 TTS 引擎实例
      this.ttsEngine_ = tts.createTtsEngine();

      // 注册事件监听
      this.ttsEngine_.on('speak', (data) => {
        console.info('[TTS] Speak callback:', JSON.stringify(data));
      });

      this.ttsEngine_.on('error', (data) => {
        console.error('[TTS] Error:', data);
        this.state_ = 'error';
        this.onError_?.(JSON.stringify(data));
      });

      console.info('[TTSPlayer] Engine initialized');
    } catch (err) {
      console.error('[TTSPlayer] Init failed:', err);
      this.state_ = 'error';
      throw err;
    }
  }

  /**
   * 开始朗读文本
   */
  async speak(text: string, options?: Partial<TtsOptions>): Promise<void> {
    if (!text) return;
    if (!this.ttsEngine_) await this.init();

    try {
      const request: tts.SpeakOptions = {
        text: text,
        speed: options?.speed ?? this.speed_,
        pitch: options?.pitch ?? 1.0,
        volume: options?.volume ?? 1.0,
        queueMode: options?.queueMode ?? 0, // 0=立即打断
      };

      await this.ttsEngine_!.speak(request);
      this.state_ = 'speaking';
      this.onStart_?.();
      console.info(`[TTSPlayer] Speaking: ${text.slice(0, 50)}...`);
    } catch (err) {
      console.error('[TTSPlayer] Speak failed:', err);
      this.state_ = 'error';
      this.onError_?.(String(err));
    }
  }

  /**
   * 暂停朗读
   */
  async pause(): Promise<void> {
    if (this.ttsEngine_ && this.state_ === 'speaking') {
      try {
        await this.ttsEngine_!.pause();
        this.state_ = 'paused';
        this.onPause_?.();
        console.info('[TTSPlayer] Paused');
      } catch (err) {
        console.error('[TTSPlayer] Pause failed:', err);
      }
    }
  }

  /**
   * 恢复朗读
   */
  async resume(): Promise<void> {
    if (this.ttsEngine_ && this.state_ === 'paused') {
      try {
        await this.ttsEngine_!.resume();
        this.state_ = 'speaking';
        this.onResume_?.();
        console.info('[TTSPlayer] Resumed');
      } catch (err) {
        console.error('[TTSPlayer] Resume failed:', err);
      }
    }
  }

  /**
   * 停止朗读
   */
  async stop(): Promise<void> {
    if (this.ttsEngine_ && (this.state_ === 'speaking' || this.state_ === 'paused')) {
      try {
        await this.ttsEngine_!.stop();
        this.state_ = 'stopped';
        this.onStop_?.();
        console.info('[TTSPlayer] Stopped');
      } catch (err) {
        console.error('[TTSPlayer] Stop failed:', err);
      }
    }
  }

  /**
   * 设置朗读速度
   */
  setSpeed(speed: number): void {
    this.speed_ = Math.max(0.5, Math.min(2.0, speed));
    if (this.ttsEngine_) {
      try {
        this.ttsEngine_!.setSpeed(this.speed_);
        console.info(`[TTSPlayer] Speed set to ${this.speed_}`);
      } catch (err) {
        console.error('[TTSPlayer] SetSpeed failed:', err);
      }
    }
  }

  /**
   * 释放 TTS 引擎资源
   */
  destroy(): void {
    if (this.ttsEngine_) {
      this.ttsEngine_.off('speak');
      this.ttsEngine_.off('error');
      this.ttsEngine_.release();
      this.ttsEngine_ = null;
    }
    this.state_ = 'idle';
    this.onStart_ = null;
    this.onStop_ = null;
    this.onError_ = null;
    console.info('[TTSPlayer] Destroyed');
  }
}
