/**
 * TTS Worker 消息协议类型定义
 */

// ---- 主线程 → Worker ----

export interface WorkerInitReq {
  type: string;  // 'init'
  modelType: string;
  modelPath: string;
}

export interface WorkerSynthesizeReq {
  type: string;  // 'synthesize'
  id: number;
  text: string;
  sid: number;
  speed: number;
}

export interface WorkerSetVoiceReq {
  type: string;  // 'setVoice'
  sid: number;
}

export interface WorkerReleaseReq {
  type: string;  // 'release'
}

export type WorkerRequest = WorkerInitReq | WorkerSynthesizeReq | WorkerSetVoiceReq | WorkerReleaseReq;

// ---- Worker → 主线程 ----

export interface WorkerInitedRsp {
  type: string;  // 'inited'
  sampleRate: number;
  numSpeakers: number;
  error?: string;
}

export interface WorkerResultRsp {
  type: string;  // 'result'
  id: number;
  samples: ArrayBuffer;
  sampleRate: number;
  error?: string;
}

export type WorkerResponse = WorkerInitedRsp | WorkerResultRsp;
