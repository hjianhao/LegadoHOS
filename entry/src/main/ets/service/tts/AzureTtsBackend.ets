/**
 * Microsoft Azure Neural TTS 后端。
 *
 * 使用 Azure REST TTS 接口返回 24kHz/16bit/mono WAV，再剥离 WAV 头输出裸 PCM。
 */

import common from '@ohos.app.ability.common';
import { http } from '@kit.NetworkKit';
import util from '@ohos.util';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { ITtsBackend, TtsSynthRequest, TtsSynthResult, TtsVoiceInfo } from './ITtsBackend';

const AZURE_SAMPLE_RATE = 24000;
const AZURE_OUTPUT_FORMAT = 'riff-24khz-16bit-mono-pcm';
const AZURE_TIMEOUT = 30000;

export interface AzureVoicePreset {
  id: string;
  name: string;
  gender: string;
  language: string;
  description: string;
}

export const AZURE_VOICES: AzureVoicePreset[] = [
  { id: 'zh-CN-XiaoxiaoNeural', name: '晓晓', gender: 'female', language: 'zh-CN', description: '女声 · 普通话 · 温和自然' },
  { id: 'zh-CN-XiaoyiNeural', name: '晓伊', gender: 'female', language: 'zh-CN', description: '女声 · 普通话 · 亲切清晰' },
  { id: 'zh-CN-YunjianNeural', name: '云健', gender: 'male', language: 'zh-CN', description: '男声 · 普通话 · 稳重叙述' },
  { id: 'zh-CN-YunxiNeural', name: '云希', gender: 'male', language: 'zh-CN', description: '男声 · 普通话 · 年轻自然' },
  { id: 'zh-CN-YunxiaNeural', name: '云夏', gender: 'male', language: 'zh-CN', description: '男声 · 普通话 · 明亮活力' },
  { id: 'zh-CN-YunyangNeural', name: '云扬', gender: 'male', language: 'zh-CN', description: '男声 · 普通话 · 播报感' },
  { id: 'zh-CN-liaoning-XiaobeiNeural', name: '晓北', gender: 'female', language: 'zh-CN', description: '女声 · 辽宁方言' },
  { id: 'zh-CN-shaanxi-XiaoniNeural', name: '晓妮', gender: 'female', language: 'zh-CN', description: '女声 · 陕西方言' },
];

export class AzureTtsBackend implements ITtsBackend {
  readonly name = 'azure';
  private context_: common.Context;
  private endpoint_: string = '';
  private key_: string = '';
  private voiceName_: string = 'zh-CN-XiaoxiaoNeural';
  private ready_: boolean = false;

  get sampleRate(): number { return AZURE_SAMPLE_RATE; }
  get ready(): boolean { return this.ready_; }

  constructor(context: common.Context) {
    this.context_ = context;
  }

  async init(): Promise<void> {
    const settings = SettingsStore.getInstance();
    await settings.init(this.context_);
    this.endpoint_ = this.normalizeEndpoint_(await settings.getTtsAzureEndpoint());
    this.key_ = await settings.getTtsAzureKey();
    this.voiceName_ = await settings.getTtsAzureVoice();
    if (!this.endpoint_) throw new Error('请先填写 Azure TTS 端点');
    if (!this.key_) throw new Error('请先填写 Azure Speech Key');
    if (!this.voiceName_) this.voiceName_ = 'zh-CN-XiaoxiaoNeural';
    this.ready_ = true;
  }

