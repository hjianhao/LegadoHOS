/**
 * TTS 后端接口 — 系统 TTS 和离线神经 TTS 的统一抽象
 *
 * 两种实现:
 *   - 当前 ReadAloudEngine 直接使用 textToSpeech（保留兼容，backend_=null 时走旧逻辑）
 *   - SherpaOnnxTtsBackend 实现此接口，通过 backend_ 注入
 */

// ---- 数据模型 ----

import { TtsModelType } from './TtsModelManager';

export interface TtsSynthRequest {
  text: string;
  speed: number;
  speakerId?: number;  // sherpa-onnx sid，系统 TTS 忽略
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
  engine: 'system' | 'sherpa-onnx';
  /** sherpa-onnx 专用：speaker id */
  sid?: number;
}

// ---- 后端接口 ----

export interface ITtsBackend {
  readonly name: string;           // 'sherpa-onnx'
  readonly modelType: TtsModelType; // 'kokoro' | 'vits'
  readonly sampleRate: number;
  readonly ready: boolean;

  /** 初始化后端（系统 TTS：创建引擎；sherpa-onnx：加载模型） */
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

export type TtsEngineType = 'system' | 'sherpa-onnx';

export const TTS_ENGINE_SYSTEM: TtsEngineType = 'system';
export const TTS_ENGINE_SHERPA_ONNX: TtsEngineType = 'sherpa-onnx';
