/**
 * 朗读引擎 — 纯 writeData 驱动，onComplete 不参与调度
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import audio from '@ohos.multimedia.audio';
import { ITtsBackend, TtsSynthRequest } from './tts/ITtsBackend';

export enum AloudState { IDLE = 0, PLAYING = 1, PAUSED = 2, STOPPED = 3 }

export interface AloudChapterText { text: string; offset: number; chapterIndex: number; }

let globalChapterProvider_: (() => Promise<AloudChapterText | null>) | null = null;

export function setAloudChapterProvider(provider: () => Promise<AloudChapterText | null>): void {
  globalChapterProvider_ = provider;
}

export interface ReadAloudVoiceConfig {
  language: string;
  person: number;
  style: string;
}

export interface ReadAloudVoice extends ReadAloudVoiceConfig {
  key: string;
  gender: string;
  description: string;
  status: string;
  downloaded: boolean;
}

export interface AloudCallback {
  onStateChange?: (state: AloudState) => void;
  onProgress?: (charIndex: number, totalChars: number) => void;
  onChapterEnd?: () => void;
  onError?: (msg: string) => void;
  /** 引擎需要下一章文本时回调 */
  onNeedNextChapter?: () => Promise<AloudChapterText | null>;
  /** 引擎成功加载新章节时回调 */
  onChapterChange?: (chapterIndex: number) => void;
}

export class TtsVoiceManager {
  static readonly DEFAULT_VOICE: ReadAloudVoiceConfig = {
    language: 'zh-CN',
    person: 13,
    style: 'interaction-broadcast',
  };

  static makeKey(language: string, person: number, style: string): string {
    return language + '#' + person + '#' + style;
  }

  static isVoiceDownloaded(status: string): boolean {
    const normalized = (status || '').toUpperCase();
    return normalized.length === 0 || normalized !== 'GA';
  }

  static statusLabel(status: string): string {
    return TtsVoiceManager.isVoiceDownloaded(status) ? '已下载' : '未下载';
  }

  static async listOfflineVoices(): Promise<ReadAloudVoice[]> {
    const voices = await textToSpeech.listVoices({
      requestId: 'voice_list_' + Date.now(),
      online: 1,
      extraParams: {
        'locate': 'CN',
      },
    });
    const result: ReadAloudVoice[] = [];
    for (let i = 0; i < voices.length; i++) {
      const voice = voices[i];
      const status = voice.status || '';
      result.push({
        key: TtsVoiceManager.makeKey(voice.language, voice.person, voice.style),
        language: voice.language,
        person: voice.person,
        style: voice.style,
        gender: voice.gender || '',
        description: voice.description || '',
        status: status,
        downloaded: TtsVoiceManager.isVoiceDownloaded(status),
      });
    }
    return result;
  }

  static async downloadVoice(voice: ReadAloudVoiceConfig, onProgress?: (progress: string) => void): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      try {
        textToSpeech.downloadVoice({
          requestId: 'voice_download_' + Date.now(),
          language: voice.language,
          person: voice.person,
          style: voice.style,
        }, (err: BusinessError, response: textToSpeech.DownloadResponse) => {
          if (err) {
            if (err.code === 1002300010) {
              resolve();
            } else {
              reject(new Error('下载音色失败: ' + err.code));
            }
            return;
          }
          if (!response) {
            reject(new Error('下载音色失败: 无下载响应'));
            return;
          }
          response.on('start', () => {
            onProgress?.('0%');
          });
          response.on('progress', (progress: string) => {
            onProgress?.(progress.indexOf('%') >= 0 ? progress : progress + '%');
          });
          response.on('complete', () => {
            onProgress?.('100%');
            resolve();
          });
          response.on('cancel', () => {
            reject(new Error('已取消音色下载'));
          });
          response.on('error', (downloadErr: BusinessError) => {
            reject(new Error('下载音色失败: ' + downloadErr.code));
          });
        });
      } catch (e) {
        reject(e as Error);
      }
    });
  }
}

