/**
 * RSS 文章列表页
 * 对应 Android RssSortScreen — 显示某个 RSS 源的文章列表
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSArticle } from '../model/RSSSource';
import { fetchArticles } from '../engine/rss/RssService';
import { NetUtil } from '../util/NetUtil';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct RssArticlesPage {
  @StorageProp('isDark') isDark: boolean = false;
  @State articles: RSSArticle[] = [];
  @State isLoading: boolean = true;
  @State sourceName: string = '';
  @State statusMsg: string = '';
  private sourceUrl: string = '';

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    if (params) {
      this.sourceUrl = (params['sourceUrl'] as string) || '';
      this.sourceName = (params['sourceName'] as string) || 'RSS 文章';
    }
    this.loadData();
  }

  async loadData() {
    this.isLoading = true;
    this.statusMsg = '';
    try {
      await this.db.waitForInit();
      const source = await this.db.rssSourceTable.getByKey(this.sourceUrl);
      if (!source) {
        this.statusMsg = '未找到源数据';
        this.isLoading = false;
        return;
      }
      this.sourceName = source.sourceName || source.sourceUrl;

      // 清除旧文章
      try { await this.db.rssArticleTable.deleteByOrigin(this.sourceUrl); } catch (_e) { /* ignore */ }

      // 修复 URL：去除 # 及之后的内容（URL 碎片）
      let cleanUrl = this.sourceUrl;
      const hashIdx = cleanUrl.indexOf('#');
      if (hashIdx > 0) {
        cleanUrl = cleanUrl.substring(0, hashIdx);
        console.info('[RssArticlesPage] cleaned URL: ' + cleanUrl);
      }

      // fetchArticles 内部会做 HTTP 请求 + 规则解析
      const hasRules = !!(source.ruleArticles && source.ruleArticles.trim().length > 0);
      console.info('[RssArticlesPage] calling fetchArticles, hasRules=' + hasRules + ', singleUrl=' + source.singleUrl + ', url=' + cleanUrl);

      const result = await fetchArticles(source.sourceName || '默认分类', cleanUrl, source);
      const fetchedArticles = result[0];
      if (fetchedArticles.length > 0) {
        await this.db.rssArticleTable.batchInsert(fetchedArticles);
      } else {
        this.statusMsg = '未解析到文章，该 URL 可能不是 RSS/Atom 格式';
      }

      this.articles = await this.db.rssArticleTable.getByOrigin(this.sourceUrl);
    } catch (e) {
      const errMsg = (e instanceof Error) ? e.message : String(e);
      this.statusMsg = '加载失败: ' + errMsg;
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('← 返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent')
        .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text(this.sourceName).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).margin({ left: 8 })
      }
      .width('100%').padding({ left: 8, right: 12, top: 8, bottom: 4 })

      if (this.statusMsg) {
        Text(this.statusMsg).fontSize(12).fontColor('#FF5722')
          .padding(8).backgroundColor('#FFF3E0').width('100%')
      }

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark))
      } else if (this.articles.length === 0) {
        Column() {
          Text('暂无文章').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          Text('该源暂无内容，请检查源URL是否正确')
            .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.articles, (article: RSSArticle) => {
              Column() {
                Text(article.title).fontSize(15)
                  .fontColor(ThemeColors.onBackground(this.isDark))
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Row() {
                  if (article.pubDate) {
                    Text(article.pubDate).fontSize(11)
                      .fontColor(ThemeColors.secondaryText(this.isDark))
                  }
                  Blank()
                  if (article.read) {
                    Text('已读').fontSize(10).fontColor('#4CAF50')
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .border({ radius: 3 }).borderColor('#4CAF50').borderWidth(0.5)
                  }
                }.width('100%').margin({ top: 4 })
              }
              .padding(12).borderRadius(8)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .margin({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
            })
          }.width('100%')
        }.layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
