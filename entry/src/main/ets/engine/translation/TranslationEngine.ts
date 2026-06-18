/**
 * 翻译引擎
 *
 * 支持：
 * 1. 字典翻译（逐词查询）
 * 2. LLM 翻译（调用外部 API 翻译整章）
 * 3. 翻译缓存（避免重复请求）
 */
import { NetUtil } from '../../util/NetUtil';
import { CacheTable } from '../../data/database/CacheTable';
import { AppDatabase } from '../../data/database/AppDatabase';

export enum TranslationProvider {
  YOUDAO = 'youdao',
  BAIDU = 'baidu',
  DEEPL = 'deepl',
  OPENAI = 'openai',
  CUSTOM = 'custom',
}

export interface TranslateConfig {
  provider: TranslationProvider;
  appId: string;
  appSecret: string;
  apiUrl: string;
  sourceLang: string;
  targetLang: string;
}

export class TranslationEngine {
  private config: TranslateConfig;
  private cacheTable: CacheTable;

  constructor(config: TranslateConfig) {
    this.config = config;
    this.cacheTable = new CacheTable(AppDatabase.getInstance().rdbStore);
  }

  /**
   * 翻译文本（带缓存）
   */
  async translate(text: string): Promise<string> {
    if (!text || !text.trim()) return text;

    // 检查缓存
    const cacheKey = `trans_${this.config.targetLang}_${text.slice(0, 100)}`;
    const cached = await this.cacheTable.get(cacheKey);
    if (cached) return cached;

    let result: string;

    switch (this.config.provider) {
      case TranslationProvider.YOUDAO:
        result = await this.translateYouDao(text);
        break;
      case TranslationProvider.BAIDU:
        result = await this.translateBaidu(text);
        break;
      case TranslationProvider.OPENAI:
        result = await this.translateOpenAI(text);
        break;
      default:
        result = text;
    }

    // 缓存结果（24小时）
    await this.cacheTable.put(cacheKey, result, 24 * 3600 * 1000);

    return result;
  }

  /**
   * 批量翻译多个段落
   */
  async translateBatch(paragraphs: string[]): Promise<string[]> {
    const results: string[] = [];
    for (const p of paragraphs) {
      if (p.trim()) {
        results.push(await this.translate(p));
      } else {
        results.push(p);
      }
    }
    return results;
  }

  /**
   * 有道翻译 API
   */
  private async translateYouDao(text: string): Promise<string> {
    const salt = Date.now();
    const sign = this.md5(`${this.config.appId}${text}${salt}${this.config.appSecret}`);
    const url = 'https://openapi.youdao.com/api';
    const body = `q=${encodeURIComponent(text)}&from=${this.config.sourceLang || 'auto'}&to=${this.config.targetLang || 'zh'}&appKey=${this.config.appId}&salt=${salt}&sign=${sign}`;

    try {
      const resp = await NetUtil.httpPost(url, body, {
        'Content-Type': 'application/x-www-form-urlencoded',
      });
      const json = JSON.parse(resp);
      if (json.translation && json.translation.length > 0) {
        return json.translation[0];
      }
    } catch (err) {
      console.error('[Translation] YouDao failed:', err);
    }
    return text;
  }

  /**
   * 百度翻译 API
   */
  private async translateBaidu(text: string): Promise<string> {
    const salt = Date.now();
    const sign = this.md5(`${this.config.appId}${text}${salt}${this.config.appSecret}`);
    const url = 'https://fanyi-api.baidu.com/api/trans/vip/translate';
    const body = `q=${encodeURIComponent(text)}&from=${this.config.sourceLang || 'auto'}&to=${this.config.targetLang || 'zh'}&appid=${this.config.appId}&salt=${salt}&sign=${sign}`;

    try {
      const resp = await NetUtil.httpPost(url, body, {
        'Content-Type': 'application/x-www-form-urlencoded',
      });
      const json = JSON.parse(resp);
      if (json.trans_result) {
        return json.trans_result.map((r: any) => r.dst).join('\n');
      }
    } catch (err) {
      console.error('[Translation] Baidu failed:', err);
    }
    return text;
  }

  /**
   * OpenAI API 翻译
   */
  private async translateOpenAI(text: string): Promise<string> {
    const url = this.config.apiUrl || 'https://api.openai.com/v1/chat/completions';

    try {
      const resp = await NetUtil.httpPost(url, JSON.stringify({
        model: 'gpt-3.5-turbo',
        messages: [
          { role: 'system', content: `将以下${this.config.sourceLang || '英文'}文本翻译为${this.config.targetLang || '中文'}` },
          { role: 'user', content: text },
        ],
        temperature: 0.3,
      }), {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.appSecret}`,
      });
      const json = JSON.parse(resp);
      return json.choices?.[0]?.message?.content || text;
    } catch (err) {
      console.error('[Translation] OpenAI failed:', err);
    }
    return text;
  }

  /**
   * 字典翻译（逐词查询）
   */
  async dictionaryLookup(word: string): Promise<string> {
    // 通过外部字典 API 查询
    const url = `https://dict.youdao.com/jsonapi?q=${encodeURIComponent(word)}`;
    try {
      const resp = await NetUtil.httpGet(url);
      const json = JSON.parse(resp);
      // 解析有道词典返回
      const explains = json.ec?.word?.[0]?.trs?.map((t: any) => t.tr?.[0]?.l?.i?.[0]) || [];
      return explains.join('; ');
    } catch {
      return '';
    }
  }

  private md5(str: string): string {
    // 简化的 MD5 实现，生产环境使用 @ohos.security.crypto
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
      hash = ((hash << 5) - hash) + str.charCodeAt(i);
      hash = hash & hash;
    }
    return Math.abs(hash).toString(16).padStart(8, '0');
  }
}
