/**
 * 书签管理页（全局）
 * - 按书分组展示全部书签
 * - 搜索：书名/章节名/原文/笔记
 * - 点击书签跳转到阅读位置（章节 + 字符偏移）
 * - 编辑（原文/笔记）与删除
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookmarkTable } from '../data/database/BookmarkTable';
import { BookTable } from '../data/database/BookTable';
import { Bookmark } from '../model/Bookmark';
import { Book } from '../model/Book';
import { BookmarkEditDialog } from '../components/reader/BookmarkEditDialog';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

interface BookmarkGroup {
  bookId: number;
  bookName: string;
  bookAuthor: string;
  items: Bookmark[];
}

@Entry
@Component
struct BookmarkPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State groups: BookmarkGroup[] = [];
  @State searchText: string = '';
  @State isLoading: boolean = true;
  @State showEditDlg: boolean = false;

  private allBookmarks: Bookmark[] = [];
  private editingBookmark_: Bookmark | null = null;

  aboutToAppear(): void {
    this.loadBookmarks();
  }

  private async loadBookmarks(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      this.allBookmarks = await new BookmarkTable(AppDatabase.getInstance().rdbStore).getAll();
      this.applyFilter();
    } catch (e) {
      console.warn('[BookmarkPage] load fail:', (e as Error).message);
    }
    this.isLoading = false;
  }

  private applyFilter(): void {
    const q = this.searchText.trim().toLowerCase();
    const filtered = q
      ? this.allBookmarks.filter((b: Bookmark): boolean => {
        return b.bookName.toLowerCase().includes(q)
          || b.chapterName.toLowerCase().includes(q)
          || b.text.toLowerCase().includes(q)
          || b.note.toLowerCase().includes(q);
      })
      : this.allBookmarks;
    const byBook = new Map<number, BookmarkGroup>();
    for (const b of filtered) {
      let g = byBook.get(b.bookId);
      if (!g) {
        g = { bookId: b.bookId, bookName: b.bookName, bookAuthor: b.bookAuthor, items: [] };
        byBook.set(b.bookId, g);
      }
      g.items.push(b);
    }
    this.groups = Array.from(byBook.values());
  }

  private formatTime(ts: number): string {
    if (!ts) return '';
    const d = new Date(ts);
    const pad = (n: number): string => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 点击书签 → 跳转到阅读位置（章节索引 + 字符偏移） */
  private async openBookmark(b: Bookmark): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const book = await new BookTable(AppDatabase.getInstance().rdbStore).getBookById(b.bookId);
      if (!book) {
        UiUtil.showToast(this.getUIContext(), { message: '书籍已删除，无法跳转', duration: 1500 });
        return;
      }
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/ReadPage',
        params: {
          bookName: book.name,
          bookAuthor: book.author,
          bookUrl: book.bookUrl,
          tocUrl: book.tocUrl,
          origin: book.origin,
          originUrl: book.originUrl,
          durChapterIndex: b.chapterIndex,
          durCharPos: b.chapterPos,
        }
      });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '打开失败', duration: 1500 });
    }
  }

  private openEdit(b: Bookmark): void {
    this.editingBookmark_ = b;
    this.showEditDlg = true;
  }

  private async saveEdit(text: string, note: string): Promise<void> {
    this.showEditDlg = false;
    const b = this.editingBookmark_;
    if (!b) return;
    try {
      b.text = text;
      b.note = note;
      b.updateTime = Date.now();
      await new BookmarkTable(AppDatabase.getInstance().rdbStore).update(b);
      UiUtil.showToast(this.getUIContext(), { message: '已保存', duration: 1200 });
      this.loadBookmarks();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '保存失败', duration: 1500 });
    }
  }

  private confirmDelete(): void {
    const b = this.editingBookmark_;
    if (!b) return;
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '删除书签',
      message: '删除「' + (b.chapterName || '未命名章节') + '」处的书签？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除', fontColor: ThemeColors.error(this.isDark),
        action: async (): Promise<void> => {
          this.showEditDlg = false;
          await new BookmarkTable(AppDatabase.getInstance().rdbStore).delete(b.id);
          UiUtil.showToast(this.getUIContext(), { message: '已删除', duration: 1200 });
          this.loadBookmarks();
        }
      }
    });
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_backward')).fontSize(24)
              .fontColor([ThemeColors.onSurface(this.isDark)])
          }
            .width(48).height(48).padding(0).borderRadius(24)
            .backgroundColor(Color.Transparent).accessibilityText($r('app.string.common_back'))
            .onClick(() => { UiUtil.back(this.getUIContext()); })
          Text($r('app.string.ui_literal_820f5b6440')).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        }
        .width('100%').height(56).padding({ left: 8, right: 12 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

        // 搜索框
        Row() {
          TextInput({ placeholder: '搜索书名 / 章节 / 原文 / 笔记', text: this.searchText })
            .width('100%').height(44)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(22)
            .padding({ left: 14, right: 14 }).fontSize(14)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .onChange((v: string) => { this.searchText = v; this.applyFilter(); })
        }.width('100%').padding({ left: 12, right: 12, top: 10 })

        if (this.isLoading) {
          LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 60 })
        } else if (this.groups.length === 0) {
          Text(this.searchText ? '没有匹配的书签' : '暂无书签\n阅读时可通过底部菜单「书签」添加')
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
            .textAlign(TextAlign.Center)
            .margin({ top: 80 })
        } else {
          List() {
            ForEach(this.groups, (g: BookmarkGroup) => {
              ListItemGroup({ header: this.groupHeader(g) }) {
                ForEach(g.items, (b: Bookmark) => {
                  ListItem() {
                    Column() {
                      Row() {
                        Text(b.chapterName || '未命名章节')
                          .fontSize(14).fontWeight(FontWeight.Medium)
                          .fontColor(ThemeColors.onBackground(this.isDark))
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(this.formatTime(b.createTime))
                          .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                          .margin({ left: 8 })
                      }.width('100%')

                      if (b.text) {
                        Text(b.text).fontSize(13)
                          .fontColor(ThemeColors.secondaryText(this.isDark))
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%').margin({ top: 4 })
                      }
                      if (b.note) {
                        Text(b.note).fontSize(13)
                          .fontColor(ThemeColors.primary(this.isDark))
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%').margin({ top: 4 })
                      }

                      Row() {
                        Text($r('app.string.ui_literal_28cd2efd8f')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
                          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                          .onClick(() => { this.openBookmark(b); })
                        Text($r('app.string.ui_literal_a7f814c0a4')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                          .margin({ left: 8 })
                          .onClick(() => { this.openEdit(b); })
                      }.width('100%').justifyContent(FlexAlign.End).margin({ top: 2 })
                    }
                    .width('100%').alignItems(HorizontalAlign.Start)
                    .padding({ left: 16, right: 16, top: 10, bottom: 8 })
                  }
                  .onClick(() => { this.openBookmark(b); })
                }, (b: Bookmark): string => { return String(b.id); })
              }
            }, (g: BookmarkGroup): string => { return String(g.bookId); })
          }
          .width('100%').layoutWeight(1)
          .sticky(StickyStyle.Header)
        }
      }
      .width('100%').height('100%')
      .backgroundColor(ThemeColors.background(this.isDark))

      if (this.showEditDlg && this.editingBookmark_) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showEditDlg = false; })
          BookmarkEditDialog({
            title: '编辑书签',
            initialText: this.editingBookmark_!.text,
            initialNote: this.editingBookmark_!.note,
            showDelete: true,
            onSave: (text: string, note: string) => { this.saveEdit(text, note); },
            onDelete: () => { this.confirmDelete(); },
            onDismiss: () => { this.showEditDlg = false; },
          })
        }.width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  groupHeader(g: BookmarkGroup) {
    Row() {
      Text(g.bookName).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(' · ' + (g.bookAuthor || '未知作者') + ' · ' + g.items.length + ' 条')
        .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 6 })
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
