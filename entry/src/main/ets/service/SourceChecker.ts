/**
 * 书源校验服务
 *
 * 对书源执行以下检查（可配置）：
 * - 搜索：使用关键词搜索，验证是否有返回结果
 * - 发现：如果有发现 URL，尝试拉取发现页内容
 * - 详情：从搜索结果取一个书籍详情页，验证详情解析
 * - 目录：从详情结果取目录 URL，验证目录解析
 * - 正文：取第一章正文，验证内容解析
 */
import { BookSource, BookSourceBookInfo, BookSourceChapter } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ExploreEngine } from '../engine/source/ExploreEngine';

export interface CheckConfig {
  keyword: string;
  timeout: number;
  checkSearch: boolean;
  checkDiscovery: boolean;
  checkInfo: boolean;
  checkCategory: boolean;
  checkContent: boolean;
}

export interface CheckResult {
  sourceUrl: string;
  sourceName: string;
  status: string;  // 'success' | 'partial' | 'fail'
  totalChecks: number;
  passedChecks: number;
  details: CheckDetail[];
  errorMessage: string;
}

export interface CheckDetail {
  name: string;
  passed: boolean;
  message: string;
  duration: number;
}

function getErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

export class SourceChecker {
  private config: CheckConfig;
  private cancelFlag: boolean = false;
  private resultsMap: Map<string, CheckResult> = new Map();

  constructor(config?: Partial<CheckConfig>) {
    this.config = {
      keyword: (config && config.keyword !== undefined) ? config.keyword : '我',
      timeout: (config && config.timeout !== undefined) ? config.timeout : 30000,
      checkSearch: (config && config.checkSearch !== undefined) ? config.checkSearch : true,
      checkDiscovery: (config && config.checkDiscovery !== undefined) ? config.checkDiscovery : false,
      checkInfo: (config && config.checkInfo !== undefined) ? config.checkInfo : false,
      checkCategory: (config && config.checkCategory !== undefined) ? config.checkCategory : false,
      checkContent: (config && config.checkContent !== undefined) ? config.checkContent : false,
    };
  }

  getConfig(): CheckConfig {
    return this.config;
  }

  updateConfig(partial: Partial<CheckConfig>): void {
    if (partial.keyword !== undefined) this.config.keyword = partial.keyword;
    if (partial.timeout !== undefined) this.config.timeout = partial.timeout;
    if (partial.checkSearch !== undefined) this.config.checkSearch = partial.checkSearch;
    if (partial.checkDiscovery !== undefined) this.config.checkDiscovery = partial.checkDiscovery;
    if (partial.checkInfo !== undefined) this.config.checkInfo = partial.checkInfo;
    if (partial.checkCategory !== undefined) this.config.checkCategory = partial.checkCategory;
    if (partial.checkContent !== undefined) this.config.checkContent = partial.checkContent;
  }

  getResult(sourceUrl: string): CheckResult | undefined {
    return this.resultsMap.get(sourceUrl);
  }

  getAllResults(): Map<string, CheckResult> {
    return this.resultsMap;
  }

  cancel(): void {
    this.cancelFlag = true;
  }

  reset(): void {
    this.cancelFlag = false;
    this.resultsMap.clear();
  }

  async checkSources(
    sources: BookSource[],
    onProgress?: (completed: number, total: number, result: CheckResult) => void
  ): Promise<Map<string, CheckResult>> {
    this.cancelFlag = false;
    const total = sources.length;
    let completed = 0;

    for (let s = 0; s < sources.length; s++) {
      if (this.cancelFlag) break;
      const result = await this.checkSingleSource(sources[s]);
      this.resultsMap.set(sources[s].sourceUrl, result);
      completed++;
      if (onProgress) {
        onProgress(completed, total, result);
      }
    }
    return this.resultsMap;
  }

