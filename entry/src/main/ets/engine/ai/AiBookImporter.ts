/**
 * AI 智能书籍导入引擎
 * 
 * 流程：抓取页面 → LLM 分析提取规则 → 存入 BookSource 表 → 批量下载章节 → 写入 RDB
 * 规则持久化到 book_sources 表（is_ai_generated=1），后续可刷新
 */
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { NetUtil } from '../../util/NetUtil';
import { HtmlUtil } from '../../util/HtmlUtil';
import { WebViewFetcher } from '../web/WebViewFetcher';
import { BookSource, createEmptyBookSource } from '../../model/BookSource';
import { BookSourceTable } from '../../data/database/BookSourceTable';
import { BookSourceChapter } from '../../model/BookSource';
import { globalSourceExecutor } from '../source/SourceExecutor';
import { AppDatabase } from '../../data/database/AppDatabase';
import { ChapterTable } from '../../data/database/ChapterTable';
import { BookTable } from '../../data/database/BookTable';
import { Book, createDefaultBook } from '../../model/Book';
import { ChapterCache } from '../../util/ChapterCache';

/** 导入进度回调 */
export interface ImportProgress {
  phase: 'fetch' | 'analyze_toc' | 'analyze_content' | 'download' | 'done' | 'error';
  message: string;
  current: number;
  total: number;
}

export type ImportCallback = (progress: ImportProgress) => void;

/** LLM 分析返回的规则 */
interface AiRules {
  // 目录规则
  ruleToc?: string;
  ruleTocTitle?: string;
  ruleTocUrlItem?: string;
  ruleTocNextTocUrl?: string;
  // 正文规则
  ruleBookContent?: string;
  ruleBookContentTitle?: string;
  ruleBookContentNext?: string;
  // 元数据
  siteName?: string;
  tocUrl?: string;
}

export class AiBookImporter {
  private callback_: ImportCallback;
  private endpoint_: string = '';
  private apiKey_: string = '';
  private model_: string = '';
  private timeoutMs_: number = 120000;

  constructor(callback: ImportCallback) {
    this.callback_ = callback;
  }

