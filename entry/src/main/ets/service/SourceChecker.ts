/** Android Legado compatible book-source validity checker. */
import { BookSource, BookSourceBookInfo, BookSourceChapter, BookSourceType, isImageSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor, isExplicitlyDisabledSearchTemplate } from '../engine/source/SourceExecutor';
import { JsEvalContext, JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { NetUtil } from '../util/NetUtil';

export interface CheckConfig {
  keyword: string;
  /** Whole-source timeout in milliseconds. */
  timeout: number;
  checkSearch: boolean;
  checkDiscovery: boolean;
  checkInfo: boolean;
  checkCategory: boolean;
  checkContent: boolean;
  concurrency: number;
}

export interface CheckDetail {
  name: string;
  passed: boolean;
  skipped?: boolean;
  message: string;
  duration: number;
}

export interface CheckResult {
  sourceUrl: string;
  sourceName: string;
  status: string; // success | fail
  totalChecks: number;
  passedChecks: number;
  details: CheckDetail[];
  errorMessage: string;
  invalidGroups: string[];
  duration: number;
}

export interface CheckStageProgress {
  sourceUrl: string;
  sourceName: string;
  detail: CheckDetail;
}

interface BookPathState {
  result: SearchResult;
  info: BookSourceBookInfo | null;
  chapters: BookSourceChapter[];
}

export class SourceCheckCancelledError extends Error {
  constructor() { super('校验已取消'); }
}

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function getUrlHost(url: string): string {
  const match = (url || '').match(/^https?:\/\/([^\/?#]+)/i);
  return match ? match[1].toLowerCase().replace(/^www\./, '') : '';
}

function isUnresolvedResult(result: SearchResult): boolean {
  const text = (result.name || '') + '\n' + (result.noteUrl || '');
  return !result.name.trim() || !result.noteUrl.trim() ||
    /\{\{|\}\}|\$\{|\bundefined\b|\bnull\b/i.test(text);
}

/** Pick a real book entry instead of a template row or an advertisement returned by a broad list rule. */
export function selectCheckResult(source: BookSource, results: SearchResult[]): SearchResult | null {
  const sourceHost = getUrlHost(source.sourceUrl);
  let selected: SearchResult | null = null;
  let selectedScore = -10000;
  for (const result of results) {
    if (isUnresolvedResult(result)) continue;
    const noteUrl = result.noteUrl.trim();
    const host = getUrlHost(noteUrl);
    let score = 0;
    if (!host || (sourceHost && host === sourceHost)) score += 20;
    if (/\/(?:book|books|novel|album|comic|manga|read)\b|\/\d+[\/_-]/i.test(noteUrl)) score += 5;
    if (result.author.trim()) score += 2;
    if (/ref_id=|doubleclick|googlesyndication|\/ads?\b|\badvert/i.test(noteUrl)) score -= 30;
    if (score > selectedScore) {
      selected = result;
      selectedScore = score;
    }
  }
  return selected;
}

function firstUrlFromExploreValue(value: unknown): string {
  if (Array.isArray(value)) {
    for (const item of value) {
      const url = firstUrlFromExploreValue(item);
      if (url) return url;
    }
    return '';
  }
  if (!value || typeof value !== 'object') return '';
  const item = value as Record<string, unknown>;
  const direct = String(item['url'] || item['exploreUrl'] || item['Url'] || '').trim();
  if (direct) return direct;
  const nestedKeys = ['data', 'categories', 'category', 'list', 'items', 'result', 'results'];
  for (const key of nestedKeys) {
    const nested = firstUrlFromExploreValue(item[key]);
    if (nested) return nested;
  }
  return '';
}

/** Parse Android exploreKinds output and skip visual section headers whose URL is empty. */
export function firstExploreUrlFromText(text: string): string {
  const raw = (text || '').trim();
  if (!raw) return '';
  try {
    const fromJson = firstUrlFromExploreValue(JSON.parse(raw) as unknown);
    if (fromJson) return fromJson;
  } catch (_error) { /* text format */ }
  const lines = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/&&/g, '\n').split('\n');
  for (const line of lines) {
    const item = line.trim();
    if (!item) continue;
    const separator = item.indexOf('::');
    const url = separator >= 0 ? item.substring(separator + 2).trim() : item;
    if (url && (separator >= 0 || /^(?:https?:\/\/|\/|data:)/i.test(url))) return url;
  }
  return '';
}

export function normalizeCheckConfig(config: CheckConfig): CheckConfig {
  const normalized: CheckConfig = {
    keyword: config.keyword.trim() || '我的',
    timeout: Math.max(1000, Math.floor(config.timeout)),
    checkSearch: config.checkSearch,
    checkDiscovery: config.checkDiscovery,
    checkInfo: config.checkInfo,
    checkCategory: config.checkCategory,
    checkContent: config.checkContent,
    concurrency: Math.min(32, Math.max(1, Math.floor(config.concurrency || 5))),
  };
  if (!normalized.checkSearch && !normalized.checkDiscovery) normalized.checkSearch = true;
  if (!normalized.checkInfo) {
    normalized.checkCategory = false;
    normalized.checkContent = false;
  }
  if (!normalized.checkCategory) normalized.checkContent = false;
  return normalized;
}

/** Android checks selected sources even when they are currently disabled. */
export function createSourceForCheck(source: BookSource): BookSource {
  const copy = JSON.parse(JSON.stringify(source)) as BookSource;
  copy.enabled = true;
  return copy;
}

/** Skip search checks only when the source explicitly documents or scripts search as disabled. */
export function isSearchCheckDisabled(source: BookSource): boolean {
  if (isExplicitlyDisabledSearchTemplate(source.ruleSearchUrl || '')) return true;
  const metadata = (source.group || '') + '\n' + (source.bookSourceComment || '');
  return /(搜索暂不可用|搜索暂时不可用|不支持搜索|搜索已关闭|默认关闭搜索)/i.test(metadata);
}

/** Volume headings are display-only TOC entries and must never be fetched as chapter content. */
export function selectReadableChapters(chapters: BookSourceChapter[], limit: number = 2): BookSourceChapter[] {
  return chapters.filter((chapter: BookSourceChapter): boolean =>
    !chapter.isVolume && !!(chapter.url || '').trim()).slice(0, Math.max(0, limit));
}

export class SourceChecker {
  private config: CheckConfig;
  private cancelled_: boolean = false;
  private runId_: string = '';
  private activeGroups_: Set<string> = new Set();
  private results_: Map<string, CheckResult> = new Map();
  private onStage_?: (progress: CheckStageProgress) => void;

  constructor(config?: Partial<CheckConfig>) {
    this.config = normalizeCheckConfig({
      keyword: config?.keyword ?? '我的',
      timeout: config?.timeout ?? 180000,
      checkSearch: config?.checkSearch ?? true,
      checkDiscovery: config?.checkDiscovery ?? true,
      checkInfo: config?.checkInfo ?? true,
      checkCategory: config?.checkCategory ?? true,
      checkContent: config?.checkContent ?? true,
      concurrency: config?.concurrency ?? 5,
    });
  }

  getConfig(): CheckConfig { return this.config; }
  getResult(sourceUrl: string): CheckResult | undefined { return this.results_.get(sourceUrl); }
  getAllResults(): Map<string, CheckResult> { return this.results_; }

  updateConfig(partial: Partial<CheckConfig>): void {
    this.config = normalizeCheckConfig({ ...this.config, ...partial });
  }

  cancel(): void {
    this.cancelled_ = true;
    this.activeGroups_.forEach((group: string) => NetUtil.cancelRequestGroup(group));
  }

  reset(): void {
    this.cancel();
    this.cancelled_ = false;
    this.results_.clear();
  }

  async checkSources(
    sources: BookSource[],
    onProgress?: (completed: number, total: number, result: CheckResult) => void,
    concurrency?: number,
    onStage?: (progress: CheckStageProgress) => void
  ): Promise<Map<string, CheckResult>> {
    this.beginRun_(onStage);
    const total = sources.length;
    let completed = 0;
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (!this.cancelled_) {
        const index = cursor++;
        if (index >= sources.length) break;
        try {
          const prepared = this.prepareSource_(sources[index]);
          let result: CheckResult;
          try {
            result = await this.checkSingleSource_(prepared);
          } finally {
            this.finishSource_(prepared);
          }
          if (this.cancelled_) break;
          this.results_.set(result.sourceUrl, result);
          completed++;
          onProgress?.(completed, total, result);
        } catch (error) {
          if (error instanceof SourceCheckCancelledError || this.cancelled_) break;
          throw error;
        }
      }
    };
    const count = Math.min(concurrency || this.config.concurrency, Math.max(1, sources.length));
    const workers: Promise<void>[] = [];
    for (let i = 0; i < count; i++) workers.push(worker());
    try {
      await Promise.all(workers);
      return this.results_;
    } finally {
      this.runId_ = '';
      this.onStage_ = undefined;
      // 批量校验会依次执行所有书源的 jsLib，QuickJS 引擎全局对象被大量
      // 函数定义填充、SharedHeap 随 postMessage 增长；结束后销毁 Worker
      // 回收内存（下次求值时按需重建），避免设备上持续累积导致 OOM。
      JsExpressionEvaluator.releaseWorker();
    }
  }

  async checkSource(source: BookSource, onStage?: (progress: CheckStageProgress) => void): Promise<CheckResult> {
    this.beginRun_(onStage);
    try {
      const prepared = this.prepareSource_(source);
      let result: CheckResult;
      try {
        result = await this.checkSingleSource_(prepared);
      } finally {
        this.finishSource_(prepared);
      }
      if (!this.cancelled_) this.results_.set(source.sourceUrl, result);
      return result;
    } finally {
      this.runId_ = '';
      this.onStage_ = undefined;
      JsExpressionEvaluator.releaseWorker();
    }
  }

  private beginRun_(onStage?: (progress: CheckStageProgress) => void): void {
    this.cancelled_ = false;
    this.results_.clear();
    this.onStage_ = onStage;
    this.runId_ = 'source-check-' + Date.now() + '-' + Math.floor(Math.random() * 1000000);
  }

  private prepareSource_(source: BookSource): BookSource {
    const copy = createSourceForCheck(source);
    copy.checkRequestGroup = this.runId_ + '-' + source.id + '-' + Math.floor(Math.random() * 1000000);
    NetUtil.startRequestGroup(copy.checkRequestGroup);
    this.activeGroups_.add(copy.checkRequestGroup);
    return copy;
  }

  private finishSource_(source: BookSource): void {
    const group = source.checkRequestGroup || '';
    if (!group) return;
    NetUtil.finishRequestGroup(group);
    this.activeGroups_.delete(group);
  }

  private async checkSingleSource_(source: BookSource): Promise<CheckResult> {
    const start = Date.now();
    const deadline = start + this.config.timeout;
    const details: CheckDetail[] = [];
    const invalidGroups: string[] = [];
    const errors: string[] = [];

    const runChannel = async (channel: string, task: () => Promise<void>): Promise<void> => {
      try {
        await task();
      } catch (error) {
        if (error instanceof SourceCheckCancelledError) throw error;
        const message = getErrorMessage(error);
        if (!errors.includes(message)) errors.push(message);
        if (!details.some((item: CheckDetail): boolean => item.name === channel)) {
          this.addDetail_(source, details, {
            name: channel, passed: false, message: '失败：' + message, duration: 0
          });
        }
        if (message.includes('校验超时')) invalidGroups.push('校验超时');
        else if (/script|javascript|quickjs|js\s/i.test(message)) invalidGroups.push(channel + 'js失效');
        else invalidGroups.push(channel + '失效');
      }
    };

    await runChannel('搜索', async (): Promise<void> => {
      if (this.config.checkSearch) {
        if (!source.ruleSearchUrl.trim() || isSearchCheckDisabled(source)) {
          const reason = source.ruleSearchUrl.trim() ? '书源已明确关闭搜索' : '搜索链接规则为空';
          this.addDetail_(source, details, { name: '搜索', passed: true, skipped: true,
            message: '跳过：' + reason, duration: 0 });
        } else {
          const searchResults = await this.checkList_(source, '搜索', this.getCheckKeyword_(source), deadline, details, errors);
          const result = selectCheckResult(source, searchResults);
          if (!result) {
            invalidGroups.push('搜索失效');
            if (searchResults.length > 0) {
              this.addDetail_(source, details, { name: '搜索结果', passed: false,
                message: '结果均为占位项或无效链接', duration: 0 });
            }
          } else {
            await this.checkBookPath_(source, result, '搜索', deadline, details, invalidGroups, errors);
          }
        }
      }
    });

    await runChannel('发现', async (): Promise<void> => {
      if (this.config.checkDiscovery) {
        const exploreUrl = await this.runBeforeDeadline_(this.getFirstExploreUrl_(source), deadline,
          source.checkRequestGroup || '');
        if (!exploreUrl) {
          this.addDetail_(source, details, { name: '发现', passed: true, skipped: true, message: '跳过：未配置发现', duration: 0 });
        } else if (!source.ruleExploreList.trim()) {
          this.addDetail_(source, details, { name: '发现', passed: true, skipped: true, message: '跳过：发现规则为空', duration: 0 });
          invalidGroups.push('发现规则为空');
        } else {
          const exploreSource = this.createExploreSource_(source, exploreUrl);
          const exploreResults = await this.checkList_(exploreSource, '发现', '', deadline, details, errors);
          const result = selectCheckResult(source, exploreResults);
          if (!result) {
            invalidGroups.push('发现失效');
            if (exploreResults.length > 0) {
              this.addDetail_(source, details, { name: '发现结果', passed: false,
                message: '结果均为占位项或无效链接', duration: 0 });
            }
          } else {
            await this.checkBookPath_(source, result, '发现', deadline, details, invalidGroups, errors);
          }
        }
      }
    });

    this.downgradeEmptySearch_(source, details, invalidGroups);

    const uniqueInvalid = Array.from(new Set(invalidGroups));
    const failed = details.filter((item: CheckDetail): boolean => !item.passed).length;
    const totalChecks = details.filter((item: CheckDetail): boolean => !item.skipped).length;
    const passedChecks = details.filter((item: CheckDetail): boolean => item.passed && !item.skipped).length;
    const status = uniqueInvalid.some((name: string): boolean => name.includes('失效') || name === '校验超时') || failed > 0
      ? 'fail' : 'success';
    const errorMessage = errors[0] || (status === 'fail' ? uniqueInvalid.join(', ') : '');
    const result: CheckResult = {
      sourceUrl: source.sourceUrl, sourceName: source.sourceName, status: status,
      totalChecks: totalChecks, passedChecks: passedChecks, details: details,
      errorMessage: errorMessage, invalidGroups: uniqueInvalid, duration: Date.now() - start,
    };
    console.info('[SourceChecker] result ' + source.sourceName + ' status=' + status +
      ' details=' + details.map((item: CheckDetail): string =>
        item.name + ':' + (item.skipped ? 'skip' : item.passed ? 'pass' : 'fail') + '(' + item.message + ')').join(' | '));
    return result;
  }

  private async checkList_(source: BookSource, name: string, keyword: string, deadline: number,
    details: CheckDetail[], errors: string[]): Promise<SearchResult[]> {
    const start = Date.now();
    try {
      const results = await this.runBeforeDeadline_(globalSourceExecutor.searchForCheck(keyword, source), deadline,
        source.checkRequestGroup || '');
      const passed = results.length > 0;
      this.addDetail_(source, details, { name: name, passed: passed,
        message: passed ? '成功返回 ' + results.length + ' 条结果' : (name + '无结果'), duration: Date.now() - start });
      return results;
    } catch (error) {
      if (error instanceof SourceCheckCancelledError) throw error;
      const message = getErrorMessage(error);
      errors.push(message);
      this.addDetail_(source, details, { name: name, passed: false, message: '失败：' + message, duration: Date.now() - start });
      throw error;
    }
  }

  private async checkBookPath_(source: BookSource, result: SearchResult, channel: string, deadline: number,
    details: CheckDetail[], invalidGroups: string[], errors: string[]): Promise<void> {
    if (!this.config.checkInfo) return;
    const state: BookPathState = { result: result, info: null, chapters: [] };
    const detailName = channel + '详情';
    const infoStart = Date.now();
    try {
      state.info = await this.runBeforeDeadline_(globalSourceExecutor.getBookInfo(source, result.noteUrl), deadline,
        source.checkRequestGroup || '');
      const info = state.info;
      const parsed = !!(info.name || info.author || info.tocUrl || info.introduce);
      // Android can continue directly from a search/explore Book object when the source has no
      // detail rules (or only @get cached fields). Directory/content are the decisive checks.
      const passed = parsed || !!(result.name || result.author || result.introduce);
      const parsedSummary = [info.name, info.author, info.wordCount]
        .filter((v: string | undefined): boolean => !!v && !/^(?:字|章|页|万字)$/.test(v.trim())).join(' · ');
      const listSummary = [result.name, result.author, result.wordCount]
        .filter((v: string): boolean => !!v).join(' · ');
      this.addDetail_(source, details, { name: detailName, passed: passed,
        message: passed ? (parsed ? (parsedSummary || listSummary) : ('沿用列表信息：' + listSummary)) : '详情解析为空',
        duration: Date.now() - infoStart });
      if (!passed) throw new Error(channel + '详情失效');
    } catch (error) {
      if (error instanceof SourceCheckCancelledError) throw error;
      const message = getErrorMessage(error);
      errors.push(message);
      if (!details.some((item: CheckDetail): boolean => item.name === detailName)) {
        this.addDetail_(source, details, { name: detailName, passed: false, message: '失败：' + message, duration: Date.now() - infoStart });
      }
      invalidGroups.push(channel + '详情失效');
      return;
    }

    if (!this.config.checkCategory || source.sourceType === BookSourceType.FILE) {
      if (source.sourceType === BookSourceType.FILE && this.config.checkCategory) {
        this.addDetail_(source, details, { name: channel + '目录', passed: true, skipped: true, message: '文件类书源跳过目录与正文', duration: 0 });
      }
      return;
    }

    const tocName = channel + '目录';
    const tocStart = Date.now();
    try {
      const tocUrl = state.info?.tocUrl || result.noteUrl;
      // 校验只需要确认目录规则和正文入口可用，不应因某本书有几十个分页而
      // 把整源校验耗尽。正常阅读仍由 getToc 默认抓取全部分页。
      const checkTocPageLimit = 3;
      const toc = await this.runBeforeDeadline_(globalSourceExecutor.getToc(
        source, tocUrl, undefined, checkTocPageLimit), deadline,
        source.checkRequestGroup || '');
      state.chapters = selectReadableChapters(toc, 2);
      const passed = state.chapters.length > 0;
      this.addDetail_(source, details, { name: tocName, passed: passed,
        message: passed ? '读取前 ' + checkTocPageLimit + ' 页，共解析 ' + toc.length + ' 章' : '目录为空',
        duration: Date.now() - tocStart });
      if (!passed) invalidGroups.push(channel + '目录失效');
    } catch (error) {
      if (error instanceof SourceCheckCancelledError) throw error;
      const message = getErrorMessage(error);
      errors.push(message);
      this.addDetail_(source, details, { name: tocName, passed: false, message: '失败：' + message, duration: Date.now() - tocStart });
      invalidGroups.push(channel + '目录失效');
    }

    if (!this.config.checkContent || state.chapters.length === 0) return;
    const contentName = channel + '正文';
    const contentStart = Date.now();
    try {
      const chapter = state.chapters[0];
      const content = await this.runBeforeDeadline_(globalSourceExecutor.getContent(
        source, chapter.url, result.noteUrl, isImageSource(source), state.chapters[1]?.url), deadline,
        source.checkRequestGroup || '');
      const passed = content.trim().length > 0;
      this.addDetail_(source, details, { name: contentName, passed: passed,
        message: passed ? '获取到 ' + content.length + ' 字内容' : '正文为空', duration: Date.now() - contentStart });
      if (!passed) invalidGroups.push(channel + '正文失效');
    } catch (error) {
      if (error instanceof SourceCheckCancelledError) throw error;
      const message = getErrorMessage(error);
      errors.push(message);
      this.addDetail_(source, details, { name: contentName, passed: false, message: '失败：' + message, duration: Date.now() - contentStart });
      invalidGroups.push(channel + '正文失效');
    }
  }

  private addDetail_(source: BookSource, details: CheckDetail[], detail: CheckDetail): void {
    if (details.length >= 0 && !details.some((item: CheckDetail): boolean => item.name === detail.name)) details.push(detail);
    this.onStage_?.({ sourceUrl: source.sourceUrl, sourceName: source.sourceName, detail: detail });
  }

  private downgradeEmptySearch_(source: BookSource, details: CheckDetail[], invalidGroups: string[]): void {
    if (source.ruleSearchCheckKeyWord.trim()) return;
    const searchDetail = details.find((item: CheckDetail): boolean =>
      item.name === '搜索' && !item.passed && item.message === '搜索无结果');
    if (!searchDetail) return;

    const expected: string[] = ['发现'];
    if (this.config.checkInfo) expected.push('发现详情');
    if (this.config.checkCategory && source.sourceType !== BookSourceType.FILE) expected.push('发现目录');
    if (this.config.checkContent && source.sourceType !== BookSourceType.FILE) expected.push('发现正文');
    const discoveryPassed = expected.every((name: string): boolean =>
      details.some((item: CheckDetail): boolean => item.name === name && item.passed && !item.skipped));
    if (!discoveryPassed) return;

    searchDetail.passed = true;
    searchDetail.skipped = true;
    searchDetail.message = '警告：当前关键词无结果，发现链路正常';
    for (let i = invalidGroups.length - 1; i >= 0; i--) {
      if (invalidGroups[i] === '搜索失效') invalidGroups.splice(i, 1);
    }
    this.onStage_?.({ sourceUrl: source.sourceUrl, sourceName: source.sourceName, detail: searchDetail });
  }

  private getCheckKeyword_(source: BookSource): string {
    const custom = source.ruleSearchCheckKeyWord.trim();
    if (custom && !custom.includes('http') && !custom.includes('::') && !custom.includes('++') && !custom.includes('--')) return custom;
    return this.config.keyword;
  }

  private async getFirstExploreUrl_(source: BookSource): Promise<string> {
    let raw = (source.exploreUrl || source.ruleExplores || '').trim();
    if (!raw) return '';
    if (raw.startsWith('@js:') || raw.startsWith('<js>')) {
      let code = raw.startsWith('@js:') ? raw.substring(4).trim() : '';
      if (raw.startsWith('<js>')) {
        const match = raw.match(/<js>([\s\S]*?)<\/js>/i);
        code = match ? match[1] : '';
      }
      if (!code) throw new Error('发现分类脚本为空');
      const context: JsEvalContext = {
        source: source,
        jsLib: source.jsLib || '',
        baseUrl: source.sourceUrl.replace(/##.*$/, '').replace(/\/+$/, ''),
        variableBlob: source.variableComment || '',
      };
      raw = (await JsExpressionEvaluator.evaluate(code, context)).trim();
      if (!raw) throw new Error('发现分类脚本执行结果为空');
    }
    return firstExploreUrlFromText(raw).replace(/\{\{page\}\}/g, '1').trim();
  }

  private createExploreSource_(source: BookSource, exploreUrl: string): BookSource {
    const copy = JSON.parse(JSON.stringify(source)) as BookSource;
    copy.enabled = true;
    copy.isExploreRequest = true;
    copy.ruleSearchUrl = exploreUrl;
    copy.ruleSearchList = source.ruleExploreList;
    copy.ruleSearchName = source.ruleExploreName;
    copy.ruleSearchAuthor = source.ruleExploreAuthor;
    copy.ruleSearchCover = source.ruleExploreCover;
    copy.ruleSearchKind = source.ruleExploreKind;
    copy.ruleSearchWordCount = source.ruleExploreWordCount;
    copy.ruleSearchLastUpdateTime = source.ruleExploreLastUpdateTime;
    copy.ruleSearchIntroduce = source.ruleExploreIntroduce;
    copy.ruleSearchNoteUrl = source.ruleExploreNoteUrl;
    return copy;
  }

  private runBeforeDeadline_<T>(promise: Promise<T>, deadline: number, requestGroup: string): Promise<T> {
    this.ensureRunning_(deadline);
    const remaining = Math.max(1, deadline - Date.now());
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void) => {
      let settled = false;
      const finish = (action: () => void): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        clearInterval(cancelTimer);
        action();
      };
      const timer = setTimeout(() => finish(() => {
        NetUtil.cancelRequestGroup(requestGroup);
        reject(new Error('校验超时 (' + this.config.timeout + 'ms)'));
      }), remaining);
      const cancelTimer = setInterval(() => {
        if (this.cancelled_) finish(() => reject(new SourceCheckCancelledError()));
      }, 50);
      promise.then((value: T) => finish(() => resolve(value)))
        .catch((error: Error) => finish(() => this.cancelled_ ? reject(new SourceCheckCancelledError()) : reject(error)));
    });
  }

  private ensureRunning_(deadline: number): void {
    if (this.cancelled_) throw new SourceCheckCancelledError();
    if (Date.now() >= deadline) throw new Error('校验超时 (' + this.config.timeout + 'ms)');
  }
}
