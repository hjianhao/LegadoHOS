/**
 * 离线缓存页 — 对齐安卓书架「缓存/导出」入口的离线缓存列表
 * - 只显示书源小说（本地导入书籍不显示）
 * - 每项：书名、已缓存/总章节，右侧「缓存」「导出」按钮
 * - 缓存进度在列表中实时刷新（轮询 BookCacheService）
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { Book } from '../model/Book';
import { BookChapter } from '../model/BookChapter';
import { BookSource } from '../model/BookSource';
import { BookCover } from '../components/BookCover';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { LocalBookEngine } from '../engine/book/LocalBookEngine';
import { ExportBookDialog } from '../components/ExportBookDialog';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { ArrayDataSource } from '../util/ArrayDataSource';

interface CacheRow {
  book: Book;
  cached: number;
  total: number;
  /** 是否有缓存任务进行中 */
  running: boolean;
  /** 进行中任务的进度（无任务时为 0/0） */
  dlDone: number;
  dlTotal: number;
}

@Entry
@Component
struct BookCachePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State @Watch('onRowsChanged_') rows: CacheRow[] = [];
  @State isLoading: boolean = true;
  @State showExportDialog: boolean = false;

  private exportBook_: Book | null = null;
  private timer_: number = -1;
  private needRefresh_: boolean = false;
  private wasRunning_: boolean = false;
  private refreshing_: boolean = false;
  private rowDataSource_: ArrayDataSource<CacheRow> = new ArrayDataSource<CacheRow>();

  private onRowsChanged_(): void {
    this.rowDataSource_.reset(this.rows);
  }

  aboutToAppear(): void {
    this.loadRows();
    this.timer_ = setInterval((): void => { this.tick(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer_ >= 0) {
      clearInterval(this.timer_);
      this.timer_ = -1;
    }
  }

  private makeRow(book: Book, cached: number, total: number): CacheRow {
    const service = BookCacheService.getInstance();
    const p = service.getProgress(book.id);
    return {
      book: book,
      cached: cached,
      total: total,
      running: service.isRunning(book.id),
      dlDone: p ? p.done : 0,
      dlTotal: p ? p.total : 0,
    };
  }

  private async loadRows(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const books = (await new BookTable(db).getAllShelfBooks())
        .filter((b: Book): boolean => !LocalBookEngine.isLocalBook(b));
      const chapterTable = new ChapterTable(db);
      const rows: CacheRow[] = [];
      for (const book of books) {
        rows.push(this.makeRow(book,
          await chapterTable.getCachedChapterCount(book.id),
          book.totalChapterNum > 0
            ? book.totalChapterNum : await chapterTable.getChapterCount(book.id)));
      }
      this.rows = rows;
    } catch (e) {
      console.warn('[BookCachePage] load fail:', (e as Error).message);
    }
    this.isLoading = false;
  }

  /** 有任务运行时每秒刷新统计；任务刚结束或动作后补刷一次 */
  private tick(): void {
    // 注意：必须读服务的实时状态，row.running 只有 refreshStats 后才更新
    const service = BookCacheService.getInstance();
    let anyRunning = false;
    for (const row of this.rows) {
      if (service.isRunning(row.book.id)) {
        anyRunning = true;
        break;
      }
    }
    if (anyRunning || this.wasRunning_ || this.needRefresh_) {
      this.needRefresh_ = false;
      this.refreshStats();
    }
    this.wasRunning_ = anyRunning;
  }

  private async refreshStats(): Promise<void> {
    if (this.refreshing_) return;
    this.refreshing_ = true;
    try {
      const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const rows: CacheRow[] = [];
      for (const row of this.rows) {
        rows.push(this.makeRow(row.book,
          await chapterTable.getCachedChapterCount(row.book.id),
          row.total));
      }
      this.rows = rows;
    } catch (_e) {}
    this.refreshing_ = false;
  }

  private progressText(row: CacheRow): string {
    if (row.running && row.dlTotal > 0) {
      return '下载中 ' + row.dlDone + '/' + row.dlTotal + ' · 已缓存 ' + row.cached + '/' + row.total + ' 章';
    }
    return '已缓存 ' + row.cached + '/' + row.total + ' 章';
  }

  private onCacheButton(book: Book): void {
    console.info('[BookCachePage] tap cache, bookId=' + book.id + ' name=' + book.name);
    const service = BookCacheService.getInstance();
    if (service.isRunning(book.id)) {
      service.cancel(book.id);
      this.needRefresh_ = true;
      return;
    }
    UiUtil.showToast(this.getUIContext(), { message: '开始缓存《' + book.name + '》', duration: 1500 });
    this.resolveAndCache(book);
  }

  private async resolveAndCache(book: Book): Promise<void> {
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const source = await BookSourceResolver.resolve(book);
      console.info('[BookCachePage] source=' + (source ? source.sourceName : 'null')
        + ' book.originUrl=' + book.originUrl + ' book.origin=' + book.origin);
      if (!source) {
        UiUtil.showToast(this.getUIContext(), { message: '书源不可用', duration: 1500 });
        return;
      }
      const chapterTable = new ChapterTable(db);
      let chapters = await chapterTable.getChaptersByBookId(book.id);
      console.info('[BookCachePage] chapters in db=' + chapters.length + ' bookId=' + book.id);
      // 缓存前先刷新目录：DB 目录可能不完整（如漫画只读过几章），否则进度和缓存范围都不对
      try {
        const toc = await globalSourceExecutor.getToc(source, book.bookUrl);
        if (toc.length > 0) {
          await chapterTable.replaceTocPreserveContent(book.id, toc);
          chapters = await chapterTable.getChaptersByBookId(book.id);
          console.info('[BookCachePage] toc refreshed, chapters=' + chapters.length);
        }
      } catch (e) {
        console.warn('[BookCachePage] refresh toc failed, use db chapters: ' + (e as Error).message);
      }
      if (chapters.length === 0) {
        UiUtil.showToast(this.getUIContext(), { message: '目录为空，请先更新目录', duration: 1500 });
        return;
      }
      const started = BookCacheService.getInstance().cacheBook({
        bookId: book.id,
        bookName: book.name,
        bookUrl: book.bookUrl,
        source: source,
        chapters: chapters.map((ch: BookChapter): CacheChapterItem => {
          return { index: ch.index, title: ch.title, url: ch.url };
        }),
        startIndex: 0,
        endIndex: chapters.length - 1,
        context: UiUtil.getHostContext(this.getUIContext()),
      });
      started.then((result) => {
        if (!result) {
          UiUtil.showToast(this.getUIContext(), { message: '该书的缓存任务已在进行中', duration: 1500 });
        }
      }).catch((e: Error) => {
        console.warn('[BookCachePage] cache fail: ' + book.name + ' - ' + e.message);
      });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '启动缓存失败', duration: 1500 });
    }
  }

  private openExport(book: Book): void {
    this.exportBook_ = book;
    this.showExportDialog = true;
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() { Text($r('app.string.ui_8179643cdc')).fontSize(20).fontColor(ThemeColors.primary(this.isDark)) }
            .backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.common_back')).onClick(() => { UiUtil.back(this.getUIContext()); })
          Text($r('app.string.ui_fa2c7b7a75')).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        }
        .width('100%').height(56).padding({ left: 8, right: 12 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

        if (this.isLoading) {
          LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 40 })
        } else if (this.rows.length === 0) {
          Text($r('app.string.ui_99160509f5'))
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 60 })
        } else {
          List() {
            LazyForEach(this.rowDataSource_, (row: CacheRow) => {
              ListItem() {
                Row() {
                  BookCover({ name: row.book.name, coverUrl: row.book.coverUrl, coverWidth: 42, coverHeight: 58 })
                    .margin({ right: 10 })
                  Column() {
                    Text(row.book.name).fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onBackground(this.isDark))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Text(this.progressText(row)).fontSize(12)
                      .fontColor(row.running
                        ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%').margin({ top: 4 })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                  Button(row.running ? '取消' : '缓存')
                    .fontSize(13)
                    .fontColor(row.running
                      ? ThemeColors.error(this.isDark) : ThemeColors.primary(this.isDark))
                    .backgroundColor(Color.Transparent)
                    .height(40).padding({ left: 6, right: 6 })
                    .onClick((): void => { this.onCacheButton(row.book); })
                  Button($r('app.string.common_export'))
                    .fontSize(13).fontColor(ThemeColors.primary(this.isDark))
                    .backgroundColor(Color.Transparent)
                    .height(40).padding({ left: 6, right: 6 })
                    .onClick((): void => { this.openExport(row.book); })
                }
                .width('100%').padding({ left: 12, right: 4, top: 8, bottom: 8 })
              }
              .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
            }, (row: CacheRow): string => {
              // key 包含进度字段：进度变化时强制重建列表项，避免固定 key 复用旧视图
              return row.book.id + '_' + row.cached + '_' + row.dlDone + '_' + (row.running ? 1 : 0);
            })
          }.width('100%').layoutWeight(1)
        }
      }
      .width('100%').height('100%')
      .backgroundColor(ThemeColors.background(this.isDark))

      if (this.showExportDialog && this.exportBook_) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showExportDialog = false; })
          ExportBookDialog({
            bookId: this.exportBook_!.id,
            bookName: this.exportBook_!.name,
            bookAuthor: this.exportBook_!.author,
            introduce: this.exportBook_!.introduce,
            bookCover: this.exportBook_!.coverUrl,
            bookUrl: this.exportBook_!.bookUrl,
            origin: this.exportBook_!.origin,
            originUrl: this.exportBook_!.originUrl,
            onDismiss: () => {
              this.showExportDialog = false;
              this.needRefresh_ = true;
            },
          })
        }.width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }
}
