/**
 * sherpa-onnx 离线 TTS 后端（支持 Kokoro / VITS 双模型）
 *
 * 模型目录: context.filesDir/tts/<model-dir>/
 * 配置: numThreads=1, provider=cpu (避免多线程 NAPI 崩溃)
 */

import { ITtsBackend, TtsSynthRequest, TtsSynthResult, TtsVoiceInfo } from './ITtsBackend';
import { TtsModelManager, TtsModelType } from './TtsModelManager';
import common from '@ohos.app.ability.common';
import {
  OfflineTts,
  OfflineTtsConfig,
  TtsInput,
  TtsOutput,
} from 'sherpa_onnx';

// ---- 音色预设 ----

interface SpeakerPreset { sid: number; name: string; gender: string; }

const KOKORO_SPEAKERS: SpeakerPreset[] = [
  { sid: 45, name: '温和女声·小贝', gender: 'female' },
  { sid: 46, name: '亲切女声·小妮', gender: 'female' },
  { sid: 47, name: '甜美女声·小晓', gender: 'female' },
  { sid: 48, name: '活力女声·小艺', gender: 'female' },
  { sid: 49, name: '沉稳男声·云健', gender: 'male' },
  { sid: 50, name: '青年男声·云希', gender: 'male' },
  { sid: 51, name: '阳光男声·云夏', gender: 'male' },
  { sid: 52, name: '磁性男声·云阳', gender: 'male' },
];

const VITS_SPEAKERS: SpeakerPreset[] = [
  { sid: 0, name: '标准女声', gender: 'female' },
  { sid: 1, name: '温和女声', gender: 'female' },
  { sid: 2, name: '沉稳男声', gender: 'male' },
  { sid: 3, name: '青年男声', gender: 'male' },
  { sid: 4, name: '明亮女声', gender: 'female' },
];

// ---- 后端 ----

export class SherpaOnnxTtsBackend implements ITtsBackend {
  readonly name = 'sherpa-onnx';
  private tts_: OfflineTts | null = null;
  private initPromise_: Promise<void> | null = null;
  private context_: common.Context;
  private modelType_: TtsModelType;
  private modelPath_: string;
  private currentSid_: number;
  private initError_: string = '';
  private warmed_: boolean = false;

  get modelType(): TtsModelType { return this.modelType_; }

  get sampleRate(): number {
    return this.modelType_ === 'vits' ? 16000 : 24000;
  }
  get ready(): boolean { return this.tts_ !== null; }
  get warmed(): boolean { return this.warmed_; }
  get initError(): string { return this.initError_; }

  constructor(context: common.Context, modelType: TtsModelType) {
    this.context_ = context;
    this.modelType_ = modelType;
    this.modelPath_ = TtsModelManager.getModelPath(context, modelType);
    this.currentSid_ = modelType === 'vits' ? 0 : 50;
  }

  // ---- init (initPromise 模式防并发) ----

  async init(): Promise<void> {
    if (this.tts_) return;
    if (this.initPromise_) return this.initPromise_;
    this.initPromise_ = this.doInit_();
    try { await this.initPromise_; }
    finally { this.initPromise_ = null; }
  }

  private async doInit_(): Promise<void> {
    this.initError_ = '';
    try {
      const exists = await TtsModelManager.isModelReady(this.modelPath_, this.modelType_);
      if (!exists) {
        this.initError_ = '模型未下载: ' + this.modelPath_;
        throw new Error(this.initError_);
      }

      const config = new OfflineTtsConfig();
      config.model.numThreads = 1;
      config.model.provider = 'cpu';
      config.model.debug = false;
      config.maxNumSentences = 1;
      config.silenceScale = 0.2;

      if (this.modelType_ === 'kokoro') {
        config.model.kokoro.model = `${this.modelPath_}/model.int8.onnx`;
        config.model.kokoro.voices = `${this.modelPath_}/voices.bin`;
        config.model.kokoro.tokens = `${this.modelPath_}/tokens.txt`;
        config.model.kokoro.dataDir = `${this.modelPath_}/espeak-ng-data`;
        config.model.kokoro.lexicon = `${this.modelPath_}/lexicon-us-en.txt,${this.modelPath_}/lexicon-zh.txt`;
        config.ruleFsts = `${this.modelPath_}/date-zh.fst,${this.modelPath_}/phone-zh.fst,${this.modelPath_}/number-zh.fst`;
      } else {
        config.model.vits.model = `${this.modelPath_}/model.onnx`;
        config.model.vits.lexicon = `${this.modelPath_}/lexicon.txt`;
        config.model.vits.tokens = `${this.modelPath_}/tokens.txt`;
        config.ruleFsts = `${this.modelPath_}/date.fst,${this.modelPath_}/number.fst`;
      }

      const t0 = Date.now();
      this.tts_ = new OfflineTts(config);
      console.info('[SherpaTts] init OK, type=' + this.modelType_ +
        ' sampleRate=' + this.tts_.sampleRate + ' speakers=' + this.tts_.numSpeakers +
        ' took=' + (Date.now() - t0) + 'ms');
    } catch (e) {
      this.initError_ = '初始化失败: ' + (e as Error).message;
      console.error('[SherpaTts] init failed: ' + (e as Error).message);
      throw new Error(this.initError_);
    }
  }