  private async checkSingleSource(source: BookSource): Promise<CheckResult> {
    const details: CheckDetail[] = [];
    let passedChecks = 0;
    let totalChecks = 0;

    let searchResults: SearchResult[] = [];
    let bookInfo: BookSourceBookInfo | null = null;
    let chapters: BookSourceChapter[] = [];

    // 1. 搜索检查
    if (this.config.checkSearch && !this.cancelFlag) {
      totalChecks++;
      const startTime = Date.now();
      try {
        const results: SearchResult[] = await this.runWithTimeout(
          globalSourceExecutor.search(this.config.keyword, [source]),
          this.config.timeout
        );
        const elapsed = Date.now() - startTime;
        if (results.length > 0) {
          searchResults = results;
          passedChecks++;
          details.push({ name: '搜索', passed: true, message: '成功返回 ' + results.length + ' 条结果', duration: elapsed });
        } else {
          details.push({ name: '搜索', passed: false, message: '无搜索结果', duration: elapsed });
        }
      } catch (e) {
        const elapsed = Date.now() - startTime;
        details.push({ name: '搜索', passed: false, message: '失败: ' + getErrorMessage(e), duration: elapsed });
      }
    }

    // 2. 发现检查
    if (this.config.checkDiscovery && !this.cancelFlag &&
        source.exploreUrl !== undefined && source.exploreUrl !== null && source.exploreUrl.trim()) {
      totalChecks++;
      const startTime = Date.now();
      try {
        const exploresRaw: string = source.ruleExplores || source.exploreUrl;
        const kinds = ExploreEngine.parseKinds(exploresRaw, source);
        let hasContent = false;
        if (kinds.length > 0) {
          const books: SearchResult[] = await this.runWithTimeout(
            ExploreEngine.fetchKindBooks(kinds[0], source, 1),
            this.config.timeout
          );
          if (books.length > 0) {
            hasContent = true;
          }
        }
        const elapsed = Date.now() - startTime;
        if (hasContent) {
          passedChecks++;
          details.push({ name: '发现', passed: true, message: '发现页正常，分类 ' + kinds.length + ' 个', duration: elapsed });
        } else {
          details.push({ name: '发现', passed: false, message: kinds.length > 0 ? '发现页无书籍' : '无发现分类', duration: elapsed });
        }
      } catch (e) {
        const elapsed = Date.now() - startTime;
        details.push({ name: '发现', passed: false, message: '失败: ' + getErrorMessage(e), duration: elapsed });
      }
    }

    // 3. 详情检查（需要搜索结果为前提）
    if (this.config.checkInfo && !this.cancelFlag && searchResults.length > 0) {
      totalChecks++;
      const startTime = Date.now();
      try {
        const noteUrl: string = searchResults[0].noteUrl;
        if (!noteUrl) {
          details.push({ name: '详情', passed: false, message: '搜索结果无书籍详情 URL', duration: Date.now() - startTime });
        } else {
          const info: BookSourceBookInfo = await this.runWithTimeout(
            globalSourceExecutor.getBookInfo(source, noteUrl),
            this.config.timeout
          );
          const elapsed = Date.now() - startTime;
          if (info !== null && ((info.name && info.name.trim()) || (info.author && info.author.trim()) || (info.introduce && info.introduce.trim()))) {
            bookInfo = info;
            passedChecks++;
            details.push({ name: '详情', passed: true, message: '书名: ' + (info.name || '未知'), duration: elapsed });
          } else {
            details.push({ name: '详情', passed: false, message: '详情页解析为空', duration: elapsed });
          }
        }
      } catch (e) {
        const elapsed = Date.now() - startTime;
        details.push({ name: '详情', passed: false, message: '失败: ' + getErrorMessage(e), duration: elapsed });
      }
    }

    // 4. 目录检查
    if (this.config.checkCategory && !this.cancelFlag) {
      let tocUrl: string = '';
      if (bookInfo !== null && bookInfo.tocUrl) {
        tocUrl = bookInfo.tocUrl;
      } else if (searchResults.length > 0) {
        tocUrl = searchResults[0].noteUrl;
      }
      if (tocUrl) {
        totalChecks++;
        const startTime = Date.now();
        try {
          const toc: BookSourceChapter[] = await this.runWithTimeout(
            globalSourceExecutor.getToc(source, tocUrl),
            this.config.timeout
          );
          const elapsed = Date.now() - startTime;
          if (toc.length > 0) {
            chapters = toc;
            passedChecks++;
            details.push({ name: '目录', passed: true, message: '共 ' + toc.length + ' 章', duration: elapsed });
          } else {
            details.push({ name: '目录', passed: false, message: '目录为空', duration: elapsed });
          }
        } catch (e) {
          const elapsed = Date.now() - startTime;
          details.push({ name: '目录', passed: false, message: '失败: ' + getErrorMessage(e), duration: elapsed });
        }
      }
    }

    // 5. 正文检查
    if (this.config.checkContent && !this.cancelFlag && chapters.length > 0) {
      totalChecks++;
      const startTime = Date.now();
      try {
        const content: string = await this.runWithTimeout(
          globalSourceExecutor.getContent(source, chapters[0].url),
          this.config.timeout
        );
        const elapsed = Date.now() - startTime;
        if (content && content.trim().length > 50) {
          passedChecks++;
          details.push({ name: '正文', passed: true, message: '获取到 ' + content.length + ' 字内容', duration: elapsed });
        } else {
          const msg: string = content ? '内容过短 (' + content.length + ' 字)' : '正文为空';
          details.push({ name: '正文', passed: false, message: msg, duration: elapsed });
        }
      } catch (e) {
        const elapsed = Date.now() - startTime;
        details.push({ name: '正文', passed: false, message: '失败: ' + getErrorMessage(e), duration: elapsed });
      }
    }

    // 判定状态
    let status: string = 'fail';
    if (totalChecks === 0) {
      status = 'fail';
    } else if (passedChecks === totalChecks) {
      status = 'success';
    } else if (passedChecks > 0) {
      status = 'partial';
    }

    const errMsg: string = (passedChecks === 0 && details.length > 0) ? details[0].message : '';

    return {
      sourceUrl: source.sourceUrl,
      sourceName: source.sourceName,
      status: status,
      totalChecks: totalChecks,
      passedChecks: passedChecks,
      details: details,
      errorMessage: errMsg,
    };
  }

  private runWithTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void) => {
      const timer = setTimeout(() => {
        reject(new Error('操作超时 (' + timeoutMs + 'ms)'));
      }, timeoutMs);
      promise.then((result: T) => {
        clearTimeout(timer);
        resolve(result);
      }).catch((err: Error) => {
        clearTimeout(timer);
        reject(err);
      });
    });
  }
}
