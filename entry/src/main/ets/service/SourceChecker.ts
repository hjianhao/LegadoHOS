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

export function normalizeCheckConfig(config: CheckConfig): CheckConfig {
  const normalized: CheckConfig = {
    keyword: config.keyword.trim() || '我',
    timeout: Math.max(1000, config.timeout),
    checkSearch: config.checkSearch,
    checkDiscovery: config.checkDiscovery,
    checkInfo: config.checkInfo,
    checkCategory: config.checkCategory,
    checkContent: config.checkContent,
  };
  if (normalized.checkInfo || normalized.checkCategory || normalized.checkContent) {
    normalized.checkSearch = true;
  }
  if (normalized.checkContent) {
    normalized.checkCategory = true;
  }
  return normalized;
}

export class SourceChecker {
  private config: CheckConfig;
  private cancelFlag: boolean = false;
  private resultsMap: Map<string, CheckResult> = new Map();

  constructor(config?: Partial<CheckConfig>) {
    this.config = normalizeCheckConfig({
      keyword: (config && config.keyword !== undefined) ? config.keyword : '我',
      timeout: (config && config.timeout !== undefined) ? config.timeout : 30000,
      checkSearch: (config && config.checkSearch !== undefined) ? config.checkSearch : true,
      checkDiscovery: (config && config.checkDiscovery !== undefined) ? config.checkDiscovery : false,
      checkInfo: (config && config.checkInfo !== undefined) ? config.checkInfo : false,
      checkCategory: (config && config.checkCategory !== undefined) ? config.checkCategory : false,
      checkContent: (config && config.checkContent !== undefined) ? config.checkContent : false,
    });
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
    this.config = normalizeCheckConfig(this.config);
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
    onProgress?: (completed: number, total: number, result: CheckResult) => void,
    concurrency: number = 5
  ): Promise<Map<string, CheckResult>> {
    this.cancelFlag = false;
    this.resultsMap.clear();
    const total = sources.length;
    let completed = 0;
    let cursor = 0;

    const worker = async (): Promise<void> => {
      while (cursor < sources.length && !this.cancelFlag) {
        const idx = cursor;
        cursor++;
        const result = await this.checkSingleSource(sources[idx]);
        if (this.cancelFlag) break;
        this.resultsMap.set(sources[idx].sourceUrl, result);
        completed++;
        if (onProgress) {
          onProgress(completed, total, result);
        }
      }
    };

    const workers: Promise<void>[] = [];
    const limit = Math.min(Math.max(1, concurrency), sources.length);
    for (let w = 0; w < limit; w++) {
      workers.push(worker());
    }
    await Promise.all<void>(workers);
    return this.resultsMap;
  }

  async checkSource(source: BookSource): Promise<CheckResult> {
    this.cancelFlag = false;
    this.resultsMap.clear();
    const result = await this.checkSingleSource(source);
    if (!this.cancelFlag) this.resultsMap.set(source.sourceUrl, result);
    return result;
  }

