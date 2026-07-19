/**
 * 缓存章节对话框 — 选择起始/结束章节，通过 BookCacheService 下载
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { BookTable } from '../../data/database/BookTable';
import { BookSource } from '../../model/BookSource';
import { BookSourceChapter } from '../../model/BookSource';
import { BookCacheService, CacheChapterItem } from '../../service/BookCacheService';
import { UiUtil } from '../../util/UiUtil';
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct CacheDialog {
  @StorageLink('isDark') isDark: boolean = false;
  @State startChapter: string = '';
  @State endChapter: string = '';
  @State isCaching: boolean = false;
  @State progressText: string = '';
  @State progressPercent: number = 0;
  @State showProgress: boolean = false;

  /** 外部传入的书籍信息 */
  bookName: string = '';
  bookOriginUrl: string = '';
  bookId: number = -1;
  source: BookSource | null = null;
  chapters: Object[] = [];
  totalChapters: number = 0;
  currentIndex: number = 0;

  onDismiss?: () => void;
  /** 缓存完成后的回调 */
  onCacheComplete?: () => void;
  /** 缓存开始时的回调 */
  onCacheStart?: () => void;
  /** 是否从后台重新打开（直接显示进度） */
  showProgressImmediate: boolean = false;

  /** 本次缓存实际使用的 bookId（startCache 时解析） */
  private resolvedBookId_: number = -1;

  aboutToAppear(): void {
    // 默认值：当前章 → 最后一章
    this.startChapter = String(this.currentIndex + 1);
    this.endChapter = String(this.totalChapters);
    // 如果是从后台重新打开（缓存进行中），直接显示进度
    if (this.showProgressImmediate && this.isCaching) {
      this.showProgress = true;
    }
  }

  build() {
    Column() {
      if (!this.showProgress) {
        this.buildInputPanel()
      } else {
        this.buildProgressPanel()
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 640, maxHeight: '92%' })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  buildInputPanel() {
    Column() {
      Text($r('app.string.ui_fa2c7b7a75')).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 4 }).alignSelf(ItemAlign.Start)

      Text($r('app.string.ui_b91af4abcf'))
        .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 章节范围
      Row() {
        Text($r('app.string.ui_08d760c5e8')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(80)
        TextInput({ placeholder: $r('app.string.ui_356a192b79'), text: this.startChapter })
          .width(80).height(40)
          .fontSize(14)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .onChange((v: string) => { this.startChapter = v; })
      }.padding({ left: 16, right: 16, bottom: 10 }).width('100%')

      Row() {
        Text($r('app.string.ui_dbd6ec8454')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(80)
        TextInput({ placeholder: String(this.totalChapters), text: this.endChapter })
          .width(80).height(40)
          .fontSize(14)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .onChange((v: string) => { this.endChapter = v; })
      }.padding({ left: 16, right: 16, bottom: 16 }).width('100%')

      Text('共 ' + this.totalChapters + ' 章，当前第 ' + (this.currentIndex + 1) + ' 章')
        .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 按钮
      Row() {
        Button($r('app.string.common_cancel')).fontSize(15).fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(Color.Transparent)
          .height(44).layoutWeight(1)
          .onClick(() => { this.onDismiss?.(); })
        Button($r('app.string.ui_4a69127be0')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark))
          .height(44).layoutWeight(1).borderRadius(0)
          .onClick(() => { this.startCache(); })
      }.width('100%').height(48)
    }
  }

  @Builder
  buildProgressPanel() {
    Column() {
      Text($r('app.string.ui_e4bccf7cfb')).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      Text(this.progressText)
        .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 进度条
      Row() {
        Column().width(this.progressPercent + '%').height(6).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(3)
          .alignSelf(ItemAlign.Start)
      }.width('100%').height(6).backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(3)
      .padding({ left: 0, right: 0 })

      Row() {
        Button($r('app.string.ui_5011ed5755')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.error(this.isDark)).height(40).layoutWeight(1).margin({ right: 4 })
          .onClick(() => { this.stopCaching(); })
        Button($r('app.string.ui_d8478a3802')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark)).height(40).layoutWeight(1).margin({ left: 4 })
          .onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 12 })
    }
  }

  /** 停止缓存并关闭面板（任务在服务端取消，通知由服务收尾） */
  private stopCaching(): void {
    if (this.resolvedBookId_ > 0) {
      BookCacheService.getInstance().cancel(this.resolvedBookId_);
    }
    this.isCaching = false;
    this.onDismiss?.();
  }

  private async startCache(): Promise<void> {
    const start = parseInt(this.startChapter) || 1;
    const end = parseInt(this.endChapter) || this.totalChapters;
    if (start < 1 || end > this.totalChapters || start > end) {
      UiUtil.showToast(this.getUIContext(), { message: '章节范围无效', duration: 1500 });
      return;
    }
    if (!this.source) {
      UiUtil.showToast(this.getUIContext(), { message: '书源不可用', duration: 1500 });
      return;
    }

    this.showProgress = true;
    this.isCaching = true;
    this.progressText = '准备缓存...';
    this.progressPercent = 0;

    // 通知父组件缓存已开始
    this.onCacheStart?.();

    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);
      let bookId = this.bookId;
      if (bookId <= 0 && this.bookOriginUrl) {
        const bookByUrl = await bookTable.getBookByUrl(this.bookOriginUrl);
        if (bookByUrl) bookId = bookByUrl.id;
      }
      if (bookId <= 0) {
        const book = await bookTable.getBookByName(this.bookName, '');
        if (book) bookId = book.id;
      }
      if (bookId <= 0) {
        this.progressText = '缓存失败：书籍未入库';
        this.isCaching = false;
        return;
      }
      this.resolvedBookId_ = bookId;

      const items: CacheChapterItem[] = [];
      for (let i = 0; i < this.chapters.length; i++) {
        const ch = this.chapters[i] as BookSourceChapter;
        items.push({ index: i, title: ch.title || '', url: ch.url || '' });
      }

      const result = await BookCacheService.getInstance().cacheBook({
        bookId: bookId,
        bookName: this.bookName,
        bookUrl: this.bookOriginUrl,
        source: this.source!,
        chapters: items,
        startIndex: start - 1,
        endIndex: end - 1,
        context: UiUtil.getHostContext(this.getUIContext()),
        onProgress: (done: number, total: number, title: string): void => {
          this.progressPercent = Math.round((done / total) * 100);
          this.progressText = '正在缓存 ' + done + '/' + total + ': ' + title;
        },
      });

      if (!result) {
        this.progressText = '该书已有缓存任务进行中';
        this.isCaching = false;
        return;
      }
      this.progressPercent = 100;
      this.progressText = result.cancelled
        ? '已取消，成功 ' + result.success + ' 章，失败 ' + result.failed + ' 章'
        : '缓存完成！成功 ' + result.success + ' 章，跳过 ' + result.skipped + ' 章，失败 ' + result.failed + ' 章';
      if (!result.cancelled) {
        UiUtil.showToast(this.getUIContext(), { message: '缓存完成: ' + result.success + ' 章', duration: 2000 });
        this.onCacheComplete?.();
      }
    } catch (err) {
      this.progressText = '缓存出错: ' + (err as Error).message;
    }
    this.isCaching = false;
  }
}
