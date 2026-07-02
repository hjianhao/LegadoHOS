/**
 * RSS 分类/文章列表页
 * 对应 Android RssSortScreen + RssArticlesPage
 * 功能：多分类标签、文章列表（4种布局）、下拉刷新、上拉加载、搜索
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource, RSSArticle } from '../model/RSSSource';
import { fetchArticles, resolveSortUrls } from '../engine/rss/RssService';
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import http from '@ohos.net.http';
import { UiUtil } from '../util/UiUtil';

interface SortTab {
  name: string;
  url: string;
}

interface LoadState {
  isRefreshing: boolean;
  isLoadingMore: boolean;
  hasMore: boolean;
  errorMessage: string | null;
}

@Entry
@Component
export struct RssSortPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State sourceUrl: string = '';
  @State sourceName: string = '';
  @State source: RSSSource | null = null;
  @State sortTabs: SortTab[] = [];
  @State currentTab: number = 0;
  @State articles: RSSArticle[] = [];
  @State loadState: LoadState = {
    isRefreshing: false,
    isLoadingMore: false,
    hasMore: true,
    errorMessage: null,
  };
  @State articleStyle: number = 0; // 0=列表, 1=大卡片, 2=网格, 3=瀑布流
  @State searchKey: string = '';
  @State isSearch: boolean = false;
  @State order: number = Date.now();
  @State nextPageUrl: string | null = null;
  @State page: number = 1;

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    if (params) {
      this.sourceUrl = params['sourceUrl'] || '';
      this.sourceName = params['sourceName'] || '';
      if (params['searchKey']) this.searchKey = params['searchKey'];
    }
    this.initSource();
  }

  async initSource() {
    if (!this.sourceUrl) return;
    try {
      await this.db.waitForInit();
      const source = await this.db.rssSourceTable.getByKey(this.sourceUrl);
      if (!source) {
        UiUtil.showToast(this.getUIContext(), { message: '订阅源不存在' });
        return;
      }
      this.source = source;
      this.articleStyle = source.articleStyle;

      // 解析分类
      const urls = await resolveSortUrls(source.sourceUrl, source.sortUrl);
      if (urls.length > 0) {
        this.sortTabs = urls.map((u: Record<string, string>): SortTab => ({
          name: u['name'] || source.sourceName,
          url: u['url']
        }));
      } else {
        this.sortTabs = [{ name: source.sourceName, url: source.sourceUrl }];
      }

      // 加载第一分类的文章
      if (this.sortTabs.length > 0) {
        this.loadArticles(this.sortTabs[0]);
      }
    } catch (e) {
      console.error(`[RssSortPage] initSource 失败: ${e}`);
    }
  }

  async loadArticles(sortTab: SortTab) {
    if (!this.source) return;
    this.loadState = {
      isRefreshing: true,
      isLoadingMore: false,
      hasMore: true,
      errorMessage: null,
    };
    this.page = 1;
    this.order = Date.now();

    try {
      const result = await fetchArticles(
        sortTab.name,
        sortTab.url,
        this.source,
        this.page,
        this.searchKey || null
      );
      const articles: RSSArticle[] = result[0] as RSSArticle[];
      const nextUrl: string = result[1] as string || '';

      // 设置排序序号
      for (let ai = 0; ai < articles.length; ai++) {
        articles[ai].order = this.order - ai;
      }

      // 保存到数据库
      for (let ai = 0; ai < articles.length; ai++) {
        await this.db.rssArticleTable.insert(articles[ai]);
      }

      // 清理旧数据
      if (this.source.ruleNextPage) {
        await this.db.rssArticleTable.clearOld(this.sourceUrl, sortTab.name, this.order - articles.length);
      }

      this.nextPageUrl = nextUrl;
      const hasMore = articles.length > 0 && !!this.source.ruleNextPage;

      // 从数据库重新读取（包含阅读状态）
      const dbArticles = await this.db.rssArticleTable.getByOriginSort(this.sourceUrl, sortTab.name);
      this.articles = dbArticles;
      this.loadState = {
        isRefreshing: false,
        isLoadingMore: false,
        hasMore: hasMore,
        errorMessage: null,
      };
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      this.loadState = {
        isRefreshing: false,
        isLoadingMore: false,
        hasMore: false,
        errorMessage: msg,
      };
    }
  }

  async loadMore() {
    const currentState = this.loadState;
    if (currentState.isRefreshing || currentState.isLoadingMore || !currentState.hasMore) return;
    if (!this.nextPageUrl || !this.source) return;

    this.loadState = {
      isRefreshing: currentState.isRefreshing,
      isLoadingMore: true,
      hasMore: currentState.hasMore,
      errorMessage: null,
    };
    this.page++;

    try {
      const sortTab = this.sortTabs[this.currentTab] || { name: '', url: '' };
      const result = await fetchArticles(
        sortTab.name,
        this.nextPageUrl,
        this.source,
        this.page,
        this.searchKey || null
      );
      const newArticles = result[0];
      const nextUrl = result[1];

      if (newArticles.length === 0) {
        this.loadState = {
          isRefreshing: currentState.isRefreshing,
          isLoadingMore: false,
          hasMore: false,
          errorMessage: null,
        };
        return;
      }

      for (let ai = 0; ai < newArticles.length; ai++) {
        newArticles[ai].order = this.order - ai;
      }

      for (let ai = 0; ai < newArticles.length; ai++) {
        await this.db.rssArticleTable.append(newArticles[ai]);
      }

      this.nextPageUrl = nextUrl;

      const dbArticles = await this.db.rssArticleTable.getByOriginSort(this.sourceUrl, sortTab.name);
      this.articles = dbArticles;
      this.loadState = {
        isRefreshing: currentState.isRefreshing,
        isLoadingMore: false,
        hasMore: !!nextUrl,
        errorMessage: null,
      };
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      if (this.page > 1) this.page--;
      this.loadState = {
        isRefreshing: currentState.isRefreshing,
        isLoadingMore: false,
        hasMore: currentState.hasMore,
        errorMessage: msg,
      };
    }
  }

  onTabChange(index: number) {
    this.currentTab = index;
    const tab = this.sortTabs[index];
    if (tab) {
      this.loadArticles(tab);
    }
  }

  openReadArticle(article: RSSArticle) {
    // 标记已读
    const updated: RSSArticle = {
      origin: article.origin,
      sort: article.sort,
      link: article.link,
      title: article.title,
      order: article.order,
      pubDate: article.pubDate,
      description: article.description,
      content: article.content,
      image: article.image,
      group: article.group,
      read: true,
      variable: article.variable,
      type: article.type,
      durPos: article.durPos,
    };
    this.db.rssArticleTable.update(updated);
    article.read = true;

    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/RssReadPage',
      params: {
        title: article.title,
        origin: this.sourceUrl,
        link: article.link,
        source: JSON.stringify(this.source),
      },
    });
  }

  switchLayout() {
    this.articleStyle = (this.articleStyle + 1) % 4;
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor('#0078D7')
          .onClick(() => UiUtil.back(this.getUIContext()))
        Text(this.sourceName).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A1A')
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text(this.articleStyle === 0 ? '列表' : this.articleStyle === 1 ? '大卡' : this.articleStyle === 2 ? '网格' : '瀑布')
            .fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.switchLayout())
        Button({ type: ButtonType.Normal }) {
          Text('搜索').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent')
        .onClick(() => {
          this.isSearch = !this.isSearch;
          if (!this.isSearch) {
            this.searchKey = '';
            const tab = this.sortTabs[this.currentTab];
            if (tab) this.loadArticles(tab);
          }
        })
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== 搜索栏 =====
      if (this.isSearch) {
        Search({ placeholder: '搜索文章...', value: this.searchKey })
          .onSubmit((val) => {
            this.searchKey = val;
            const tab = this.sortTabs[this.currentTab];
            if (tab) this.loadArticles(tab);
          })
          .width('100%').padding({ left: 12, right: 12, bottom: 8 })
      }

      // ===== 分类标签 =====
      if (this.sortTabs.length > 1) {
        Scroll() {
          Row() {
            ForEach(this.sortTabs, (tab: SortTab, idx: number) => {
              Column() {
                Text(tab.name).fontSize(14)
                  .fontColor(this.currentTab === idx ? '#0078D7' : (this.isDark ? '#AAA' : '#666'))
                  .fontWeight(this.currentTab === idx ? FontWeight.Bold : FontWeight.Normal)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                if (this.currentTab === idx) {
                  Divider().color('#0078D7').width('80%').height(2).borderRadius(1)
                }
              }
              .onClick(() => this.onTabChange(idx))
            })
          }
        }
        .width('100%').height(36)
        .scrollBar(BarState.Off)
        .width('100%').height(40)
      }

      // ===== 文章列表 =====
      if (this.loadState.isRefreshing && this.articles.length === 0) {
        LoadingProgress().color('#0078D7')
      } else if (this.articles.length === 0) {
        Column() {
          Text(this.loadState.errorMessage || '暂无文章').fontSize(14)
            .fontColor(this.isDark ? '#AAA' : '#888')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            if (this.articleStyle <= 1) {
              // 列表 / 大卡片布局
              ForEach(this.articles, (article: RSSArticle) => {
                this.buildArticleListItem(article)
              })
            } else {
              // 网格布局
              Grid() {
                ForEach(this.articles, (article: RSSArticle) => {
                  GridItem() {
                    this.buildArticleGridItem(article)
                  }
                })
              }
              .columnsTemplate('1fr 1fr')
              .rowsGap(8).columnsGap(8)
              .padding(12)
            }

            // 加载更多
            if (this.loadState.isLoadingMore) {
              LoadingProgress().color('#0078D7').height(60)
            } else if (this.loadState.errorMessage) {
              Text(this.loadState.errorMessage).fontSize(12).fontColor('#F44336')
                .padding(12).onClick(() => this.loadMore())
            } else if (!this.loadState.hasMore && this.articles.length > 0) {
              Text('— 已加载全部 —').fontSize(12).fontColor(this.isDark ? '#888' : '#AAA')
                .width('100%').textAlign(TextAlign.Center).padding(12)
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        // 滚动触底加载更多
        .onReachEnd(() => {
          this.loadMore();
        })
        // 下拉刷新
        .onReachStart(() => {
          const tab = this.sortTabs[this.currentTab];
          if (tab) this.loadArticles(tab);
        })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  @Builder
  buildArticleListItem(article: RSSArticle) {
    Row() {
      Column() {
        Text(article.title).fontSize(15)
          .fontColor(article.read ? (this.isDark ? '#888' : '#999') : (this.isDark ? '#E0E0E0' : '#333'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)
        if (article.pubDate) {
          Text(article.pubDate).fontSize(11).fontColor(this.isDark ? '#888' : '#AAA')
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (article.image) {
        Image(article.image)
          .width(90).height(60).borderRadius(6)
          .objectFit(ImageFit.Cover)
          .margin({ left: 8 })
      }
    }
    .padding(12).margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
    .width('100%')
    .onClick(() => this.openReadArticle(article))
  }

  @Builder
  buildArticleGridItem(article: RSSArticle) {
    Column() {
      if (article.image) {
        Image(article.image)
          .width('100%').height(120).borderRadius(8)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height(120).borderRadius(8)
          .backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
      }
      Text(article.title).fontSize(13)
        .fontColor(article.read ? (this.isDark ? '#888' : '#999') : (this.isDark ? '#E0E0E0' : '#333'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(18).margin({ top: 6 })
      if (article.pubDate) {
        Text(article.pubDate).fontSize(10).fontColor(this.isDark ? '#888' : '#AAA')
          .margin({ top: 2 })
      }
    }
    .padding(8).borderRadius(10)
    .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
    .onClick(() => this.openReadArticle(article))
  }
}
