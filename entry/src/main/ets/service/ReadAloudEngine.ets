/**
 * 朗读引擎 — 纯 writeData 驱动，onComplete 不参与调度
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import audio from '@ohos.multimedia.audio';

export enum AloudState { IDLE = 0, PLAYING = 1, PAUSED = 2, STOPPED = 3 }

export interface AloudCallback {
  onStateChange?: (state: AloudState) => void;
  onProgress?: (charIndex: number, totalChars: number) => void;
  onChapterEnd?: () => void;
  onError?: (msg: string) => void;
}

export class ReadAloudEngine {
  private ttsEngine_: textToSpeech.TextToSpeechEngine | null = null;
  private audioRenderer_: audio.AudioRenderer | null = null;
  private state_: AloudState = AloudState.IDLE;
  private speed_: number = 1.0;
  private textQueue_: string[] = [];
  private currentTextIdx_: number = 0;
  private totalChars_: number = 0;
  private playedChars_: number = 0;
  private callback_: AloudCallback;
  // 每段 TTS 合成后，onData 小块拼成完整 ArrayBuffer
  private chunkPcm_: ArrayBuffer[] = [];
  private chunkFull_: Uint8Array | null = null;
  private chunkOffset_: number = 0;
  private synthPending_: boolean = false;
  private chapterEnded_: boolean = false;

  constructor(callback: AloudCallback) { this.callback_ = callback; }

  get state(): AloudState { return this.state_; }

  private setState_(s: AloudState): void {
    this.state_ = s;
    this.callback_.onStateChange?.(s);
  }

  async init(): Promise<void> {
    const extraParam: Record<string, Object> = {
      'name': 'legado_tts_' + Date.now(),
      'style': 'interaction-broadcast',
      'locate': 'CN',
    };

    this.ttsEngine_ = await new Promise<textToSpeech.TextToSpeechEngine>((resolve, reject) => {
      textToSpeech.createEngine(
        { language: 'zh-CN', person: 13, online: 1, extraParams: extraParam },
        (err: BusinessError, engine: textToSpeech.TextToSpeechEngine) => {
          if (err) { reject(new Error('TTS: ' + err.code)); }
          else {
            engine.setListener({
              onStart: () => {},
              onData: (_reqId: string, audioData: ArrayBuffer) => {
                this.chunkPcm_.push(audioData);
              },
              onComplete: () => {
                // 合成完 → 拼接所有小块为完整 PCM
                this.buildChunk_();
              },
              onStop: () => {},
              onError: (_reqId: string, code: number) => {
                this.callback_.onError?.('TTS error: ' + code);
              },
            });
            resolve(engine);
          }
        });
    });

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    };
    this.audioRenderer_ = await audio.createAudioRenderer({
      streamInfo: streamInfo,
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MEDIA, rendererFlags: 0 },
    });

    this.audioRenderer_.on('writeData', (buffer: ArrayBuffer) => {
      this.writeData_(buffer);
    });
  }

  async speak(text: string, speed: number = 1.0): Promise<void> {
    if (!this.ttsEngine_ || !this.audioRenderer_) { this.callback_.onError?.('引擎未初始化'); return; }
    this.speed_ = speed;
    this.chunkPcm_ = [];
    this.chunkFull_ = null;
    this.chunkOffset_ = 0;
    this.synthPending_ = false;
    this.chapterEnded_ = false;
    this.textQueue_ = this.splitText_(text);
    this.currentTextIdx_ = 0;
    this.totalChars_ = text.length;
    this.playedChars_ = 0;
    console.info('[Aloud] ' + text.length + ' chars → ' + this.textQueue_.length + ' chunks');
    await this.audioRenderer_.start();
    this.setState_(AloudState.PLAYING);
    this.speakNext_();
  }

  async pause(): Promise<void> {
    if (this.state_ !== AloudState.PLAYING) return;
    await this.audioRenderer_?.pause();
    this.setState_(AloudState.PAUSED);
  }

  async resume(): Promise<void> {
    if (this.state_ !== AloudState.PAUSED) return;
    await this.audioRenderer_?.start();
    this.setState_(AloudState.PLAYING);
  }

  async stop(): Promise<void> {
    try { await this.ttsEngine_?.stop(); } catch (_) {}
    try { await this.audioRenderer_?.stop(); await this.audioRenderer_?.flush(); } catch (_) {}
    this.chunkFull_ = null;
    this.chunkPcm_ = [];
    this.setState_(AloudState.STOPPED);
  }

  async release(): Promise<void> {
    await this.stop();
    try { await this.audioRenderer_?.release(); } catch (_) {}
    try { await this.ttsEngine_?.shutdown(); } catch (_) {}
    this.audioRenderer_ = null;
    this.ttsEngine_ = null;
    this.setState_(AloudState.IDLE);
  }

  // ========================

  private splitText_(text: string): string[] {
    const clean = text.replace(/\s+/g, ' ');
    const result: string[] = [];
    let start = 0;
    while (start < clean.length) {
      let end = Math.min(start + 300, clean.length);
      if (end < clean.length) {
        for (let i = end; i > start + 150; i--) {
          if ('。！？\n'.includes(clean[i])) { end = i + 1; break; }
        }
      }
      result.push(clean.substring(start, end).trim());
      start = end;
    }
    return result.filter(s => s.length > 0);
  }

  private speakNext_(): void {
    if (this.state_ !== AloudState.PLAYING || this.synthPending_) return;
    if (this.currentTextIdx_ >= this.textQueue_.length) {
      this.chapterEnded_ = true;
      return;
    }
    const text = this.textQueue_[this.currentTextIdx_];
    this.currentTextIdx_++;
    this.playedChars_ += text.length;
    this.callback_.onProgress?.(this.playedChars_, this.totalChars_);
    this.synthPending_ = true;
    console.info('[Aloud] synth chunk ' + (this.currentTextIdx_) + ': ' + text.length + ' chars');

    const extraParam: Record<string, Object> = {};
    extraParam['speed'] = this.speed_;
    extraParam['volume'] = 1.0;
    extraParam['playType'] = 0;
    extraParam['audioType'] = 'pcm';

    try {
      this.ttsEngine_!.speak(text, { requestId: 't_' + Date.now(), extraParams: extraParam });
    } catch (e) {
      this.synthPending_ = false;
      this.callback_.onError?.('合成失败: ' + (e as Error).message);
    }
  }

  /** onData 收集完 → 拼成大块 */
  private buildChunk_(): void {
    this.synthPending_ = false;
    if (this.chunkPcm_.length === 0) {
      this.chunkFull_ = null;
      return;
    }
    const total = this.chunkPcm_.reduce((s: number, b: ArrayBuffer) => s + b.byteLength, 0);
    const merged = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < this.chunkPcm_.length; i++) {
      const src = new Uint8Array(this.chunkPcm_[i]);
      merged.set(src, offset);
      offset += src.byteLength;
    }
    this.chunkPcm_ = [];
    this.chunkFull_ = merged;
    this.chunkOffset_ = 0;
    console.info('[Aloud] chunk ready: ' + total + ' bytes PCM');
  }

  /** writeData: 从当前位置复制数据，不够就填 0 */
  private writeData_(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    const dst = new Uint8Array(buffer);
    const bufLen = dst.byteLength;
    let written = 0;

    while (written < bufLen) {
      if (!this.chunkFull_ || this.chunkOffset_ >= this.chunkFull_.byteLength) {
        // 当前段播完，换下一段
        this.chunkFull_ = null;
        this.chunkOffset_ = 0;
        // 触发预合成
        if (!this.synthPending_ && !this.chapterEnded_) {
          this.speakNext_();
        }
        if (!this.chunkFull_) {
          // 没数据了，剩余填 0
          if (written > 0) {
            // 部分填了，剩余填零
          }
          for (let i = written; i < bufLen; i++) dst[i] = 0;
          return audio.AudioDataCallbackResult.VALID;
        }
      }
      const src = this.chunkFull_!;
      const avail = src.byteLength - this.chunkOffset_;
      const copy = Math.min(bufLen - written, avail);
      dst.set(src.slice(this.chunkOffset_, this.chunkOffset_ + copy), written);
      this.chunkOffset_ += copy;
      written += copy;
    }
    // 全部播完且章节结束
    if (!this.chunkFull_ && this.chapterEnded_ && !this.synthPending_ && this.chunkPcm_.length === 0) {
      this.callback_.onChapterEnd?.();
      return audio.AudioDataCallbackResult.INVALID;
    }
    return audio.AudioDataCallbackResult.VALID;
  }
}
