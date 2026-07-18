/** 从龙空选中主题中整理推荐/讨论书目的轻量 Agent。 */
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { NetUtil } from '../../util/NetUtil';
import { LkongThreadContent } from '../../service/LkongService';

export interface LkongBookRecommendation {
  name: string;
  author: string;
  reason: string;
}

export interface LkongAnalysisRecord {
  id: string;
  title: string;
  createdAt: number;
  filterLabel: string;
  threadCount: number;
  books: LkongBookRecommendation[];
}

export class LkongBookAgent {
  private static readonly MAX_BATCH_CHARS: number = 80000;
  private endpoint: string = '';
  private apiKey: string = '';
  private model: string = '';
  private timeoutMs: number = 120000;

  async init(context: Context): Promise<void> {
    const store = SettingsStore.getInstance();
    await store.init(context);
    this.endpoint = await store.getAiEndpoint();
    this.apiKey = await store.getAiApiKey();
    this.model = await store.getAiModel();
    this.timeoutMs = (await store.getAiTimeoutSeconds()) * 1000;
  }

  isConfigured(): boolean {
    return this.endpoint.trim().length > 0 && this.model.trim().length > 0 && this.apiKey.trim().length > 0;
  }

  async analyze(threads: LkongThreadContent[]): Promise<LkongBookRecommendation[]> {
    if (!this.isConfigured()) throw new Error('请先在设置中配置大模型 API');
    const batches: string[] = [];
    let currentBatch = '';
    for (const item of threads) {
      // 普通多选尽量拼接为一次请求；只有总上下文确实较大时才自动分批。
      const heading = `\n=== 主题：${item.thread.title}（${item.thread.author}）===\n`;
      const contentLimit = Math.max(0, LkongBookAgent.MAX_BATCH_CHARS - heading.length);
      const block = heading + item.content.substring(0, contentLimit);
      if (currentBatch && currentBatch.length + block.length > LkongBookAgent.MAX_BATCH_CHARS) {
        batches.push(currentBatch);
        currentBatch = block;
      } else {
        currentBatch += block;
      }
    }
    if (currentBatch) batches.push(currentBatch);
    if (batches.length === 0) throw new Error('所选帖子没有可分析的正文');

    const allBooks: LkongBookRecommendation[] = [];
    for (const batch of batches) {
      allBooks.push(...await this.analyzeBatch(batch));
    }
    return this.mergeBooks(allBooks);
  }

  private async analyzeBatch(context: string): Promise<LkongBookRecommendation[]> {
    const systemPrompt = `你是网文推荐整理 Agent。只依据用户提供的论坛主题和回复，提取其中被推荐或被实质讨论的小说。
【主帖】的书目优先级最高；如果主帖是编号或分段的推书清单，必须逐项检查，不得只抽取跟帖中的书。
合并同一本书的不同写法并去重。输出必须是 JSON 对象，格式为：
{"books":[{"name":"书名","author":"作者，不确定时为空字符串","reason":"综合帖子观点的简洁推荐理由；有争议时同时说明优缺点"}]}
不要虚构书名、作者或评价。不要输出 Markdown或其他文字。`;
    const userPrompt = '请分析以下龙空“推书试读”主题：\n' + context;
    const request: Record<string, Object> = {
      'model': this.model,
      'messages': [
        { 'role': 'system', 'content': systemPrompt },
        { 'role': 'user', 'content': userPrompt },
      ],
      'temperature': 0.1,
      'max_tokens': 4096,
    };
    // OpenRouter 可能将免费路由到推理模型。降低推理强度并要求 JSON，
    // 避免 token 全消耗在 reasoning 后 message.content 为空。
    if (this.endpoint.toLowerCase().includes('openrouter.ai')) {
      request['response_format'] = { 'type': 'json_object' };
      request['reasoning'] = { 'effort': 'low', 'exclude': true };
    }
    // DeepSeek V4 默认开启思考模式。推书整理是结构化抽取任务，关闭思考可避免
    // max_tokens 全部消耗在 reasoning_content，导致最终 content 为空。
    if (this.endpoint.toLowerCase().includes('api.deepseek.com')) {
      request['thinking'] = { 'type': 'disabled' };
      request['response_format'] = { 'type': 'json_object' };
      request['max_tokens'] = 16384;
    }
    const body = JSON.stringify(request);
    console.info('[LkongBookAgent] request model=' + this.model + ', contextChars=' + context.length +
      ', timeoutMs=' + this.timeoutMs + ', maxTokens=' + String(request['max_tokens'] || ''));
    const response = await NetUtil.httpPost(this.endpoint, body, {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + this.apiKey,
    }, this.timeoutMs);
    return this.parseResponse(response);
  }