export class ReadAloudEngine {
  private ttsEngine_: textToSpeech.TextToSpeechEngine | null = null;
  private audioRenderer_: audio.AudioRenderer | null = null;
  private state_: AloudState = AloudState.IDLE;
  private speed_: number = 1.0;
  private backend_: ITtsBackend | null = null;
  private currentRendererRate_: number = 0;  // 当前 AudioRenderer 的采样率
  private textQueue_: string[] = [];
  private currentTextIdx_: number = 0;
  private totalChars_: number = 0;
  private playedChars_: number = 0;
  private startTextOffset_: number = 0;
  private startChapterIdx_: number = 0;
  private totalPcmWritten_: number = 0;
  private callback_: AloudCallback;
  // 每段 TTS 合成后，onData 小块按 requestId 拼成完整 ArrayBuffer
  private activeChunkOffset_: number = 0;  // 正在播放块的文本起始偏移
  private systemRequestSeq_: number = 0;
  private systemSessionId_: number = 0;
  private activeSystemRequestId_: string = '';
  private systemChunkPcm_: Map<string, ArrayBuffer[]> = new Map();
  private systemChunkOffset_: Map<string, number> = new Map();
  private systemChunkText_: Map<string, string> = new Map();
  private systemChunkRetry_: Map<string, number> = new Map();
  // 双缓冲：activeChunk_ 正在播放，pendingChunk_ 预合成中
  private activeChunk_: Uint8Array | null = null;
  private activeOffset_: number = 0;
  private pendingQueue_: Uint8Array[] = [];
  private pendingOffsetQueue_: number[] = []; // 队列替代单个 pending，防止覆盖
  private synthPending_: boolean = false;
  private synthCount_: number = 0; // 正在合成的任务数量（支持并行预合成）
  private static readonly MAX_SYNTH_CONCURRENCY = 3; // 最大并行合成数量
  private firstChunkReady_: boolean = false;
  private chapterEnded_: boolean = false;
  private chapterEndFired_: boolean = false;
  private voice_: ReadAloudVoiceConfig;
  // 预合成配置：熄屏后需要更多预合成来保证流畅播放
  private static readonly PRELOAD_COUNT = 15; // 预合成15句音频（熄屏后合成慢，需要更多缓冲）

  constructor(callback: AloudCallback, voice?: ReadAloudVoiceConfig) {
    this.callback_ = callback;
    this.voice_ = voice || TtsVoiceManager.DEFAULT_VOICE;
  }

  get state(): AloudState { return this.state_; }
  get startOffset(): number { return this.startTextOffset_; }
  get startChapter(): number { return this.startChapterIdx_; }
  /** 基于实际播出字节数估算的字符位置 */
  get playbackPosition(): number { return this.activeChunkOffset_ + this.startTextOffset_; }
  get playedChars(): number { return this.playedChars_; }

  updateCallback(callback: AloudCallback): void { this.callback_ = callback; }
  setVoice(language: string, person: number, style: string): void { this.voice_ = { language, person, style }; }

  /** 设置 TTS 后端（null=系统 TTS，非 null=扩展后端）。 */
  async setBackend(backend: ITtsBackend | null): Promise<void> {
    if (backend === this.backend_) return;
    if (this.backend_) {
      try { await this.backend_.release(); } catch (_) { /* ignore */ }
    }
    this.backend_ = backend;
    if (backend) {
      await backend.init();
    }
    const targetRate = backend ? backend.sampleRate : 16000;
    if (this.audioRenderer_ && this.currentRendererRate_ !== targetRate) {
      await this.recreateAudioRenderer_(targetRate);
    }
  }

  getBackend(): ITtsBackend | null { return this.backend_; }

  private setState_(s: AloudState): void {
    this.state_ = s;
    this.callback_.onStateChange?.(s);
  }

