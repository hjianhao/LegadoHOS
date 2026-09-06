/**
 * 朗读引擎 — writeData 负责实时供数，合成回调只负责入队和触发下一段预合成
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import audio from '@ohos.multimedia.audio';
import { ITtsBackend, TtsSynthRequest } from './tts/ITtsBackend';

export enum AloudState { IDLE = 0, PLAYING = 1, PAUSED = 2, STOPPED = 3 }

export interface AloudChapterText {
  text: string;
  offset: number;
  chapterIndex: number;
  /** 章节标题，用于同步系统媒体通知的标题。 */
  title?: string;
}

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
  onChapterChange?: (chapterIndex: number, title?: string, totalChars?: number) => void;
  /** 蓝牙耳机断开导致引擎自动暂停时回调 */
  onAutoPause?: (reason: string) => void;
}

/** 扩展 TTS 后端的有序合成结果。网络请求允许并行，但播放必须按文本顺序。 */
interface OrderedBackendChunk {
  pcm: Uint8Array;
  textOffset: number;
}

interface DeferredSystemSynthesis {
  text: string;
  chunkOffset: number;
  retryCount: number;
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
  private currentChapterTitle_: string = '';
  private totalPcmWritten_: number = 0;
  private callback_: AloudCallback;
  // 每段 TTS 合成后，onData 小块按 requestId 拼成完整 ArrayBuffer
  private activeChunkOffset_: number = 0;  // 正在播放块的文本起始偏移
  private systemRequestSeq_: number = 0;
  private systemSessionId_: number = 0;
  // 每次开始/停止朗读都创建新的播放世代。异步合成或章节预取完成后，
  // 必须确认仍属于当前世代，否则旧章节的结果会混入新章节队列。
  private playbackSessionId_: number = 0;
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
  // Azure 等网络后端允许并行合成，结果可能乱序返回；先按序号暂存，再按顺序放入播放队列。
  private backendReadyChunks_: Map<number, OrderedBackendChunk | null> = new Map();
  private nextSynthesisSeq_: number = 0;
  private nextBackendSeqToPlay_: number = 0;
  private synthPending_: boolean = false;
  private synthCount_: number = 0; // 正在合成的任务数量（支持并行预合成）
  private static readonly MAX_SYNTH_CONCURRENCY = 3; // 最大并行合成数量
  private firstChunkReady_: boolean = false;
  private chapterEnded_: boolean = false;
  private chapterEndFired_: boolean = false;
  private voice_: ReadAloudVoiceConfig;
  // 蓝牙耳机断开自动暂停：监听音频输出设备变化，断连后立即暂停，避免从扬声器外放
  private routingManager_: audio.AudioRoutingManager | null = null;
  private deviceChangeCb_: ((action: audio.DeviceChangeAction) => void) | null = null;
  private outputWasHeadset_: boolean = false;  // 最近一次记录时，输出设备是否为耳机
  // 预合成配置：熄屏后需要更多预合成来保证流畅播放
  private static readonly PRELOAD_COUNT = 15; // 预合成15句音频（熄屏后合成慢，需要更多缓冲）
  private refillTimer_: number = -1;
  private chapterEndTimer_: number = -1;
  private bufferUnderrunLogged_: boolean = false;
  // pause/resume 都是异步系统调用，避免连续点击并发调用 AudioRenderer.start/pause。
  private rendererTransition_: Promise<void> | null = null;
  // 朗读诊断：只记录异常供数、分段切换和持续近静音，避免在实时回调中刷屏。
  private rendererWriteCount_: number = 0;
  private rendererLastCallbackAt_: number = 0;
  private rendererChunkSeq_: number = 0;
  private activeChunkStartedAt_: number = 0;
  private activeChunkPcmMs_: number = 0;
  private pcmQuietSince_: number = 0;
  private pcmQuietLogged_: boolean = false;
  private rendererUnderrunStartedAt_: number = 0;
  private interruptionActive_: boolean = false;
  private interruptionStartedAt_: number = 0;
  private autoResumeEligible_: boolean = false;
  private autoResumeTimer_: number = -1;
  private interruptionGeneration_: number = 0;
  private wasPlayingBeforeInterruption_: boolean = false;
  private static readonly AUTO_RESUME_WINDOW_MS = 60 * 1000;
  // 系统 TTS 请求诊断：用于区分合成耗时、回调传输耗时和入队耗时。
  private systemRequestStartedAt_: Map<string, number> = new Map();
  private systemRequestDataBytes_: Map<string, number> = new Map();
  private systemRequestDataCount_: Map<string, number> = new Map();
  private deferredSystemSynthesis_: DeferredSystemSynthesis | null = null;

  constructor(callback: AloudCallback, voice?: ReadAloudVoiceConfig) {
    this.callback_ = callback;
    this.voice_ = voice || TtsVoiceManager.DEFAULT_VOICE;
  }

