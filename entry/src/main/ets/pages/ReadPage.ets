/**
 * 阅读页 — 参照 legado-with-MD3 阅读体验
 *
 * 功能：
 * - 自动获取目录，选择第一章
 * - 检测目录反转（某些网站最新章在首位）
 * - 目录列表跳转
 * - 字体大小、行高调节
 * - 阅读位置记忆（当前章节索引）
 */
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookTable } from '../data/database/BookTable';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { NetUtil } from '../util/NetUtil';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { HtmlUtil } from '../util/HtmlUtil';
import router from '@ohos.router';

/** 判断标题是否为第一章 */
function isFirstChapter(title: string): boolean {
  const t = title.trim();
  // 匹配 "第一章"、"第1章"、"第 一 章"、"引子"、"序章"、"楔子"、"序幕"、"序言"
  return /(^第[\s]*[一1][\s]*章)|(^引子)|(^序[章言曲])|(^楔子)|(^序幕)/.test(t);
}

/** 检测章节列表是否反转（最新章在首位） */
function isReversedOrder(chapters: BookSourceChapter[]): boolean {
  if (chapters.length < 3) return false;
  const first = chapters[0].title;
  const mid = chapters[Math.floor(chapters.length / 2)].title;
  const last = chapters[chapters.length - 1].title;

  const firstIsEnd = /(大结局|尾声|后记|完本|完|最终章|最后一章)/.test(first);
  const firstIsStart = isFirstChapter(first);
  const midIsStart = isFirstChapter(mid);
  const lastIsStart = isFirstChapter(last);

  // 检查章节数字：如果第一个章节号很大（如1032），最后一个很小（如1），说明反转
  const firstNum = first.match(/(\d+)/);
  const lastNum = last.match(/(\d+)/);
  const firstNumVal = firstNum ? parseInt(firstNum[1]) : 0;
  const lastNumVal = lastNum ? parseInt(lastNum[1]) : 0;

  if (firstIsEnd && lastIsStart) return true;
  if (midIsStart && !firstIsStart) return true;
  if (lastIsStart && !firstIsStart) return true;
  // 第一个章节号远大于最后一个（如1032 vs 1），说明是反转
  if (firstNumVal > lastNumVal && firstNumVal > 50) return true;

  return false;
}

@Entry
@Component
export struct ReadPage {
  @State text: string = '';
  @State isDark: boolean = false;
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State originUrl: string = '';

  @State isLoading: boolean = true;
  @State chapters: BookSourceChapter[] = [];
  @State currentIndex: number = 0;
  @State totalChapters: number = 0;

  // 阅读设置
  @State fontSize: number = 20;
  @State lineHeight: number = 36;
  @State showSettings: boolean = false;
  @State showToc: boolean = false;
  @State progress: string = '';

