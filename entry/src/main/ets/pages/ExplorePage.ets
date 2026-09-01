/**
 * 发现页面
 * 参照 Android 版 Legado ExploreScreen
 *
 * 列出所有有 exploreUrl 的书源。
 * 每个书源可展开，通过获取 exploreUrl 返回的 JSON/文本解析分类。
 * 点击分类可跳转到书籍列表页（ExploreBookPage）。
 */
import { ThemeColors } from '../theme/ThemeColors';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { JsExpressionEvaluator, JsEvalContext } from '../engine/source/JsExpressionEvaluator';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { UiUtil } from '../util/UiUtil';
import { BookSourceChangeNotifier } from '../service/BookSourceChangeNotifier';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { QysgRuntimeHostComponent } from '../engine/qysg/QysgRuntimeManager';
import { globalSourceGateway } from '../engine/source/SourceGateway';

interface ExploreCategory {
  name: string;
  url: string;
  keyword: string;
  style: string;
  bookUrl: string;
  // 同一分类页内的子列表可以使用自己的规则；未提供时回退到书源全局发现规则。
  ruleExploreList: string;
  ruleExploreName: string;
  ruleExploreAuthor: string;
  ruleExploreCover: string;
  ruleExploreNoteUrl: string;
  ruleExploreKind: string;
  ruleExploreWordCount: string;
  ruleExploreLastUpdateTime: string;
  ruleExploreLastChapter: string;
  ruleExploreIntroduce: string;
  parent: string;
  /** 动态两级发现：点击该项目会去抓取其 url 返回的子分类列表展开（而非书籍列表）。 */
  isSubNav: boolean;
  // 布局属性（从 style JSON 解析）
  flexBasisPercent: number;
  flexGrow: number;
  wrapBefore: boolean;
}

interface SourceLoginAction {
  name: string;
  action: string;
}

@Component
export struct ExplorePage {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageLink('bookSourceRevision') @Watch('onBookSourceRevisionChanged') bookSourceRevision: number = 0;
  @State exploreSources: BookSource[] = [];
  @State searchKey: string = '';
  @State filterHistory: string[] = [];
  @State showFilterHistory: boolean = false;
  @State expandedSourceUrl: string = '';
  @State loadingKinds: boolean = false;
  @State categoryCache: Record<string, ExploreCategory[]> = {};
  @State resolvedCategories: ExploreCategory[] = [];
  @State resolvedFoundSource: BookSource | null = null;
  @State actionSourceUrl: string = '';
  @State sourceActionBusy: boolean = false;
  @State loadError: string = '';
  @State categoryError: string = '';
  /** 动态两级发现：当前展开的一级发现项 url（空表示全部收起）。 */
  @State dynamicExpandedUrl: string = '';
  /** 一级发现项 url → 其二级分类列表缓存。 */
  @State subCategoryCache: Record<string, ExploreCategory[]> = {};
  /** 正在加载子分类的一级发现项 url。 */
  @State subLoadingUrl: string = '';

  private sourceRequestId: number = 0;
  private categoryRequestId: number = 0;
  private isActive: boolean = false;
  private lastCategoryError: string = '';
  private loadedSourceRevision: number = -1;

  aboutToAppear(): void {
    this.isActive = true;
    void this.loadFilterHistory();
    if (this.exploreSources.length === 0 || this.loadedSourceRevision !== this.bookSourceRevision) {
      void this.loadExploreSources();
    }
  }

  aboutToDisappear(): void {
    void this.addFilterHistory_(this.searchKey);
    this.isActive = false;
    this.sourceRequestId++;
    this.categoryRequestId++;
  }

  private onBookSourceRevisionChanged(): void {
    if (this.isActive) void this.loadExploreSources();
  }

  private normalizeFilterHistory_(items: string[]): string[] {
    const result: string[] = [];
    for (const item of items || []) {
      const value = (item || '').trim();
      if (value && !result.includes(value)) {
        result.push(value);
        if (result.length >= 20) break;
      }
    }
    return result;
  }

