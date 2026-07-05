/**
 * 发现书籍列表页
 * 直接走 SourceExecutor 引擎解析，复用搜索/发现规则。
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
struct ExploreBookPage {
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

  @StorageLink('isDark') isDark: boolean = false;
  @State books: SearchResult[] = [];
  @State isLoading: boolean = true;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
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

  private makeSource(catUrl: string): BookSource {
    return {
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
      ruleBookInfoLastUpdateTime: '', ruleBookInfoFrom: '', ruleBookInfoTocUrl: '',
      ruleBookInfoLastChapter: '', ruleBookInfoCanReName: '', ruleBookInfoDownloadUrls: '',
      ruleBookInfoRelatedBooks: '',
      ruleTocUrl: '', ruleToc: '', ruleTocTitle: '', ruleTocUrlItem: '',
      ruleTocPreUpdateJs: '', ruleTocFormatJs: '', ruleTocIsVolume: '',
      ruleTocIsVip: '', ruleTocIsPay: '', ruleTocUpdateTime: '', ruleTocNextTocUrl: '',
      ruleBookContentUrl: '', ruleBookContent: '', ruleBookContentNext: '',
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
  }

  async loadBooks(): Promise<void> {
    this.isLoading = true;
    this.errorMsg = '';
    this.books = [];
    console.info('[ExploreBook] Loading: ' + this.categoryName + ', url: ' + this.categoryUrl);

    try {
      let catUrl: string = this.categoryUrl || '';
      if (!catUrl) {
        this.isLoading = false;
        this.errorMsg = '该分类无可用链接';
        return;
      }
      if (!catUrl.startsWith('http') && this.sourceUrl) {
        const baseUrl: string = this.sourceUrl.replace(/(https?:\/\/[^\/]+).*/, '$1');
        catUrl = baseUrl + (catUrl.startsWith('/') ? '' : '/') + catUrl;
      }
      catUrl = catUrl.replace(/\{\{page\}\}/g, '1');
      // qbread rank API doesn't support text sub param — strip it
      catUrl = catUrl.replace(/[&?]sub=[^&]*/g, '');
      console.info('[ExploreBook] Full URL: ' + catUrl);

      const source: BookSource = this.makeSource(catUrl);
      const results: SearchResult[] = await globalSourceExecutor.search(this.categoryName || '', [source]);
      console.info('[ExploreBook] Engine: ' + results.length + ' books');
      this.books = results;
    } catch (e) {
      this.errorMsg = '加载失败: ' + (e instanceof Error ? e.message : String(e));
      console.error('[ExploreBook] Error: ' + JSON.stringify(e));
    } finally {
      this.isLoading = false;
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
        Text('\u2190').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          .onClick((): void => { UiUtil.back(this.getUIContext()); })
        Text(this.categoryName || this.sourceName)
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark))
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
            }.border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
          })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