  async init(): Promise<void> {
    // 应用暂存的 backend（来自 setGlobalBackend，引擎创建前的调用）
    if (!this.backend_ && pendingBackend_) {
      const backend = pendingBackend_;
      pendingBackend_ = null;
      this.backend_ = backend;
    }
    // 确保扩展后端已就绪
    if (this.backend_ && !this.backend_.ready) {
      console.info('[Aloud] waiting for backend init...');
      await this.backend_.init();
    }

    // 系统 TTS 引擎（仅在无后端时需要）
    if (!this.backend_) {
      const extraParam: Record<string, Object> = {
        'name': 'legado_tts_' + Date.now(),
        'style': this.voice_.style,
        'locate': 'CN',
      };

      this.ttsEngine_ = await new Promise<textToSpeech.TextToSpeechEngine>((resolve, reject) => {
        textToSpeech.createEngine(
          { language: this.voice_.language, person: this.voice_.person, online: 1, extraParams: extraParam },
          (err: BusinessError, engine: textToSpeech.TextToSpeechEngine) => {
            if (err) { reject(new Error('TTS: ' + err.code)); }
            else {
              engine.setListener({
                onStart: () => {},
                onData: (reqId: string, audioData: ArrayBuffer) => {
                  const chunks = this.systemChunkPcm_.get(reqId);
                  if (!chunks) return;
                  chunks.push(audioData);
                },
                onComplete: (reqId: string) => {
                  this.buildSystemChunk_(reqId);
                },
                onStop: () => {},
                onError: (reqId: string, code: number, errorMessage: string) => {
                  this.handleSystemTtsError_(reqId, code, errorMessage);
                },
              });
              resolve(engine);
            }
          });
      });
    }

    // AudioRenderer（根据后端采样率选择）
    const sampleRate = this.backend_ ? this.backend_.sampleRate : 16000;
    const samplingRate = this.sampleRateToEnum_(sampleRate);
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: samplingRate,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    };
    try {
      this.audioRenderer_ = await audio.createAudioRenderer({
        streamInfo: streamInfo,
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK, rendererFlags: 0 },
      });
      this.audioRenderer_.on('writeData', (buffer: ArrayBuffer) => {
        this.writeData_(buffer);
      });
      this.currentRendererRate_ = sampleRate;
    } catch (err) {
      throw new Error(String(err));
    }
    console.info('[Aloud] init OK, sampleRate=' + sampleRate + ' backend=' + (this.backend_ ? this.backend_.name : 'system'));
  }

  async speak(text: string, speed: number = 1.0, startOffset: number = 0, startChapter: number = 0): Promise<void> {
    this.startChapterIdx_ = startChapter;
    // 需要 audioRenderer_，还需要合成能力（系统 TTS 引擎或扩展后端）
    if (!this.audioRenderer_ || (!this.ttsEngine_ && !this.backend_)) { this.callback_.onError?.('引擎未初始化'); return; }
    
    this.startTextOffset_ = startOffset;
    this.speed_ = speed;
    this.systemSessionId_++;
    this.resetSystemSynthesisState_();
    this.activeChunk_ = null; this.activeOffset_ = 0; this.pendingQueue_ = []; this.pendingOffsetQueue_ = [];
    this.synthPending_ = false; this.synthCount_ = 0; this.firstChunkReady_ = false; this.pendingChapterFetch_ = ""; this.lastChapterIdx_ = -1; this.totalPcmWritten_ = 0;
    this.chapterEnded_ = false; this.chapterEndFired_ = false;
    this.textQueue_ = this.splitText_(text);
    this.currentTextIdx_ = 0; this.totalChars_ = text.length; this.playedChars_ = 0;
    console.info('[Aloud] ' + text.length + ' chars → ' + this.textQueue_.length + ' chunks');
    this.setState_(AloudState.PLAYING);
    this.speakNext_();
    await this.audioRenderer_.start();
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
    this.systemSessionId_++;
    this.activeChunk_ = null; this.pendingQueue_ = []; this.pendingOffsetQueue_ = [];
    this.resetSystemSynthesisState_();
    this.synthPending_ = false; this.synthCount_ = 0;
    this.firstChunkReady_ = false; this.chapterEndFired_ = false;
    try { await this.ttsEngine_?.stop(); } catch (_) {}
    try { await this.audioRenderer_?.stop(); await this.audioRenderer_?.flush(); } catch (_) {}
    this.setState_(AloudState.STOPPED);
  }

  async release(): Promise<void> {
    await this.stop();
    try { await this.audioRenderer_?.release(); } catch (_) {}
    try { await this.ttsEngine_?.shutdown(); } catch (_) {}
    if (this.backend_) {
      try { await this.backend_.release(); } catch (_) { /* ignore */ }
      this.backend_ = null;
    }
    this.audioRenderer_ = null;
    this.ttsEngine_ = null;
    this.currentRendererRate_ = 0;
    this.setState_(AloudState.IDLE);
  }

  // ---- 音频渲染器重建（切换后端时采样率可能变化） ----

  private async recreateAudioRenderer_(sampleRate: number): Promise<void> {
    if (this.audioRenderer_) {
      try { await this.audioRenderer_.stop(); } catch (_) {}
      try { await this.audioRenderer_.release(); } catch (_) {}
      this.audioRenderer_ = null;
    }
    const samplingRate = this.sampleRateToEnum_(sampleRate);
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: samplingRate,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    };
    try {
      this.audioRenderer_ = await audio.createAudioRenderer({
        streamInfo: streamInfo,
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK, rendererFlags: 0 },
      });
    } catch (err) {
      throw new Error('创建音频播放器失败: ' + (err as Error).message);
    }
    try {
      this.audioRenderer_.on('writeData', (buffer: ArrayBuffer) => {
        this.writeData_(buffer);
      });
    } catch (err) {
      try {
        await this.audioRenderer_.release();
      } catch (_e) {}
      this.audioRenderer_ = null;
      throw new Error('注册音频写入回调失败: ' + (err as Error).message);
    }
    this.activeChunk_ = null;
    this.activeOffset_ = 0;
    this.currentRendererRate_ = sampleRate;
    console.info('[Aloud] AudioRenderer recreated, sampleRate=' + sampleRate);
  }

  private sampleRateToEnum_(rate: number): audio.AudioSamplingRate {
    switch (rate) {
      case 8000:  return audio.AudioSamplingRate.SAMPLE_RATE_8000;
      case 11025: return audio.AudioSamplingRate.SAMPLE_RATE_11025;
      case 12000: return audio.AudioSamplingRate.SAMPLE_RATE_12000;
      case 16000: return audio.AudioSamplingRate.SAMPLE_RATE_16000;
      case 22050: return audio.AudioSamplingRate.SAMPLE_RATE_22050;
      case 24000: return audio.AudioSamplingRate.SAMPLE_RATE_24000;
      case 32000: return audio.AudioSamplingRate.SAMPLE_RATE_32000;
      case 44100: return audio.AudioSamplingRate.SAMPLE_RATE_44100;
      case 48000: return audio.AudioSamplingRate.SAMPLE_RATE_48000;
      default:    return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    }
  }

  // ========================

  /** 分句：优先按句号/问号/感叹号/分号，目标 20-40 字/段 */
  private splitText_(text: string): string[] {
    const result: string[] = []; let start = 0;
    while (start < text.length) {
      let end = Math.min(start + 45, text.length);  // 目标 20-40 字，最长 45
      if (end < text.length) {
        for (let i = end; i > start + 15; i--) {  // 最低回头到 15 字
          if ('。！？\n；;'.includes(text[i])) {
            end = i + 1;
            break;
          }
        }
        // 没找到句末标点 → 在逗号处断
        if (end === start + 45) {
          for (let i = end; i > start + 20; i--) {
            if ('，,：:'.includes(text[i])) { end = i + 1; break; }
          }
        }
      }
      result.push(text.substring(start, end).trim());
      start = end;
    }
    return result.filter(s => s.length > 0);
  }

  private pendingChapterFetch_: string = "";
  private lastChapterIdx_: number = -1;
  private speakNext_(): void {
    // 检查是否需要预合成：如果pendingQueue已有足够多的音频，则不再合成
    if (this.state_ !== AloudState.PLAYING) return;
    if (this.pendingQueue_.length >= ReadAloudEngine.PRELOAD_COUNT) return;
    const maxConcurrency = this.backend_ ? ReadAloudEngine.MAX_SYNTH_CONCURRENCY : 1;
    if (this.synthCount_ >= maxConcurrency) return; // 系统 TTS 串行，扩展后端允许并行预合成
    
    if (this.currentTextIdx_ >= this.textQueue_.length) {
      const provider = this.callback_.onNeedNextChapter || globalChapterProvider_;
      if (provider) {
        const key = this.currentTextIdx_ + "_" + this.textQueue_.length;
        if (key === this.pendingChapterFetch_) return;
        this.pendingChapterFetch_ = key;
        provider().then((next: AloudChapterText | null) => {
          this.pendingChapterFetch_ = "";
          if (next && next.text) {
            if (next.chapterIndex === this.lastChapterIdx_) return;
            this.lastChapterIdx_ = next.chapterIndex;
            this.textQueue_ = this.splitText_(next.text); this.currentTextIdx_ = 0;
            this.totalChars_ = next.text.length; this.playedChars_ = 0; this.startTextOffset_ = next.offset;
            this.callback_.onChapterChange?.(next.chapterIndex || 0);
            this.speakNext_();
          } else { this.chapterEnded_ = true; }
        });
      } else { this.chapterEnded_ = true; }
      return;
    }
    const text = this.textQueue_[this.currentTextIdx_]; this.currentTextIdx_++;
    this.playedChars_ += text.length;
    this.callback_.onProgress?.(this.playbackPosition, this.totalChars_);
    const chunkOffset = this.playedChars_ - text.length;
    this.synthPending_ = true;
    this.synthCount_++; // 增加合成任务计数
    console.info('[Aloud] synth chunk ' + (this.currentTextIdx_) + ': ' + text.length + ' chars, pending=' + this.pendingQueue_.length + ', synthCount=' + this.synthCount_);

    if (this.backend_) {
      // 扩展 TTS 后端：异步合成 → 直接 push 到 pendingQueue_
      this.synthesizeWithBackend_(text, chunkOffset);
    } else {
      // 系统 TTS：speak + onData/onComplete 回调流
      this.synthesizeWithSystem_(text, chunkOffset, 0);
    }
    
    // 立即继续预合成下一句（并行合成）
    this.speakNext_();
  }

  /** 系统 TTS 每次 speak 都按 requestId 独立收集 PCM，避免回调串包。 */
  private buildSystemChunk_(requestId: string): void {
    const chunks = this.systemChunkPcm_.get(requestId);
    const chunkOffset = this.systemChunkOffset_.get(requestId);
    if (!chunks || chunkOffset === undefined) return;

    this.cleanupSystemRequest_(requestId);
    if (chunks.length === 0) { this.speakNext_(); return; }
    const total = chunks.reduce((s: number, b: ArrayBuffer) => s + b.byteLength, 0);
    const merged = new Uint8Array(total); let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      const src = new Uint8Array(chunks[i]);
      merged.set(src, offset);
      offset += src.byteLength;
    }
    this.pendingQueue_.push(merged);
    this.pendingOffsetQueue_.push(chunkOffset);
    console.info('[Aloud] system chunk ready: ' + total + ' bytes PCM');
    if (!this.firstChunkReady_) this.firstChunkReady_ = true;
    this.speakNext_();
  }

  /** 离线后端合成：async synthesize → 直接 push 到 pendingQueue_ */
  private async synthesizeWithBackend_(text: string, chunkOffset: number): Promise<void> {
    try {
      const req: TtsSynthRequest = { text, speed: this.speed_ };
      console.info('[Aloud] backend synthesize start: text.len=' + text.length + ' speed=' + this.speed_);
      const synthStart = Date.now();
      const result = await this.backend_!.synthesize(req);
      const synthMs = Date.now() - synthStart;
      const audioSec = result.pcm.byteLength / (result.sampleRate * 2);  // S16LE mono
      const rtf = synthMs / 1000 / audioSec;
      console.info('[Aloud] backend chunk ready: ' + result.pcm.byteLength + ' bytes PCM, ' +
        audioSec.toFixed(1) + 's audio, synth=' + synthMs + 'ms, RTF=' + rtf.toFixed(2));
      const pcm = new Uint8Array(result.pcm);
      this.pendingQueue_.push(pcm);
      this.pendingOffsetQueue_.push(chunkOffset);
      if (!this.firstChunkReady_) this.firstChunkReady_ = true;
    } catch (e) {
      this.callback_.onError?.('合成失败: ' + (e as Error).message);
    } finally {
      this.synthCount_ = Math.max(0, this.synthCount_ - 1); // 减少合成任务计数
      this.synthPending_ = this.synthCount_ > 0;
      if (this.state_ === AloudState.PLAYING) this.speakNext_();  // 预合成下一句
    }
  }

  /** 系统 TTS 合成：speak + onData/onComplete 回调（原有逻辑） */
  private synthesizeWithSystem_(text: string, chunkOffset: number, retryCount: number): void {
    const extraParam: Record<string, Object> = {};
    extraParam['speed'] = this.speed_;
    extraParam['volume'] = 1.0;
    extraParam['playType'] = 0;
    extraParam['audioType'] = 'pcm';
    const requestId = 'tts_' + this.systemSessionId_ + '_' + (++this.systemRequestSeq_) + '_' + Date.now();
    this.activeSystemRequestId_ = requestId;
    this.systemChunkPcm_.set(requestId, []);
    this.systemChunkOffset_.set(requestId, chunkOffset);
    this.systemChunkText_.set(requestId, text);
    this.systemChunkRetry_.set(requestId, retryCount);
    try {
      this.ttsEngine_!.speak(text, { requestId: requestId, extraParams: extraParam });
    } catch (e) {
      this.cleanupSystemRequest_(requestId);
      const msg = '合成失败: ' + (e as Error).message;
      if (this.hasPlayableAudio_()) {
        console.warn('[Aloud] ' + msg);
        this.speakNext_();
      } else {
        this.callback_.onError?.(msg);
      }
    }
  }

  private handleSystemTtsError_(requestId: string, code: number, errorMessage: string): void {
    const text = this.systemChunkText_.get(requestId);
    const chunkOffset = this.systemChunkOffset_.get(requestId);
    const retryCount = this.systemChunkRetry_.get(requestId) ?? 0;
    if (text === undefined || chunkOffset === undefined) return;

    this.cleanupSystemRequest_(requestId);
    if (code === 401 && retryCount < 1 && this.state_ === AloudState.PLAYING) {
      console.warn('[Aloud] system TTS 401, retry request=' + requestId + ', message=' + errorMessage);
      this.synthPending_ = true;
      this.synthCount_++;
      this.synthesizeWithSystem_(text, chunkOffset, retryCount + 1);
      return;
    }

    const msg = '系统朗读合成失败: ' + code + (errorMessage ? ' ' + errorMessage : '');
    if (this.hasPlayableAudio_()) {
      console.warn('[Aloud] ' + msg);
      this.speakNext_();
    } else {
      this.callback_.onError?.(msg);
    }
  }

  private cleanupSystemRequest_(requestId: string): void {
    this.systemChunkPcm_.delete(requestId);
    this.systemChunkOffset_.delete(requestId);
    this.systemChunkText_.delete(requestId);
    this.systemChunkRetry_.delete(requestId);
    if (this.activeSystemRequestId_ === requestId) this.activeSystemRequestId_ = '';
    this.synthCount_ = Math.max(0, this.synthCount_ - 1);
    this.synthPending_ = this.synthCount_ > 0;
  }

  private resetSystemSynthesisState_(): void {
    this.activeSystemRequestId_ = '';
    this.systemChunkPcm_.clear();
    this.systemChunkOffset_.clear();
    this.systemChunkText_.clear();
    this.systemChunkRetry_.clear();
  }

  private hasPlayableAudio_(): boolean {
    return this.activeChunk_ !== null || this.pendingQueue_.length > 0 || this.firstChunkReady_;
  }

  /** writeData: 从 active 缓冲读取，耗尽时从 pending 换入 */
  private writeData_(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    if (this.state_ !== AloudState.PLAYING) return audio.AudioDataCallbackResult.INVALID;
    const dst = new Uint8Array(buffer); const bufLen = dst.byteLength; let written = 0;
    while (written < bufLen) {
      if (!this.activeChunk_ || this.activeOffset_ >= this.activeChunk_.byteLength) {
        this.activeChunk_ = null; this.activeOffset_ = 0;
        if (this.pendingQueue_.length > 0) {
          this.activeChunk_ = this.pendingQueue_[0];
          if (this.pendingOffsetQueue_.length > 0) {
            const off = this.pendingOffsetQueue_[0];
            console.info("[Engine] swap active: offset=" + off + ", pending=" + (this.pendingQueue_.length - 1));
            this.activeChunkOffset_ = off;
            this.pendingOffsetQueue_.splice(0, 1);
          }
          this.pendingQueue_.splice(0, 1);
          this.firstChunkReady_ = false;
          // 从pendingQueue换入后，触发预合成，保持足够的预合成数量
          this.speakNext_();
        }
        if (!this.activeChunk_) {
          for (let i = written; i < bufLen; i++) dst[i] = 0;
          if (this.chapterEnded_ && !this.synthPending_ && this.synthCount_ === 0 && !this.chapterEndFired_) {
            this.chapterEndFired_ = true;
            this.callback_.onChapterEnd?.();
            return audio.AudioDataCallbackResult.INVALID;
          }
          return audio.AudioDataCallbackResult.VALID;
        }
      }
      const src = this.activeChunk_!; const avail = src.byteLength - this.activeOffset_; const copy = Math.min(bufLen - written, avail);
      dst.set(src.slice(this.activeOffset_, this.activeOffset_ + copy), written); this.activeOffset_ += copy; written += copy; this.totalPcmWritten_ += copy;
    }
    return audio.AudioDataCallbackResult.VALID;
  }
}

