/**
 * 发现书籍列表页
 * 直接 HTTP 获取，JSON 优先，回退到 SourceExecutor 引擎解析。
 */
import { AppTheme } from '../theme/AppTheme';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import router from '@ohos.router';
import { NetUtil } from '../util/NetUtil';

@Entry
@Component
export struct ExploreBookPage {
  @State sourceName: string = '';
  @State sourceUrl: string = '';
  @State categoryName: string = '';
  @State categoryUrl: string = '';
  @State header: string = '';
  @State ruleExploreList: string = '';
  @State ruleExploreName: string = '';
  @State ruleExploreAuthor: string = '';
  @State ruleExploreCover: string = '';
  @State ruleExploreKind: string = '';
  @State ruleExploreWordCount: string = '';
  @State ruleExploreLastChapter: string = '';
  @State ruleExploreLastUpdateTime: string = '';
  @State ruleExploreNoteUrl: string = '';

  @State isDark: boolean = false;
  @State books: SearchResult[] = [];
  @State isLoading: boolean = true;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.sourceName = String(params['sourceName'] || '');
      this.sourceUrl = String(params['sourceUrl'] || '');
      this.categoryName = String(params['categoryName'] || '');
      this.categoryUrl = String(params['categoryUrl'] || '');
      this.header = String(params['header'] || '');
      this.ruleExploreList = String(params['ruleExploreList'] || '');
      this.ruleExploreName = String(params['ruleExploreName'] || '');
      this.ruleExploreAuthor = String(params['ruleExploreAuthor'] || '');
      this.ruleExploreCover = String(params['ruleExploreCover'] || '');
      this.ruleExploreKind = String(params['ruleExploreKind'] || '');
      this.ruleExploreWordCount = String(params['ruleExploreWordCount'] || '');
      this.ruleExploreLastChapter = String(params['ruleExploreLastChapter'] || '');
      this.ruleExploreLastUpdateTime = String(params['ruleExploreLastUpdateTime'] || '');
      this.ruleExploreNoteUrl = String(params['ruleExploreNoteUrl'] || '');
    }
    void this.loadBooks();
  }

  /**
   * JSON 解析辅助：从任意对象中递归找数组
   */
  private findBooksArray(obj: Object, depth: number): Record<string, Object>[] {
    if (depth > 4 || !obj || typeof obj !== 'object') return [];
    const arr = obj as Object[];
    if (Array.isArray(arr) && arr.length > 1) {
      // 验证第一个元素看起来像书籍对象（有 name/title/bookName 等字段）
      const first = arr[0] as Record<string, Object>;
      if (first && typeof first === 'object') {
        const hasBookLike = first['name'] || first['title'] || first['bookName'] ||
          first['novelName'] || first['book_name'] || first['novel_name'] ||
          first['author'] || first['url'] || first['bookUrl'];
        if (hasBookLike) return arr as Record<string, Object>[];
      }
    }
    const rec = obj as Record<string, Object>;
    const keys = Object.keys(rec);
    for (let k = 0; k < keys.length; k++) {
      const v = rec[keys[k]];
      if (typeof v === 'object' && v !== null) {
        const sub = this.findBooksArray(v as Object, depth + 1);
        if (sub.length > 0) return sub;
      }
    }
    return [];
  }

  async loadBooks(): Promise<void> {
    this.isLoading = true;
    this.errorMsg = '';
    this.books = [];
    console.info('[ExploreBook] Loading: ' + this.categoryName + ', url: ' + this.categoryUrl);

    try {
      let catUrl = this.categoryUrl || '';
      if (!catUrl) {
        this.isLoading = false;
        this.errorMsg = '该分类无可用链接';
        return;
      }
      if (!catUrl.startsWith('http') && this.sourceUrl) {
        const baseUrl = this.sourceUrl.replace(/(https?:\/\/[^\/]+).*/, '$1');
        catUrl = baseUrl + (catUrl.startsWith('/') ? '' : '/') + catUrl;
      }
      catUrl = catUrl.replace(/\{\{page\}\}/g, '1');
      console.info('[ExploreBook] Full URL: ' + catUrl);

      const reqHeaders: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS 5.0)',
        'Referer': this.sourceUrl || '',
      };
      if (this.header) {
        try {
          const hdrs: Record<string, Object> = JSON.parse(this.header) as Record<string, Object>;
          const hkeys = Object.keys(hdrs);
          for (let h = 0; h < hkeys.length; h++) {
            reqHeaders[hkeys[h]] = String(hdrs[hkeys[h]]);
          }
        } catch (_e) { /* ignore */ }
      }
      const body = await NetUtil.httpGet(catUrl, reqHeaders, 15000);
      console.info('[ExploreBook] Got ' + body.length + ' bytes');

      if (!body) {
        this.isLoading = false;
        this.errorMsg = '服务器返回空数据';
        return;
      }

      let results: SearchResult[] = [];

      // 尝试 JSON 解析
      try {
        const json: Object = JSON.parse(body) as Object;
        let items: Record<string, Object>[] = [];
        // 按规则路径提取
        const rule = this.ruleExploreList || '';
        if (rule) {
          try {
            // 简单 JSONPath 提取
            let cur: Object | null = json;
            let p = rule.replace(/^\$\.?/, '');
            const parts = p.split('.');
            for (let pi = 0; pi < parts.length; pi++) {
              if (cur === null || cur === undefined) break;
              const part = parts[pi];
              const arrW = part.match(/^(\w+)?\[\*\]$/);
              if (arrW) {
                if (arrW[1]) cur = (cur as Record<string, Object>)[arrW[1]] as Object;
                if (Array.isArray(cur)) { items = cur as Record<string, Object>[]; break; }
                cur = null;
                break;
              }
              const idxM = part.match(/^(\w+)?\[(\d+)\]$/);
              if (idxM) {
                if (idxM[1]) cur = (cur as Record<string, Object>)[idxM[1]] as Object;
                if (Array.isArray(cur)) cur = (cur as Object[])[parseInt(idxM[2])] as Object;
                continue;
              }
              cur = (cur as Record<string, Object>)[part] as Object;
            }
          } catch (_jp) { /* ignore */ }
        }
        // 自动探测
        if (items.length === 0) {
          items = this.findBooksArray(json, 0);
        }
        if (items.length > 0) {
          for (let i = 0; i < items.length; i++) {
            const item = items[i] as Record<string, Object>;
            const name = String(item['name'] || item['title'] || item['bookName'] || item['novelName'] || item['book_name'] || '');
            if (!name) continue;
            const noteUrl = String(item['url'] || item['bookUrl'] || item['novelId'] || item['id'] || '');
            results.push({
              key: (this.sourceUrl || '') + '|' + noteUrl,
              name: name,
              author: String(item['author'] || item['Author'] || item['author_name'] || ''),
              coverUrl: this.validImageUrl(item['cover'] || item['coverUrl'] || item['cover_url'] || item['img'] || item['image'] || ''),
              noteUrl: noteUrl,
              origin: this.sourceName, originUrl: this.sourceUrl || '',
              kind: String(item['kind'] || item['category'] || item['type'] || ''),
              wordCount: String(item['wordCount'] || item['words'] || item['word_count'] || ''),
              introduce: String(item['introduce'] || item['description'] || item['intro'] || ''),
              lastUpdateTime: '', helperMsg: '',
              duration: 0, searchTime: Date.now(), sourceCount: 1,
              sourceOrigins: this.sourceName ? [this.sourceName] : [],
            });
          }
          console.info('[ExploreBook] JSON: ' + results.length + ' books');
        }
      } catch (_je) {
        console.info('[ExploreBook] Not JSON');
      }

      // JSON 没结果 → 用 SourceExecutor 引擎解析
      if (results.length === 0) {
        const source: BookSource = {
          id: 0, sourceName: this.sourceName, sourceUrl: this.sourceUrl,
          sourceType: 0, group: '', enabled: true, weight: 0, customOrder: 0,
          ruleSearchUrl: catUrl,
          ruleSearchList: this.ruleExploreList,
          ruleSearchName: this.ruleExploreName,
          ruleSearchAuthor: this.ruleExploreAuthor,
          ruleSearchCover: this.ruleExploreCover,
          ruleSearchNoteUrl: this.ruleExploreNoteUrl,
          ruleSearchKind: this.ruleExploreKind,
          ruleSearchWordCount: this.ruleExploreWordCount,
          ruleSearchLastUpdateTime: this.ruleExploreLastUpdateTime || '',
          ruleSearchLastChapter: this.ruleExploreLastChapter,
          ruleSearchIntroduce: '', ruleSearchCheckKeyWord: '',
          ruleBookInfoInit: '', ruleBookInfoName: '', ruleBookInfoAuthor: '', ruleBookInfoCover: '',
          ruleBookInfoIntroduce: '', ruleBookInfoKind: '', ruleBookInfoWordCount: '',
          ruleBookInfoLastChapter: '', ruleBookInfoLastUpdateTime: '', ruleBookInfoFrom: '',
          ruleBookInfoTocUrl: '', ruleBookInfoCanReName: '', ruleBookInfoDownloadUrls: '',
          ruleBookInfoRelatedBooks: '',
          ruleTocUrl: '', ruleToc: '', ruleTocTitle: '', ruleTocUrlItem: '',
          ruleTocPreUpdateJs: '', ruleTocFormatJs: '', ruleTocIsVolume: '',
          ruleTocIsVip: '', ruleTocIsPay: '', ruleTocUpdateTime: '', ruleTocNextTocUrl: '',
          ruleBookContent: '', ruleBookContentUrl: '', ruleBookContentNext: '',
          ruleBookContentSubContent: '', ruleBookContentTitle: '', ruleBookContentWebJs: '',
          ruleBookContentSourceRegex: '', ruleBookContentReplaceRegex: '',
          ruleBookContentImageStyle: '', ruleBookContentImageDecode: '',
          ruleBookContentPayAction: '', ruleBookContentCallBackJs: '',
          ruleExplores: '', ruleReview: '', ruleReviewUrl: '', ruleReviewAvatar: '',
          ruleReviewContent: '', ruleReviewPostTime: '', ruleReviewQuoteUrl: '',
          script: '', header: this.header,
          respondTime: 0, respond: 0, concurrentRate: '', bookSourceComment: '',
          variableComment: '', coverDecodeJs: '', loginUrl: '', loginCheckJs: '',
          jsLib: '', bookUrlPattern: '',
          ruleExploreScreen: '', ruleExploreList: '', ruleExploreName: '', ruleExploreAuthor: '',
          ruleExploreCover: '', ruleExploreKind: '', ruleExploreWordCount: '',
          ruleExploreLastChapter: '', ruleExploreLastUpdateTime: '', ruleExploreNoteUrl: '',
          ruleExploreIntroduce: '', exploreUrl: '', loginUi: '',
          eventListener: false, customButton: false, homepageModules: '',
          enabledCookieJar: false, enabledExplore: true, exploreScreen: '',
          review: '', reviewUrl: '', reviewAvatar: '', reviewContent: '',
          reviewPostTime: '', reviewQuoteUrl: '',
          createTime: 0, updateTime: 0, rawJson: '',
        };
        results = await globalSourceExecutor.search(this.categoryName || '', [source]);
        console.info('[ExploreBook] Engine: ' + results.length + ' books');
      }

      this.books = results;
    } catch (e) {
      this.errorMsg = '加载失败: ' + (e instanceof Error ? e.message : String(e));
      console.error('[ExploreBook] Error: ' + JSON.stringify(e));
    } finally {
      this.isLoading = false;
    }
  }

  private validImageUrl(url: string | Object): string {
    const s = String(url || '');
    if (s.startsWith('http://') || s.startsWith('https://') || s.startsWith('//')) return s;
    return '';
  }

  openBookDetail(book: SearchResult): void {
    router.pushUrl({
      url: 'pages/BookInfoPage',
      params: {
        name: book.name, author: book.author, coverUrl: book.coverUrl,
        noteUrl: book.noteUrl, origin: book.origin, originUrl: book.originUrl,
        introduce: book.introduce, kind: book.kind, wordCount: book.wordCount
      }
    });
  }

  build() {
    Column() {
      Row() {
        Text('\u2190').fontSize(20).fontColor(this.isDark ? '#FFF' : '#333')
          .onClick((): void => { router.back(); })
        Text(this.categoryName || this.sourceName)
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#FFF' : '#111')
          .margin({ left: 12 }).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('').width(20)
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().color('#0078D7').margin({ top: 80 })
          Text('加载中...').fontSize(14).fontColor('#888').margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.errorMsg) {
        Column() {
          Text('\u26A0\uFE0F').fontSize(48).margin({ top: 80 })
          Text(this.errorMsg).fontSize(14).fontColor('#888').margin({ top: 8 })
          Button('重试').margin({ top: 12 }).fontSize(13)
            .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
            .onClick((): void => { void this.loadBooks(); })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.books.length === 0) {
        Column() {
          Text('\uD83D\uDCDA').fontSize(48).margin({ top: 80 })
          Text('没有找到书籍').fontSize(16).fontColor('#888').margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else {
        Text('找到 ' + this.books.length + ' 本书').fontSize(12)
          .fontColor('#888').padding({ left: 16, top: 4 })
        List() {
          ForEach(this.books, (item: SearchResult) => {
            ListItem() {
              Row() {
                BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 44, coverHeight: 62 })
                  .margin({ right: 12 })
                Column() {
                  Text(item.name).fontSize(15).fontWeight(FontWeight.Bold)
                    .alignSelf(ItemAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.author || '未知作者').fontSize(12).fontColor('#888')
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  Text(item.kind || '').fontSize(11).fontColor('#AAA')
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start).height(62).justifyContent(FlexAlign.Center)
              }.padding(12).width('100%')
              .onClick((): void => { this.openBookDetail(item); })
            }.border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
          })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