  async synthesize(req: TtsSynthRequest): Promise<TtsSynthResult> {
    if (!this.ready_) await this.init();
    const body = this.buildSsml_(req.text, req.speed);
    const httpRequest = http.createHttp();
    let resp: http.HttpResponse;
    try {
      resp = await httpRequest.request(this.endpoint_, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/ssml+xml',
          'Ocp-Apim-Subscription-Key': this.key_,
          'X-Microsoft-OutputFormat': AZURE_OUTPUT_FORMAT,
          'User-Agent': 'LegadoHOS',
        },
        extraData: body,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: AZURE_TIMEOUT,
        readTimeout: AZURE_TIMEOUT,
      });
    } catch (err) {
      throw new Error('Azure 请求失败: ' + (err as Error).message);
    } finally {
      httpRequest.destroy();
    }

    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      const message = this.responseToText_(resp.result);
      throw new Error('Azure HTTP ' + resp.responseCode + (message ? ': ' + message.substring(0, 120) : ''));
    }
    const wav = this.resultToBuffer_(resp.result);
    const pcm = this.stripWavHeader_(wav);
    return { pcm, sampleRate: AZURE_SAMPLE_RATE };
  }

  async listVoices(): Promise<TtsVoiceInfo[]> {
    const result: TtsVoiceInfo[] = [];
    for (const voice of AZURE_VOICES) {
      result.push({
        id: voice.id,
        name: voice.name,
        gender: voice.gender,
        language: voice.language,
        description: voice.description,
        downloaded: true,
        engine: 'azure',
      });
    }
    return result;
  }

  setVoice(voiceId: string): void {
    if (voiceId) this.voiceName_ = voiceId;
  }

  async warmup(): Promise<void> {}

  async release(): Promise<void> {
    this.ready_ = false;
  }

  private normalizeEndpoint_(endpoint: string): string {
    let value = (endpoint || '').trim();
    while (value.endsWith('/')) value = value.substring(0, value.length - 1);
    const lower = value.toLowerCase();
    if (lower.indexOf('/cognitiveservices/v1') >= 0) return value;
    if (lower.indexOf('.tts.speech.microsoft.com') >= 0 || lower.indexOf('.tts.speech.azure.cn') >= 0) {
      return value + '/cognitiveservices/v1';
    }
    const globalRegion = this.matchRegion_(lower, 'https://', '.api.cognitive.microsoft.com');
    if (globalRegion) {
      return 'https://' + globalRegion + '.tts.speech.microsoft.com/cognitiveservices/v1';
    }
    const chinaRegion = this.matchRegion_(lower, 'https://', '.api.cognitive.azure.cn');
    if (chinaRegion) {
      return 'https://' + chinaRegion + '.tts.speech.azure.cn/cognitiveservices/v1';
    }
    return value;
  }

  private matchRegion_(value: string, prefix: string, suffix: string): string {
    if (!value.startsWith(prefix)) return '';
    const start = prefix.length;
    const idx = value.indexOf(suffix, start);
    if (idx <= start) return '';
    return value.substring(start, idx);
  }

  private buildSsml_(text: string, speed: number): string {
    const rate = Math.max(-50, Math.min(100, Math.round((speed - 1.0) * 100)));
    const rateText = rate >= 0 ? '+' + rate + '%' : rate + '%';
    const locale = this.voiceName_.startsWith('zh-') ? 'zh-CN' : 'en-US';
    return '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="' + locale + '">' +
      '<voice name="' + this.escapeXml_(this.voiceName_) + '">' +
      '<prosody rate="' + rateText + '">' + this.escapeXml_(text) + '</prosody>' +
      '</voice></speak>';
  }

  private escapeXml_(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  private resultToBuffer_(result: string | Object | ArrayBuffer): ArrayBuffer {
    if (result instanceof ArrayBuffer) return result;
    if (typeof result === 'string') {
      const encoder = new util.TextEncoder();
      return encoder.encodeInto(result).buffer;
    }
    throw new Error('Azure 返回数据类型异常');
  }

  private responseToText_(result: string | Object | ArrayBuffer): string {
    try {
      if (typeof result === 'string') return result;
      if (result instanceof ArrayBuffer) {
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(result));
      }
      return JSON.stringify(result);
    } catch (_) {
      return '';
    }
  }

  private stripWavHeader_(buffer: ArrayBuffer): ArrayBuffer {
    const bytes = new Uint8Array(buffer);
    if (bytes.length < 44) return buffer;
    if (bytes[0] !== 0x52 || bytes[1] !== 0x49 || bytes[2] !== 0x46 || bytes[3] !== 0x46) {
      return buffer;
    }
    for (let i = 12; i + 8 <= bytes.length; i++) {
      if (bytes[i] === 0x64 && bytes[i + 1] === 0x61 && bytes[i + 2] === 0x74 && bytes[i + 3] === 0x61) {
        const size = bytes[i + 4] | (bytes[i + 5] << 8) | (bytes[i + 6] << 16) | (bytes[i + 7] << 24);
        const start = i + 8;
        const end = Math.min(start + size, bytes.length);
        return buffer.slice(start, end);
      }
    }
    return buffer.slice(44);
  }
}

let azureBackend_: AzureTtsBackend | null = null;

export function getAzureTtsBackend(context: common.Context): AzureTtsBackend {
  if (!azureBackend_) azureBackend_ = new AzureTtsBackend(context);
  return azureBackend_;
}