// ---- 全局引擎管理 ----
let globalEngine_: ReadAloudEngine | null = null;
let globalVoice_: ReadAloudVoiceConfig = TtsVoiceManager.DEFAULT_VOICE;
/** 待应用的 backend（引擎尚未创建时暂存） */
let pendingBackend_: ITtsBackend | null = null;

export function getGlobalAloudEngine(callback: AloudCallback): ReadAloudEngine {
  if (globalEngine_) {
    globalEngine_.updateCallback(callback);
    return globalEngine_;
  }
  globalEngine_ = new ReadAloudEngine(callback, globalVoice_);
  // 如果面板已注册 listener，新引擎需要绑定
  if (globalListener_) {
    globalEngine_.updateCallback(makeCallbackForGlobal_());
  }
  return globalEngine_;
}

export function getGlobalAloudState(): AloudState {
  return globalEngine_?.state ?? AloudState.IDLE;
}

export function getGlobalEngineRef(): ReadAloudEngine | null {
  return globalEngine_;
}

/** 为全局引擎设置 TTS 后端（切换引擎类型时调用） */
export async function setGlobalBackend(backend: ITtsBackend | null): Promise<void> {
  if (globalEngine_) {
    await globalEngine_.setBackend(backend);
  } else {
    // 引擎尚未创建，暂存 backend 等待 getGlobalAloudEngine 创建后注入
    pendingBackend_ = backend;
  }
}

