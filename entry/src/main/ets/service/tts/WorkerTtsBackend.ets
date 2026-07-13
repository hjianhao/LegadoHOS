/**
 * Worker 后端 — 通过 Worker 线程调用 sherpa-onnx
 */

import { ITtsBackend, TtsSynthRequest, TtsSynthResult, TtsVoiceInfo } from './ITtsBackend';
import { TtsModelManager, TtsModelType } from './TtsModelManager';
import common from '@ohos.app.ability.common';
import { worker } from '@kit.ArkTS';

// ---- 音色 ----

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

// ---- 内部类型 ----

class PendingReq {
  id: number = 0;
  resolve: (rsp: Record<string, Object>) => void = (_rsp: Record<string, Object>): void => {};
  reject: (err: Error) => void = (_err: Error): void => {};
}

// ---- 后端 ----

export class WorkerTtsBackend implements ITtsBackend {
  readonly name = 'sherpa-onnx';
  private worker_: worker.ThreadWorker | null = null;
  private context_: common.Context;
  private modelType_: TtsModelType;
  private modelPath_: string;
  private currentSid_: number;
  private ready_: boolean = false;
  private warmed_: boolean = false;
  private sampleRate_: number;
  private nextId_: number = 1;
  private pending_: PendingReq[] = [];
  private initPromise_: Promise<void> | null = null;

  get modelType(): TtsModelType { return this.modelType_; }
  get sampleRate(): number { return this.sampleRate_; }
  get ready(): boolean { return this.ready_; }
  get warmed(): boolean { return this.warmed_; }

  constructor(context: common.Context, modelType: TtsModelType) {
    this.context_ = context;
    this.modelType_ = modelType;
    this.modelPath_ = TtsModelManager.getModelPath(context, modelType);
    this.sampleRate_ = modelType === 'vits' ? 16000 : 24000;
    this.currentSid_ = modelType === 'vits' ? 0 : 50;
  }

  async init(): Promise<void> {
    if (this.ready_) return;
    if (this.initPromise_) return this.initPromise_;
    this.initPromise_ = this.doInit_();
    try { await this.initPromise_; }
    finally { this.initPromise_ = null; }
  }

  private async doInit_(): Promise<void> {
    const exists = await TtsModelManager.isModelReady(this.modelPath_, this.modelType_);
    if (!exists) throw new Error('模型未下载: ' + this.modelPath_);

    this.worker_ = new worker.ThreadWorker('entry/ets/workers/TtsWorker');
    this.worker_.onmessage = (event: Object): void => {
      this.onMsg_(event as Record<string, Object>);
    };
    this.worker_.onerror = (): void => {
      console.error('[WorkerTts] worker error');
    };

    const initId = this.nextId_++;
    const req: Record<string, Object> = {
      'type': 'init',
      'id': initId,
      'modelType': this.modelType_,
      'modelPath': this.modelPath_,
    };
    const rsp = await this.request_(req);

    if (rsp['error'] !== undefined) {
      throw new Error('Worker init failed: ' + (rsp['error'] as string));
    }

    this.ready_ = true;
    this.sampleRate_ = (rsp['sampleRate'] as number) || this.sampleRate_;
    console.info('[WorkerTts] init OK, sampleRate=' + this.sampleRate_);
  }

  async synthesize(req: TtsSynthRequest): Promise<TtsSynthResult> {
    const id = this.nextId_++;
    const msg: Record<string, Object> = {
      'type': 'synthesize',
      'id': id,
      'text': req.text,
      'sid': req.speakerId ?? this.currentSid_,
      'speed': req.speed,
    };
    const rsp = await this.request_(msg);

    if (rsp['error'] !== undefined) {
      throw new Error(rsp['error'] as string);
    }

    this.warmed_ = true;
    return {
      pcm: rsp['samples'] as ArrayBuffer,
      sampleRate: (rsp['sampleRate'] as number) || this.sampleRate_,
    };
  }

  async listVoices(): Promise<TtsVoiceInfo[]> {
    const speakers = this.modelType_ === 'kokoro' ? KOKORO_SPEAKERS : VITS_SPEAKERS;
    const result: TtsVoiceInfo[] = [];
    for (const v of speakers) {
      result.push({
        id: `${this.modelType_}-${v.sid}`,
        name: v.name,
        gender: v.gender,
        language: 'zh-CN',
        description: `${v.gender === 'female' ? '女声' : '男声'} · ` +
          (this.modelType_ === 'kokoro' ? '高品质' : '轻量流畅'),
        downloaded: this.ready_,
        engine: 'sherpa-onnx',
        sid: v.sid,
      });
    }
    return result;
  }

  setVoice(voiceId: string): void {
    const match = voiceId.match(/^(kokoro|vits)-(\d+)$/);
    if (match) {
      this.currentSid_ = parseInt(match[2]);
      const msg: Record<string, Object> = { 'type': 'setVoice', 'sid': this.currentSid_ };
      this.worker_?.postMessage(msg);
    }
  }

  async warmup(): Promise<void> {
    // Worker 中不需要单独预热
  }

  async release(): Promise<void> {
    const msg: Record<string, Object> = { 'type': 'release' };
    try { this.worker_?.postMessage(msg); } catch (_) { /* ignore */ }
    try { this.worker_?.terminate(); } catch (_) { /* ignore */ }
    this.worker_ = null;
    this.ready_ = false;
    this.warmed_ = false;
    this.pending_ = [];
  }

  // ---- Worker 通信 ----

  private request_(msg: Record<string, Object>): Promise<Record<string, Object>> {
    return new Promise<Record<string, Object>>((resolve, reject) => {
      const pending = new PendingReq();
      pending.id = (msg['id'] as number) ?? 0;
      pending.resolve = resolve;
      pending.reject = reject;
      this.pending_.push(pending);
      this.worker_!.postMessage(msg);
    });
  }

  private onMsg_(rsp: Record<string, Object>): void {
    const id = rsp['id'] as number | undefined;
    if (id === undefined) return;

    for (let i = this.pending_.length - 1; i >= 0; i--) {
      if (this.pending_[i].id === id) {
        const req = this.pending_[i];
        this.pending_.splice(i, 1);
        req.resolve(rsp);
        return;
      }
    }
  }
}

// ---- 全局缓存 ----

const workerCache: Map<string, WorkerTtsBackend> = new Map();

export function getWorkerTtsBackend(context: common.Context, type: TtsModelType): WorkerTtsBackend {
  const key = type;
  let b = workerCache.get(key);
  if (!b) {
    b = new WorkerTtsBackend(context, type);
    workerCache.set(key, b);
  }
  return b;
}
