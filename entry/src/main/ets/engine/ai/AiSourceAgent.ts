/**
 * AI 书源生成 Agent — 多步分析 LLM 驱动的书源规则提取
 *
 * 流程：首页分析 → 搜索分析 → 书籍详情 → 目录分析 → 正文分析 → 汇总
 * 支持 WebView 兜底和登录认证
 */
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { NetUtil } from '../../util/NetUtil';
import { HtmlUtil } from '../../util/HtmlUtil';
import { WebViewFetcher } from '../web/WebViewFetcher';
import util from '@ohos.util';

/** 分析步骤 */
export enum AiStep {
  HOMEPAGE = 0,
  SEARCH = 1,
  BOOK_INFO = 2,
  TOC = 3,
  CONTENT = 4,
  COMPILE = 5,
}

/** 步骤状态 */
export interface AiStepResult {
  step: AiStep;
  label: string;
  status: 'pending' | 'running' | 'done' | 'error';
  summary: string;
  data: Record<string, string>;
}

/** Agent 回调 */
export interface AiAgentCallback {
  onStepUpdate?: (result: AiStepResult) => void;
  onLog?: (msg: string) => void;
  onRequestWebView?: (url: string) => Promise<string>;
  onRequestLogin?: (url: string) => Promise<Record<string, string>>;
}

/** 系统 prompt（source.md 规则文档，运行时加载） */
let cachedSourceMd_: string = '';

export class AiSourceAgent {
  private callback_: AiAgentCallback;
  private endpoint_: string = '';
  private apiKey_: string = '';
  private model_: string = '';
  private results_: AiStepResult[] = [];
  private homepageUrl_: string = '';
  private searchKeyword_: string = '';

  constructor(callback: AiAgentCallback) {
    this.callback_ = callback;
  }

  /** 加载配置 */
  async init(context: Context): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.init(context);
    this.endpoint_ = await s.getAiEndpoint();
    this.apiKey_ = await s.getAiApiKey();
    this.model_ = await s.getAiModel();

