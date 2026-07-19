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

interface ExploreCategory {
  name: string;
  url: string;
  keyword: string;
  style: string;
  bookUrl: string;
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
  @State exploreSources: BookSource[] = [];
  @State searchKey: string = '';
  @State expandedSourceUrl: string = '';
  @State loadingKinds: boolean = false;
  @State categoryCache: Record<string, ExploreCategory[]> = {};
  @State resolvedCategories: ExploreCategory[] = [];
  @State resolvedFoundSource: BookSource | null = null;
  @State actionSourceUrl: string = '';
  @State sourceActionBusy: boolean = false;
  @State loadError: string = '';
  @State categoryError: string = '';

  private sourceRequestId: number = 0;
  private categoryRequestId: number = 0;
  private isActive: boolean = false;
  private lastCategoryError: string = '';

  aboutToAppear(): void {
    this.isActive = true;
    if (this.exploreSources.length === 0) void this.loadExploreSources();
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.sourceRequestId++;
    this.categoryRequestId++;
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
        // 兼容：检查 ruleExplores 是否为 :: 格式（如 "玄幻::/xuanhuan/"）
        if (s.ruleExplores && s.ruleExplores.trim().length > 0 && s.ruleExplores.includes('::')) return true;
        return false;
      });
      if (!this.isActive || runId !== this.sourceRequestId) return;
      this.exploreSources = sources;
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
          flexBasisPercent: 0, flexGrow: 0, wrapBefore: false,
        });
      } else {
        result.push({
          name: trimmed, url: '', keyword: '', style: '', bookUrl: '',
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
      }
    });
  }

  /**
   * 计算分类行（与 Android calculateExploreKindRows 一致）
   * 每行最多 maxSpan(6) 列，根据 flexBasisPercent 分配宽度
   */
  calculateKindRows(kinds: ExploreCategory[], maxSpan: number): ExploreCategory[][] {
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
          .onChange((v: string) => { this.searchKey = v; })
        if (this.searchKey.length > 0) {
          Button($r('app.string.ui_0951b9a022')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).width(44).height(44)
            .backgroundColor(Color.Transparent).margin({ left: 4 }).accessibilityText($r('app.string.ui_74aba3dac5'))
            .onClick(() => { this.searchKey = ''; })
        }
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

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
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
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
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
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
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  buildKindGrid(source: BookSource) {
    Column() {
      ForEach(this.calculateKindRows(this.resolvedCategories, 6), (row: ExploreCategory[]) => {
        Row() {
          ForEach(row, (cat: ExploreCategory) => {
            Button(cat.name)
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
