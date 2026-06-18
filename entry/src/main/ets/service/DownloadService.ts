/**
 * 下载服务
 * 负责章节缓存、书籍下载、批量下载
 */
import { BookChapter } from '../model/BookChapter';
import { Book } from '../model/Book';
import { NetUtil } from '../util/NetUtil';
import { AppDatabase } from '../data/database/AppDatabase';
import { ChapterTable } from '../data/database/ChapterTable';

export type DownloadTaskStatus = 'queued' | 'downloading' | 'completed' | 'failed';

export interface DownloadTask {
  id: string;
  bookId: number;
  chapterIndex: number;
  url: string;
  status: DownloadTaskStatus;
  progress: number;    // 0-100
  errorMsg: string;
}

export class DownloadService {
  private static instance: DownloadService;
  private tasks: Map<string, DownloadTask> = new Map();
  private queue: DownloadTask[] = [];
  private maxConcurrent: number = 3;
  private activeCount: number = 0;
  private chapterTable: ChapterTable | null = null;

  private constructor() {
    this.chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
  }

  static getInstance(): DownloadService {
    if (!DownloadService.instance) {
      DownloadService.instance = new DownloadService();
    }
    return DownloadService.instance;
  }

  /**
   * 添加下载任务
   */
  addTask(bookId: number, chapterIndex: number, url: string): string {
    const id = `${bookId}_${chapterIndex}`;
    if (this.tasks.has(id)) return id;

    const task: DownloadTask = {
      id, bookId, chapterIndex, url,
      status: 'queued', progress: 0, errorMsg: '',
    };

    this.tasks.set(id, task);
    this.queue.push(task);
    this.processQueue();

    return id;
  }

  /**
   * 批量下载章节
   */
  async downloadChapters(bookId: number, chapters: BookChapter[]): Promise<void> {
    for (const chapter of chapters) {
      if (chapter.isDownloaded || chapter.isCached) continue;
      this.addTask(bookId, chapter.index, chapter.url);
    }
  }

  /**
   * 下载整本书
   */
  async downloadBook(book: Book, chapters: BookChapter[]): Promise<void> {
    await this.downloadChapters(book.id, chapters);
  }

  /**
   * 获取所有任务
   */
  getTasks(): DownloadTask[] {
    return Array.from(this.tasks.values());
  }

  /**
   * 获取任务进度
   */
  getProgress(): { completed: number; total: number } {
    let completed = 0;
    let total = 0;
    for (const task of this.tasks.values()) {
      total++;
      if (task.status === 'completed') completed++;
    }
    return { completed, total };
  }

  private async processQueue(): Promise<void> {
    while (this.activeCount < this.maxConcurrent && this.queue.length > 0) {
      const task = this.queue.shift()!;
      this.activeCount++;
      task.status = 'downloading';

      this.executeTask(task).finally(() => {
        this.activeCount--;
        this.processQueue();
      });
    }
  }

  private async executeTask(task: DownloadTask): Promise<void> {
    try {
      const content = await NetUtil.httpGet(task.url);
      task.progress = 100;
      task.status = 'completed';

      // 保存到数据库
      if (this.chapterTable) {
        const chapter = await this.chapterTable.getChapterByIndex(task.bookId, task.chapterIndex);
        if (chapter) {
          chapter.content = content;
          chapter.isDownloaded = true;
          chapter.isCached = true;
          await this.chapterTable.updateChapter(chapter);
        }
      }
    } catch (err) {
      task.status = 'failed';
      task.errorMsg = err.message;
      console.error(`[Download] Task ${task.id} failed:`, err);
    }
  }
}