  get state(): AloudState { return this.state_; }
  get startOffset(): number { return this.startTextOffset_; }
  get startChapter(): number { return this.startChapterIdx_; }
  get currentChapterTitle(): string { return this.currentChapterTitle_; }
  get totalChars(): number { return this.totalChars_; }
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
    const previous = this.state_;
    this.state_ = s;
    if (s === AloudState.PLAYING) {
      this.wasPlayingBeforeInterruption_ = true;
    } else if (s === AloudState.PAUSED) {
      // 中断导致的暂停仍保留“中断前在播放”快照，供稍后到达的
      // audioInterrupt BEGIN 回调使用；用户主动暂停时 clearInterruptionState_ 已清掉它。
      // 若系统先发 stateChange(PAUSED)，此时 interruptionActive_ 还未由
      // audioInterrupt 回调置位；保留前一状态 PLAYING，后续仍可自动恢复。
      if (!this.interruptionActive_ && previous !== AloudState.PLAYING) {
        this.wasPlayingBeforeInterruption_ = false;
      }
    } else {
      this.wasPlayingBeforeInterruption_ = false;
    }
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
                onStart: (requestId: string, response: textToSpeech.StartResponse) => {
                  const startedAt = this.systemRequestStartedAt_.get(requestId) || 0;
                  console.info('[AloudDiag] system TTS start: request=' + requestId +
                    ', wait=' + (startedAt > 0 ? Date.now() - startedAt : -1) + 'ms' +
                    ', sampleRate=' + response.sampleRate);
                  // 系统 TTS 会在这里返回真实采样率。当前默认音色应为 16 kHz，
                  // 若设备返回其它采样率，按 16 kHz 播放会表现为变速或跳音，需从日志确认。
                  if (response.sampleRate > 0 && response.sampleRate !== this.currentRendererRate_) {
                    console.warn('[Aloud] system TTS sample rate=' + response.sampleRate +
                      ', renderer=' + this.currentRendererRate_ + ', request=' + requestId);
                  }
                },
                onData: (reqId: string, audioData: ArrayBuffer) => {
                  const chunks = this.systemChunkPcm_.get(reqId);
                  if (!chunks) return;
                  chunks.push(audioData);
                  this.systemRequestDataBytes_.set(reqId,
                    (this.systemRequestDataBytes_.get(reqId) || 0) + audioData.byteLength);
                  this.systemRequestDataCount_.set(reqId,
                    (this.systemRequestDataCount_.get(reqId) || 0) + 1);
                },
                onComplete: (reqId: string) => {
                  this.buildSystemChunk_(reqId);
                },
                // 系统生命周期（例如切后台）也可能主动停止一次 speak。
                // 如果忽略该回调，请求会一直留在 systemChunkPcm_，synthCount_ 也不会归零，
                // 后续预合成会永久停在“有任务进行中”的状态。
                onStop: (reqId: string) => {
                  this.handleSystemTtsStop_(reqId);
                },
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
        return this.writeData_(buffer);
      });
      this.attachRendererDiagnostics_(this.audioRenderer_);
      try {
        // 显式使用共享中断模式，确保焦点恢复时能收到 RESUME 提示。
        this.audioRenderer_.setInterruptModeSync(audio.InterruptMode.SHARE_MODE);
      } catch (e) {
        console.warn('[Aloud] set renderer interrupt mode failed: ' + (e as Error).message);
      }
      this.currentRendererRate_ = sampleRate;
    } catch (err) {
      throw new Error(String(err));
    }
    this.registerDeviceChangeListener_();
    console.info('[Aloud] init OK, sampleRate=' + sampleRate + ' backend=' + (this.backend_ ? this.backend_.name : 'system'));
  }

  async speak(text: string, speed: number = 1.0, startOffset: number = 0, startChapter: number = 0,
    chapterTitle: string = ''): Promise<void> {
    const sessionId = ++this.playbackSessionId_;
    this.clearInterruptionState_();
    this.startChapterIdx_ = startChapter;
    this.currentChapterTitle_ = chapterTitle;
    // 需要 audioRenderer_，还需要合成能力（系统 TTS 引擎或扩展后端）
    if (!this.audioRenderer_ || (!this.ttsEngine_ && !this.backend_)) { this.callback_.onError?.('引擎未初始化'); return; }
    
    this.startTextOffset_ = startOffset;
    this.speed_ = speed;
    this.cancelChapterEnd_();
    this.systemSessionId_++;
    this.resetSystemSynthesisState_();
    this.activeChunk_ = null; this.activeOffset_ = 0; this.pendingQueue_ = []; this.pendingOffsetQueue_ = [];
    this.backendReadyChunks_.clear(); this.nextSynthesisSeq_ = 0; this.nextBackendSeqToPlay_ = 0;
    this.bufferUnderrunLogged_ = false;
    this.synthPending_ = false; this.synthCount_ = 0; this.firstChunkReady_ = false; this.pendingChapterFetch_ = ""; this.lastChapterIdx_ = -1; this.totalPcmWritten_ = 0;
    this.chapterEnded_ = false; this.chapterEndFired_ = false;
    this.resetRendererDiagnostics_();
    this.textQueue_ = this.splitText_(text);
    this.currentTextIdx_ = 0;
    // speak 接收的是从 startOffset 截取后的文本，但回调位置使用章节绝对字符偏移。
    // 将起始偏移计入总数，避免从章节中间开始朗读时通知进度超过 100%。
    this.totalChars_ = text.length + startOffset;
    this.playedChars_ = 0;
    console.info('[Aloud] ' + text.length + ' chars → ' + this.textQueue_.length + ' chunks');
    this.setState_(AloudState.PLAYING);
    this.speakNext_(sessionId);
    const renderer = this.audioRenderer_;
    if (!renderer) return;
    await renderer.start();
    // 渲染器启动后音频路由已确定，记录输出设备是否为耳机，供断连自动暂停判断
    this.outputWasHeadset_ = this.isCurrentOutputHeadset_();
  }

  async pause(): Promise<void> {
    // 用户主动暂停后，即使稍后收到旧的 RESUME 事件也不能自动继续播放。
    this.clearInterruptionState_();
    if (this.state_ !== AloudState.PLAYING) return;
    const renderer = this.audioRenderer_;
    if (!renderer) return;
    if (this.rendererTransition_) {
      console.info('[AloudDiag] pause ignored: renderer transition in progress');
      return;
    }
    const transition = Promise.resolve().then(async (): Promise<void> => {
      if (this.state_ !== AloudState.PLAYING) return;
      try {
        await renderer.pause();
        if (this.state_ === AloudState.PLAYING) this.setState_(AloudState.PAUSED);
      } catch (e) {
        console.warn('[Aloud] pause renderer failed: ' + (e as Error).message);
      }
    });
    this.rendererTransition_ = transition;
    transition.then((): void => {
      if (this.rendererTransition_ === transition) this.rendererTransition_ = null;
    }, (): void => {
      if (this.rendererTransition_ === transition) this.rendererTransition_ = null;
    });
    await transition;
  }

  async resume(): Promise<void> {
    if (this.state_ !== AloudState.PAUSED) return;
    // 临时失去焦点期间不能主动抢回音频焦点；等待系统发送 RESUME。
    if (this.interruptionActive_) {
      console.info('[Aloud] resume deferred while audio focus is interrupted');
      return;
    }
    const renderer = this.audioRenderer_;
    if (!renderer) return;
    if (this.rendererTransition_) {
      console.info('[AloudDiag] resume ignored: renderer transition in progress');
      return;
    }
    const transition = Promise.resolve().then(async (): Promise<void> => {
      if (this.state_ !== AloudState.PAUSED) return;
      try {
        await renderer.start();
        if (this.state_ === AloudState.PAUSED) {
          this.setState_(AloudState.PLAYING);
          this.resumeDeferredSystemSynthesis_();
        }
      } catch (e) {
        console.warn('[Aloud] resume renderer failed: ' + (e as Error).message);
      }
    });
    this.rendererTransition_ = transition;
    transition.then((): void => {
      if (this.rendererTransition_ === transition) this.rendererTransition_ = null;
    }, (): void => {
      if (this.rendererTransition_ === transition) this.rendererTransition_ = null;
    });
    await transition;
  }

  async stop(): Promise<void> {
    const sessionId = ++this.playbackSessionId_;
    this.clearInterruptionState_();
    this.systemSessionId_++;
    this.activeChunk_ = null; this.pendingQueue_ = []; this.pendingOffsetQueue_ = [];
    this.backendReadyChunks_.clear(); this.nextSynthesisSeq_ = 0; this.nextBackendSeqToPlay_ = 0;
    this.cancelRefill_();
    this.cancelChapterEnd_();
    this.resetSystemSynthesisState_();
    this.synthPending_ = false; this.synthCount_ = 0;
    this.firstChunkReady_ = false; this.chapterEnded_ = false; this.chapterEndFired_ = false;
    this.pendingChapterFetch_ = "";
    // 先阻止 writeData 和完成回调继续驱动旧队列，再等待系统资源停止。
    if (this.state_ !== AloudState.STOPPED) this.setState_(AloudState.STOPPED);
    const rendererTransition = this.rendererTransition_;
    if (rendererTransition) {
      try { await rendererTransition; } catch (_) {}
    }
    try { await this.ttsEngine_?.stop(); } catch (_) {}
    if (sessionId !== this.playbackSessionId_) return;
    try { await this.audioRenderer_?.stop(); await this.audioRenderer_?.flush(); } catch (_) {}
  }

  async release(): Promise<void> {
    await this.stop();
    this.unregisterDeviceChangeListener_();
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
        return this.writeData_(buffer);
      });
      this.attachRendererDiagnostics_(this.audioRenderer_);
      try {
        this.audioRenderer_.setInterruptModeSync(audio.InterruptMode.SHARE_MODE);
      } catch (e) {
        console.warn('[Aloud] set renderer interrupt mode failed: ' + (e as Error).message);
      }
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
    this.resetRendererDiagnostics_();
    console.info('[Aloud] AudioRenderer recreated, sampleRate=' + sampleRate);
  }

  private attachRendererDiagnostics_(renderer: audio.AudioRenderer): void {
    try {
      renderer.on('audioInterrupt', (event: audio.InterruptEvent) => {
        console.warn('[AloudDiag] audio interrupt: event=' + event.eventType +
          ', force=' + event.forceType + ', hint=' + event.hintType +
          ', state=' + this.state_ + ', pending=' + this.pendingQueue_.length +
          ', synth=' + this.synthCount_);
        this.handleAudioInterrupt_(event);
      });
    } catch (e) {
      console.warn('[AloudDiag] register audioInterrupt failed: ' + (e as Error).message);
    }
    try {
      renderer.on('stateChange', (state: audio.AudioState) => {
        console.info('[AloudDiag] renderer state=' + state + ', pending=' + this.pendingQueue_.length +
          ', active=' + (this.activeChunk_ ? this.activeChunk_.byteLength - this.activeOffset_ : 0));
      });
    } catch (e) {
      console.warn('[AloudDiag] register renderer stateChange failed: ' + (e as Error).message);
    }
  }

  private resetRendererDiagnostics_(): void {
    this.rendererWriteCount_ = 0;
    this.rendererLastCallbackAt_ = 0;
    this.rendererChunkSeq_ = 0;
    this.activeChunkStartedAt_ = 0;
    this.activeChunkPcmMs_ = 0;
    this.pcmQuietSince_ = 0;
    this.pcmQuietLogged_ = false;
    this.rendererUnderrunStartedAt_ = 0;
  }

  /**
   * 处理 AudioRenderer 的音频焦点中断。
   *
   * 默认策略下 BEGIN/PAUSE 通常由系统强制执行，END/RESUME 则要求应用主动
   * start()。SHARE/PAUSE 设备上系统不会替我们暂停，因此这里也补一次 pause。
   */
  private handleAudioInterrupt_(event: audio.InterruptEvent): void {
    if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        // STOP 代表永久失去焦点，必须由用户重新点击播放，不自动恢复。
        this.clearInterruptionState_();
        if (this.state_ === AloudState.PLAYING || this.state_ === AloudState.PAUSED) {
          this.setState_(AloudState.STOPPED);
        }
        return;
      }
      if (event.hintType !== audio.InterruptHint.INTERRUPT_HINT_PAUSE) return;
      if (this.state_ !== AloudState.PLAYING && !this.wasPlayingBeforeInterruption_) return;

      this.interruptionGeneration_++;
      this.interruptionActive_ = true;
      this.interruptionStartedAt_ = Date.now();
      this.autoResumeEligible_ = true;
      this.scheduleAutoResumeExpiry_();

      if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        // 系统已经暂停渲染器；只同步引擎/UI 状态，不能再次调用 pause()。
        this.setState_(AloudState.PAUSED);
      } else {
        // 共享中断模式由应用自行执行暂停，避免继续向扬声器供数。
        const renderer = this.audioRenderer_;
        this.setState_(AloudState.PAUSED);
        if (renderer) {
          renderer.pause().catch((e: Error) => {
            console.warn('[Aloud] pause for shared audio interrupt failed: ' + e.message);
          });
        }
      }
      return;
    }

    if (event.eventType !== audio.InterruptType.INTERRUPT_TYPE_END ||
      event.hintType !== audio.InterruptHint.INTERRUPT_HINT_RESUME) return;
    if (!this.interruptionActive_ || !this.autoResumeEligible_) return;

    const elapsed = Date.now() - this.interruptionStartedAt_;
    if (elapsed > ReadAloudEngine.AUTO_RESUME_WINDOW_MS) {
      console.info('[Aloud] audio focus restored after auto-resume window: ' + elapsed + 'ms');
      this.clearInterruptionState_();
      return;
    }

    // 先清除标记再 start()，这样 start 触发的异步 stateChange 不会被认为仍在
    // 中断期间；若系统仍未交还焦点，AudioRenderer.start() 失败时保持暂停态。
    this.interruptionActive_ = false;
    this.autoResumeEligible_ = false;
    this.cancelAutoResumeTimer_();
    console.info('[Aloud] audio focus restored, auto resume after ' + elapsed + 'ms');
    this.resume().catch((e: Error) => {
      console.warn('[Aloud] auto resume failed: ' + e.message);
    });
  }

  private scheduleAutoResumeExpiry_(): void {
    this.cancelAutoResumeTimer_();
    const generation = this.interruptionGeneration_;
    this.autoResumeTimer_ = setTimeout((): void => {
      this.autoResumeTimer_ = -1;
      if (generation !== this.interruptionGeneration_ || !this.interruptionActive_) return;
      this.autoResumeEligible_ = false;
      this.interruptionActive_ = false;
      console.info('[Aloud] audio interruption exceeded auto-resume window');
    }, ReadAloudEngine.AUTO_RESUME_WINDOW_MS);
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

  /** 焦点中断期间系统 TTS 被停止时，恢复渲染器后补发丢失的当前句。 */
  private resumeDeferredSystemSynthesis_(): void {
    const deferred = this.deferredSystemSynthesis_;
    if (!deferred || this.state_ !== AloudState.PLAYING || !this.ttsEngine_) return;
    this.deferredSystemSynthesis_ = null;
    this.synthCount_++;
    this.synthPending_ = true;
    const sessionId = this.playbackSessionId_;
    setTimeout((): void => {
      if (sessionId !== this.playbackSessionId_ || this.state_ !== AloudState.PLAYING) {
        this.synthCount_ = Math.max(0, this.synthCount_ - 1);
        this.synthPending_ = this.synthCount_ > 0;
        return;
      }
      this.synthesizeWithSystem_(deferred.text, deferred.chunkOffset, deferred.retryCount);
    }, 0);
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

  // ---- 耳机/外接音频设备断开自动暂停 ----

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
      // 监听注册时先记录当前路由，覆盖“进入页面前耳机已连接”的场景。
      this.outputWasHeadset_ = this.isCurrentOutputHeadset_();
      console.info('[Aloud] deviceChange listener registered');
    } catch (e) {
      console.warn('[Aloud] register deviceChange listener failed: ' + (e as Error).message);
      this.routingManager_ = null;
      this.deviceChangeCb_ = null;
    }
  }

  private unregisterDeviceChangeListener_(): void {
    if (!this.routingManager_ || !this.deviceChangeCb_) return;
    try {
      this.routingManager_.off('deviceChange', this.deviceChangeCb_);
    } catch (e) {
      console.warn('[Aloud] unregister deviceChange listener failed: ' + (e as Error).message);
    }
    this.routingManager_ = null;
    this.deviceChangeCb_ = null;
    this.outputWasHeadset_ = false;
  }

  /** 输出设备变化回调：耳机断开时自动暂停，避免扬声器外放造成尴尬 */
  private handleDeviceChange_(action: audio.DeviceChangeAction): void {
    const wasHeadset = this.outputWasHeadset_;
    const nowHeadset = this.isCurrentOutputHeadset_();
    this.outputWasHeadset_ = nowHeadset;
    if (action.type !== audio.DeviceChangeType.DISCONNECT || !wasHeadset || nowHeadset) return;

    // 设备断开优先级高于焦点恢复：清掉中断标记，防止稍后 END/RESUME 恢复到扬声器。
    const shouldPause = this.state_ === AloudState.PLAYING || this.interruptionActive_;
    if (!shouldPause) return;
    console.info('[Aloud] headset output disconnected, auto pause');
    this.clearInterruptionState_();
    if (this.state_ === AloudState.PLAYING) {
      // 先同步切到暂停态，避免异步 pause() 完成前到达的旧 BEGIN/PAUSE
      // 又把这次设备断开误判为可自动恢复的焦点中断。
      this.setState_(AloudState.PAUSED);
      this.audioRenderer_?.pause().catch(() => {});
    }
    this.callback_.onAutoPause?.('耳机已断开，朗读已暂停');
  }

  /** 查询当前朗读流（AUDIOBOOK usage）实际输出的设备是否为耳机 */
  private isCurrentOutputHeadset_(): boolean {
    try {
      const routing = this.routingManager_ ?? audio.getAudioManager().getRoutingManager();
      // 优先按朗读流的实际路由查询
      const preferred = routing.getPreferredOutputDeviceForRendererInfoSync({
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0,
      });
      if (preferred.length > 0) return this.containsHeadsetDevice_(preferred);
      // 个别场景路由查询为空时，回退到全部输出设备列表
      return this.containsHeadsetDevice_(routing.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG));
    } catch (e) {
      console.warn('[Aloud] query output devices failed: ' + (e as Error).message);
    }
    return false;
  }

  private containsHeadsetDevice_(devices: audio.AudioDeviceDescriptors): boolean {
    for (let i = 0; i < devices.length; i++) {
      const t = devices[i].deviceType;
      if (t === audio.DeviceType.BLUETOOTH_SCO || t === audio.DeviceType.BLUETOOTH_A2DP ||
        t === audio.DeviceType.WIRED_HEADSET || t === audio.DeviceType.WIRED_HEADPHONES ||
        t === audio.DeviceType.USB_HEADSET) return true;
    }
    return false;
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
  private speakNext_(sessionId: number = this.playbackSessionId_): void {
    if (sessionId !== this.playbackSessionId_) return;
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
          if (sessionId !== this.playbackSessionId_) return;
          this.pendingChapterFetch_ = "";
          if (next && next.text) {
            if (next.chapterIndex === this.lastChapterIdx_) return;
            this.lastChapterIdx_ = next.chapterIndex;
            this.textQueue_ = this.splitText_(next.text); this.currentTextIdx_ = 0;
            this.totalChars_ = next.text.length; this.playedChars_ = 0; this.startTextOffset_ = next.offset;
            this.startChapterIdx_ = next.chapterIndex;
            this.currentChapterTitle_ = next.title || '';
            this.callback_.onChapterChange?.(next.chapterIndex || 0, this.currentChapterTitle_, next.text.length);
            this.speakNext_(sessionId);
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
    const synthesisSeq = this.nextSynthesisSeq_++;
    console.info('[Aloud] synth chunk ' + (this.currentTextIdx_) + ': ' + text.length + ' chars, pending=' + this.pendingQueue_.length + ', synthCount=' + this.synthCount_);

    if (this.backend_) {
      // 扩展 TTS 后端：异步合成，结果按 synthesisSeq 排序后再进入播放队列。
      this.synthesizeWithBackend_(text, chunkOffset, sessionId, synthesisSeq);
    } else {
      // 系统 TTS：speak + onData/onComplete 回调流
      this.synthesizeWithSystem_(text, chunkOffset, 0);
    }
    
    // 立即继续预合成下一句（并行合成）
    this.speakNext_(sessionId);
  }

  /** 系统 TTS 每次 speak 都按 requestId 独立收集 PCM，避免回调串包。 */
  private buildSystemChunk_(requestId: string): void {
    const chunks = this.systemChunkPcm_.get(requestId);
    const chunkOffset = this.systemChunkOffset_.get(requestId);
    if (!chunks || chunkOffset === undefined) return;

    const startedAt = this.systemRequestStartedAt_.get(requestId) || 0;
    const receivedBytes = this.systemRequestDataBytes_.get(requestId) || 0;
    const receivedCount = this.systemRequestDataCount_.get(requestId) || 0;
    const elapsed = startedAt > 0 ? Date.now() - startedAt : -1;
    this.cleanupSystemRequest_(requestId);
    if (chunks.length === 0) {
      console.warn('[AloudDiag] system TTS complete without PCM: request=' + requestId +
        ', elapsed=' + elapsed + 'ms, data=' + receivedCount + ', bytes=' + receivedBytes);
      this.speakNext_();
      return;
    }
    const total = chunks.reduce((s: number, b: ArrayBuffer) => s + b.byteLength, 0);
    const merged = new Uint8Array(total); let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      const src = new Uint8Array(chunks[i]);
      merged.set(src, offset);
      offset += src.byteLength;
    }
    this.pendingQueue_.push(merged);
    this.pendingOffsetQueue_.push(chunkOffset);
    const audioMs = this.currentRendererRate_ > 0 ? total / (this.currentRendererRate_ * 2) * 1000 : 0;
    console.info('[Aloud] system chunk ready: ' + total + ' bytes PCM');
    console.info('[AloudDiag] system TTS complete: request=' + requestId +
      ', elapsed=' + elapsed + 'ms, data=' + receivedCount +
      ', bytes=' + receivedBytes + ', audio=' + audioMs.toFixed(0) +
      'ms, pending=' + this.pendingQueue_.length);
    if (!this.firstChunkReady_) this.firstChunkReady_ = true;
    this.speakNext_();
  }

  /** 离线后端合成：async synthesize → 直接 push 到 pendingQueue_ */
  private async synthesizeWithBackend_(text: string, chunkOffset: number, sessionId: number,
    synthesisSeq: number): Promise<void> {
    const backend = this.backend_;
    if (!backend || sessionId !== this.playbackSessionId_) return;
    try {
      const req: TtsSynthRequest = { text, speed: this.speed_ };
      console.info('[Aloud] backend synthesize start: text.len=' + text.length + ' speed=' + this.speed_);
      const synthStart = Date.now();
      const result = await backend.synthesize(req);
      if (sessionId !== this.playbackSessionId_) return;
      const synthMs = Date.now() - synthStart;
      const audioSec = result.pcm.byteLength / (result.sampleRate * 2);  // S16LE mono
      const rtf = synthMs / 1000 / audioSec;
      console.info('[Aloud] backend chunk ready: ' + result.pcm.byteLength + ' bytes PCM, ' +
        audioSec.toFixed(1) + 's audio, synth=' + synthMs + 'ms, RTF=' + rtf.toFixed(2));
      const pcm = new Uint8Array(result.pcm);
      this.backendReadyChunks_.set(synthesisSeq, { pcm: pcm, textOffset: chunkOffset });
      this.flushBackendChunks_();
    } catch (e) {
      if (sessionId === this.playbackSessionId_) {
        // 标记失败的序号，避免前面的请求失败后把后续音频永久卡在排序队列中。
        this.backendReadyChunks_.set(synthesisSeq, null);
        this.flushBackendChunks_();
        this.callback_.onError?.('合成失败: ' + (e as Error).message);
      }
    } finally {
      if (sessionId !== this.playbackSessionId_) return;
      this.synthCount_ = Math.max(0, this.synthCount_ - 1); // 减少合成任务计数
      this.synthPending_ = this.synthCount_ > 0;
      if (this.state_ === AloudState.PLAYING) this.speakNext_();  // 预合成下一句
    }
  }

  /** 将并行后端已完成的 PCM 按文本顺序转移到 AudioRenderer 播放队列。 */
  private flushBackendChunks_(): void {
    while (this.backendReadyChunks_.has(this.nextBackendSeqToPlay_)) {
      const seq = this.nextBackendSeqToPlay_++;
      const ready = this.backendReadyChunks_.get(seq);
      this.backendReadyChunks_.delete(seq);
      if (!ready || ready.pcm.byteLength === 0) continue;
      this.pendingQueue_.push(ready.pcm);
      this.pendingOffsetQueue_.push(ready.textOffset);
      if (!this.firstChunkReady_) this.firstChunkReady_ = true;
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
    this.systemRequestStartedAt_.set(requestId, Date.now());
    this.systemRequestDataBytes_.set(requestId, 0);
    this.systemRequestDataCount_.set(requestId, 0);
    console.info('[AloudDiag] system TTS request: request=' + requestId +
      ', text=' + text.length + ' chars, retry=' + retryCount +
      ', pending=' + this.pendingQueue_.length);
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

    const startedAt = this.systemRequestStartedAt_.get(requestId) || 0;
    console.warn('[AloudDiag] system TTS error: request=' + requestId +
      ', code=' + code + ', elapsed=' + (startedAt > 0 ? Date.now() - startedAt : -1) +
      'ms, data=' + (this.systemRequestDataCount_.get(requestId) || 0) +
      ', bytes=' + (this.systemRequestDataBytes_.get(requestId) || 0));
    this.cleanupSystemRequest_(requestId);
    if (this.state_ === AloudState.PAUSED &&
      (this.interruptionActive_ || this.wasPlayingBeforeInterruption_)) {
      // 音频焦点中断可能让系统 TTS 报错而不是回调 onStop；保留当前句，
      // 待焦点恢复或用户手动恢复后重新合成。
      this.deferredSystemSynthesis_ = { text: text, chunkOffset: chunkOffset, retryCount: retryCount };
      console.info('[Aloud] defer system TTS retry until audio focus is restored');
      return;
    }
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

  /** 系统 TTS 被生命周期/系统服务停止时，清理请求并在播放中补发一次。 */
  private handleSystemTtsStop_(requestId: string): void {
    const text = this.systemChunkText_.get(requestId);
    const chunkOffset = this.systemChunkOffset_.get(requestId);
    const retryCount = this.systemChunkRetry_.get(requestId) ?? 0;
    if (text === undefined || chunkOffset === undefined) return;

    const startedAt = this.systemRequestStartedAt_.get(requestId) || 0;
    console.warn('[AloudDiag] system TTS stopped: request=' + requestId +
      ', elapsed=' + (startedAt > 0 ? Date.now() - startedAt : -1) +
      'ms, data=' + (this.systemRequestDataCount_.get(requestId) || 0) +
      ', bytes=' + (this.systemRequestDataBytes_.get(requestId) || 0));
    const sessionId = this.playbackSessionId_;
    this.cleanupSystemRequest_(requestId);
    if (this.state_ === AloudState.PAUSED &&
      (this.interruptionActive_ || this.wasPlayingBeforeInterruption_)) {
      this.deferredSystemSynthesis_ = { text: text, chunkOffset: chunkOffset, retryCount: retryCount };
      console.info('[Aloud] defer system TTS retry until audio focus is restored');
      return;
    }
    if (this.state_ !== AloudState.PLAYING || sessionId !== this.playbackSessionId_) return;

    if (retryCount < 1) {
      // 不在 TTS 原生回调栈内立即再次 speak，避免与 stop 的 IPC 收尾交错。
      this.synthCount_++;
      this.synthPending_ = true;
      setTimeout((): void => {
        if (sessionId !== this.playbackSessionId_ || this.state_ !== AloudState.PLAYING) {
          this.synthCount_ = Math.max(0, this.synthCount_ - 1);
          this.synthPending_ = this.synthCount_ > 0;
          return;
        }
        this.synthesizeWithSystem_(text, chunkOffset, retryCount + 1);
      }, 0);
      return;
    }

    const msg = '系统朗读合成被停止';
    if (this.hasPlayableAudio_()) {
      console.warn('[Aloud] ' + msg + ', request=' + requestId);
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
    this.systemRequestStartedAt_.delete(requestId);
    this.systemRequestDataBytes_.delete(requestId);
    this.systemRequestDataCount_.delete(requestId);
    if (this.activeSystemRequestId_ === requestId) this.activeSystemRequestId_ = '';
    this.synthCount_ = Math.max(0, this.synthCount_ - 1);
    this.synthPending_ = this.synthCount_ > 0;
  }

  private resetSystemSynthesisState_(): void {
    this.activeSystemRequestId_ = '';
    this.deferredSystemSynthesis_ = null;
    this.systemChunkPcm_.clear();
    this.systemChunkOffset_.clear();
    this.systemChunkText_.clear();
    this.systemChunkRetry_.clear();
    this.systemRequestStartedAt_.clear();
    this.systemRequestDataBytes_.clear();
    this.systemRequestDataCount_.clear();
  }

  private hasPlayableAudio_(): boolean {
    return this.activeChunk_ !== null || this.pendingQueue_.length > 0 || this.firstChunkReady_;
  }

  /** writeData 是实时回调，不能在其中直接做合成调度或触发 UI 回调。 */
  private scheduleRefill_(): void {
    if (this.refillTimer_ >= 0) return;
    const sessionId = this.playbackSessionId_;
    this.refillTimer_ = setTimeout((): void => {
      this.refillTimer_ = -1;
      this.speakNext_(sessionId);
    }, 0);
  }

  private cancelRefill_(): void {
    if (this.refillTimer_ >= 0) {
      clearTimeout(this.refillTimer_);
      this.refillTimer_ = -1;
    }
  }

  /** 章节结束回调可能触发翻页和 UI 更新，不能在 AudioRenderer 实时回调中同步执行。 */
  private scheduleChapterEnd_(): void {
    if (this.chapterEndTimer_ >= 0) return;
    const sessionId = this.playbackSessionId_;
    this.chapterEndTimer_ = setTimeout((): void => {
      this.chapterEndTimer_ = -1;
      if (sessionId !== this.playbackSessionId_ || !this.chapterEndFired_) return;
      this.setState_(AloudState.STOPPED);
      this.callback_.onChapterEnd?.();
    }, 0);
  }

  private cancelChapterEnd_(): void {
    if (this.chapterEndTimer_ >= 0) {
      clearTimeout(this.chapterEndTimer_);
      this.chapterEndTimer_ = -1;
    }
  }

  /** writeData: 从 active 缓冲读取，耗尽时从 pending 换入 */
  private writeData_(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    if (this.state_ !== AloudState.PLAYING) return audio.AudioDataCallbackResult.INVALID;
    const now = Date.now();
    const dst = new Uint8Array(buffer); const bufLen = dst.byteLength; let written = 0;
    const previousCallbackAt = this.rendererLastCallbackAt_;
    this.rendererLastCallbackAt_ = now;
    this.rendererWriteCount_++;
    if (previousCallbackAt > 0 && this.currentRendererRate_ > 0) {
      const callbackGap = now - previousCallbackAt;
      const expectedMs = bufLen / (this.currentRendererRate_ * 2) * 1000;
      const warningMs = Math.max(150, expectedMs * 2.5);
      if (callbackGap > warningMs) {
        console.warn('[AloudDiag] renderer callback gap=' + callbackGap +
          'ms, expected~' + expectedMs.toFixed(0) + 'ms, buffer=' + bufLen +
          ', pending=' + this.pendingQueue_.length + ', active=' +
          (this.activeChunk_ ? this.activeChunk_.byteLength - this.activeOffset_ : 0) +
          ', synth=' + this.synthCount_ + ', totalWritten=' + this.totalPcmWritten_);
      }
    }
    if (this.rendererWriteCount_ % 100 === 0) {
      console.info('[AloudDiag] renderer heartbeat: callbacks=' + this.rendererWriteCount_ +
        ', buffer=' + bufLen + ', pending=' + this.pendingQueue_.length +
        ', active=' + (this.activeChunk_ ? this.activeChunk_.byteLength - this.activeOffset_ : 0) +
        ', synth=' + this.synthCount_ + ', totalWritten=' + this.totalPcmWritten_);
    }
    while (written < bufLen) {
      if (!this.activeChunk_ || this.activeOffset_ >= this.activeChunk_.byteLength) {
        const previousChunk = this.activeChunk_;
        if (previousChunk && this.activeChunkStartedAt_ > 0) {
          const wallMs = now - this.activeChunkStartedAt_;
          const deltaMs = wallMs - this.activeChunkPcmMs_;
          const level = Math.abs(deltaMs) > 250 ? 'WARN' : 'INFO';
          console.info('[AloudDiag] chunk end (' + level + '): seq=' + this.rendererChunkSeq_ +
            ', wall=' + wallMs + 'ms, pcm=' + this.activeChunkPcmMs_.toFixed(0) +
            'ms, delta=' + deltaMs.toFixed(0) + 'ms, pending=' + this.pendingQueue_.length);
        }
        this.activeChunk_ = null; this.activeOffset_ = 0;
        if (this.pendingQueue_.length > 0) {
          this.activeChunk_ = this.pendingQueue_[0];
          if (this.pendingOffsetQueue_.length > 0) {
            const off = this.pendingOffsetQueue_[0];
            this.activeChunkOffset_ = off;
            this.pendingOffsetQueue_.splice(0, 1);
          }
          this.pendingQueue_.splice(0, 1);
          this.firstChunkReady_ = false;
          this.bufferUnderrunLogged_ = false;
          this.rendererChunkSeq_++;
          this.activeChunkStartedAt_ = now;
          this.activeChunkPcmMs_ = this.currentRendererRate_ > 0
            ? this.activeChunk_.byteLength / (this.currentRendererRate_ * 2) * 1000 : 0;
          if (this.rendererUnderrunStartedAt_ > 0) {
            console.warn('[AloudDiag] renderer underrun end: duration=' +
              (now - this.rendererUnderrunStartedAt_) + 'ms, pending=' +
              this.pendingQueue_.length + ', synth=' + this.synthCount_);
            this.rendererUnderrunStartedAt_ = 0;
          }
          console.info('[AloudDiag] chunk start: seq=' + this.rendererChunkSeq_ +
            ', bytes=' + this.activeChunk_.byteLength +
            ', pcm=' + this.activeChunkPcmMs_.toFixed(0) + 'ms, offset=' +
            this.activeChunkOffset_ + ', pending=' + this.pendingQueue_.length +
            ', synth=' + this.synthCount_);
          // 从 pendingQueue 换入后异步触发预合成，避免阻塞音频实时回调。
          if (this.synthCount_ === 0) this.scheduleRefill_();
        }
        if (!this.activeChunk_) {
          if (this.rendererUnderrunStartedAt_ === 0) {
            this.rendererUnderrunStartedAt_ = now;
            console.warn('[AloudDiag] renderer underrun start: pending=' + this.pendingQueue_.length +
              ', synth=' + this.synthCount_ + ', chapterEnded=' + this.chapterEnded_);
          }
          for (let i = written; i < bufLen; i++) dst[i] = 0;
          if (this.chapterEnded_ && !this.synthPending_ && this.synthCount_ === 0 && !this.chapterEndFired_) {
            this.chapterEndFired_ = true;
            // 章节已经结束时先切出 PLAYING，防止渲染器的后续回调再次触发；
            // 状态通知和切章回调放到事件循环，避免阻塞音频实时回调。
            this.state_ = AloudState.STOPPED;
            this.wasPlayingBeforeInterruption_ = false;
            this.scheduleChapterEnd_();
            return audio.AudioDataCallbackResult.INVALID;
          }
          // 合成回调偶尔晚于音频拉取时，异步补一次调度，避免在实时回调里直接启动 TTS。
          if (this.synthCount_ === 0) this.scheduleRefill_();
          if (!this.bufferUnderrunLogged_) {
            this.bufferUnderrunLogged_ = true;
            console.warn('[Aloud] audio buffer underrun: pending=' + this.pendingQueue_.length +
              ', synth=' + this.synthCount_ + ', chapterEnded=' + this.chapterEnded_);
          }
          return audio.AudioDataCallbackResult.VALID;
        }
      }
      const src = this.activeChunk_!; const avail = src.byteLength - this.activeOffset_; const copy = Math.min(bufLen - written, avail);
      dst.set(src.subarray(this.activeOffset_, this.activeOffset_ + copy), written); this.activeOffset_ += copy; written += copy; this.totalPcmWritten_ += copy;
    }
    this.inspectRendererPcm_(dst, now);
    return audio.AudioDataCallbackResult.VALID;
  }

  /** 对输出缓冲做低成本抽样，只记录持续近静音，帮助区分音频内容停顿和供数断流。 */
  private inspectRendererPcm_(buffer: Uint8Array, now: number): void {
    if (buffer.byteLength < 2) return;
    let peak = 0;
    // S16LE 单声道，每 16 个采样抽查一个，避免在实时回调中完整扫描缓冲区。
    for (let i = 0; i + 1 < buffer.byteLength; i += 32) {
      const raw = buffer[i] | (buffer[i + 1] << 8);
      const sample = raw >= 0x8000 ? raw - 0x10000 : raw;
      const absolute = sample < 0 ? -sample : sample;
      if (absolute > peak) peak = absolute;
    }
    const quiet = peak <= 32;
    if (quiet) {
      if (this.pcmQuietSince_ === 0) {
        this.pcmQuietSince_ = now;
      }
      if (!this.pcmQuietLogged_ && now - this.pcmQuietSince_ >= 180) {
        this.pcmQuietLogged_ = true;
        console.warn('[AloudDiag] PCM near-silence start: duration>=180ms, peak=' + peak +
          ', source=pcm' +
          ', pending=' + this.pendingQueue_.length + ', active=' +
          (this.activeChunk_ ? this.activeChunk_.byteLength - this.activeOffset_ : 0));
      }
      return;
    }
    if (this.pcmQuietSince_ > 0) {
      const quietMs = now - this.pcmQuietSince_;
      if (this.pcmQuietLogged_ || quietMs >= 180) {
        console.warn('[AloudDiag] PCM near-silence end: duration=' + quietMs +
          'ms, peak=' + peak + ', source=pcm');
      }
    }
    this.pcmQuietSince_ = 0;
    this.pcmQuietLogged_ = false;
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
  // 面板可能已因隐藏而保留监听，以便后台更新媒体通知；引擎释放后解除引用。
  globalListener_ = null;
}

// ---- 全局监听（面板注册监听器，不管理引擎生命周期） ----

export interface AloudGlobalListener {
  onState?: (state: AloudState) => void;
  onProgress?: (charIndex: number, total: number) => void;
  onChapterEnd?: () => void;
  onError?: (msg: string) => void;
  onChapterChange?: (chapterIndex: number, title?: string, totalChars?: number) => void;
  onAutoPause?: (reason: string) => void;
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
    onChapterChange: (chapterIndex: number, title?: string, totalChars?: number) => {
      if (globalListener_) globalListener_.onChapterChange?.(chapterIndex, title, totalChars);
    },
    onAutoPause: (reason: string) => { if (globalListener_) globalListener_.onAutoPause?.(reason); },
    onError: (msg: string) => { if (globalListener_) globalListener_.onError?.(msg); },
    onNeedNextChapter: async (): Promise<AloudChapterText | null> => {
      if (globalChapterProvider_) return await globalChapterProvider_();
      return null;
    },
  };
  return cb;
}
