/**
 * TTS 后端接口 — 系统 TTS 和可选云端 TTS 的统一抽象
 *
 * 两种实现:
 *   - 当前 ReadAloudEngine 直接使用 textToSpeech（保留兼容，backend_=null 时走旧逻辑）
 *   - AzureTtsBackend 实现此接口，通过 backend_ 注入
 */

// ---- 数据模型 ----

export interface TtsSynthRequest {
  text: string;
  speed: number;
}

export interface TtsSynthResult {
  pcm: ArrayBuffer;    // Int16 PCM，可直接送入 AudioRenderer
  sampleRate: number;
}

export interface TtsVoiceInfo {
  id: string;
  name: string;
  gender: string;
  language: string;
  description: string;
  downloaded: boolean;
  engine: 'system' | 'azure';
}

// ---- 后端接口 ----

export interface ITtsBackend {
  readonly name: string;
  readonly sampleRate: number;
  readonly ready: boolean;

  /** 初始化后端。 */
  init(): Promise<void>;

  /** 合成一段文本为 Int16 PCM */
  synthesize(req: TtsSynthRequest): Promise<TtsSynthResult>;

  /** 获取可用音色列表 */
  listVoices(): Promise<TtsVoiceInfo[]>;

  /** 设置当前音色 */
  setVoice(voiceId: string): void;

  /** 预热模型（首次推理需加载 ONNX 到内存，耗时较长） */
  warmup(): Promise<void>;

  /** 释放资源 */
  release(): Promise<void>;
}

// ---- 引擎标识 ----

export type TtsEngineType = 'system' | 'azure';

export const TTS_ENGINE_SYSTEM: TtsEngineType = 'system';
export const TTS_ENGINE_AZURE: TtsEngineType = 'azure';