  // ---- synthesize (不用 callback，跳过 TSFN 避免 NAPI 崩溃) ----

  async synthesize(req: TtsSynthRequest): Promise<TtsSynthResult> {
    if (!this.tts_) throw new Error('Backend not initialized');
    const input = new TtsInput();
    input.text = req.text;
    input.sid = req.speakerId ?? this.currentSid_;
    input.speed = req.speed;
    // enableExternalBuffer=false：强制安全拷贝
    // 不设置 callback：跳过 TSFN（TypedThreadSafeFunction），避免 InvokeJsCallback 崩溃
    input.enableExternalBuffer = false;
    console.info('[SherpaTts] synthesize: type=' + this.modelType_ +
      ' text.len=' + req.text.length + ' sid=' + input.sid);
    let output: TtsOutput;
    try {
      output = await this.tts_.generateAsync(input);
    } catch (e) {
      throw new Error('合成异常: ' + (e as Error).message);
    }
    if (!output || !output.samples || output.samples.length === 0) {
      throw new Error('合成结果为空');
    }
    if (output.samples.length < 0 || output.samples.length > 10000000) {
      console.warn('[SherpaTts] invalid samples length: ' + output.samples.length + ', skipping');
      throw new Error('合成数据异常: samples.length=' + output.samples.length);
    }
    console.info('[SherpaTts] synthesize done: samples=' + output.samples.length +
      ' sampleRate=' + output.sampleRate);
    this.warmed_ = true;
    return {
      pcm: this.float32ToInt16_(output.samples),
      sampleRate: output.sampleRate,
    };
  }

  // ---- voices ----

  async listVoices(): Promise<TtsVoiceInfo[]> {
    const modelReady = await TtsModelManager.isModelReady(this.modelPath_, this.modelType_);
    const speakers = this.modelType_ === 'kokoro' ? KOKORO_SPEAKERS : VITS_SPEAKERS;
    const result: TtsVoiceInfo[] = [];
    for (const v of speakers) {
      const info: TtsVoiceInfo = {
        id: `${this.modelType_}-${v.sid}`,
        name: v.name,
        gender: v.gender,
        language: 'zh-CN',
        description: `${v.gender === 'female' ? '女声' : '男声'} · ` +
          (this.modelType_ === 'kokoro' ? '高品质' : '轻量流畅'),
        downloaded: modelReady,
        engine: 'sherpa-onnx',
        sid: v.sid,
      };
      result.push(info);
    }
    return result;
  }

  setVoice(voiceId: string): void {
    const match = voiceId.match(/^(kokoro|vits)-(\d+)$/);
    if (match) {
      const sid = parseInt(match[2]);
      if (!isNaN(sid) && sid >= 0) {
        this.currentSid_ = sid;
      }
    }
  }

  async warmup(): Promise<void> {
    if (!this.tts_ || this.warmed_) return;
  }

  async release(): Promise<void> {
    this.tts_ = null;
    this.warmed_ = false;
    this.initPromise_ = null;
  }

  // ---- 内部 ----

  private float32ToInt16_(samples: Float32Array): ArrayBuffer {
    const buf = new ArrayBuffer(samples.length * 2);
    const view = new DataView(buf);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1.0, Math.min(1.0, samples[i]));
      view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
    return buf;
  }
}

// ---- 全局缓存 ----

const cache: Map<string, SherpaOnnxTtsBackend> = new Map();

export function getSherpaOnnxBackend(context: common.Context, type: TtsModelType): SherpaOnnxTtsBackend {
  const key = type;
  let b = cache.get(key);
  if (!b) {
    b = new SherpaOnnxTtsBackend(context, type);
    cache.set(key, b);
  }
  return b;
}
