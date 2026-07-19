/**
 * 书架管理页面 — 对标 Android BookshelfManageScreen 的批量管理主流程
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookGroupTable } from '../data/database/BookGroupTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { Book } from '../model/Book';
import { BookGroup, BookGroupItem, bookMatchesSystemGroup } from '../model/BookGroup';
import { BookCover } from '../components/BookCover';
import { BookshelfTransferService } from '../service/BookshelfTransferService';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { BookExportService, ExportBookInfo, ExportOptions } from '../service/BookExportService';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookChapter } from '../model/BookChapter';
import { BookSource } from '../model/BookSource';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { ArrayDataSource } from '../util/ArrayDataSource';

@Entry
@Component
struct BookshelfManagePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State allBooks: Book[] = [];
  @State books: Book[] = [];
  @State groups: BookGroupItem[] = [];
  @State selectedBookIds: number[] = [];
  @State selectedGroupId: number = BookGroup.ALL;
  @State searchText: string = '';
  @State isLoading: boolean = true;
  @State showGroupChooser: boolean = false;
  private bookDataSource_: ArrayDataSource<Book> = new ArrayDataSource<Book>();

  aboutToAppear(): void {
    this.loadData();
  }

  async loadData(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const groupDao = new BookGroupTable(db);
      this.groups = await groupDao.getAllGroups();
      this.allBooks = await bookDao.getAllShelfBooks();
      this.applyFilters();
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '加载书架失败', duration: 1500 });
    }
    this.isLoading = false;
  }

  applyFilters(): void {
    let result = [...this.allBooks];
    if (this.selectedGroupId < BookGroup.CUSTOM) {
      result = result.filter((book: Book): boolean => bookMatchesSystemGroup(book, this.selectedGroupId));
    } else {
      result = result.filter((book: Book): boolean => book.groupId === this.selectedGroupId);
    }
    const q = this.searchText.trim().toLowerCase();
    if (q) {
      result = result.filter((book: Book): boolean => {
        return book.name.toLowerCase().includes(q) || (book.author || '').toLowerCase().includes(q);
      });
    }
    this.books = result;
    this.bookDataSource_.reset(result);
    this.selectedBookIds = this.selectedBookIds.filter((id: number): boolean => result.some((book: Book): boolean => book.id === id));
  }

  isSelected(id: number): boolean {
    return this.selectedBookIds.includes(id);
  }

  toggleBook(id: number): void {
    if (this.isSelected(id)) {
      this.selectedBookIds = this.selectedBookIds.filter((item: number): boolean => item !== id);
    } else {
      this.selectedBookIds = [...this.selectedBookIds, id];
    }
  }

  selectAll(): void {
    if (this.selectedBookIds.length === this.books.length) {
      this.selectedBookIds = [];
    } else {
      this.selectedBookIds = this.books.map((book: Book): number => book.id);
    }
  }

  invertSelect(): void {
    const next: number[] = [];
    for (const book of this.books) {
      if (!this.selectedBookIds.includes(book.id)) next.push(book.id);
    }
    this.selectedBookIds = next;
  }

  selectedBooks(): Book[] {
    return this.books.filter((book: Book): boolean => this.selectedBookIds.includes(book.id));
  }

  requireSelection(): boolean {
    if (this.selectedBookIds.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '请先选择书籍', duration: 1500 });
      return false;
    }
    return true;
  }

  async removeSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '移出书架',
      message: '确定将选中的 ' + this.selectedBookIds.length + ' 本书移出书架？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '移出', fontColor: ThemeColors.error(this.isDark),
        action: async (): Promise<void> => {
          try {
            const bookDao = new BookTable(AppDatabase.getInstance().rdbStore);
            await bookDao.setShelfByIds(this.selectedBookIds, false);
            UiUtil.showToast(this.getUIContext(), { message: '已移出 ' + this.selectedBookIds.length + ' 本', duration: 1500 });
            this.selectedBookIds = [];
            await this.loadData();
            AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
          } catch (_e) {
            UiUtil.showToast(this.getUIContext(), { message: '操作失败', duration: 1500 });
          }
        }
      }
    });
  }

  async clearCacheSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const chapterDao = new ChapterTable(AppDatabase.getInstance().rdbStore);
      for (const id of this.selectedBookIds) {
        await chapterDao.clearContentByBookId(id);
      }
      UiUtil.showToast(this.getUIContext(), { message: '已清除章节缓存', duration: 1500 });
      await this.loadData();
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '清除失败', duration: 1500 });
    }
  }

  async cacheSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const chapterDao = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const sourceDao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources = await sourceDao.getAllSources();
      const cacheService = BookCacheService.getInstance();
      let startedBooks = 0;
      let queued = 0;
      for (const book of this.selectedBooks()) {
        const chapters = await chapterDao.getChaptersByBookId(book.id);
        if (chapters.length === 0) continue;
        const source = sources.find((s: BookSource): boolean =>
          s.sourceUrl === book.originUrl || s.sourceName === book.origin);
        if (!source || cacheService.isRunning(book.id)) continue;
        startedBooks++;
        queued += chapters.length;
        // 后台执行，不等待完成；进度在通知栏展示
        cacheService.cacheBook({
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
        }).then((result) => {
          if (result) {
            console.info('[BookshelfManage] cache done: ' + book.name
              + ' success=' + result.success + ' failed=' + result.failed);
          }
        }).catch((e: Error) => {
          console.warn('[BookshelfManage] cache fail: ' + book.name + ' - ' + e.message);
        });
      }
      UiUtil.showToast(this.getUIContext(), {
        message: startedBooks > 0
          ? '已开始缓存 ' + startedBooks + ' 本书（共 ' + queued + ' 章）'
          : '选中书籍无可用书源或目录为空',
        duration: 1800
      });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '加入缓存失败', duration: 1500 });
    }
  }

  async exportSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const json = await BookshelfTransferService.exportBookshelf(this.selectedBooks());
      const uris = await new picker.DocumentViewPicker().save({ newFileNames: ['bookshelf_selected.json'] });
      if (!uris || uris.length === 0) return;
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(f.fd, json);
      fileIo.closeSync(f);
      UiUtil.showToast(this.getUIContext(), { message: '已导出选中书籍', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '导出失败', duration: 1500 });
    }
  }

  /** 批量导出：先选格式（TXT / EPUB），再选目录，每本书导出一个文件 */
  chooseExportFormat(): void {
    if (!this.requireSelection()) return;
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '批量导出',
      message: '选择导出格式（每本书导出一个文件，自动下载缺失章节）',
      primaryButton: { value: 'TXT', action: (): void => { this.exportSelectedBooks('txt'); } },
      secondaryButton: { value: 'EPUB', action: (): void => { this.exportSelectedBooks('epub'); } },
    });
  }

  /** 批量导出到用户选择的目录 */
  async exportSelectedBooks(format: string): Promise<void> {
    const books = this.selectedBooks();
    const ext = format === 'epub' ? '.epub' : '.txt';
    let dirUri = '';
    try {
      const uris = await new picker.DocumentViewPicker().select({
        selectMode: picker.DocumentSelectMode.FOLDER,
      });
      if (!uris || uris.length === 0) return;
      dirUri = uris[0];
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '选择导出目录失败', duration: 1500 });
      return;
    }
    UiUtil.showToast(this.getUIContext(), { message: '开始导出 ' + books.length + ' 本书...', duration: 1500 });
    let success = 0;
    let failed = 0;
    for (const book of books) {
      try {
        const info: ExportBookInfo = {
          id: book.id,
          name: book.name,
          author: book.author,
          introduce: book.introduce,
          coverUrl: book.coverUrl,
          bookUrl: book.bookUrl,
          origin: book.origin,
          originUrl: book.originUrl,
        };
        const fileName = BookExportService.suggestFileName(info, ext);
        const options: ExportOptions = {
          includeTitle: true,
          useReplace: true,
          downloadMissing: true,
          context: UiUtil.getHostContext(this.getUIContext()),
        };
        const result = format === 'epub'
          ? await BookExportService.exportBookEpub(info, dirUri + '/' + fileName, options)
          : await BookExportService.exportBookTxt(info, dirUri + '/' + fileName, options);
        if (result.success) {
          success++;
        } else {
          failed++;
          console.warn('[BookshelfManage] export fail: ' + book.name + ' - ' + result.error);
        }
      } catch (e) {
        failed++;
        console.warn('[BookshelfManage] export error: ' + book.name + ' - ' + (e as Error).message);
      }
    }
    UiUtil.showToast(this.getUIContext(), {
      message: '导出完成：成功 ' + success + ' 本，失败 ' + failed + ' 本',
      duration: 2500
    });
  }

  async moveSelectedToGroup(groupId: number): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const bookDao = new BookTable(AppDatabase.getInstance().rdbStore);
      await bookDao.batchUpdateGroup(this.selectedBookIds, groupId);
      this.showGroupChooser = false;
      UiUtil.showToast(this.getUIContext(), { message: '已移动分组', duration: 1500 });
      this.selectedBookIds = [];
      await this.loadData();
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '移动失败', duration: 1500 });
    }
  }

  groupName(id: number): string {
    const group = this.groups.find((item: BookGroupItem): boolean => item.id === id);
    return group ? group.name : '全部';
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Button() { Text($r('app.string.ui_8179643cdc')).fontSize(20).fontColor(ThemeColors.primary(this.isDark)) }
            .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.common_back'))
            .onClick(() => { UiUtil.back(this.getUIContext()); })
          Text($r('app.string.ui_4f5a0869c2')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text('选中 ' + this.selectedBookIds.length).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        }
        .width('100%').height(56).padding({ left: 8, right: 12 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

        Row() {
          TextInput({ placeholder: $r('app.string.ui_2c643fe94c'), text: this.searchText })
            .width('100%').height(44)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(22).padding({ left: 14, right: 14 }).fontSize(14)
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .onChange((value: string): void => { this.searchText = value; this.applyFilters(); })
        }.width('100%').padding({ left: 12, right: 12, top: 10 })

        Scroll() {
          Row() {
            ForEach(this.groups, (group: BookGroupItem) => {
              Button(group.name).fontSize(13)
                .height(40).padding({ left: 12, right: 12 }).margin({ right: 8 })
                .fontColor(this.selectedGroupId === group.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .backgroundColor(this.selectedGroupId === group.id ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                .borderRadius(20)
                .onClick((): void => {
                  this.selectedGroupId = group.id;
                  this.applyFilters();
                })
            })
          }.padding({ left: 12, right: 12, top: 10, bottom: 8 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')

        Row() {
          Button($r('app.string.common_select_all')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.selectAll(); })
          Button($r('app.string.common_invert_selection')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.invertSelect(); })
          Button($r('app.string.ui_591f3aa55f')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { if (this.requireSelection()) this.showGroupChooser = true; })
          Button($r('app.string.ui_6938ad92fa')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.exportSelected(); })
          Button($r('app.string.common_export')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.chooseExportFormat(); })
          Button($r('app.string.ui_6cdba4aad0')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.cacheSelected(); })
          Button($r('app.string.ui_36528cefed')).fontSize(13).fontColor(ThemeColors.error(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.clearCacheSelected(); })
          Button($r('app.string.ui_0d01c5a3a2')).fontSize(13).fontColor(ThemeColors.error(this.isDark)).backgroundColor(Color.Transparent)
            .height(40).padding({ left: 8, right: 8 }).onClick(() => { this.removeSelected(); })
        }
        .width('100%').padding({ left: 6, right: 6 }).backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { top: 0.5, bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

        Text(this.groupName(this.selectedGroupId) + ' · ' + this.books.length + ' 本')
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').padding({ left: 12, top: 8, bottom: 4 })

        if (this.isLoading) {
          LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 40 })
        } else {
          List() {
            LazyForEach(this.bookDataSource_, (book: Book) => {
              ListItem() {
                Row() {
                  Checkbox().select(this.isSelected(book.id))
                    .onChange((_checked: boolean): void => { this.toggleBook(book.id); })
                    .margin({ right: 8 })
                  BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: 42, coverHeight: 58 })
                    .margin({ right: 10 })
                  Column() {
                    Text(book.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Row() {
                      Text(book.author || '未知作者').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                      Text(this.groupName(book.groupId)).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                    }.width('100%').margin({ top: 4 })
                    if (book.latestChapterTitle) {
                      Text('最新: ' + book.latestChapterTitle).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 2 })
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }
                .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
              }
              .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
              .onClick((): void => { this.toggleBook(book.id); })
            }, (book: Book): string => String(book.id))
          }.width('100%').layoutWeight(1)
        }
      }
      .width('100%').height('100%')
      .backgroundColor(ThemeColors.background(this.isDark))

      if (this.showGroupChooser) {
        Column().width('100%').height('100%').backgroundColor(ThemeColors.scrim(this.isDark))
          .onClick((): void => { this.showGroupChooser = false; })
        Column() {
          Text($r('app.string.ui_fe238ad8bf')).fontSize(16).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onSurface(this.isDark))
            .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 8 })
          List() {
            ForEach(this.groups, (group: BookGroupItem) => {
              if (group.id === BookGroup.ALL || group.id >= BookGroup.CUSTOM) {
                ListItem() {
                  Row() {
                    Text(group.name).fontSize(15).layoutWeight(1).fontColor(ThemeColors.onSurface(this.isDark))
                    Text($r('app.string.ui_60ecbc7f40')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
                  }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                }.onClick((): void => { this.moveSelectedToGroup(group.id); })
              }
            })
          }.width('100%').height(260)
          Row() {
            Button($r('app.string.common_cancel')).height(48).width('100%')
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(24)
              .onClick((): void => { this.showGroupChooser = false; })
          }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 16 })
        }
        .position({ left: 0, bottom: 0 }).width('100%')
        .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 })
      }
    }
    .width('100%').height('100%')
  }
}