  private source: BookSource | null = null;

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    const params = router.getParams() as Record<string, string>;
    if (params) {
      this.bookName = params['name'] || '';
      this.bookAuthor = params['author'] || '';
      this.bookUrl = params['bookUrl'] || '';
      this.originUrl = params['originUrl'] || params['origin'] || '';
    }
    console.info('[Read] Book URL:', this.bookUrl, 'Source:', this.originUrl);
    this.loadContent();
  }

  async loadContent(): Promise<void> {
    if (!this.bookUrl) {
      this.text = '暂无内容';
      this.isLoading = false;
      return;
    }
    if (!this.bookUrl.startsWith('http://') && !this.bookUrl.startsWith('https://')) {
      this.text = '无法获取内容';
      this.isLoading = false;
      return;
    }

    try {
      // 查找书源
      if (this.originUrl) {
        await AppDatabase.getInstance().waitForInit();
        const db = AppDatabase.getInstance().rdbStore;
        const dao = new BookSourceTable(db);
        const sources = await dao.getAllSources();
        const matched = sources.find(s => s.sourceUrl === this.originUrl);
        if (matched) {
          this.source = matched;
          console.info('[Read] Source:', this.source.sourceName);
        }
      }

      if (this.source) {
        // ---- 第一步：获取目录 ----
        const chapters = await globalSourceExecutor.getToc(this.source, this.bookUrl);
        if (chapters.length > 0) {
          console.info('[Read] Got', chapters.length, 'chapters');

          // ---- 检测反转 ----
          if (isReversedOrder(chapters)) {
            console.info('[Read] Chapter list reversed, correcting order');
            chapters.reverse();
            // 反转后重新设 index
            chapters.forEach((ch, i) => ch.index = i);
          }

          this.chapters = chapters;
          this.totalChapters = chapters.length;

          // ---- 找第一章 ----
          let firstIdx = 0;
          for (let i = 0; i < chapters.length; i++) {
            if (isFirstChapter(chapters[i].title)) {
              firstIdx = i;
              break;
            }
          }
          this.currentIndex = firstIdx;

          // ---- 第二步：加载正文 ----
          await this.loadChapter(firstIdx);
        } else {
          console.info('[Read] No TOC, loading book URL directly');
          this.totalChapters = 0;
          const content = await globalSourceExecutor.getContent(this.source, this.bookUrl, this.bookUrl);
          this.text = content || '（正文提取中...）';
        }
      } else {
        // 无书源直连
        console.info('[Read] No source, direct fetch');
        const html = await NetUtil.httpGet(this.bookUrl, {
          'Accept': 'text/html,application/json,*/*',
          'Referer': this.bookUrl
        });
        this.text = this.stripHtml(html).substring(0, 5000);
      }
    } catch (err) {
      console.error('[Read] Error:', (err as Error).message);
      this.text = '无法获取正文内容';
    }
    this.isLoading = false;
  }

  /** 加载指定章节 */
  async loadChapter(index: number): Promise<void> {
    if (!this.source || index < 0 || index >= this.chapters.length) return;
    this.isLoading = true;

    const chapter = this.chapters[index];
    this.currentIndex = index;
    this.progress = `${index + 1}/${this.chapters.length}`;
    console.info('[Read] Loading chapter', index + 1, ':', chapter.title, 'URL:', (chapter.url || '').substring(0, 60));

    try {
      // 如果章节 URL 为空，用书 URL 兜底
      const url = chapter.url || this.bookUrl;
      const content = await globalSourceExecutor.getContent(this.source, url, this.bookUrl);
      this.text = content || '（正文提取中...）';
      this.bookName = this.bookName.replace(/ - .*$/, '') + ' - ' + chapter.title;
      console.info('[Read] Content:', this.text.length, 'chars');

      // 保存阅读进度
      this.saveReadingProgress();
    } catch (err) {
      console.error('[Read] Chapter load failed:', err);
      this.text = '加载章节失败';
    }
    this.isLoading = false;
  }

  /** 上一章 */
  async prevChapter(): Promise<void> {
    if (this.currentIndex > 0) {
      await this.loadChapter(this.currentIndex - 1);
    }
  }

  /** 下一章 */
  async nextChapter(): Promise<void> {
    if (this.currentIndex < this.chapters.length - 1) {
      await this.loadChapter(this.currentIndex + 1);
    }
  }

  /** 保存阅读进度到数据库 */
  private async saveReadingProgress(): Promise<void> {
    if (!this.source) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);
      const existing = await bookTable.getBookByName(this.bookName.replace(/ - .*$/, ''), this.bookAuthor);
      if (existing) {
        existing.durChapterIndex = this.currentIndex;
        existing.durChapterTitle = this.chapters[this.currentIndex]?.title || '';
        existing.totalChapterNum = this.chapters.length;
        // 最新章节标题 = 章节列表最后一个
        existing.latestChapterTitle = this.chapters.length > 0
          ? this.chapters[this.chapters.length - 1].title : '';
        existing.lastOpenTime = Date.now();
        existing.isShelf = true;
        await bookTable.updateBook(existing);
        console.info('[Read] Progress saved:', existing.durChapterTitle,
          'latest:', existing.latestChapterTitle, 'total:', existing.totalChapterNum);
      }
    } catch (e) {
      console.warn('[Read] Save progress failed:', e);
    }
  }

  private stripHtml(html: string): string {
    return HtmlUtil.stripHtml(html);
  }

  build() {
    Column() {
      // ===== 顶部导航 =====
      Row() {
        Button() { Text('←').fontSize(18) }
          .width(40).height(40).backgroundColor('transparent')
          .onClick(() => { router.back(); })
        Text(this.bookName).fontSize(15).fontWeight(FontWeight.Bold)
          .margin({ left: 8 }).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.totalChapters > 0) {
          Text(this.progress).fontSize(12).fontColor('#888').margin({ right: 4 })
        }
        Button() { Text('☰').fontSize(18) }
          .width(40).height(40).backgroundColor('transparent')
          .onClick(() => { this.showToc = !this.showToc; this.showSettings = false; })
        Button() { Text('⚙').fontSize(18) }
          .width(40).height(40).backgroundColor('transparent')
          .onClick(() => { this.showSettings = !this.showSettings; this.showToc = false; })
      }.padding({ left: 8, right: 8 }).width('100%').height(48)

      // ===== 正文区域 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
      } else {
        Scroll() {
          Text(this.text)
            .fontSize(this.fontSize)
            .lineHeight(this.lineHeight)
            .fontColor(this.isDark ? '#C0C0C0' : '#333')
            .padding({ left: 20, right: 20 })
            .width('100%')
        }
        .layoutWeight(1).width('100%')
        // 翻页通过底部按钮操作
      }

      // ===== 底部导航（翻页按钮） =====
      if (this.chapters.length > 0 && !this.isLoading) {
        Row() {
          Button('上一章').fontSize(13).height(36)
            .backgroundColor('#555').fontColor('#FFF').borderRadius(18)
            .layoutWeight(1).margin({ right: 4 })
            .enabled(this.currentIndex > 0)
            .onClick(() => { this.prevChapter(); })

          Button('下一章').fontSize(13).height(36)
            .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
            .layoutWeight(1).margin({ left: 4 })
            .enabled(this.currentIndex < this.chapters.length - 1)
            .onClick(() => { this.nextChapter(); })
        }.padding(8).width('100%')
      }

      // ===== 目录弹窗 =====
      if (this.showToc && this.chapters.length > 0) {
        Column() {
          Row() {
            Text('目录').fontSize(16).fontWeight(FontWeight.Bold)
            Blank()
            Button('✕').fontSize(14).backgroundColor('transparent')
              .onClick(() => { this.showToc = false; })
          }.padding(12).width('100%')

          List({ space: 0 }) {
            ForEach(this.chapters, (ch: BookSourceChapter) => {
              ListItem() {
                Text(ch.title)
                  .fontSize(14)
                  .fontColor(ch.index === this.currentIndex ? '#0078D7' : (this.isDark ? '#CCC' : '#444'))
                  .fontWeight(ch.index === this.currentIndex ? FontWeight.Bold : FontWeight.Normal)
                  .padding({ top: 8, bottom: 8, left: 16 })
                  .width('100%')
                  .backgroundColor(ch.index === this.currentIndex
                    ? (this.isDark ? '#2A3A4A' : '#E8F4FD')
                    : 'transparent')
              }
              .onClick(() => {
                this.showToc = false;
                this.loadChapter(ch.index);
              })
            })
          }.layoutWeight(1).width('100%')
        }
        .width('100%').height('60%')
        .backgroundColor(this.isDark ? '#1E1E1E' : '#FFF')
        .border({ radius: { topLeft: 16, topRight: 16 } })
        .shadow({ radius: 8, color: '#00000044' })
        .position({ bottom: 0 })
      }

      // ===== 设置面板 =====
      if (this.showSettings) {
        Column() {
          Row() {
            Text('阅读设置').fontSize(16).fontWeight(FontWeight.Bold)
            Blank()
            Button('✕').fontSize(14).backgroundColor('transparent')
              .onClick(() => { this.showSettings = false; })
          }.padding(12).width('100%')

          // 字体大小
          Row() {
            Text('A').fontSize(14)
            Slider({ value: this.fontSize, min: 14, max: 32, step: 1 })
              .layoutWeight(1).height(40)
              .onChange((v: number) => { this.fontSize = v; })
            Text('A').fontSize(24)
          }.padding({ left: 16, right: 16 })

          // 行高
          Row() {
            Text('行距').fontSize(14)
            Slider({ value: this.lineHeight, min: 24, max: 52, step: 2 })
              .layoutWeight(1).height(40)
              .onChange((v: number) => { this.lineHeight = v; })
            Text(this.lineHeight + '').fontSize(14).fontColor('#888')
          }.padding({ left: 16, right: 16 }).margin({ top: 8 })

          // 背景色
          Row() {
            Text('背景').fontSize(14)
            ForEach(['#F5F0E8', '#F0F0F0', '#CCE8CF', '#F5E6D0', '#1E1E1E'], (color: string) => {
              Column()
                .width(36).height(36)
                .backgroundColor(color)
                .border({ radius: 18, width: 2, color: this.isDark && color === '#1E1E1E' ? '#666' : '#DDD' })
                .margin({ right: 8 })
                .onClick(() => {
                  if (color === '#1E1E1E') {
                    this.isDark = true;
                  } else {
                    this.isDark = false;
                  }
                })
            })
          }.padding({ left: 16, right: 16 }).margin({ top: 12, bottom: 20 })
        }
        .width('100%')
        .backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
        .border({ radius: { topLeft: 16, topRight: 16 } })
        .shadow({ radius: 8, color: '#00000044' })
        .position({ bottom: 0 })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#1E1E1E' : '#F5F0E8')
  }
}