  private async checkSingleSource(source: BookSource): Promise<CheckResult> {
    const details: CheckDetail[] = [];
    let passedChecks = 0;
    let totalChecks = 0;

    let searchResults: SearchResult[] = [];
    let bookInfo: BookSourceBookInfo | null = null;
    let chapters: BookSourceChapter[] = [];

    // 1. 搜索检查 — 跳过未配置搜索规则的书源
    if (this.config.checkSearch && !this.cancelFlag) {
      if (!source.ruleSearchUrl || !source.ruleSearchUrl.trim()) {
        details.push({ name: '搜索', passed: false, message: '未配置搜索规则', duration: 0 });
        totalChecks++;
      } else {
        totalChecks++;
        const startTime = Date.now();
        try {
          const results: SearchResult[] = await this.runWithTimeout(
            globalSourceExecutor.searchForCheck(this.config.keyword, source),
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
    }

    // 2. 发现检查：使用发现 URL 和发现规则真实执行一次请求与解析
    if (this.config.checkDiscovery && !this.cancelFlag) {
      totalChecks++;
      const exploreUrl = this.getFirstExploreUrl_(source);
      if (!exploreUrl) {
        details.push({ name: '发现', passed: false, message: '未配置可执行的发现 URL', duration: 0 });
      } else if (!source.ruleExploreList || !source.ruleExploreList.trim()) {
        details.push({ name: '发现', passed: false, message: '未配置发现列表规则', duration: 0 });
      } else {
        const startTime = Date.now();
        try {
          const exploreSource = this.createExploreSource_(source, exploreUrl);
          const results: SearchResult[] = await this.runWithTimeout(
            globalSourceExecutor.searchForCheck('', exploreSource),
            this.config.timeout
          );
          const elapsed = Date.now() - startTime;
          if (results.length > 0) {
            passedChecks++;
            details.push({
              name: '发现', passed: true,
              message: '成功返回 ' + results.length + ' 条结果', duration: elapsed
            });
          } else {
            details.push({ name: '发现', passed: false, message: '发现页无解析结果', duration: elapsed });
          }
        } catch (e) {
          details.push({
            name: '发现', passed: false,
            message: '失败: ' + getErrorMessage(e), duration: Date.now() - startTime
          });
        }
      }
    }

    // 3. 详情检查
    if (this.config.checkInfo && !this.cancelFlag) {
      totalChecks++;
      if (searchResults.length > 0 && searchResults[0].noteUrl) {
        const startTime = Date.now();
        try {
          bookInfo = await this.runWithTimeout(
            globalSourceExecutor.getBookInfo(source, searchResults[0].noteUrl),
            this.config.timeout
          );
          const elapsed = Date.now() - startTime;
          if (bookInfo.name || bookInfo.author || bookInfo.tocUrl || bookInfo.introduce) {
            passedChecks++;
            const summary = [bookInfo.name, bookInfo.author, bookInfo.wordCount]
              .filter((value: string | undefined): boolean => !!value).join(' · ');
            details.push({ name: '详情', passed: true, message: summary || '详情解析成功', duration: elapsed });
          } else {
            details.push({ name: '详情', passed: false, message: '详情字段均为空', duration: elapsed });
          }
        } catch (e) {
          details.push({ name: '详情', passed: false, message: '失败: ' + getErrorMessage(e), duration: Date.now() - startTime });
        }
      } else {
        details.push({ name: '详情', passed: false, message: '搜索无结果', duration: 0 });
      }
    }

    // 4. 目录检查
    if (this.config.checkCategory && !this.cancelFlag) {
      totalChecks++;
      const tocUrl: string = (bookInfo && bookInfo.tocUrl) ? bookInfo.tocUrl : searchResults.length > 0 ? searchResults[0].noteUrl :
        (source.ruleTocUrl || source.sourceUrl || '');
      if (!tocUrl) {
        details.push({ name: '目录', passed: false, message: '无目录 URL', duration: 0 });
      } else {
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
    if (this.config.checkContent && !this.cancelFlag) {
      totalChecks++;
      if (chapters.length === 0) {
        details.push({ name: '正文', passed: false, message: '没有可测试的章节', duration: 0 });
      } else {
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

  private getFirstExploreUrl_(source: BookSource): string {
    let raw = (source.exploreUrl || source.ruleExplores || '').trim();
    if (!raw) return '';
    try {
      const parsed = JSON.parse(raw);
      const first = Array.isArray(parsed) ? parsed[0] : parsed;
      if (first && typeof first === 'object') {
        const value = String(first['url'] || first['exploreUrl'] || '');
        if (value) raw = value;
      }
    } catch (_e) {
      const firstLine = raw.split(/\r?\n|&&/)[0].trim();
      const separator = firstLine.indexOf('::');
      raw = separator >= 0 ? firstLine.substring(separator + 2).trim() : firstLine;
    }
    raw = raw.replace(/\{\{page\}\}/g, '1').split('##')[0].trim();
    if (!raw || raw.startsWith('@js') || raw.indexOf('<js>') >= 0) return '';
    if (/^https?:\/\//.test(raw)) return raw;
    const base = source.sourceUrl.match(/^(https?:\/\/[^/]+)/);
    if (!base) return '';
    if (raw.startsWith('/')) return base[1] + raw;
    return source.sourceUrl.replace(/\/[^/]*$/, '/') + raw;
  }

  private createExploreSource_(source: BookSource, exploreUrl: string): BookSource {
    const cloned = JSON.parse(JSON.stringify(source)) as BookSource;
    cloned.enabled = true;
    cloned.isExploreRequest = true;
    cloned.ruleSearchUrl = exploreUrl;
    cloned.ruleSearchList = source.ruleExploreList;
    cloned.ruleSearchName = source.ruleExploreName;
    cloned.ruleSearchAuthor = source.ruleExploreAuthor;
    cloned.ruleSearchCover = source.ruleExploreCover;
    cloned.ruleSearchKind = source.ruleExploreKind;
    cloned.ruleSearchWordCount = source.ruleExploreWordCount;
    cloned.ruleSearchLastUpdateTime = source.ruleExploreLastUpdateTime;
    cloned.ruleSearchIntroduce = source.ruleExploreIntroduce;
    cloned.ruleSearchNoteUrl = source.ruleExploreNoteUrl;
    return cloned;
  }

  private runWithTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void) => {
      let settled = false;
      const finish = (action: () => void): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        clearInterval(cancelTimer);
        action();
      };
      const timer = setTimeout(() => {
        finish(() => { reject(new Error('操作超时 (' + timeoutMs + 'ms)')); });
      }, timeoutMs);
      const cancelTimer = setInterval(() => {
        if (this.cancelFlag) {
          finish(() => { reject(new Error('校验已取消')); });
        }
      }, 100);
      promise.then((result: T) => {
        finish(() => { resolve(result); });
      }).catch((err: Error) => {
        finish(() => { reject(err); });
      });
    });
  }
}