  private mergeBooks(items: LkongBookRecommendation[]): LkongBookRecommendation[] {
    const merged: LkongBookRecommendation[] = [];
    const indexByKey = new Map<string, number>();
    for (const book of items) {
      const key = (book.name.replace(/[《》\s]/g, '') + '\u0000' + book.author.replace(/\s/g, '')).toLowerCase();
      const existingIndex = indexByKey.get(key);
      if (existingIndex === undefined) {
        indexByKey.set(key, merged.length);
        merged.push(book);
      } else if (!merged[existingIndex].reason.includes(book.reason)) {
        merged[existingIndex] = {
          name: merged[existingIndex].name,
          author: merged[existingIndex].author || book.author,
          reason: merged[existingIndex].reason + '；' + book.reason,
        };
      }
    }
    return merged;
  }

  parseResponse(response: string): LkongBookRecommendation[] {
    const json = JSON.parse(response) as Record<string, Object>;
    const choices = json['choices'] as Array<Record<string, Object>> | undefined;
    if (!choices || choices.length === 0) {
      const error = json['error'] as Record<string, Object> | undefined;
      const errorMessage = error ? String(error['message'] || '') : '';
      throw new Error(errorMessage ? '大模型请求失败：' + errorMessage : '大模型响应为空');
    }
    const choice = choices[0];
    const message = choice['message'] as Record<string, Object> | undefined;
    const content = message ? this.extractText_(message['content']) : '';
    const reasoning = message ? this.extractText_(message['reasoning'] || message['reasoning_content']) : '';
    const fallbackText = this.extractText_(choice['text']);
    const finishReason = String(choice['finish_reason'] || '');
    const model = String(json['model'] || this.model || 'unknown');
    console.info('[LkongBookAgent] response model=' + model + ', finish=' + finishReason +
      ', contentLength=' + content.length + ', reasoningLength=' + reasoning.length);

    const raw = content || fallbackText || reasoning;
    const rows = this.extractRows_(raw);
    if (rows.length === 0) {
      if (finishReason === 'length' || (!content && reasoning.length > 0)) {
        throw new Error('模型输出被推理或长度限制耗尽，请重试或选择非推理模型');
      }
      throw new Error('大模型未返回可识别的书籍列表');
    }
    const books: LkongBookRecommendation[] = [];
    const seen = new Set<string>();
    for (const row of rows) {
      const name = String(row['name'] || row['title'] || '').trim();
      const author = String(row['author'] || '').trim();
      const reason = String(row['reason'] || row['recommendation'] || '').trim();
      const key = (name + '\u0000' + author).toLowerCase();
      if (!name || seen.has(key)) continue;
      seen.add(key);
      books.push({ name: name, author: author, reason: reason || '帖子中提及或讨论' });
    }
    if (books.length === 0) throw new Error('所选帖子中未提取到明确书目');
    return books;
  }

  private extractText_(value: Object | undefined): string {
    if (value === undefined || value === null) return '';
    if (typeof value === 'string') return value;
    if (!Array.isArray(value)) return '';
    const parts = value as Array<Record<string, Object>>;
    let text = '';
    for (const part of parts) {
      text += String(part['text'] || part['content'] || '');
    }
    return text;
  }

  private extractRows_(content: string): Array<Record<string, Object>> {
    if (!content.trim()) return [];
    const match = content.match(/```(?:json)?\s*([\s\S]*?)```/i);
    const raw = (match ? match[1] : content).trim();
    const direct = this.tryParseRows_(raw);
    if (direct.length > 0) return direct;

    const objectStart = raw.indexOf('{');
    const objectEnd = raw.lastIndexOf('}');
    if (objectStart >= 0 && objectEnd > objectStart) {
      const objectRows = this.tryParseRows_(raw.substring(objectStart, objectEnd + 1));
      if (objectRows.length > 0) return objectRows;
    }
    const arrayStart = raw.indexOf('[');
    const arrayEnd = raw.lastIndexOf(']');
    if (arrayStart >= 0 && arrayEnd > arrayStart) {
      return this.tryParseRows_(raw.substring(arrayStart, arrayEnd + 1));
    }
    return [];
  }

  private tryParseRows_(raw: string): Array<Record<string, Object>> {
    try {
      const parsed = JSON.parse(raw) as Object;
      if (Array.isArray(parsed)) return parsed as Array<Record<string, Object>>;
      const wrapper = parsed as Record<string, Object>;
      const rows = wrapper['books'] || wrapper['recommendations'] || wrapper['items'] || wrapper['data'];
      return Array.isArray(rows) ? rows as Array<Record<string, Object>> : [];
    } catch (_e) {
      return [];
    }
  }
}
