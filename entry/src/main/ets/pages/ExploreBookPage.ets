/**
 * 发现书籍列表页
 * 直接走 SourceExecutor 引擎解析，复用搜索/发现规则。
 */
import { ThemeColors } from '../theme/ThemeColors';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import { UiUtil } from '../util/UiUtil';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';

@Entry
@Component
struct ExploreBookPage {
  @State sourceId: number = 0;
  @State sourceName: string = '';
  @State sourceUrl: string = '';
  @State categoryName: string = '';
  @State categoryUrl: string = '';

  @StorageLink('isDark') isDark: boolean = false;
  @State books: SearchResult[] = [];
  @State isLoading: boolean = true;
  @State errorMsg: string = '';

  private requestId: number = 0;
  private isActive: boolean = false;

  aboutToAppear(): void {
    this.isActive = true;
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    if (params) {
      this.sourceId = Number(params['sourceId'] || 0);
      this.categoryName = String(params['categoryName'] || '');
      this.categoryUrl = String(params['categoryUrl'] || '');
    }
    void this.loadBooks();
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.requestId++;
  }

  private makeExploreSource(source: BookSource, catUrl: string): BookSource {
    source.isExploreRequest = true;
    source.ruleSearchUrl = catUrl;
    source.ruleSearchList = source.ruleExploreList || source.ruleSearchList;
    source.ruleSearchName = source.ruleExploreName || source.ruleSearchName;
    source.ruleSearchAuthor = source.ruleExploreAuthor || source.ruleSearchAuthor;
    source.ruleSearchCover = source.ruleExploreCover || source.ruleSearchCover;
    source.ruleSearchNoteUrl = source.ruleExploreNoteUrl || source.ruleSearchNoteUrl;
    source.ruleSearchKind = source.ruleExploreKind || source.ruleSearchKind;
    source.ruleSearchWordCount = source.ruleExploreWordCount || source.ruleSearchWordCount;
    source.ruleSearchLastUpdateTime = source.ruleExploreLastUpdateTime || source.ruleSearchLastUpdateTime;
    source.ruleSearchLastChapter = source.ruleExploreLastChapter || source.ruleSearchLastChapter;
    source.ruleSearchIntroduce = source.ruleExploreIntroduce || source.ruleSearchIntroduce;
    return source;
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
      const results: SearchResult[] = await globalSourceExecutor.search(this.categoryName || '', [exploreSource]);
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
        Button('\u2190').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('返回')
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
          Text('加载中...').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.errorMsg) {
        Column() {
          Text('\u26A0\uFE0F').fontSize(48).margin({ top: 80 })
          Text(this.errorMsg).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          Button('重试').margin({ top: 12 }).fontSize(13)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(18)
            .onClick((): void => { void this.loadBooks(); })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.books.length === 0) {
        Column() {
          Text('\uD83D\uDCDA').fontSize(48).margin({ top: 80 })
          Text('没有找到书籍').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else {
        Text('找到 ' + this.books.length + ' 本书').fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark)).padding({ left: 16, top: 4 })
        List() {
          ForEach(this.books, (item: SearchResult) => {
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
          })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
