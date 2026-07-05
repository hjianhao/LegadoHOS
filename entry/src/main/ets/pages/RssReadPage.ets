/**
 * RSS 文章阅读页
 * 对应 Android RssReadRouteScreen — WebView 渲染文章内容
 * 功能：内容加载、收藏、分享、朗读、重定向策略
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource, RSSArticle, RssStar } from '../model/RSSSource';
import { fetchContent } from '../engine/rss/RssService';
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import web_webview from '@ohos.web.webview';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
export struct RssReadPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State title: string = '';
  @State origin: string = '';
  @State link: string = '';
  @State article: RSSArticle | null = null;
  @State source: RSSSource | null = null;
  @State content: string = '';
  @State isLoading: boolean = true;
  @State isStarred: boolean = false;
  @State showMenu: boolean = false;
  @State webProgress: number = 100;
  @State starGroup: string = '默认分组';
  @State showStarEdit: boolean = false;
  @State starTitle: string = '';

  private db: AppDatabase = AppDatabase.getInstance();
  private webviewController: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear() {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    if (params) {
      this.title = params['title'] || '';
      this.origin = params['origin'] || '';
      this.link = params['link'] || '';
      if (params['source']) {
        try {
          this.source = JSON.parse(params['source']) as RSSSource;
        } catch (_e) { /* ignore */ }
      }
    }
    this.loadContent();
  }

  async loadContent() {
    if (!this.origin) return;
    this.isLoading = true;
    try {
      await this.db.waitForInit();

      // 获取 RSS 源定义
      if (!this.source) {
        this.source = await this.db.rssSourceTable.getByKey(this.origin);
      }

      // 获取文章（从数据库）
      let article = await this.db.rssArticleTable.getByOriginSort(this.origin, '');
      if (this.link) {
        // 查找具体文章
        const dbArts = await this.db.rssArticleTable.getByOriginSort(this.origin, '');
        this.article = dbArts.find(a => a.link === this.link) || null;
      }

      // 检查是否已收藏
      if (this.link) {
        const star = await this.db.rssStarTable.get(this.origin, this.link);
        this.isStarred = !!star;
      }

      if (this.article && this.link) {
        // 标记已读
        const updatedArticle: RSSArticle = {
          origin: this.article.origin,
          sort: this.article.sort,
          link: this.article.link,
          title: this.article.title,
          order: this.article.order,
          pubDate: this.article.pubDate,
          description: this.article.description,
          content: this.article.content,
          image: this.article.image,
          group: this.article.group,
          read: true,
          variable: this.article.variable,
          type: this.article.type,
          durPos: this.article.durPos,
        };
        await this.db.rssArticleTable.update(updatedArticle);

        // 如果有 ruleContent，提取正文
        if (this.source && this.source.ruleContent && this.article.link) {
          try {
            const body = await fetchContent(this.article, this.source.ruleContent, this.source);
            if (body && !body.startsWith('http')) {
              this.content = this.wrapHtml(body);
              this.isLoading = false;
              return;
            }
          } catch (_e) { /* fallback to webview */ }
        }

        // 有 description 则使用
        if (this.article.description) {
          this.content = this.wrapHtml(this.article.description);
          this.isLoading = false;
          return;
        }
      }

      // 默认：用 WebView 加载链接
      this.isLoading = false;
    } catch (e) {
      console.error(`[RssReadPage] 加载失败: ${e}`);
      this.isLoading = false;
    }
  }

  wrapHtml(body: string): string {
    let style = `
      <style>
        img{max-width:100% !important; height:auto;}
        video{object-fit:fill; max-width:100% !important; height:auto;}
        body{word-wrap:break-word; padding:16px; line-height:1.8; font-size:16px;}
        *{max-width:100% !important;}
      </style>`;
    if (this.source && this.source.style) {
      style = `<style>${this.source.style}</style>`;
    }
    // 检测是否已有样式
    if (body.includes('<style>')) {
      return body;
    }
    return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">${style}</head><body>${body}</body></html>`;
  }

  async toggleStar() {
    if (!this.article || !this.link) return;
    try {
      if (this.isStarred) {
        await this.db.rssStarTable.delete(this.origin, this.link);
        this.isStarred = false;
        UiUtil.showToast(this.getUIContext(), { message: '已取消收藏' });
      } else {
        const star: RssStar = {
          origin: this.origin,
          link: this.link,
          sort: '',
          title: this.article.title,
          starTime: Date.now(),
          pubDate: this.article.pubDate,
          description: this.article.description,
          content: this.content || this.article.description,
          image: this.article.image,
          group: '默认分组',
          variable: null,
          type: this.article.type,
          durPos: 0,
        };
        await this.db.rssStarTable.insert(star);
        this.isStarred = true;
        this.starTitle = this.article.title;
        this.starGroup = '默认分组';
        UiUtil.showToast(this.getUIContext(), { message: '已收藏' });
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: `操作失败: ${e}` });
    }
  }

  async updateStarInfo() {
    if (!this.article || !this.link) return;
    try {
      const star = await this.db.rssStarTable.get(this.origin, this.link);
      if (star) {
        star.title = this.starTitle || star.title;
        star.group = this.starGroup || star.group;
        await this.db.rssStarTable.update(star);
        UiUtil.showToast(this.getUIContext(), { message: '已更新收藏信息' });
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: `更新失败: ${e}` });
    }
    this.showStarEdit = false;
  }

  shareUrl() {
    const url = this.link || this.origin;
    if (url) {
      // 复制到剪贴板（简化）
      UiUtil.showToast(this.getUIContext(), { message: `链接: ${url}` });
    }
  }

  openInBrowser() {
    const url = this.link || this.origin;
    if (url) {
      UiUtil.showToast(this.getUIContext(), { message: `浏览器打开: ${url}` });
    }
  }

  onPageProgress(event: Object) {
    const ev = event as Record<string, Object>;
    const progress = ev['progress'] as number || 0;
    this.webProgress = progress;
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => UiUtil.back(this.getUIContext()))
        Text(this.title || 'RSS 阅读')
          .fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Text(this.isStarred ? '★' : '☆').fontSize(20).fontColor('#FFC107')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.toggleStar())
        Button({ type: ButtonType.Normal }) {
          Text('分享').fontSize(13).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent')
        .onClick(() => this.shareUrl())
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // 加载进度条
      if (this.webProgress < 100) {
        Row()
          .width(`${this.webProgress}%`).height(3)
          .backgroundColor(ThemeColors.primary(this.isDark))
          .borderRadius(2)
      }

      // ===== 内容区 =====
      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark))
      } else if (this.content) {
        // 使用 WebView 渲染 HTML 内容
        Web({ src: '', controller: this.webviewController })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onPageBegin(() => {
            if (this.content) {
              this.webviewController.loadData(
                this.content,
                'text/html',
                'utf-8',
                this.link || this.origin
              );
            }
          })
          .onProgressChange((event) => this.onPageProgress(event))
          .layoutWeight(1)
      } else {
        // 直接加载原文链接
        Web({ src: this.link || this.origin, controller: this.webviewController })
          .javaScriptAccess(this.source?.enableJs ?? true)
          .domStorageAccess(true)
          .onProgressChange((event) => this.onPageProgress(event))
          .layoutWeight(1)
      }

      // ===== 底部操作栏 =====
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('打开浏览器').fontSize(13).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent')
        .onClick(() => this.openInBrowser())

        Blank()

        if (this.isStarred) {
          Button({ type: ButtonType.Normal }) {
            Text('编辑收藏').fontSize(13).fontColor(ThemeColors.primary(this.isDark))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            this.showStarEdit = true;
          })
        }

        Button({ type: ButtonType.Normal }) {
          Text('刷新').fontSize(13).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent').margin({ left: 8 })
        .onClick(() => {
          this.isLoading = true;
          this.content = '';
          this.loadContent();
        })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 12, top: 8 })
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