    // 加载 source.md
    if (!cachedSourceMd_) {
      try {
        const rm = context.resourceManager;
        const raw = await rm.getRawFileContent('source.md');
        if (raw) {
          const decoder = new util.TextDecoder('utf-8');
          cachedSourceMd_ = decoder.decodeToString(raw);
        }
      } catch (_e) {
        cachedSourceMd_ = 'Legado book source rule format (not loaded).';
      }
    }
  }

  /** 检查是否已配置 */
  isConfigured(): boolean {
    return this.endpoint_.length > 0 && this.apiKey_.length > 0;
  }

  private log_(msg: string): void { this.callback_.onLog?.(msg); }

  /** 执行完整分析 */
  async analyze(homepageUrl: string, searchKeyword: string): Promise<AiStepResult[]> {
    // Store for compile step
    this.homepageUrl_ = homepageUrl;
    this.searchKeyword_ = searchKeyword;
    this.results_ = [
      { step: AiStep.HOMEPAGE, label: '首页分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.SEARCH, label: '搜索分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.BOOK_INFO, label: '详情分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.TOC, label: '目录分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.CONTENT, label: '正文分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.COMPILE, label: '汇总生成', status: 'pending', summary: '', data: {} },
    ];

    try {
      // Step 1: 首页分析
      await this.runStep_(AiStep.HOMEPAGE, homepageUrl, { url: homepageUrl, keyword: searchKeyword });

      // 获取搜索结果 URL（从首页分析得到的 searchUrl 构造）
      const searchData = this.results_[AiStep.HOMEPAGE].data;
      const baseUrl = this.extractOrigin_(homepageUrl);
      const searchUrl = this.buildSearchUrl_(searchData['searchUrl'] || '', baseUrl, searchKeyword);

      // Step 2: 搜索分析
      await this.runStep_(AiStep.SEARCH, searchUrl, { url: searchUrl, baseUrl, keyword: searchKeyword });

      // 获取搜索结果中第一本书的 URL
      const noteUrl = this.results_[AiStep.SEARCH].data['firstBookUrl'] || '';
      const bookUrl = noteUrl || homepageUrl;

      // Step 3: 书籍详情
      await this.runStep_(AiStep.BOOK_INFO, bookUrl, { url: bookUrl, baseUrl });

      // 获取目录 URL
      const tocUrl = this.results_[AiStep.BOOK_INFO].data['tocUrl'] || bookUrl;

      // Step 4: 目录分析
      await this.runStep_(AiStep.TOC, tocUrl, { url: tocUrl, baseUrl });

      // 获取第一章 URL
      const firstChapterUrl = this.results_[AiStep.TOC].data['firstChapterUrl'] || tocUrl;

      // Step 5: 正文分析
      await this.runStep_(AiStep.CONTENT, firstChapterUrl, { url: firstChapterUrl, baseUrl });

      // Step 6: 汇总
      await this.compile_();
    } catch (e) {
      console.error('[AiAgent] Error:', (e as Error).message);
    }

    return this.results_;
  }

  /** 获取最终编译的 BookSource JSON */
  getCompiledSource(): Record<string, string> {
    return this.results_[AiStep.COMPILE].data;
  }

  // ==================== 内部方法 ====================

  /** 获取网页 HTML，自动处理 WebView 兜底 */
  private async fetchHtml_(url: string, label: string): Promise<{ html: string; usedWebView: boolean }> {
    let html = '';
    let usedWebView = false;

    this.log_('📡 抓取 ' + label + ': ' + url.substring(0, 80));
    try {
      html = await NetUtil.httpGet(url, undefined, 25000);
      this.log_('  直接请求成功: ' + html.length + ' 字节');
    } catch (e) {
      const msg = (e as Error).message || '';
      this.log_('  ⚠️ 直接请求失败: ' + msg.substring(0, 60));
    }

    // 检测 SPA / Cloudflare / JS 保护
    if (!html || html.length < 500 || html.includes('Cloudflare') ||
        html.includes('challenge-platform') || html.includes('_cf_chl_opt') ||
        html.includes('<div id="app"></div>') || html.includes('id="root"')) {
      this.log_('  🔒 疑似SPA/JS渲染页面(' + html.length + '字节)，启动 WebView...');

      if (WebViewFetcher.isReady()) {
        try {
          const result = await WebViewFetcher.fetch(url, 30000);
          if (result.html && result.html.length > 200) {
            html = result.html;
            usedWebView = true;
            this.log_('  WebView 成功: ' + html.length + ' 字节');
          }
        } catch (_wv) { this.log_('  WebView 也失败了'); }
      } else if (this.callback_.onRequestWebView) {
        html = await this.callback_.onRequestWebView(url);
        usedWebView = true;
      }
    }

    return { html: HtmlUtil.stripHtml(html) || html, usedWebView };
  }

  /** 执行单步分析 */
  private async runStep_(step: AiStep, fetchUrl: string, context: Record<string, string>): Promise<void> {
    const r = this.results_[step];
    r.status = 'running';
    this.callback_.onStepUpdate?.(r);

    const { html, usedWebView } = await this.fetchHtml_(fetchUrl, r.label);
    if (usedWebView) {
      r.summary += ' (WebView)';
      r.data['useWebView'] = 'true';
    }

    // 截断 HTML
    const truncated = html.length > 50000 ? html.substring(0, 50000) : html;
    this.log_('🤖 发送 ' + truncated.length + ' 字节 HTML 给 ' + this.model_ + '...');
    const instruction = this.buildInstruction_(step, context);

    try {
      const response = await this.callLlm_(cachedSourceMd_, instruction, truncated);
      const parsed = this.parseJson_(response);
      const keys = Object.keys(parsed);
      this.log_('  ✅ LLM 响应: ' + response.length + ' 字符, 字段: ' + keys.join(', '));
      r.data = { ...r.data, ...parsed };
      r.status = 'done';
      r.summary = this.summarize_(step, parsed);
    } catch (e) {
      r.status = 'error';
      r.summary = '分析失败: ' + (e as Error).message?.substring(0, 60);
      this.log_('  ❌ 错误: ' + (e as Error).message?.substring(0, 80));
    }
    this.callback_.onStepUpdate?.(r);
  }

  /** 调用 LLM API */
  private async callLlm_(systemPrompt: string, userPrompt: string, html: string): Promise<string> {
    const userContent = userPrompt + '\n\n=== 页面 HTML 片段 ===\n' + html;
    const body = '{"model":"' + this.model_ + '","messages":[{"role":"system","content":' +
      JSON.stringify(systemPrompt) + '},{"role":"user","content":' +
      JSON.stringify(userContent) + '}],"temperature":0.1,"max_tokens":4096}';

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + this.apiKey_,
    };

    const resp = await NetUtil.httpPost(this.endpoint_, body, headers, 120000);
    const json = JSON.parse(resp) as Record<string, Object>;
    const choices = json['choices'] as Array<Record<string, Object>>;
    if (choices && choices.length > 0) {
      const msg = choices[0]['message'] as Record<string, Object>;
      return (msg['content'] as string) || '';
    }
    throw new Error('Empty response');
  }

  /** 解析 JSON 响应 */
  private parseJson_(text: string): Record<string, string> {
    // 提取 JSON 块
    const jsonMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (jsonMatch) {
      return JSON.parse(jsonMatch[1]) as Record<string, string>;
    }
    // 尝试直接解析
    const trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return JSON.parse(trimmed) as Record<string, string>;
    }
    return {};
  }

  /** 构建每步指令 */
  private buildInstruction_(step: AiStep, ctx: Record<string, string>): string {
    const baseUrl = ctx['baseUrl'] || ctx['url'];

    switch (step) {
      case AiStep.HOMEPAGE:
        return `你是一个 Legado 阅读器书源规则生成专家。请分析以下小说网站首页的 HTML 结构。

任务：
1. 识别搜索功能：找到搜索框/表单，提取搜索 URL 模板。关键词用 {{key}} 占位。
2. 如果是 GET 请求：如 "https://example.com/search?keyword={{key}}"
3. 如果是 POST 请求：在 URL 后附加 JSON 选项，如 "https://example.com/search,{"method":"POST","body":"keyword={{key}}"}"

返回 JSON：
{
  "searchUrl": "搜索URL模板",
  "searchMethod": "GET或POST",
  "siteName": "网站名称"
}`;

      case AiStep.SEARCH:
        return `请分析以下小说网站搜索"${ctx['keyword']}"的结果页 HTML。

任务：找到搜索结果列表，提取各字段的 CSS 选择器。

返回 JSON：
{
  "ruleSearchList": "结果列表项选择器（如 .novelslist2@li）",
  "ruleSearchName": "书名选择器（如 a.0@text）",
  "ruleSearchAuthor": "作者选择器（如 td.1@text）",
  "ruleSearchCover": "封面选择器（如 img.0@src）",
  "ruleSearchNoteUrl": "详情页URL选择器（如 a.0@href）",
  "firstBookUrl": "${baseUrl} 加上详情页相对路径的完整URL"
}`;

      case AiStep.BOOK_INFO:
        return `请分析以下书籍详情页的 HTML。

任务：提取书籍基本信息的选择器，以及目录页的链接。

返回 JSON：
{
  "ruleBookInfoName": "书名选择器",
  "ruleBookInfoAuthor": "作者选择器",
  "ruleBookInfoCover": "封面选择器",
  "ruleBookInfoIntroduce": "简介选择器",
  "ruleBookInfoKind": "分类选择器",
  "tocUrl": "目录页完整URL"
}`;

      case AiStep.TOC:
        return `请分析以下目录页的 HTML。

任务：提取章节列表的 CSS 选择器。注意识别分卷或多页目录。

返回 JSON（使用 Legado Default 规则语法，详见 system prompt）：
{
  "ruleTocUrl": "目录页URL模板（如有分页，用 {{page}} 占位）",
  "ruleToc": "章节列表选择器（如 .chapter@li 或 ul.list@li）",
  "ruleTocTitle": "章节标题选择器（如 a.0@text）",
  "ruleTocUrlItem": "章节链接选择器（如 a.0@href）",
  "firstChapterUrl": "第一章的完整URL"
}`;

      case AiStep.CONTENT:
        return `请分析以下章节正文页的 HTML。

任务：提取正文内容和翻页的选择器。

返回 JSON：
{
  "ruleBookContentUrl": "正文页URL模板（如有，用 {{}} 占位）",
  "ruleBookContent": "正文内容选择器（如 #content@html 或 .content@textNodes）",
  "ruleBookContentNext": "下一页链接选择器（如 a.next@href）"
}`;

      default:
        return '';
    }
  }

  /** 汇总生成 */
  private async compile_(): Promise<void> {
    const r = this.results_[AiStep.COMPILE];
    r.status = 'running';
    this.callback_.onStepUpdate?.(r);

    // 合并所有步骤的数据
    const allData: Record<string, string> = {
      sourceUrl: this.homepageUrl_,
      sourceType: '1',
      weight: '0',
      enabled: 'true',
      respondTime: '180000',
    };
    for (const step of this.results_) {
      if (step.step === AiStep.COMPILE) continue;
      for (const k of Object.keys(step.data)) {
        allData[k] = step.data[k];
      }
    }

    r.data = allData;
    r.status = 'done';
    r.summary = `共提取 ${Object.keys(allData).length} 个规则字段`;
    this.callback_.onStepUpdate?.(r);
  }

  /** 构造搜索 URL */
  private buildSearchUrl_(searchUrl: string, baseUrl: string, keyword: string): string {
    if (!searchUrl) {
      return `${baseUrl}/search?keyword=${encodeURIComponent(keyword)}`;
    }
    return searchUrl.replace(/\{\{key\}\}/g, keyword).replace(/\{\{keyword\}\}/g, keyword);
  }

  /** 提取 URL 的 origin */
  private extractOrigin_(url: string): string {
    const m = url.match(/^(https?:\/\/[^\/]+)/);
    return m ? m[1] : url;
  }

  /** 生成步骤摘要 */
  private summarize_(step: AiStep, data: Record<string, string>): string {
    const keys = Object.keys(data).filter(k => !k.startsWith('first') && !k.startsWith('toc'));
    return `提取 ${keys.length} 个字段`;
  }
}
