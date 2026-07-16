declare module 'libsherpa_onnx.so' {
  export interface OfflineTtsOutput {
    samples: Float32Array;
    sampleRate: number;
  }

  export function createOfflineTts(config: Record<string, Object>): object;
  export function getOfflineTtsSampleRate(handle: object): number;
  export function getOfflineTtsNumSpeakers(handle: object): number;
  export function offlineTtsGenerateAsync(handle: object, input: Record<string, Object>): Promise<OfflineTtsOutput>;
}
