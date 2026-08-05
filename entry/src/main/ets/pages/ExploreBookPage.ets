/**
 * 发现书籍列表页
 * 直接走 SourceExecutor 引擎解析，复用搜索/发现规则。
 */
import { ThemeColors } from '../theme/ThemeColors';
import { ArrayDataSource } from '../util/ArrayDataSource';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import { WebViewEngine } from '../components/WebViewEngine';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { CloudflareDialog } from '../components/reader/CloudflareDialog';
import { CaptchaDialog } from '../components/reader/CaptchaDialog';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { UiUtil } from '../util/UiUtil';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { image } from '@kit.ImageKit';

@Entry
@Component
struct ExploreBookPage {
  @State sourceId: number = 0;
  @State sourceName: string = '';
  @State sourceUrl: string = '';
  @State categoryName: string = '';
  @State categoryUrl: string = '';
  @State categoryRulesJson: string = '';

  @StorageLink('isDark') isDark: boolean = false;
  @State @Watch('onBooksChanged_') books: SearchResult[] = [];
  private bookDataSource_: ArrayDataSource<SearchResult> = new ArrayDataSource<SearchResult>();

  private onBooksChanged_(): void {
    this.bookDataSource_.reset(this.books);
  }
  @State isLoading: boolean = true;
  @State errorMsg: string = '';

  private requestId: number = 0;
  private isActive: boolean = false;

  aboutToAppear(): void {
    this.isActive = true;
    // 注册 Cloudflare 交互验证弹窗
    WebViewFetcher.interactiveFetcher = (url: string): Promise<string> => {
      return new Promise((resolve) => {
        WebViewFetcher.interactiveResolve = resolve;
        let dlg: CustomDialogController | null = null;
        dlg = new CustomDialogController({
          builder: CloudflareDialog({ controller: dlg!, url: url }),
          autoCancel: false,
          customStyle: true,
          alignment: DialogAlignment.Center,
        });
        dlg.open();
      });
    };
    // 注册验证码输入弹窗处理器
    JsExpressionEvaluator.captchaHandler = (captchaUrl: string, captchaImage?: image.PixelMap | null): Promise<string> => {
      return new Promise((resolve) => {
        let dlg: CustomDialogController | null = null;
        dlg = new CustomDialogController({
          builder: CaptchaDialog({ controller: dlg!, captchaUrl: captchaUrl, captchaImage: captchaImage ?? null, captchaResolve: resolve }),
          autoCancel: false,
          customStyle: true,
          alignment: DialogAlignment.Center,
        });
        dlg.open();
      });
    };
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    if (params) {
      this.sourceId = Number(params['sourceId'] || 0);
      this.categoryName = String(params['categoryName'] || '');
      this.categoryUrl = String(params['categoryUrl'] || '');
      this.categoryRulesJson = String(params['categoryRules'] || '');
    }
    void this.loadBooks();
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.requestId++;
  }

  private makeExploreSource(source: BookSource, catUrl: string): BookSource {
    // 发现开关与普通搜索开关是独立的。不能直接复用数据库对象：
    // enabled=false 的源仍然可以 enabledExplore=true，分类页请求应临时启用，
    // 同时不能把发现规则写回普通搜索规则或后续页面使用的源对象。
    const exploreSource: BookSource = JSON.parse(JSON.stringify(source)) as BookSource;
    exploreSource.enabled = true;
    exploreSource.isExploreRequest = true;
    exploreSource.ruleSearchUrl = catUrl;
    const categoryRules: Record<string, string> = this.parseCategoryRules_();
    exploreSource.ruleSearchList = categoryRules['ruleExploreList'] || source.ruleExploreList || source.ruleSearchList;
    exploreSource.ruleSearchName = categoryRules['ruleExploreName'] || source.ruleExploreName || source.ruleSearchName;
    exploreSource.ruleSearchAuthor = categoryRules['ruleExploreAuthor'] || source.ruleExploreAuthor || source.ruleSearchAuthor;
    exploreSource.ruleSearchCover = categoryRules['ruleExploreCover'] || source.ruleExploreCover || source.ruleSearchCover;
    exploreSource.ruleSearchNoteUrl = categoryRules['ruleExploreNoteUrl'] || source.ruleExploreNoteUrl || source.ruleSearchNoteUrl;
    exploreSource.ruleSearchKind = categoryRules['ruleExploreKind'] || source.ruleExploreKind || source.ruleSearchKind;
    exploreSource.ruleSearchWordCount = categoryRules['ruleExploreWordCount'] || source.ruleExploreWordCount || source.ruleSearchWordCount;
    exploreSource.ruleSearchLastUpdateTime = categoryRules['ruleExploreLastUpdateTime'] || source.ruleExploreLastUpdateTime || source.ruleSearchLastUpdateTime;
    exploreSource.ruleSearchLastChapter = categoryRules['ruleExploreLastChapter'] || source.ruleExploreLastChapter || source.ruleSearchLastChapter;
    exploreSource.ruleSearchIntroduce = categoryRules['ruleExploreIntroduce'] || source.ruleExploreIntroduce || source.ruleSearchIntroduce;
    return exploreSource;
  }

  private parseCategoryRules_(): Record<string, string> {
    if (!this.categoryRulesJson || !this.categoryRulesJson.trim()) return {};
    try {
      const parsed = JSON.parse(this.categoryRulesJson) as Record<string, Object>;
      const result: Record<string, string> = {};
      Object.keys(parsed).forEach((key: string): void => {
        const value = parsed[key];
        if (typeof value === 'string' && value.trim()) result[key] = value.trim();
      });
      return result;
    } catch (_e) {
      console.warn('[ExploreBook] Invalid category rules payload');
      return {};
    }
  }