export async function releaseGlobalAloudEngine(): Promise<void> {
  if (globalEngine_) {
    await globalEngine_.release();
    globalEngine_ = null;
  }
}

// ---- 全局监听（面板注册监听器，不管理引擎生命周期） ----

export interface AloudGlobalListener {
  onState?: (state: AloudState) => void;
  onProgress?: (charIndex: number, total: number) => void;
  onChapterEnd?: () => void;
  onError?: (msg: string) => void;
  onChapterChange?: (chapterIndex: number) => void;
}

let globalListener_: AloudGlobalListener | null = null;

export function setAloudGlobalListener(listener: AloudGlobalListener | null): void {
  globalListener_ = listener;
  if (globalEngine_ && listener) {
    globalEngine_.updateCallback(makeCallbackForGlobal_());
  }
}

function makeCallbackForGlobal_(): AloudCallback {
  const cb: AloudCallback = {
    onStateChange: (s: AloudState) => { if (globalListener_) globalListener_.onState?.(s); },
    onProgress: (ci: number, t: number) => { if (globalListener_) globalListener_.onProgress?.(ci, t); },
    onChapterEnd: () => { if (globalListener_) globalListener_.onChapterEnd?.(); },
    onChapterChange: (chapterIndex: number) => { if (globalListener_) globalListener_.onChapterChange?.(chapterIndex); },
    onError: (msg: string) => { if (globalListener_) globalListener_.onError?.(msg); },
    onNeedNextChapter: async (): Promise<AloudChapterText | null> => {
      if (globalChapterProvider_) return await globalChapterProvider_();
      return null;
    },
  };
  return cb;
}
