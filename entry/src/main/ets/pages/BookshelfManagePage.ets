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
import { DownloadService } from '../service/DownloadService';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';

@Entry
@Component
struct BookshelfManagePage {
  @State allBooks: Book[] = [];
  @State books: Book[] = [];
  @State groups: BookGroupItem[] = [];
  @State selectedBookIds: number[] = [];
  @State selectedGroupId: number = BookGroup.ALL;
  @State searchText: string = '';
  @State isLoading: boolean = true;
  @State showGroupChooser: boolean = false;

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
      promptAction.showToast({ message: '加载书架失败', duration: 1500 });
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
      promptAction.showToast({ message: '请先选择书籍', duration: 1500 });
      return false;
    }
    return true;
  }

  async removeSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    AlertDialog.show({
      title: '移出书架',
      message: '确定将选中的 ' + this.selectedBookIds.length + ' 本书移出书架？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '移出', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            const bookDao = new BookTable(AppDatabase.getInstance().rdbStore);
            await bookDao.setShelfByIds(this.selectedBookIds, false);
            promptAction.showToast({ message: '已移出 ' + this.selectedBookIds.length + ' 本', duration: 1500 });
            this.selectedBookIds = [];
            await this.loadData();
            AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
          } catch (_e) {
            promptAction.showToast({ message: '操作失败', duration: 1500 });
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
        await chapterDao.deleteChaptersByBookId(id);
      }
      promptAction.showToast({ message: '已清除章节缓存', duration: 1500 });
      await this.loadData();
    } catch (_e) {
      promptAction.showToast({ message: '清除失败', duration: 1500 });
    }
  }

  async cacheSelected(): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const chapterDao = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const download = DownloadService.getInstance();
      let queued = 0;
      for (const book of this.selectedBooks()) {
        const chapters = await chapterDao.getChaptersByBookId(book.id);
        if (chapters.length === 0) continue;
        await download.downloadBook(book, chapters);
        queued += chapters.length;
      }
      promptAction.showToast({ message: queued > 0 ? '已加入缓存队列 ' + queued + ' 章' : '选中书籍暂无目录', duration: 1800 });
    } catch (_e) {
      promptAction.showToast({ message: '加入缓存失败', duration: 1500 });
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
      promptAction.showToast({ message: '已导出选中书籍', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '导出失败', duration: 1500 });
    }
  }

  async moveSelectedToGroup(groupId: number): Promise<void> {
    if (!this.requireSelection()) return;
    try {
      const bookDao = new BookTable(AppDatabase.getInstance().rdbStore);
      await bookDao.batchUpdateGroup(this.selectedBookIds, groupId);
      this.showGroupChooser = false;
      promptAction.showToast({ message: '已移动分组', duration: 1500 });
      this.selectedBookIds = [];
      await this.loadData();
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
    } catch (_e) {
      promptAction.showToast({ message: '移动失败', duration: 1500 });
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
          Button() { Text('←').fontSize(20).fontColor('#0078D7') }
            .backgroundColor(Color.Transparent)
            .onClick(() => { router.back(); })
          Text('书架管理').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text('选中 ' + this.selectedBookIds.length).fontSize(13).fontColor('#888')
        }
        .width('100%').height(56).padding({ left: 8, right: 12 })
        .backgroundColor('#FFF')
        .border({ width: { bottom: 0.5 }, color: '#E8E8E8' })

        TextInput({ placeholder: '搜索书名或作者', text: this.searchText })
          .width('calc(100% - 24)').height(36).margin({ left: 12, right: 12, top: 10 })
          .backgroundColor('#F5F5F5').borderRadius(18).padding({ left: 12 }).fontSize(14)
          .onChange((value: string): void => { this.searchText = value; this.applyFilters(); })

        Scroll() {
          Row() {
            ForEach(this.groups, (group: BookGroupItem) => {
              Button(group.name).fontSize(13)
                .height(30).padding({ left: 12, right: 12 }).margin({ right: 8 })
                .fontColor(this.selectedGroupId === group.id ? '#FFF' : '#555')
                .backgroundColor(this.selectedGroupId === group.id ? '#0078D7' : '#EEE')
                .borderRadius(15)
                .onClick((): void => {
                  this.selectedGroupId = group.id;
                  this.applyFilters();
                })
            })
          }.padding({ left: 12, right: 12, top: 10, bottom: 8 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')

        Row() {
          Button('全选').fontSize(13).fontColor('#0078D7').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.selectAll(); })
          Button('反选').fontSize(13).fontColor('#0078D7').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.invertSelect(); })
          Button('移动').fontSize(13).fontColor('#0078D7').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { if (this.requireSelection()) this.showGroupChooser = true; })
          Button('导出').fontSize(13).fontColor('#0078D7').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.exportSelected(); })
          Button('缓存').fontSize(13).fontColor('#0078D7').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.cacheSelected(); })
          Button('清缓存').fontSize(13).fontColor('#FF9800').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.clearCacheSelected(); })
          Button('移出').fontSize(13).fontColor('#F44336').backgroundColor(Color.Transparent)
            .height(34).padding({ left: 8, right: 8 }).onClick(() => { this.removeSelected(); })
        }
        .width('100%').padding({ left: 6, right: 6 }).backgroundColor('#FAFAFA')
        .border({ width: { top: 0.5, bottom: 0.5 }, color: '#E8E8E8' })

        Text(this.groupName(this.selectedGroupId) + ' · ' + this.books.length + ' 本')
          .fontSize(12).fontColor('#888').width('100%').padding({ left: 12, top: 8, bottom: 4 })

        if (this.isLoading) {
          LoadingProgress().color('#0078D7').margin({ top: 40 })
        } else {
          List() {
            ForEach(this.books, (book: Book) => {
              ListItem() {
                Row() {
                  Checkbox().select(this.isSelected(book.id))
                    .onChange((_checked: boolean): void => { this.toggleBook(book.id); })
                    .margin({ right: 8 })
                  BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: 42, coverHeight: 58 })
                    .margin({ right: 10 })
                  Column() {
                    Text(book.name).fontSize(14).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Row() {
                      Text(book.author || '未知作者').fontSize(12).fontColor('#888')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                      Text(this.groupName(book.groupId)).fontSize(11).fontColor('#999')
                    }.width('100%').margin({ top: 4 })
                    if (book.latestChapterTitle) {
                      Text('最新: ' + book.latestChapterTitle).fontSize(11).fontColor('#999')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 2 })
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }
                .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
              }
              .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
              .onClick((): void => { this.toggleBook(book.id); })
            })
          }.width('100%').layoutWeight(1)
        }
      }
      .width('100%').height('100%')
      .backgroundColor('#FFF')

      if (this.showGroupChooser) {
        Column().width('100%').height('100%').backgroundColor('#66000000')
          .onClick((): void => { this.showGroupChooser = false; })
        Column() {
          Text('移动到分组').fontSize(16).fontWeight(FontWeight.Bold)
            .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 8 })
          List() {
            ForEach(this.groups, (group: BookGroupItem) => {
              if (group.id === BookGroup.ALL || group.id >= BookGroup.CUSTOM) {
                ListItem() {
                  Row() {
                    Text(group.name).fontSize(15).layoutWeight(1)
                    Text('›').fontSize(16).fontColor('#CCC')
                  }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                }.onClick((): void => { this.moveSelectedToGroup(group.id); })
              }
            })
          }.width('100%').height(260)
          Button('取消').height(40).width('calc(100% - 32)').margin({ left: 16, right: 16, top: 8, bottom: 16 })
            .backgroundColor('#EEE').fontColor('#666').borderRadius(8)
            .onClick((): void => { this.showGroupChooser = false; })
        }
        .position({ left: 0, bottom: 0 }).width('100%')
        .backgroundColor('#FFF').borderRadius({ topLeft: 16, topRight: 16 })
      }
    }
    .width('100%').height('100%')
  }
}