  async loadBooks(): Promise<void> {
    const runId = ++this.requestId;
    this.isLoading = true;
    this.errorMsg = '';
    this.books = [];
    console.info('[ExploreBook] Loading: ' + this.categoryName + ', url: ' + this.categoryUrl);

    try {
      await AppDatabase.getInstance().waitForInit();
      const source = await new BookSourceTable(AppDatabase.getInstance().rdbStore).getSourceById(this.sourceId);
      if (!source) throw new Error('书源已被删除或不存在');
      if (!this.isActive || runId !== this.requestId) return;
      this.sourceName = source.sourceName;
      this.sourceUrl = source.sourceUrl;
      let catUrl: string = this.categoryUrl || '';
      if (!catUrl) {
        this.isLoading = false;
        this.errorMsg = '该分类无可用链接';
        return;
      }
      if (catUrl.startsWith('//')) {
        // 协议相对地址应继承书源协议，不能作为站内路径再次拼接域名。
        // 例如起点分类地址 //www.qidian.com/free/... 应解析为
        // https://www.qidian.com/free/...，而不是 https://www.qidian.com//www.qidian.com/free/...
        const sourceSchemeMatch: RegExpMatchArray | null = this.sourceUrl.match(/^(https?):/i);
        const sourceScheme: string = sourceSchemeMatch ? sourceSchemeMatch[1].toLowerCase() : 'https';
        catUrl = sourceScheme + ':' + catUrl;
      } else if (!/^https?:\/\//i.test(catUrl) && this.sourceUrl) {
        // Android 版允许在 bookSourceUrl 后附加 `##...` 作为同域书源的唯一标识。
        // 该标识只参与书源身份判断，不能进入实际请求地址。
        const cleanSourceUrl: string = this.sourceUrl.replace(/##.*$/, '').replace(/\/+$/, '');
        const baseUrl: string = cleanSourceUrl.replace(/(https?:\/\/[^\/]+).*/, '$1');
        catUrl = baseUrl + (catUrl.startsWith('/') ? '' : '/') + catUrl;
      }
      catUrl = catUrl.replace(/\{\{page\}\}/g, '1');
      // qbread rank API doesn't support text sub param — strip it
      catUrl = catUrl.replace(/[&?]sub=[^&]*/g, '');
      console.info('[ExploreBook] Full URL: ' + catUrl);

      const exploreSource: BookSource = this.makeExploreSource(source, catUrl);
      // 部分站点（如雨忆文学网）服务端会随机返回空列表页，0 条时重试两次
      let results: SearchResult[] = [];
      for (let attempt = 0; attempt < 3; attempt++) {
        results = await globalSourceExecutor.search(this.categoryName || '', [exploreSource]);
        if (!this.isActive || runId !== this.requestId) return;
        if (results.length > 0) break;
        console.info('[ExploreBook] 0 books, retry ' + (attempt + 1) + '/2');
      }
      if (!this.isActive || runId !== this.requestId) return;
      console.info('[ExploreBook] Engine: ' + results.length + ' books');
      this.books = results;
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      this.errorMsg = '加载失败: ' + (e instanceof Error ? e.message : String(e));
      console.error('[ExploreBook] Error: ' + JSON.stringify(e));
    } finally {
      if (this.isActive && runId === this.requestId) this.isLoading = false;
    }
  }

  openBookDetail(book: SearchResult): void {
    UiUtil.pushUrl(this.getUIContext(), {
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
        Button($r('app.string.ui_8179643cdc')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.common_back'))
          .onClick((): void => { UiUtil.back(this.getUIContext()); })
        Text(this.categoryName || this.sourceName)
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 12 }).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().width(44)
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 80 })
          Text($r('app.string.common_loading')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.errorMsg) {
        Column() {
          Text($r('app.string.ui_76e163cfa2')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(48).margin({ top: 80 })
          Text(this.errorMsg).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          Button($r('app.string.common_retry')).margin({ top: 12 }).fontSize(13)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(18)
            .onClick((): void => { void this.loadBooks(); })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.books.length === 0) {
        Column() {
          Text($r('app.string.ui_a2cd7e5079')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 80 })
          Text($r('app.string.ui_55f4785cab')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else {
        Text('找到 ' + this.books.length + ' 本书').fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark)).padding({ left: 16, top: 4 })
        List() {
          LazyForEach(this.bookDataSource_, (item: SearchResult) => {
            ListItem() {
              Row() {
                BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 56, coverHeight: 80, coverDecodeJs: item.coverDecodeJs || '' })
                  .margin({ right: 12 })
                Column() {
                  Text(item.name).fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor(ThemeColors.onBackground(this.isDark))
                    .alignSelf(ItemAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((item.author || '未知作者') + (item.wordCount ? '  ·  ' + item.wordCount : ''))
                    .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  Text(item.kind || '').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  if (item.introduce) {
                    Text(item.introduce).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                      .alignSelf(ItemAlign.Start).margin({ top: 2 }).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }.layoutWeight(1).alignItems(HorizontalAlign.Start).height(80).justifyContent(FlexAlign.Center)
              }.padding(12).width('100%')
              .onClick((): void => { this.openBookDetail(item); })
            }.border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
          }, (item: SearchResult): string => item.key)
        }.width('100%').layoutWeight(1)
      }
      // 隐藏 WebView，用于 SPA 站点的 JS 渲染兜底
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