  private async loadFilterHistory(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      const history = await store.get<string[]>('explore_source_filter_history', []);
      if (this.isActive) this.filterHistory = this.normalizeFilterHistory_(history);
    } catch (_e) {
      if (this.isActive) this.filterHistory = [];
    }
  }

  private async addFilterHistory_(raw: string): Promise<void> {
    const value = (raw || '').trim();
    if (!value || value === '失效') return;
    this.filterHistory = this.normalizeFilterHistory_([value, ...this.filterHistory]);
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      await store.put('explore_source_filter_history', this.filterHistory);
    } catch (_e) { /* 历史记录失败不影响过滤 */ }
  }

  private async clearFilterHistory_(): Promise<void> {
    this.filterHistory = [];
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      await store.put('explore_source_filter_history', []);
    } catch (_e) { /* ignore */ }
  }

  private visibleFilterHistory_(): string[] {
    const query = this.searchKey.trim().toLowerCase();
    if (!query) return this.filterHistory.slice(0, 8);
    return this.filterHistory.filter((item: string): boolean => item.toLowerCase().includes(query)).slice(0, 8);
  }

  getFilteredSources(): BookSource[] {
    const q = this.searchKey.trim().toLowerCase();
    if (!q) return this.exploreSources;
    return this.exploreSources.filter((s: BookSource) =>
      (s.sourceName || '').toLowerCase().includes(q) ||
      (s.group || '').toLowerCase().includes(q));
  }

  async loadExploreSources(): Promise<void> {
    const runId = ++this.sourceRequestId;
    this.loadError = '';
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const allSources = await dao.getAllSources();
      // 筛选有发现数据的源：优先从 exploreUrl，其次从 rawJson 提取
      for (let i = 0; i < allSources.length; i++) {
        const s = allSources[i];
        // 如果 exploreUrl 为空，尝试从 rawJson 提取
        if ((!s.exploreUrl || s.exploreUrl.trim() === '') && s.rawJson) {
          try {
            const rj: Record<string, Object> = JSON.parse(s.rawJson) as Record<string, Object>;
            const eu = rj['exploreUrl'] as string;
            if (eu && eu.trim().length > 0) {
              s.exploreUrl = eu;
              console.info('[Explore] Recovered exploreUrl from rawJson for ' + s.sourceName + ', len=' + eu.length);
            }
          } catch (_x) { /* ignore */ }
        }
        console.info('[Explore] Source ' + s.sourceName + ': exploreUrl=' + ((s.exploreUrl || '').substring(0, 100)) + ' rawJson_len=' + ((s.rawJson || '').length));
      }
      // 筛选 exploreUrl 非空的源，或者 ruleExplores 是 :: 格式的（简单兼容）
      const sources = allSources.filter((s: BookSource): boolean => {
        // 与 Android 版 Legado 一致：发现页只展示 enabledExplore=true 的书源。
        // enabled 是搜索开关，与发现开关相互独立。
        if (!s.enabledExplore) return false;
        if (s.exploreUrl && s.exploreUrl.trim().length > 0) return true;
        if (s.sourceFormat === 1) return true;
        // 兼容：检查 ruleExplores 是否为 :: 格式（如 "玄幻::/xuanhuan/"）
        if (s.ruleExplores && s.ruleExplores.trim().length > 0 && s.ruleExplores.includes('::')) return true;
        return false;
      });
      if (!this.isActive || runId !== this.sourceRequestId) return;
      this.exploreSources = sources;
      this.loadedSourceRevision = this.bookSourceRevision;
      console.info('[Explore] Loaded ' + this.exploreSources.length + ' explore sources');
    } catch (_e) {
      console.error('[Explore] loadExploreSources error: ' + JSON.stringify(_e));
      if (this.isActive && runId === this.sourceRequestId) {
        this.loadError = (_e as Error).message || '发现书源加载失败';
      }
    }
  }

  private cacheCategories(cacheKey: string, categories: ExploreCategory[]): ExploreCategory[] {
    const next: Record<string, ExploreCategory[]> = {};
    for (const key of Object.keys(this.categoryCache)) next[key] = this.categoryCache[key];
    next[cacheKey] = categories;
    this.categoryCache = next;
    return categories;
  }

  /**
   * 获取并解析分类
   * 支持格式:
   * 1. JSON 数组: [{"name":"xxx","url":"..."}, ...]
   * 2. 文本行(&& 或 \n 分隔): 分类名::url
   * 3. JS 脚本 (<js>...</js> 或 @js:...) — 通过 JsExpressionEvaluator 执行
   * 4. HTTP URL — 请求后解析 JSON 或文本
   */
  async loadCategories(source: BookSource, forceReload: boolean = false): Promise<ExploreCategory[]> {
    this.lastCategoryError = '';
    const cacheKey = source.sourceUrl;
    if (!forceReload && this.categoryCache[cacheKey]) {
      return this.categoryCache[cacheKey];
    }

    if (source.sourceFormat === 1) {
      try {
        const items = await globalSourceGateway.getExploreItems(source);
        const categories: ExploreCategory[] = items.map((item): ExploreCategory => ({
          name: item.title,
          url: item.target,
          keyword: '',
          style: '',
          bookUrl: '',
          ruleExploreList: '',
          ruleExploreName: '',
          ruleExploreAuthor: '',
          ruleExploreCover: '',
          ruleExploreNoteUrl: '',
          ruleExploreKind: '',
          ruleExploreWordCount: '',
          ruleExploreLastUpdateTime: '',
          ruleExploreLastChapter: '',
          ruleExploreIntroduce: '',
          parent: '',
          isSubNav: item.kind === 'heading',
          flexBasisPercent: item.flexBasisPercent,
          flexGrow: 0,
          wrapBefore: item.flexBasisPercent >= 1,
        }));
        this.cacheCategories(cacheKey, categories);
        return categories;
      } catch (error) {
        this.lastCategoryError = String(error);
        throw error instanceof Error ? error : new Error(String(error));
      }
    }

    await this.ensureSourceVariable(source);

    let exploreUrl = source.exploreUrl || '';
    console.info('[Explore] loadCategories for ' + source.sourceName + ', exploreUrl=' + exploreUrl.substring(0, 120));

    // 1. exploreUrl 是纯 JSON 数组/对象
    const exploreTrimmed = exploreUrl.trim();
    if (exploreTrimmed.startsWith('[') || exploreTrimmed.startsWith('{')) {
      const parsed = this.parseExploreJson(exploreUrl);
      if (parsed.length > 0) {
        this.cacheCategories(cacheKey, parsed);
        console.info('[Explore] Parsed ' + parsed.length + ' categories from exploreUrl JSON');
        return parsed;
      }
    }

    // 2. JS 脚本: <js>...</js> 或 @js:...（通过 Worker 线程执行，不阻塞 UI）
    if (exploreUrl.startsWith('<js>') || exploreUrl.startsWith('@js:')) {
      try {
        let jsCode = '';
        if (exploreUrl.startsWith('<js>')) {
          const match = exploreUrl.match(/<js>([\s\S]*?)<\/js>/i);
          if (match) jsCode = match[1];
        } else {
          jsCode = exploreUrl.substring(4).trim();
        }
        if (jsCode) {
          const baseUrl = this.getBaseUrl_(source.sourceUrl);
          const ctx: JsEvalContext = {
            source: source,
            jsLib: source.jsLib || '',
            baseUrl: baseUrl,
            variableBlob: source.variableComment || '',
          };
          const result = await JsExpressionEvaluator.evaluate(jsCode, ctx);
          console.info('[Explore] JS evaluate result (len=' + (result ? result.length : 0) + '): ' + (result || '').substring(0, 200));
          if (result && result.trim()) {
            // 检测 QuickJS 桥返回的异常信息（napi_bridge.cpp 将 JS 异常作为字符串返回）
            const trimmed = result.trim();
            if (/^(TypeError|SyntaxError|ReferenceError|RangeError|Error|URIError|EvalError):/i.test(trimmed)) {
              console.error('[Explore] JS exception in exploreUrl:', trimmed.substring(0, 200));
              throw new Error(trimmed);
            }
            // 先尝试 JSON 解析（兼容 Legado Android 的 exploreKinds 逻辑：
            // 先 isJsonArray，再 split(&&|\n) + :: 格式）
            const jsonParsed = this.parseExploreJson(result);
            if (jsonParsed.length > 0) {
              this.cacheCategories(cacheKey, jsonParsed);
              console.info('[Explore] Parsed ' + jsonParsed.length + ' categories from JS exploreUrl (JSON)');
              return jsonParsed;
            }
            // JS 结果不是 JSON 时，尝试 :: / && 文本格式解析
            const lineParsed = this.parseExploreLines(result);
            if (lineParsed.length > 0) {
              this.cacheCategories(cacheKey, lineParsed);
              console.info('[Explore] Parsed ' + lineParsed.length + ' categories from JS exploreUrl (lines)');
              return lineParsed;
            }
          }
        }
      } catch (e) {
        console.error('[Explore] JS exploreUrl evaluation failed: ' + JSON.stringify(e));
        this.lastCategoryError = (e as Error).message || '发现脚本执行失败';
      }
      // JS 执行失败，fallback 到旧版 HOS 的分类字段
      const legacyParsed = this.parseLegacyExploreCategories(source.ruleExplores);
      if (legacyParsed.length > 0) {
        this.cacheCategories(cacheKey, legacyParsed);
        return legacyParsed;
      }
      const result: ExploreCategory[] = [];
      this.cacheCategories(cacheKey, result);
      return result;
    }

    // 3. Legado 标准文本分类：分类名::URL（优先使用 exploreUrl）
    if (exploreUrl && !exploreUrl.startsWith('http')) {
      const lineParsed = this.parseExploreLines(exploreUrl);
      if (lineParsed.length > 0) {
        this.cacheCategories(cacheKey, lineParsed);
        return lineParsed;
      }
    }

    // 兼容旧版 HOS 的 ruleExplores 分类字段，但拒绝把 CSS 选择器当分类。
    const legacyParsed = this.parseLegacyExploreCategories(source.ruleExplores);
    if (legacyParsed.length > 0) {
      this.cacheCategories(cacheKey, legacyParsed);
      return legacyParsed;
    }

    if (!exploreUrl) {
      const result: ExploreCategory[] = [];
      this.cacheCategories(cacheKey, result);
      return result;
    }

    // 4. HTTP URL — 请求后解析
    if (exploreUrl.startsWith('http')) {
      try {
        const body = await this.httpGet(exploreUrl, source.header || '');
        if (body) {
          const parsed = this.parseExploreJson(body);
          if (parsed.length > 0) {
            this.cacheCategories(cacheKey, parsed);
            return parsed;
          }
          const lineParsed = this.parseExploreLines(body);
          if (lineParsed.length > 0) {
            this.cacheCategories(cacheKey, lineParsed);
            return lineParsed;
          }
        }
      } catch (e) {
        console.error('[Explore] HTTP get failed: ' + JSON.stringify(e));
        this.lastCategoryError = (e as Error).message || '分类网络请求失败';
      }
      // HTTP 失败，fallback 到旧版 HOS 的分类字段
      const fallbackParsed = this.parseLegacyExploreCategories(source.ruleExplores);
      if (fallbackParsed.length > 0) {
        this.cacheCategories(cacheKey, fallbackParsed);
        return fallbackParsed;
      }
    }

    // 5. 最后尝试按行/&& 解析
    const lineParsed = this.parseExploreLines(exploreUrl);
    this.cacheCategories(cacheKey, lineParsed);
    return lineParsed;
  }

  /** 从书源 URL 提取基础域名 */
  private getBaseUrl_(rawUrl: string): string {
    if (!rawUrl) return '';
    return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
  }

  private buildCategory(item: Record<string, Object>, defaultName: string): ExploreCategory {
    const name = String(item['title'] || item['name'] || item['Name'] || defaultName);
    const url = String(item['url'] || item['exploreUrl'] || item['Url'] || '');
    const keyword = String(item['keyword'] || item['Keyword'] || '');
    const styleRaw: Record<string, Object> | null = (item['style'] || item['Style']) ? (item['style'] || item['Style']) as Record<string, Object> : null;
    console.info('[Explore] buildCategory: name=' + name + ', url=' + url + ', hasStyle=' + (styleRaw !== null));
    let flexBasisPercent = 0;
    let flexGrow = 0;
    let wrapBefore = false;

    if (styleRaw) {
      const fbp = styleRaw['layout_flexBasisPercent'];
      if (typeof fbp === 'number') flexBasisPercent = fbp as number;
      else if (typeof fbp === 'string') flexBasisPercent = parseFloat(fbp as string) || 0;
      const fg = styleRaw['layout_flexGrow'];
      if (typeof fg === 'number') flexGrow = fg as number;
      else if (typeof fg === 'string') flexGrow = parseFloat(fg as string) || 0;
      wrapBefore = styleRaw['layout_wrapBefore'] ? true : false;
    }
    return {
      name: name,
      url: url,
      keyword: keyword,
      style: '',
      bookUrl: String(item['bookUrl'] || item['BookUrl'] || ''),
      ruleExploreList: String(item['ruleExploreList'] || item['bookList'] || ''),
      ruleExploreName: String(item['ruleExploreName'] || item['nameRule'] || ''),
      ruleExploreAuthor: String(item['ruleExploreAuthor'] || item['authorRule'] || ''),
      ruleExploreCover: String(item['ruleExploreCover'] || item['coverRule'] || ''),
      ruleExploreNoteUrl: String(item['ruleExploreNoteUrl'] || item['bookUrlRule'] || ''),
      ruleExploreKind: String(item['ruleExploreKind'] || item['kindRule'] || ''),
      ruleExploreWordCount: String(item['ruleExploreWordCount'] || item['wordCountRule'] || ''),
      ruleExploreLastUpdateTime: String(item['ruleExploreLastUpdateTime'] || item['lastUpdateTimeRule'] || ''),
      ruleExploreLastChapter: String(item['ruleExploreLastChapter'] || item['lastChapterRule'] || ''),
      ruleExploreIntroduce: String(item['ruleExploreIntroduce'] || item['introRule'] || ''),
      parent: String(item['parent'] || item['parentTitle'] || ''),
      // “dynamic”: true 表示该发现项是动态两级的一级：点击后抓取其 url 返回的子分类展开。
      isSubNav: item['dynamic'] === true || item['dynamic'] === 'true' ||
        item['isSubNav'] === true || item['expand'] === true,
      flexBasisPercent: flexBasisPercent,
      flexGrow: flexGrow,
      wrapBefore: wrapBefore,
    };
  }

  /**
   * 从任何值中提取分类数组（递归搜索嵌套对象中的数组属性）
   */
  private extractCategoryArray_(val: Object | null): Object[] | null {
    if (!val) return null;
    if (Array.isArray(val)) return val as Object[];
    if (typeof val !== 'object') return null;
    const obj = val as Record<string, Object>;
    // 如果顶层对象本身有 name/title/url，作为单元素数组返回
    if (obj['name'] || obj['title'] || obj['url']) {
      return [obj];
    }
    // 否则按优先级搜索嵌套数组属性
    const arrayKeys = ['data', 'categories', 'category', 'list', 'items',
      'result', 'results', 'books', 'dataList', 'records', 'datas'];
    for (const key of arrayKeys) {
      const candidate = obj[key];
      if (Array.isArray(candidate)) return candidate as Object[];
    }
    // 最后：查找对象中的第一个数组值
    for (const key of Object.keys(obj)) {
      const candidate = obj[key];
      if (Array.isArray(candidate)) return candidate as Object[];
    }
    return null;
  }

  parseExploreJson(jsonStr: string): ExploreCategory[] {
    const result: ExploreCategory[] = [];
    if (!jsonStr || jsonStr.trim() === '') return result;
    try {
      const parsed: Object = JSON.parse(jsonStr) as Object;
      const arr = this.extractCategoryArray_(parsed);
      if (arr) {
        for (let i = 0; i < arr.length; i++) {
          const item: Object = arr[i];
          if (typeof item === 'object' && item !== null) {
            result.push(this.buildCategory(item as Record<string, Object>, '分类' + (i + 1)));
          }
        }
        return result;
      }
    } catch (_e) {
      console.error('[Explore] JSON parse error: ' + (_e as Error)?.message?.substring(0, 200) + ', input preview: ' + jsonStr.substring(0, 200));
    }
    return result;
  }

  /**
   * ruleExplores 是旧版 HOS 的兼容字段。只有 JSON 分类或包含 :: 的文本
   * 才能作为发现分类，避免把 ruleExplore.bookList 的 CSS 选择器显示到界面。
   */
  private parseLegacyExploreCategories(text: string): ExploreCategory[] {
    if (!text || !text.trim()) return [];
    const trimmed = text.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      return this.parseExploreJson(text);
    }
    if (text.includes('::')) {
      return this.parseExploreLines(text);
    }
    return [];
  }

  parseExploreLines(text: string): ExploreCategory[] {
    const result: ExploreCategory[] = [];
    if (!text || text.trim() === '') return result;
    let normalized = text;
    normalized = normalized.replace(/\r\n/g, '\n');
    normalized = normalized.replace(/\r/g, '\n');
    normalized = normalized.replace(/&&/g, '\n');
    const lines = normalized.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const doubleColonIdx = trimmed.indexOf('::');
      if (doubleColonIdx >= 0) {
        result.push({
          name: trimmed.substring(0, doubleColonIdx).trim(),
          url: trimmed.substring(doubleColonIdx + 2).trim(),
          keyword: '', style: '', bookUrl: '',
          ruleExploreList: '', ruleExploreName: '', ruleExploreAuthor: '', ruleExploreCover: '',
          ruleExploreNoteUrl: '', ruleExploreKind: '', ruleExploreWordCount: '',
          ruleExploreLastUpdateTime: '', ruleExploreLastChapter: '', ruleExploreIntroduce: '', parent: '', isSubNav: false,
          flexBasisPercent: 0, flexGrow: 0, wrapBefore: false,
        });
      } else {
        result.push({
          name: trimmed, url: '', keyword: '', style: '', bookUrl: '',
          ruleExploreList: '', ruleExploreName: '', ruleExploreAuthor: '', ruleExploreCover: '',
          ruleExploreNoteUrl: '', ruleExploreKind: '', ruleExploreWordCount: '',
          ruleExploreLastUpdateTime: '', ruleExploreLastChapter: '', ruleExploreIntroduce: '', parent: '', isSubNav: false,
          flexBasisPercent: 0, flexGrow: 0, wrapBefore: false,
        });
      }
    }
    return result;
  }

  async httpGet(url: string, headerStr: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      const headers: Record<string, string> = {
        'Accept': 'application/json,text/html,*/*',
        'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS 5.0)',
      };
      if (headerStr) {
        try {
          const h: Record<string, Object> = JSON.parse(headerStr) as Record<string, Object>;
          if (typeof h === 'object' && h !== null) {
            const keys: string[] = Object.keys(h);
            for (let i = 0; i < keys.length; i++) {
              headers[keys[i]] = String(h[keys[i]]);
            }
          }
        } catch (e2) {
          // ignore
        }
      }
      req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 10000,
      }, (err, data) => {
        req.destroy();
        if (err) {
          console.error('[Explore] HTTP error: ' + JSON.stringify(err));
          reject(new Error(err.message || '分类网络请求失败'));
        } else {
          if (data.responseCode >= 400) {
            reject(new Error('HTTP ' + data.responseCode.toString()));
            return;
          }
          if (typeof data.result === 'string') { resolve(data.result); } else { const buf = data.result as ArrayBuffer; const u8 = new Uint8Array(buf); resolve(util.TextDecoder.create('utf-8').decodeToString(u8)); }
        }
      });
    });
  }

  getCategories(sourceUrl: string): ExploreCategory[] {
    return this.categoryCache[sourceUrl] || [];
  }

  private async persistSourceVariable(source: BookSource, variable: string): Promise<void> {
    source.variableComment = variable;
    const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
    await dao.updateVariable(source.id, source.sourceUrl, variable);
  }

  /** 首次使用时执行 loginUrl，取得并持久化 source.getVariable()。 */
  private async ensureSourceVariable(source: BookSource): Promise<void> {
    if (!source.loginUrl || source.variableComment) return;
    const result = await JsExpressionEvaluator.evaluate(
      source.loginUrl + '\nsource.getVariable();',
      {
        source: source,
        jsLib: source.jsLib || '',
        baseUrl: this.getBaseUrl_(source.sourceUrl),
        variableBlob: '',
      }
    );
    if (result && result.trim() && result !== 'null' && result !== 'undefined') {
      await this.persistSourceVariable(source, result.trim());
      console.info('[Explore] Initialized and persisted source variables for ' + source.sourceName);
    }
  }

  getSourceLoginActions(source: BookSource): SourceLoginAction[] {
    if (!source.loginUi) return [];
    try {
      const parsed = JSON.parse(source.loginUi) as Array<Record<string, Object>>;
      if (!Array.isArray(parsed)) return [];
      const actions: SourceLoginAction[] = [];
      for (const item of parsed) {
        const type = String(item['type'] || '');
        const action = String(item['action'] || '').trim();
        if (type === 'button' && action) {
          actions.push({ name: String(item['name'] || '执行'), action: action });
        }
      }
      return actions;
    } catch (_e) {
      return [];
    }
  }

  getCurrentSourceLine(source: BookSource): string {
    if (!source.variableComment) return '';
    try {
      const variable = JSON.parse(source.variableComment) as Record<string, Object>;
      return String(variable['url'] || '');
    } catch (_e) {
      return '';
    }
  }

  private withoutCategoryCache(sourceUrl: string): Record<string, ExploreCategory[]> {
    const next: Record<string, ExploreCategory[]> = {};
    for (const key of Object.keys(this.categoryCache)) {
      if (key !== sourceUrl) next[key] = this.categoryCache[key];
    }
    return next;
  }

  async runSourceLoginAction(source: BookSource, action: SourceLoginAction): Promise<void> {
    if (this.sourceActionBusy || !source.loginUrl) return;
    this.sourceActionBusy = true;
    try {
      const result = await JsExpressionEvaluator.evaluate(
        source.loginUrl + '\n' + action.action + '\nsource.getVariable();',
        {
          source: source,
          jsLib: source.jsLib || '',
          baseUrl: this.getBaseUrl_(source.sourceUrl),
          variableBlob: source.variableComment || '',
        }
      );
      if (!result || !result.trim() || result === 'null' || result === 'undefined') {
        throw new Error('脚本没有返回书源变量');
      }
      await this.persistSourceVariable(source, result.trim());
      this.categoryCache = this.withoutCategoryCache(source.sourceUrl);
      this.loadingKinds = true;
      const categories = await this.loadCategories(source, true);
      if (!this.isActive || this.expandedSourceUrl !== source.sourceUrl) return;
      this.resolvedCategories = categories;
      const line = this.getCurrentSourceLine(source);
      UiUtil.showToast(this.getUIContext(), { message: action.name + '完成' + (line ? '：' + line : '') });
    } catch (e) {
      console.error('[Explore] Source action failed: ' + (e as Error).message);
      if (this.isActive) {
        UiUtil.showToast(this.getUIContext(), { message: action.name + '失败：' + (e as Error).message });
      }
    } finally {
      this.loadingKinds = false;
      this.sourceActionBusy = false;
    }
  }

  toggleExpand(sourceUrl: string): void {
    const runId = ++this.categoryRequestId;
    this.categoryError = '';
    if (this.expandedSourceUrl === sourceUrl) {
      this.expandedSourceUrl = '';
      this.actionSourceUrl = '';
      this.resolvedCategories = [];
      this.resolvedFoundSource = null;
    } else {
      this.expandedSourceUrl = sourceUrl;
      this.actionSourceUrl = '';
      this.loadingKinds = true;
      // 找到源并加载分类
      for (const src of this.exploreSources) {
        if (src.sourceUrl === sourceUrl) {
          this.resolvedFoundSource = src;
          // 如果 exploreUrl 为空，尝试从 rawJson 提取
          if (!src.exploreUrl && src.rawJson) {
            try {
              const rj: Record<string, Object> = JSON.parse(src.rawJson) as Record<string, Object>;
              const eu = rj['exploreUrl'] as string;
              if (eu) src.exploreUrl = eu;
            } catch (_x) { /* ignore */ }
          }
          void this.loadCategories(src).then((cats: ExploreCategory[]) => {
            if (!this.isActive || runId !== this.categoryRequestId || this.expandedSourceUrl !== src.sourceUrl) return;
            this.resolvedCategories = cats;
            this.categoryError = cats.length === 0 ? this.lastCategoryError : '';
            this.loadingKinds = false;
            console.info('[Explore] Got ' + cats.length + ' categories for ' + src.sourceName);
          }).catch((error: Error) => {
            if (!this.isActive || runId !== this.categoryRequestId || this.expandedSourceUrl !== src.sourceUrl) return;
            this.loadingKinds = false;
            this.resolvedCategories = [];
            this.categoryError = error.message || '分类加载失败';
            UiUtil.showToast(this.getUIContext(), { message: '分类加载失败：' + (error.message || '网络错误') });
          });
          return;
        }
      }
      this.resolvedFoundSource = null;
      this.resolvedCategories = [];
      this.loadingKinds = false;
    }
  }

  /** 解析任意文本为分类（复用 JSON/文本/JS 的兼容规则）。 */
  private toCategories_(text: string): ExploreCategory[] {
    const jsonParsed = this.parseExploreJson(text);
    if (jsonParsed.length > 0) return jsonParsed;
    return this.parseExploreLines(text);
  }

  /**
   * 动态两级发现：展开/收起一个一级发现项。
   * 点击一级（平台）→ 抓取其 url 返回的二级分类列表并内联展开；
   * 再点另一个一级 → 切换（收起旧的、加载/展开新的）。
   */
  async toggleDynamicSubNav(source: BookSource, parent: ExploreCategory): Promise<void> {
    // 再次点击当前已展开项 → 收起
    if (this.dynamicExpandedUrl === parent.url) {
      this.dynamicExpandedUrl = '';
      this.subLoadingUrl = '';
      return;
    }
    if (!parent.url || parent.url.trim() === '') return;
    this.dynamicExpandedUrl = parent.url;
    // 已缓存则直接展开，不重复请求
    if (this.subCategoryCache[parent.url]) {
      this.subLoadingUrl = '';
      return;
    }
    this.subLoadingUrl = parent.url;
    let cats: ExploreCategory[] = [];
    try {
      if (/^<js>|^@js:/.test(parent.url)) {
        let jsCode = parent.url;
        if (parent.url.startsWith('<js>')) {
          const match = parent.url.match(/<js>([\s\S]*?)<\/js>/i);
          jsCode = match ? match[1] : '';
        } else {
          jsCode = parent.url.substring(4).trim();
        }
        if (jsCode) {
          const baseUrl = this.getBaseUrl_(source.sourceUrl);
          const ctx: JsEvalContext = {
            source: source,
            jsLib: source.jsLib || '',
            baseUrl: baseUrl,
            variableBlob: source.variableComment || '',
          };
          const result = await JsExpressionEvaluator.evaluate(jsCode, ctx);
          if (result && result.trim()) cats = this.toCategories_(result);
        }
      } else if (/^https?:\/\//i.test(parent.url)) {
        // 平台参数常含中文（如 source=番茄），http 模块不自动编码，先转义。
        const encodedUrl = parent.url.replace(/[^\x00-\x7F]+/g, (part: string): string =>
          encodeURIComponent(part)).replace(/ /g, '%20').replace(/%20/g, '%20');
        const body = await this.httpGet(encodedUrl, source.header || '');
        if (body) cats = this.toCategories_(body);
      }
    } catch (e) {
      console.error('[Explore] load sub-categories failed for ' + parent.name + ': ' + String(e));
      this.subLoadingUrl = '';
      this.dynamicExpandedUrl = '';
      return;
    }
    this.subLoadingUrl = '';
    if (cats.length === 0) {
      // 没有二级分类时保持收起态，避免显示空区域
      this.dynamicExpandedUrl = '';
      return;
    }
    const next: Record<string, ExploreCategory[]> = {};
    const keys = Object.keys(this.subCategoryCache);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.subCategoryCache[keys[i]];
    }
    next[parent.url] = cats;
    this.subCategoryCache = next;
  }

  openCategory(source: BookSource, category: ExploreCategory): void {
    // 无 URL 的分类不跳转
    if (!category.url || category.url.trim() === '') {
      console.warn('[Explore] Category ' + category.name + ' has no URL, skip');
      return;
    }
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/ExploreBookPage',
      params: {
        sourceId: source.id,
        categoryName: category.name,
        categoryUrl: category.url,
        categoryKeyword: category.keyword,
        categoryRules: JSON.stringify({
          ruleExploreList: category.ruleExploreList,
          ruleExploreName: category.ruleExploreName,
          ruleExploreAuthor: category.ruleExploreAuthor,
          ruleExploreCover: category.ruleExploreCover,
          ruleExploreNoteUrl: category.ruleExploreNoteUrl,
          ruleExploreKind: category.ruleExploreKind,
          ruleExploreWordCount: category.ruleExploreWordCount,
          ruleExploreLastUpdateTime: category.ruleExploreLastUpdateTime,
          ruleExploreLastChapter: category.ruleExploreLastChapter,
          ruleExploreIntroduce: category.ruleExploreIntroduce,
        }),
      }
    });
  }

  /**
   * 计算分类行（与 Android calculateExploreKindRows 一致）
   * 每行最多 maxSpan(6) 列，根据 flexBasisPercent 分配宽度
   */
  calculateKindRows(kinds: ExploreCategory[], maxSpan: number): ExploreCategory[][] {
    // Android 书源通常把发现页写成“父分类（100%）+ 子分类（25%）”的
    // 顺序结构。不能把它们当成一个普通的流式网格，否则父分类按钮会和
    // 第一组子分类挤在同一行。只要配置中出现全宽条目，就按全宽条目切组：
    // 全宽条目独占一行，紧随其后的非全宽条目组成下一行（必要时再按列数
    // 换行）。这也兼容企鹅阅读的配置，其中父分类没有 parent 字段而是
    // 单纯依靠 style.layout_flexBasisPercent 表示层级。
    // 某些旧配置/模型输出会漏写父分类的 100% 样式，但子项已经带有
    // parent 字段。此时根据父子关系补全父分类语义，不能再把它按 50%
    // 普通按钮排进子分类那一行。
    const hasExplicitChildren = kinds.some((kind: ExploreCategory): boolean =>
      kind.parent.trim().length > 0);
    const isFullWidthCategory = (kind: ExploreCategory): boolean =>
      kind.wrapBefore || kind.flexBasisPercent >= 1.0 ||
      (hasExplicitChildren && kind.parent.trim().length === 0 && kind.url.trim().length > 0);
    const hasFullWidth = kinds.some((kind: ExploreCategory): boolean => isFullWidthCategory(kind));
    if (hasFullWidth) {
      const groupedRows: ExploreCategory[][] = [];
      let childRow: ExploreCategory[] = [];
      let childSpan = 0;
      const flushChildRow = (): void => {
        if (childRow.length > 0) {
          groupedRows.push(childRow);
          childRow = [];
          childSpan = 0;
        }
      };
      for (const kind of kinds) {
        const fullWidth = isFullWidthCategory(kind);
        if (fullWidth) {
          flushChildRow();
          groupedRows.push([kind]);
          continue;
        }
        let span = 2;
        if (kind.flexBasisPercent > 0) {
          span = Math.max(1, Math.min(maxSpan, Math.round(maxSpan * kind.flexBasisPercent)));
        } else if (kind.flexGrow > 0) {
          span = 3;
        }
        if (childRow.length > 0 && childSpan + span > maxSpan) flushChildRow();
        childRow.push(kind);
        childSpan += span;
        if (childSpan >= maxSpan) flushChildRow();
      }
      flushChildRow();
      return groupedRows;
    }

    // 没有全宽样式时保留旧版普通网格行为，兼容简单的 name::url 配置。
    const rows: ExploreCategory[][] = [];
    let currentRow: ExploreCategory[] = [];
    let currentSpan = 0;

    for (const kind of kinds) {
      let span = 2; // default
      if (kind.wrapBefore || kind.flexBasisPercent >= 1.0) {
        span = maxSpan;
      } else if (kind.flexBasisPercent > 0) {
        span = Math.max(1, Math.min(maxSpan, Math.round(maxSpan * kind.flexBasisPercent)));
      } else if (kind.flexGrow > 0) {
        span = 3;
      }
      if ((kind.wrapBefore && currentRow.length > 0) || (currentSpan + span > maxSpan)) {
        rows.push(currentRow);
        currentRow = [];
        currentSpan = 0;
      }
      currentRow.push(kind);
      currentSpan += span;
      if (currentSpan >= maxSpan) {
        rows.push(currentRow);
        currentRow = [];
        currentSpan = 0;
      }
    }
    if (currentRow.length > 0) {
      rows.push(currentRow);
    }
    return rows;
  }

  build() {
    Column() {
      // 顶部标题
      Row() {
        Text($r('app.string.ui_523e40a074')).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
      }.width('100%').padding({ left: 16, top: 12, bottom: 8 })

      // 搜索框 — 过滤当前显示的发现源
      Row() {
        TextInput({ placeholder: $r('app.string.ui_6966e1dc8e') })
          .height(44).layoutWeight(1)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontSize(14).padding({ left: 16 }).borderRadius(22)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((v: string) => { this.searchKey = v; this.showFilterHistory = true; })
          .onFocus(() => { this.showFilterHistory = true; })
          .onSubmit(() => {
            void this.addFilterHistory_(this.searchKey);
            this.showFilterHistory = false;
          })
          if (this.searchKey.length > 0) {
            Button($r('app.string.ui_0951b9a022')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).width(44).height(44)
              .backgroundColor(Color.Transparent).margin({ left: 4 }).accessibilityText($r('app.string.ui_74aba3dac5'))
            .onClick(() => {
              void this.addFilterHistory_(this.searchKey);
              this.searchKey = '';
            })
          }
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      if (this.showFilterHistory && this.visibleFilterHistory_().length > 0) {
        Column() {
          Row() {
            Text('过滤历史').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
            Text('清空').fontSize(12).fontColor(ThemeColors.error(this.isDark))
              .onClick(() => { void this.clearFilterHistory_(); })
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
          ForEach(this.visibleFilterHistory_(), (item: string) => {
            Row() {
              Text('↻').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width(24)
              Text(item).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            }.width('100%').height(40).padding({ left: 16, right: 16 })
              .backgroundColor(ThemeColors.surface(this.isDark))
              .onClick(() => {
                this.searchKey = item;
                this.showFilterHistory = false;
              })
          }, (item: string): string => item)
        }.width('100%').padding({ bottom: 4 })
          .backgroundColor(ThemeColors.surface(this.isDark))
          .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
      }

      if (this.loadError) {
        Column() {
          Text($r('app.string.ui_ec6fd1a827')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text(this.loadError).fontSize(12).fontColor(ThemeColors.error(this.isDark))
            .textAlign(TextAlign.Center).margin({ top: 8 }).padding({ left: 24, right: 24 })
          Button($r('app.string.common_retry')).height(44).margin({ top: 16 })
            .onClick((): void => { void this.loadExploreSources(); })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.getFilteredSources().length === 0) {
        Column() {
          Text($r('app.string.ui_b154edc2dd')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 80 })
          Text($r('app.string.ui_c1a9e8ea2e')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          Text($r('app.string.ui_0357072997')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else {
        // 书源列表
        List() {
          ForEach(this.getFilteredSources(), (source: BookSource) => {
            ListItem() {
              Column() {
                // 书源卡片头部
                Flex({ alignItems: ItemAlign.Center }) {
                  Column() {
                    Text(source.sourceName).fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onBackground(this.isDark)).alignSelf(ItemAlign.Start)
                    Text(source.group || '').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                      .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  }.flexShrink(1).alignItems(HorizontalAlign.Start)

                  Text(this.expandedSourceUrl === source.sourceUrl ? '收起' : '展开')
                    .fontSize(12).fontColor(ThemeColors.primary(this.isDark))
                    .flexShrink(0).margin({ left: 8 })
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .accessibilityDescription('双击' + (this.expandedSourceUrl === source.sourceUrl ? '收起' : '展开') + source.sourceName + '分类')
                .onClick((): void => { this.toggleExpand(source.sourceUrl); })

                // 展开：加载中 / 分类网格
                if (this.expandedSourceUrl === source.sourceUrl) {
                  if (this.getSourceLoginActions(source).length > 0) {
                    Row() {
                      Text(this.actionSourceUrl === source.sourceUrl ? '收起线路与发现设置' : '线路与发现设置')
                        .fontSize(13).fontColor(ThemeColors.primary(this.isDark))
                      if (this.getCurrentSourceLine(source)) {
                        Text(this.getCurrentSourceLine(source)).fontSize(11)
                          .fontColor(ThemeColors.secondaryText(this.isDark))
                          .layoutWeight(1).textAlign(TextAlign.End).margin({ left: 8 })
                      }
                    }
                    .width('100%').padding({ left: 16, right: 16, bottom: 10 })
                    .onClick((): void => {
                      this.actionSourceUrl = this.actionSourceUrl === source.sourceUrl ? '' : source.sourceUrl;
                    })
                    if (this.actionSourceUrl === source.sourceUrl) {
                      this.buildSourceActions(source)
                    }
                  }
                  if (this.loadingKinds) {
                    Row() {
                      LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
                      Text($r('app.string.ui_6aae64b4ab')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
                    }.padding(16)
                  } else if (this.categoryError) {
                    Row() {
                      Text(this.categoryError).fontSize(12).fontColor(ThemeColors.error(this.isDark))
                        .layoutWeight(1).maxLines(2)
                      Button($r('app.string.common_retry')).height(44).fontSize(12)
                        .onClick((): void => {
                          this.expandedSourceUrl = '';
                          this.toggleExpand(source.sourceUrl);
                        })
                    }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
                  } else if (this.resolvedCategories.length === 0) {
                    Text($r('app.string.ui_f11956caf6')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
                      .padding({ left: 16, bottom: 12 })
                  } else {
                    this.buildKindGrid(source)
                  }
                }
              }
              .width('100%')
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(12).margin({ left: 16, right: 16, bottom: 10 })
              .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            }
          })
        }.width('100%').layoutWeight(1)
      }
      QysgRuntimeHostComponent()
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  buildKindGrid(source: BookSource) {
    if (this.resolvedCategories.some((cat: ExploreCategory): boolean => cat.isSubNav)) {
      this.buildDynamicSubNav(source)
    } else {
      Column() {
      ForEach(this.calculateKindRows(this.resolvedCategories, 6), (row: ExploreCategory[]) => {
        Row() {
          ForEach(row, (cat: ExploreCategory) => {
            Button(cat.parent ? '↳ ' + cat.name : cat.name)
              .fontSize(13)
              .fontColor(ThemeColors.onBackground(this.isDark))
              .height(44)
              .padding({ left: 6, right: 6 })
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
              .borderRadius(8)
              .accessibilityText('打开分类：' + cat.name)
              .layoutWeight(cat.flexBasisPercent > 0 ? cat.flexBasisPercent : 1)
              .margin({ left: 3, right: 3, bottom: 4 })
              .onClick((): void => { this.openCategory(source, cat); })
          })
        }.width('100%').padding({ left: 12, right: 12 })
      })
      Row().height(8)
      }
    }
  }

  /** 动态两级发现：判断某个一级发现项是否处于展开态。 */
  private isDynamicExpanded_(url: string): boolean {
    return this.dynamicExpandedUrl === url;
  }

  /** 过滤动态两级里无 url 或明显占位的二级分类瓦片（避免显示无意义的空按钮）。 */
  private filteredSubNavChildren_(url: string): ExploreCategory[] {
    const all = this.subCategoryCache[url] || [];
    return all.filter((cat: ExploreCategory): boolean => {
      if (!cat.url || cat.url.trim() === '') return false;
      if (/(点击登录|切换后段|长按刷新|当前为|刷新即可|敬请期待|未开发|暂无记录|加载中)/.test(cat.name)) return false;
      return true;
    });
  }

  /**
   * 动态两级发现：一级是若干"平台/分类目录"项，点击展开该目录下的二级分类；
   * 再点另一个一级则切换。二级分类点击后进入书籍列表页。
   */
  @Builder
  buildDynamicSubNav(source: BookSource) {
    Column({ space: 6 }) {
      ForEach(this.resolvedCategories, (parent: ExploreCategory) => {
        // qysg 用 type=1、空 url 表示静态分组标题（如“玄幻魔法”），
        // 不是需要再次请求子分类的动态导航。空 url 不能参与展开状态判断，
        // 否则 dynamicExpandedUrl/subLoadingUrl 的初始空值会让标题永久显示加载中。
        if (parent.isSubNav && !parent.url.trim()) {
          Text('▾ ' + parent.name)
            .width('100%').height(46).fontSize(15)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(8)
            .textAlign(TextAlign.Center)
            .accessibilityText('分类分组：' + parent.name)
        } else {
          Button((this.isDynamicExpanded_(parent.url) ? '▾ ' : '▸ ') + parent.name)
            .width('100%').height(46).fontSize(15)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(8)
            .accessibilityText('展开分类：' + parent.name)
            .onClick((): void => { void this.toggleDynamicSubNav(source, parent); })
          if (parent.url.trim() && this.isDynamicExpanded_(parent.url)) {
            if (this.subLoadingUrl === parent.url) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(ThemeColors.primary(this.isDark))
                Text('加载分类中…').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
              }.width('100%').padding({ left: 16, top: 6, bottom: 6 })
            } else {
              if (this.filteredSubNavChildren_(parent.url).length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.filteredSubNavChildren_(parent.url), (child: ExploreCategory) => {
                    Button(child.name)
                      .fontSize(14)
                      .fontColor(ThemeColors.onBackground(this.isDark))
                      .height(44)
                      .padding({ left: 6, right: 6 })
                      .width('31%')
                      .margin({ left: '1%', right: '1%', bottom: 8 })
                      .backgroundColor(ThemeColors.surface(this.isDark))
                      .borderRadius(8)
                      .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
                      .accessibilityText('打开分类：' + child.name)
                      .onClick((): void => { this.openCategory(source, child); })
                  }, (child: ExploreCategory): string => child.url || child.name)
                }.width('100%').padding({ left: 14, right: 14, top: 4 })
              } else {
                Text('该分类下暂无子分类').fontSize(13)
                  .fontColor(ThemeColors.secondaryText(this.isDark)).padding({ left: 16, top: 4, bottom: 4 })
              }
            }
          }
        }
      }, (parent: ExploreCategory): string => parent.url || parent.name)
      Row().height(8)
    }.width('100%').padding({ left: 12, right: 12 })
  }

  @Builder
  buildSourceActions(source: BookSource) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.getSourceLoginActions(source), (item: SourceLoginAction) => {
        Button(item.name)
          .fontSize(12)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .width('31%').height(44).padding({ left: 4, right: 4 })
          .margin({ left: '1%', right: '1%', bottom: 8 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .borderRadius(8)
          .accessibilityText('执行书源操作：' + item.name)
          .opacity(this.sourceActionBusy ? 0.5 : 1)
          .onClick((): void => { void this.runSourceLoginAction(source, item); })
      })
    }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
  }
}
