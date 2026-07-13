/**
 * TTS Worker (.ts) - 直接使用 NAPI，不依赖 ArkTS 封装
 *
 * sherpa_onnx HAR 的 NAPI 类型声明在 libsherpa_onnx.so 中，
 * 可以在 .ts worker 中直接 import，绕过 ArkTS 导入限制。
 */
import worker from '@ohos.worker';
import {
  createOfflineTts,
  getOfflineTtsSampleRate,
  getOfflineTtsNumSpeakers,
  offlineTtsGenerateAsync,
} from 'libsherpa_onnx.so';

const workerPort = worker.workerPort;

let ttsHandle: object | null = null;
let currentSid: number = 0;

interface TtsOutputNapi {
  samples: Float32Array;
  sampleRate: number;
}

workerPort.onmessage = async (e: Object): Promise<void> => {
  const data = e as Record<string, Object>;
  const type = data['type'] as string;

  if (type === 'init') {
    await handleInit(data['modelType'] as string, data['modelPath'] as string);
  } else if (type === 'synthesize') {
    await handleSynthesize(
      data['id'] as number,
      data['text'] as string,
      (data['sid'] as number) ?? currentSid,
      (data['speed'] as number) ?? 1.0
    );
  } else if (type === 'setVoice') {
    currentSid = (data['sid'] as number) || 0;
  } else if (type === 'release') {
    ttsHandle = null;
  }
};

async function handleInit(modelType: string, modelPath: string): Promise<void> {
  try {
    const config: Record<string, Object> = {};
    const model: Record<string, Object> = {};
    const kokoro: Record<string, Object> = {};
    const vits: Record<string, Object> = {};

    model['numThreads'] = 1;
    model['provider'] = 'cpu';
    model['debug'] = false;

    if (modelType === 'kokoro') {
      kokoro['model'] = `${modelPath}/model.int8.onnx`;
      kokoro['voices'] = `${modelPath}/voices.bin`;
      kokoro['tokens'] = `${modelPath}/tokens.txt`;
      kokoro['dataDir'] = `${modelPath}/espeak-ng-data`;
      kokoro['lexicon'] = `${modelPath}/lexicon-us-en.txt,${modelPath}/lexicon-zh.txt`;
      model['kokoro'] = kokoro;
      config['ruleFsts'] = `${modelPath}/date-zh.fst,${modelPath}/phone-zh.fst,${modelPath}/number-zh.fst`;
    } else {
      vits['model'] = `${modelPath}/model.onnx`;
      vits['lexicon'] = `${modelPath}/lexicon.txt`;
      vits['tokens'] = `${modelPath}/tokens.txt`;
      model['vits'] = vits;
      config['ruleFsts'] = `${modelPath}/date.fst,${modelPath}/number.fst`;
    }

    config['model'] = model;
    config['maxNumSentences'] = 1;
    config['silenceScale'] = 0.2;

    ttsHandle = createOfflineTts(config);
    const sampleRate = getOfflineTtsSampleRate(ttsHandle);
    const numSpeakers = getOfflineTtsNumSpeakers(ttsHandle);

    workerPort.postMessage({ type: 'inited', sampleRate: sampleRate, numSpeakers: numSpeakers });
    console.info('[TtsWorker] init OK, sampleRate=' + sampleRate + ' speakers=' + numSpeakers);
  } catch (e) {
    workerPort.postMessage({ type: 'inited', error: String(e) });
    console.error('[TtsWorker] init failed: ' + String(e));
  }
}

async function handleSynthesize(id: number, text: string, sid: number, speed: number): Promise<void> {
  try {
    if (!ttsHandle) throw new Error('TTS not initialized');

    const input: Record<string, Object> = {
      text: text,
      sid: sid,
      speed: speed,
      enableExternalBuffer: true,
    };

    const output = await offlineTtsGenerateAsync(ttsHandle, input) as TtsOutputNapi;
    const int16Pcm = float32ToInt16(output.samples);

    workerPort.postMessage({
      type: 'result', id: id, samples: int16Pcm, sampleRate: output.sampleRate
    }, [int16Pcm]);
    console.info('[TtsWorker] synthesize done: ' + output.samples.length + ' samples');
  } catch (e) {
    workerPort.postMessage({ type: 'result', id: id, error: String(e) });
    console.error('[TtsWorker] synthesize failed: ' + String(e));
  }
}

function float32ToInt16(samples: Float32Array): ArrayBuffer {
  const buf = new ArrayBuffer(samples.length * 2);
  const view = new DataView(buf);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1.0, Math.min(1.0, samples[i]));
    view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
  }
  return buf;
}
