/**
 * 发现页面
 * 参照 Android 版 Legado ExploreScreen
 *
 * 列出所有有 exploreUrl 的书源。
 * 每个书源可展开，通过获取 exploreUrl 返回的 JSON/文本解析分类。
 * 点击分类可跳转到书籍列表页（ExploreBookPage）。
 */
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
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

  aboutToAppear(): void {
    void this.loadExploreSources();
  }

  getFilteredSources(): BookSource[] {
    const q = this.searchKey.trim().toLowerCase();
    if (!q) return this.exploreSources;
    return this.exploreSources.filter((s: BookSource) =>
      (s.sourceName || '').toLowerCase().includes(q) ||
      (s.group || '').toLowerCase().includes(q));
  }

  async loadExploreSources(): Promise<void> {
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
      this.exploreSources = allSources.filter((s: BookSource): boolean => {
        if (s.exploreUrl && s.exploreUrl.trim().length > 0) return true;
        // 兼容：检查 ruleExplores 是否为 :: 格式（如 "玄幻::/xuanhuan/"）
        if (s.ruleExplores && s.ruleExplores.trim().length > 0 && s.ruleExplores.includes('::')) return true;
        return false;
      });
      console.info('[Explore] Loaded ' + this.exploreSources.length + ' explore sources');
    } catch (_e) {
      console.error('[Explore] loadExploreSources error: ' + JSON.stringify(_e));
    }
  }

  /**
   * 获取并解析分类
   * 支持格式:
   * 1. JSON 数组: [{"name":"xxx","url":"..."}, ...]
   * 2. 文本行(&& 或 \n 分隔): 分类名::url
   * 3. JS 脚本 (<js>...</js> 或 @js:...) — 暂不支持，返回空
   */
  async loadCategories(source: BookSource): Promise<ExploreCategory[]> {
    const cacheKey = source.sourceUrl;
    if (this.categoryCache[cacheKey]) {
      return this.categoryCache[cacheKey];
    }

    let exploreUrl = source.exploreUrl || '';
    console.info('[Explore] loadCategories for ' + source.sourceName + ', exploreUrl=' + exploreUrl.substring(0, 120));

    // 如果 exploreUrl 是 JSON 数组/对象，直接解析
    const exploreTrimmed = exploreUrl.trim();
    if (exploreTrimmed.startsWith('[') || exploreTrimmed.startsWith('{')) {
      const parsed = this.parseExploreJson(exploreUrl);
      if (parsed.length > 0) {
        this.categoryCache[cacheKey] = parsed;
        console.info('[Explore] Parsed ' + parsed.length + ' categories from exploreUrl JSON');
        return parsed;
      }
    }

    // fallback: 尝试 ruleExplores
    if (source.ruleExplores) {
      const lineParsed = this.parseExploreLines(source.ruleExplores);
      if (lineParsed.length > 0) {
        this.categoryCache[cacheKey] = lineParsed;
        return lineParsed;
      }
      const jsonParsed = this.parseExploreJson(source.ruleExplores);
      if (jsonParsed.length > 0) {
        this.categoryCache[cacheKey] = jsonParsed;
        return jsonParsed;
      }
    }

    if (!exploreUrl) {
      const result: ExploreCategory[] = [];
      this.categoryCache[cacheKey] = result;
      return result;
    }

    // JS脚本暂不支持
    if (exploreUrl.startsWith('<js>') || exploreUrl.startsWith('@js:')) {
      console.warn('[Explore] JS exploreUrl not supported yet');
      // fallback to ruleExplores
      if (source.ruleExplores) {
        const parsed = this.parseExploreJson(source.ruleExplores);
        if (parsed.length > 0) {
          this.categoryCache[cacheKey] = parsed;
          return parsed;
        }
      }
      const result: ExploreCategory[] = [];
      this.categoryCache[cacheKey] = result;
      return result;
    }

    // 如果 exploreUrl 本身是 JSON 数组/对象，直接解析
    if (exploreUrl.trim().startsWith('[') || exploreUrl.trim().startsWith('{')) {
      const parsed = this.parseExploreJson(exploreUrl);
      if (parsed.length > 0) {
        this.categoryCache[cacheKey] = parsed;
        return parsed;
      }
    }

    // 尝试 HTTP 请求获取
    if (exploreUrl.startsWith('http')) {
      try {
        const body = await this.httpGet(exploreUrl, source.header || '');
        if (body) {
          const parsed = this.parseExploreJson(body);
          if (parsed.length > 0) {
            this.categoryCache[cacheKey] = parsed;
            return parsed;
          }
          const lineParsed = this.parseExploreLines(body);
          if (lineParsed.length > 0) {
            this.categoryCache[cacheKey] = lineParsed;
            return lineParsed;
          }
        }
      } catch (e) {
        console.error('[Explore] HTTP get failed: ' + JSON.stringify(e));
      }
      // HTTP 失败，fallback 到 ruleExplores
      if (source.ruleExplores) {
        const parsed = this.parseExploreJson(source.ruleExplores);
        if (parsed.length > 0) {
          this.categoryCache[cacheKey] = parsed;
          return parsed;
        }
      }
    }

    // 最后尝试按行/&& 解析
    const lineParsed = this.parseExploreLines(exploreUrl);
    this.categoryCache[cacheKey] = lineParsed;
    return lineParsed;
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

  parseExploreJson(jsonStr: string): ExploreCategory[] {
    const result: ExploreCategory[] = [];
    if (!jsonStr || jsonStr.trim() === '') return result;
    try {
      const parsed: Object = JSON.parse(jsonStr) as Object;
      if (Array.isArray(parsed)) {
        const arr: Object[] = parsed as Object[];
        for (let i = 0; i < arr.length; i++) {
          const item: Object = arr[i];
          if (typeof item === 'object' && item !== null) {
            result.push(this.buildCategory(item as Record<string, Object>, '分类' + (i + 1)));
          }
        }
        return result;
      }
      // 单对象
      if (typeof parsed === 'object' && parsed !== null) {
        const single: Record<string, Object> = parsed as Record<string, Object>;
        if (single['name'] || single['title'] || single['url']) {
          result.push(this.buildCategory(single, '发现'));
        }
      }
    } catch (_e) {
      console.error('[Explore] JSON parse error');
    }
    return result;
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
    return new Promise<string>((resolve, _reject) => {
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
          resolve('');
        } else {
          if (typeof data.result === 'string') { resolve(data.result); } else { const buf = data.result as ArrayBuffer; const u8 = new Uint8Array(buf); resolve(util.TextDecoder.create('utf-8').decodeToString(u8)); }
        }
      });
    });
  }

  getCategories(sourceUrl: string): ExploreCategory[] {
    return this.categoryCache[sourceUrl] || [];
  }

  toggleExpand(sourceUrl: string): void {
    if (this.expandedSourceUrl === sourceUrl) {
      this.expandedSourceUrl = '';
      this.resolvedCategories = [];
      this.resolvedFoundSource = null;
    } else {
      this.expandedSourceUrl = sourceUrl;
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
            this.resolvedCategories = cats;
            this.loadingKinds = false;
            console.info('[Explore] Got ' + cats.length + ' categories for ' + src.sourceName);
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
        sourceName: source.sourceName,
        sourceUrl: source.sourceUrl,
        ruleExploreList: source.ruleExploreList || source.ruleSearchList || '',
        ruleExploreName: source.ruleExploreName || source.ruleSearchName || '',
        ruleExploreAuthor: source.ruleExploreAuthor || source.ruleSearchAuthor || '',
        ruleExploreCover: source.ruleExploreCover || source.ruleSearchCover || '',
        ruleExploreKind: source.ruleExploreKind || source.ruleSearchKind || '',
        ruleExploreWordCount: source.ruleExploreWordCount || source.ruleSearchWordCount || '',
        ruleExploreLastChapter: source.ruleExploreLastChapter || source.ruleSearchLastChapter || '',
        ruleExploreLastUpdateTime: source.ruleExploreLastUpdateTime || source.ruleSearchLastUpdateTime || '',
        ruleExploreNoteUrl: source.ruleExploreNoteUrl || source.ruleSearchNoteUrl || '',
        categoryName: category.name,
        categoryUrl: category.url,
        categoryKeyword: category.keyword,
        header: source.header || '',
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
        Text('发现').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFF' : '#111')
      }.width('100%').padding({ left: 16, top: 12, bottom: 8 })

      // 搜索框 — 过滤当前显示的发现源
      Row() {
        TextInput({ placeholder: '筛选发现源...' })
          .height(42).layoutWeight(1)
          .backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
          .fontSize(14).padding({ left: 16 }).borderRadius(22)
          .onChange((v: string) => { this.searchKey = v; })
        if (this.searchKey.length > 0) {
          Text('✕').fontSize(14).fontColor('#AAA').width(36).height(36)
            .textAlign(TextAlign.Center).margin({ left: 8 })
            .onClick(() => { this.searchKey = ''; })
        }
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      if (this.getFilteredSources().length === 0) {
        Column() {
          Text('🔍').fontSize(48).margin({ top: 80 })
          Text('暂无可用的发现书源').fontSize(16).fontColor('#888').margin({ top: 8 })
          Text('请在书源管理中导入带有发现URL的书源').fontSize(12).fontColor('#888').margin({ top: 4 })
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
                      .fontColor(this.isDark ? '#FFF' : '#111').alignSelf(ItemAlign.Start)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(source.group || '').fontSize(11).fontColor('#888')
                      .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  }.flexShrink(1).alignItems(HorizontalAlign.Start)

                  Text(this.expandedSourceUrl === source.sourceUrl ? '收起' : '展开')
                    .fontSize(12).fontColor('#0078D7')
                    .flexShrink(0).margin({ left: 8 })
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick((): void => { this.toggleExpand(source.sourceUrl); })

                // 展开：加载中 / 分类网格
                if (this.expandedSourceUrl === source.sourceUrl) {
                  if (this.loadingKinds) {
                    Row() {
                      LoadingProgress().width(20).height(20).color('#0078D7')
                      Text('加载分类...').fontSize(13).fontColor('#888').margin({ left: 8 })
                    }.padding(16)
                  } else if (this.resolvedCategories.length === 0) {
                    Text('无分类').fontSize(13).fontColor('#888')
                      .padding({ left: 16, bottom: 12 })
                  } else {
                    this.buildKindGrid(source)
                  }
                }
              }
              .width('100%')
              .backgroundColor(this.isDark ? '#1E1E1E' : '#FFF')
              .borderRadius(12).margin({ left: 16, right: 16, bottom: 10 })
              .border({ width: 1, color: this.isDark ? '#333' : '#E8E8E8' })
            }
          })
        }.width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  @Builder
  buildKindGrid(source: BookSource) {
    Column() {
      ForEach(this.calculateKindRows(this.resolvedCategories, 6), (row: ExploreCategory[]) => {
        Row() {
          ForEach(row, (cat: ExploreCategory) => {
            Text(cat.name)
              .fontSize(13)
              .fontColor(this.isDark ? '#DDD' : '#333')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .height(36)
              .padding({ left: 6, right: 6 })
              .backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
              .borderRadius(8)
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
