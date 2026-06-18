/**
 * 章节管理器
 *
 * 管理书籍的目录、当前阅读位置、章节切换逻辑。
 */
import { Book } from '../../model/Book';
import { BookChapter } from '../../model/BookChapter';
import { ChapterTable } from '../../data/database/ChapterTable';

export class ChapterManager {
  private chapterTable_: ChapterTable | null = null;
  private chapters_: BookChapter[] = [];
  private currentChapterIndex_: number = 0;
  private currentBook_: Book | null = null;

  get chapters(): BookChapter[] { return this.chapters_; }
  get currentIndex(): number { return this.currentChapterIndex_; }
  get currentChapter(): BookChapter | null {
    return this.chapters_[this.currentChapterIndex_] || null;
  }
  get totalChapters(): number { return this.chapters_.length; }
  get progress(): number {
    if (this.totalChapters <= 0) return 0;
    return (this.currentChapterIndex_ + 1) / this.totalChapters;
  }

  /**
   * 初始化章节列表
   */
  async init(rdbStore: any, book: Book): Promise<void> {
    this.currentBook_ = book;
    this.chapterTable_ = new ChapterTable(rdbStore);
    this.chapters_ = await this.chapterTable_.getChaptersByBookId(book.id);
    this.currentChapterIndex_ = Math.min(book.durChapterIndex, this.chapters_.length - 1);
    if (this.currentChapterIndex_ < 0) this.currentChapterIndex_ = 0;
  }

  /**
   * 从外部设置章节列表（书源获取后）
   */
  setChapters(chapters: BookChapter[]): void {
    this.chapters_ = chapters;
  }

  /**
   * 跳转到指定章节
   */
  goToChapter(index: number): BookChapter | null {
    if (index < 0 || index >= this.chapters_.length) return null;
    this.currentChapterIndex_ = index;
    return this.chapters_[index];
  }

  /**
   * 上一章
   */
  prevChapter(): BookChapter | null {
    return this.goToChapter(this.currentChapterIndex_ - 1);
  }

  /**
   * 下一章
   */
  nextChapter(): BookChapter | null {
    return this.goToChapter(this.currentChapterIndex_ + 1);
  }

  /**
   * 获取章节内容（优先缓存，否则从书源获取）
   */
  async getChapterContent(
    chapter: BookChapter,
    contentFetcher?: (url: string) => Promise<string>
  ): Promise<string> {
    if (chapter.content) return chapter.content;

    if (contentFetcher && chapter.url) {
      try {
        const content = await contentFetcher(chapter.url);
        chapter.content = content;
        chapter.isCached = true;
        // 异步写入数据库
        if (this.chapterTable_) {
          await this.chapterTable_.updateChapter(chapter).catch(() => {});
        }
        return content;
      } catch (err) {
        console.error('[ChapterManager] Fetch content failed:', err);
        return '加载失败: ' + err.message;
      }
    }

    return '内容加载中...';
  }

  /**
   * 标记章节为已读
   */
  async markAsRead(index: number): Promise<void> {
    if (index >= 0 && index < this.chapters_.length) {
      this.chapters_[index].isRead = true;
      if (this.chapterTable_) {
        await this.chapterTable_.updateChapter(this.chapters_[index]).catch(() => {});
      }
    }
  }
}