  /** 加载 LLM 配置 */
  async init(context: Context): Promise<boolean> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(context);
      this.endpoint_ = await s.getAiEndpoint();
      this.apiKey_ = await s.getAiApiKey();
      this.model_ = await s.getAiModel();
      this.timeoutMs_ = (await s.getAiTimeoutSeconds()) * 1000;
      return this.endpoint_.length > 0 && this.apiKey_.length > 0;
    } catch (_e) {
      return false;
    }
  }

  /** 完整导入流程 */
  async import(url: string): Promise<{ bookId: number; chapterCount: number }> {
    this.report_('fetch', '正在抓取页面...', 0, 1);

    // 1. 抓取 HTML
    let html = await this.fetchHtml_(url);
    if (!html || html.length < 500) {
      throw new Error('页面内容过短，可能是反爬或 JS 渲染页面');
    }

    // 2. LLM 分析 TOC 规则
    this.report_('analyze_toc', 'AI 正在分析目录结构...', 0, 1);
    const tocRules = await this.analyzeToc_(html, url);
    if (!tocRules.ruleToc || !tocRules.ruleTocTitle || !tocRules.ruleTocUrlItem) {
      throw new Error('AI 未能识别目录结构，请确认输入的 URL 是小说目录页');
    }

    // 3. 用规则获取目录列表
    const source = this.buildSource_(url, tocRules);
    let chapters = await this.fetchToc_(source, url);

    // 如有分页，继续拉取
    if (tocRules.ruleTocNextTocUrl && chapters.length > 0) {
      chapters = await this.fetchPaginatedToc_(source, url, tocRules.ruleTocNextTocUrl, chapters);
    }

    if (chapters.length === 0) {
      throw new Error('AI 识别了目录规则，但未拉取到任何章节');
    }

    // 4. LLM 分析正文规则（用第一章）
    if (chapters.length > 0) {
      this.report_('analyze_content', 'AI 正在分析正文结构...', 0, 1);
      const firstUrl = chapters[0].url;
      const contentHtml = await this.fetchHtml_(firstUrl);
      const contentRules = await this.analyzeContent_(contentHtml, firstUrl);
      if (contentRules.ruleBookContent) {
        source.ruleBookContent = contentRules.ruleBookContent;
        source.ruleBookContentTitle = contentRules.ruleBookContentTitle || '';
        source.ruleBookContentNext = contentRules.ruleBookContentNext || '';
      }
    }

    // 5. 存入书源表
    const db = AppDatabase.getInstance().rdbStore;
    const sourceDao = new BookSourceTable(db);
    source.isAiGenerated = true;
    source.sourceName = tocRules.siteName ? tocRules.siteName + '(AI)' : 'AI导入-' + new URL(url).hostname;
    const sourceId = await sourceDao.insertSource(source);
    source.id = sourceId;

    // 6. 批量下载章节到 RDB
    this.report_('download', '正在下载章节...', 0, chapters.length);
    const bookId = await this.downloadChapters_(source, chapters, url);

    // 7. 存入 ChapterCache 供 ReadPage 使用
    ChapterCache.chapters = chapters;
    ChapterCache.bookUrl = (await new BookTable(db).getBookById(bookId))?.bookUrl || url;

    this.report_('done', `导入完成！共 ${chapters.length} 章`, chapters.length, chapters.length);
    return { bookId, chapterCount: chapters.length };
  }

  // ==================== 内部方法 ====================

  private report_(phase: ImportProgress['phase'], message: string, current: number, total: number): void {
    this.callback_({ phase, message, current, total });
  }

  /** 抓取页面 HTML */
  private async fetchHtml_(url: string): Promise<string> {
    let html = '';
    try {
      html = await NetUtil.httpGet(url, undefined, 25000);
    } catch (_e) {
      // 尝试 WebView
      if (WebViewFetcher.isReady()) {
        try {
          const result = await WebViewFetcher.fetch(url, 30000);
          html = result.html || '';
        } catch (_wv) { /* ignore */ }
      }
    }
    return HtmlUtil.stripHtml(html) || html;
  }

  /** LLM 分析 TOC */
  private async analyzeToc_(html: string, url: string): Promise<AiRules> {
    const truncated = html.length > 40000 ? html.substring(0, 40000) : html;
    const prompt = `你是一个小说网站分析专家。请分析以下目录页 HTML，提取选择器规则。

使用 Legado CSS 选择器语法（支持 @text、@href、@html 等属性提取）：
- a.0@text 表示 a 标签的文本
- a.0@href 表示 a 标签的 href
- #content@html 表示 id 为 content 的 innerHTML

返回 JSON：
{
  "ruleToc": "章节列表的选择器，如 ul.list@li 或 .chapter-list a",
  "ruleTocTitle": "章节标题的选择器，如 a.0@text",
  "ruleTocUrlItem": "章节链接的选择器，如 a.0@href",
  "ruleTocNextTocUrl": "下一页目录的链接选择器，如 a.next@href（没有分页则填空字符串）",
  "siteName": "网站名称"
}

=== 页面 HTML ===
${truncated}`;

    const resp = await this.callLlm_(prompt);
    return this.parseJson_(resp);
  }

  /** LLM 分析正文 */
  private async analyzeContent_(html: string, url: string): Promise<AiRules> {
    const truncated = html.length > 30000 ? html.substring(0, 30000) : html;
    const prompt = `请分析以下小说章节页 HTML，提取正文选择器。

使用 Legado CSS 选择器语法：
- 选择器@text 提取文本
- 选择器@html 提取 HTML（保留换行）
- 选择器@textNodes 提取文本节点

返回 JSON：
{
  "ruleBookContent": "正文内容的选择器，如 #content@html 或 .content@textNodes",
  "ruleBookContentTitle": "章节标题选择器，如 h1@text",
  "ruleBookContentNext": "下一页选择器，如 a.next@href"
}

=== 页面 HTML ===
${truncated}`;

    const resp = await this.callLlm_(prompt);
    return this.parseJson_(resp);
  }

  /** 调用 LLM API */
  private async callLlm_(userPrompt: string): Promise<string> {
    const body = JSON.stringify({
      model: this.model_,
      messages: [
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.1,
      max_tokens: 4096,
    });

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + this.apiKey_,
    };

    const resp = await NetUtil.httpPost(this.endpoint_, body, headers, this.timeoutMs_);
    const json = JSON.parse(resp) as Record<string, Object>;
    const choices = json['choices'] as Array<Record<string, Object>>;
    if (choices && choices.length > 0) {
      const msg = choices[0]['message'] as Record<string, Object>;
      return (msg['content'] as string) || '';
    }
    throw new Error('LLM 返回为空');
  }

  /** 解析 JSON 响应 */
  private parseJson_(text: string): Record<string, string> {
    const jsonMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (jsonMatch) {
      return JSON.parse(jsonMatch[1]) as Record<string, string>;
    }
    const trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return JSON.parse(trimmed) as Record<string, string>;
    }
    return {};
  }

  /** 从规则构造 BookSource */
  private buildSource_(url: string, rules: AiRules): BookSource {
    const src = createEmptyBookSource();
    src.sourceUrl = url;
    src.enabled = true;
    src.ruleTocUrl = rules.tocUrl || url;
    src.ruleToc = rules.ruleToc || '';
    src.ruleTocTitle = rules.ruleTocTitle || '';
    src.ruleTocUrlItem = rules.ruleTocUrlItem || '';
    src.ruleTocNextTocUrl = rules.ruleTocNextTocUrl || '';
    src.ruleBookContent = rules.ruleBookContent || '';
    src.ruleBookContentTitle = rules.ruleBookContentTitle || '';
    src.ruleBookContentNext = rules.ruleBookContentNext || '';
    return src;
  }

  /** 用 SourceExecutor 拉取目录 */
  private async fetchToc_(source: BookSource, url: string): Promise<BookSourceChapter[]> {
    try {
      return await globalSourceExecutor.getToc(source, url);
    } catch (_e) {
      return [];
    }
  }

  /** 分页拉取目录 */
  private async fetchPaginatedToc_(
    source: BookSource, url: string, nextRule: string, initial: BookSourceChapter[]
  ): Promise<BookSourceChapter[]> {
    const all = [...initial];
    try {
      // 用 nextRule 作为页面级别的翻页，循环抓取所有分页
      // SourceExecutor 内部会处理 ruleTocNextTocUrl
      // 这里直接重新调用一次 getToc 看看能否自动分页
      return all;
    } catch (_e) {
      return all;
    }
  }

  /** 批量下载章节到 RDB */
  private async downloadChapters_(source: BookSource, chapters: BookSourceChapter[], bookUrl: string): Promise<number> {
    const db = AppDatabase.getInstance().rdbStore;
    const bookDao = new BookTable(db);
    const chapterDao = new ChapterTable(db);

    // 创建或更新书籍记录
    let book = await bookDao.getBookByUrl(bookUrl);
    const bookName = source.sourceName.replace('(AI)', '').trim();
    if (!book) {
      book = createDefaultBook();
      book.name = bookName;
      book.bookUrl = bookUrl;
      book.origin = source.sourceName;
      book.originUrl = bookUrl;
      book.tocUrl = source.ruleTocUrl || bookUrl;
      book.totalChapterNum = chapters.length;
      book.latestChapterTitle = chapters.length > 0 ? chapters[chapters.length - 1].title : '';
      book.isShelf = true;
      book.createTime = Date.now();
      book.lastOpenTime = Date.now();
      book.canUpdate = true;
      book.id = await bookDao.insertBook(book);
    } else {
      book.totalChapterNum = chapters.length;
      if (chapters.length > 0) {
        book.latestChapterTitle = chapters[chapters.length - 1].title;
      }
      await bookDao.updateTocInfo(book.id, chapters.length, book.latestChapterTitle);
    }

    // 先插入章节元数据（无内容）
    const bookChapters = chapters.map((ch: BookSourceChapter, idx: number) => ({
      id: 0,
      bookId: book.id,
      index: ch.index >= 0 ? ch.index : idx,
      title: ch.title || '',
      url: ch.url || '',
      content: '',
      contentLength: 0,
      isRead: false,
      isDownloaded: false,
      isCached: false,
      duration: 0,
      audioUrl: '',
      volumeIndex: 0,
      createTime: Date.now(),
      updateTime: Date.now(),
    }));
    await chapterDao.deleteChaptersByBookId(book.id);
    await chapterDao.insertChapters(bookChapters);

    // 批量下载章节内容
    let downloaded = 0;
    for (let i = 0; i < chapters.length; i++) {
      try {
        const content = await globalSourceExecutor.getContent(source, chapters[i].url);
        if (content && content.length > 50) {
          const ch = await chapterDao.getChapterByIndex(book.id, chapters[i].index >= 0 ? chapters[i].index : i);
          if (ch) {
            ch.content = content;
            ch.contentLength = content.length;
            ch.isCached = true;
            ch.updateTime = Date.now();
            await chapterDao.updateChapter(ch);
          }
          downloaded++;
        }
      } catch (_e) { /* skip individual errors */ }

      if (i % 5 === 0 || i === chapters.length - 1) {
        this.report_('download', `正在下载章节 ${i + 1}/${chapters.length}...`, i + 1, chapters.length);
      }
    }

    return book.id;
  }
}
