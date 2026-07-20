/**
 * 书籍章节缓存下载服务（统一入口）
 *
 * 合并原 CacheDialog 内联顺序循环与 DownloadService 两套逻辑：
 * - 并发下载（默认 4，上限 8）
 * - 单章失败自动重试 3 次
 * - 自动跳过已缓存章节
 * - 通知栏进度（每书一个通知）
 * - 传入 context 时启动后台任务保活
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookChapter, createDefaultChapter } from '../model/BookChapter';
import { BookSource, isImageSource } from '../model/BookSource';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import notificationManager from '@ohos.notificationManager';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';

/** 待缓存章节的最小信息（BookChapter / BookSourceChapter 均可适配） */
export interface CacheChapterItem {
  index: number;
  title: string;
  url: string;
}

export interface CacheBookRequest {
  bookId: number;
  bookName: string;
  /** 书籍详情页 URL，作为 getContent 的 bookUrl 参数 */
  bookUrl: string;
  source: BookSource;
  chapters: CacheChapterItem[];
  /** 起始章节索引（含，0 基）；指定了 indices 时忽略 */
  startIndex: number;
  /** 结束章节索引（含，0 基）；指定了 indices 时忽略 */
  endIndex: number;
  /** 可选：显式章节索引列表（多选缓存场景），去重排序后生效 */
  indices?: number[];
  /** 传入则下载期间保持后台运行 */
  context?: common.Context;
  onProgress?: (done: number, total: number, currentTitle: string) => void;
}

export interface CacheBookResult {
  total: number;
  skipped: number;
  success: number;
  failed: number;
  cancelled: boolean;
}

interface ActiveTask {
  cancelled: boolean;
  done: number;
  total: number;
}

/** 缓存任务进度快照 */
export interface CacheProgress {
  done: number;
  total: number;
}

export class BookCacheService {
  private static instance_: BookCacheService;

  static getInstance(): BookCacheService {
    if (!BookCacheService.instance_) {
      BookCacheService.instance_ = new BookCacheService();
    }
    return BookCacheService.instance_;
  }

  /** 每本书同时只允许一个缓存任务 */
  private activeTasks_: Map<number, ActiveTask> = new Map();
  /** 正在进行后台保活的任务数 */
  private bgTaskCount_: number = 0;

  /** 并发数（对齐安卓上限 8） */
  readonly concurrency: number = 4;
  /** 单章失败重试次数（对齐安卓 3 次） */
  readonly maxRetry: number = 3;

  isRunning(bookId: number): boolean {
    return this.activeTasks_.has(bookId);
  }

  /** 请求取消某书的缓存任务（正在下载的章节会完成后停止） */
  cancel(bookId: number): void {
    const task = this.activeTasks_.get(bookId);
    if (task) task.cancelled = true;
  }

  /** 查询进行中任务的进度（供缓存管理页轮询），无任务返回 null */
  getProgress(bookId: number): CacheProgress | null {
    const task = this.activeTasks_.get(bookId);
    if (!task) return null;
    return { done: task.done, total: task.total };
  }

  /**
   * 缓存指定范围的章节内容到 chapters 表。
   * 返回 null 表示该书已有缓存任务在进行中。
   */
  async cacheBook(req: CacheBookRequest): Promise<CacheBookResult | null> {
    if (this.activeTasks_.has(req.bookId)) return null;

    const result: CacheBookResult = { total: 0, skipped: 0, success: 0, failed: 0, cancelled: false };
    let indices: number[] = [];
    if (req.indices && req.indices.length > 0) {
      const set = new Set<number>();
      for (const i of req.indices) {
        if (i >= 0 && i < req.chapters.length) set.add(i);
      }
      indices = Array.from(set).sort((a: number, b: number): number => a - b);
    } else {
      const start = Math.max(0, req.startIndex);
      const end = Math.min(req.endIndex, req.chapters.length - 1);
      for (let i = start; i <= end; i++) indices.push(i);
    }
    console.info('[BookCache] start bookId=' + req.bookId + ' chapters=' + req.chapters.length
      + ' count=' + indices.length);
    if (indices.length === 0 || req.bookId <= 0) {
      console.warn('[BookCache] invalid request: bookId=' + req.bookId + ' count=' + indices.length);
      return result;
    }
    result.total = indices.length;

    const task: ActiveTask = { cancelled: false, done: 0, total: indices.length };
    this.activeTasks_.set(req.bookId, task);
    const notifId = 2000 + (req.bookId % 10000);
    if (req.context) this.startBgTask(req.context);

    await AppDatabase.getInstance().waitForInit();
    const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);

    let done = 0;
    let cursor = 0;
    const updateProgress = (title: string): void => {
      task.done = done;
      this.reportProgress(req, done, result.total, title, notifId);
    };
    const worker = async (): Promise<void> => {
      while (!task.cancelled) {
        const pos = cursor++;
        if (pos >= indices.length) break;
        const idx = indices[pos];
        const ch = req.chapters[idx];
        if (!ch) {
          result.failed++;
          done++;
          continue;
        }

        try {
          // 已缓存的跳过；漫画源额外校验：旧版缓存不含图片（下载时未保留 <img>），视为未缓存重新下载
          const existing = await chapterTable.getChapterByIndex(req.bookId, idx);
          const isImage = isImageSource(req.source);
          if (existing && (existing.isCached || existing.isDownloaded) && existing.content.length > 10) {
            const badComicCache = isImage &&
              globalSourceExecutor.extractImageUrls(existing.content, ch.url || req.bookUrl).length === 0;
            if (!badComicCache) {
              // 内容已缓存；漫画源仍需补齐本章图片（离线可看的必要条件）
              if (isImage) {
                await this.cacheChapterImages_(req, ch, existing.content, task);
              }
              result.skipped++;
              done++;
              updateProgress(ch.title || '');
              continue;
            }
          }

          const content = await this.downloadWithRetry(req, ch);
          if (task.cancelled) break;

          if (content && content.length > 10) {
            await this.saveContent(chapterTable, req.bookId, idx, ch, content, existing);
            if (isImage) {
              await this.cacheChapterImages_(req, ch, content, task);
            }
            result.success++;
          } else {
            result.failed++;
            console.warn('[BookCache] empty content, chapter ' + (idx + 1) + ': ' + ch.title);
          }
        } catch (err) {
          result.failed++;
          console.warn('[BookCache] failed chapter ' + (idx + 1) + ': ' + (err as Error).message);
        }
        done++;
        updateProgress(ch.title || '');
      }
    };

    try {
      const workers: Promise<void>[] = [];
      const n = Math.min(this.concurrency, indices.length);
      for (let w = 0; w < n; w++) workers.push(worker());
      await Promise.all(workers);
    } finally {
      result.cancelled = task.cancelled;
      this.activeTasks_.delete(req.bookId);
      this.publishNotif(notifId, '离线缓存' + (result.cancelled ? '已取消' : '完成'),
        '《' + req.bookName + '》 成功 ' + result.success + ' 章，失败 ' + result.failed + ' 章');
      if (req.context) this.stopBgTask(req.context);
    }
    return result;
  }

  private async downloadWithRetry(req: CacheBookRequest, ch: CacheChapterItem): Promise<string> {
    if (!ch.url) return '';
    let lastErr: Error | null = null;
    for (let attempt = 1; attempt <= this.maxRetry; attempt++) {
      try {
        const content = await globalSourceExecutor.getContent(req.source, ch.url, req.bookUrl, isImageSource(req.source));
        if (content && content.length > 10) return content;
        if (attempt < this.maxRetry) await this.sleep(500 * attempt);
      } catch (err) {
        lastErr = err as Error;
        if (attempt < this.maxRetry) await this.sleep(500 * attempt);
      }
    }
    if (lastErr) console.warn('[BookCache] retry exhausted: ' + ch.title + ' - ' + lastErr.message);
    return '';
  }

  private async saveContent(chapterTable: ChapterTable, bookId: number, idx: number,
    ch: CacheChapterItem, content: string, existing: BookChapter | null): Promise<void> {
    const now = Date.now();
    if (existing) {
      existing.content = content;
      existing.contentLength = content.length;
      existing.isDownloaded = true;
      existing.isCached = true;
      existing.updateTime = now;
      await chapterTable.updateChapter(existing);
    } else {
      const newCh = createDefaultChapter();
      newCh.bookId = bookId;
      newCh.index = idx;
      newCh.title = ch.title || '';
      newCh.url = ch.url || '';
      newCh.content = content;
      newCh.contentLength = content.length;
      newCh.isDownloaded = true;
      newCh.isCached = true;
      newCh.createTime = now;
      newCh.updateTime = now;
      await chapterTable.insertChapters([newCh]);
    }
  }

  /** 漫画章节：下载本章全部图片到本地图片缓存（load 自带已缓存跳过/在途去重/队列） */
  private async cacheChapterImages_(req: CacheBookRequest, ch: CacheChapterItem, content: string, task: ActiveTask): Promise<void> {
    const urls: string[] = globalSourceExecutor.extractImageUrls(content, ch.url || req.bookUrl);
    for (const u of urls) {
      if (task.cancelled) return;
      try {
        await MangaImageLoader.load(u, req.source);
      } catch (err) {
        console.warn('[BookCache] image failed: ' + (err as Error).message);
      }
    }
  }

  private reportProgress(req: CacheBookRequest, done: number, total: number, title: string, notifId: number): void {
    if (req.onProgress) req.onProgress(done, total, title);
    this.publishNotif(notifId, '离线缓存', '《' + req.bookName + '》 ' + done + '/' + total + ' 章');
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => { setTimeout(resolve, ms); });
  }

  private publishNotif(id: number, title: string, text: string): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          contentType: 0,
          normal: { title: title, text: text },
        },
      };
      notificationManager.publish(request, (err: Error) => {
        if (err) console.warn('[BookCache] notif error:', err.message);
      });
    } catch (e) {
      console.warn('[BookCache] notif error:', (e as Error).message);
    }
  }

  private async startBgTask(context: common.Context): Promise<void> {
    this.bgTaskCount_++;
    if (this.bgTaskCount_ > 1) return;
    try {
      const want = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'io.legado.hos', abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
      });
      await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], want);
      console.info('[BookCache] bg task started');
    } catch (e) {
      console.warn('[BookCache] bg task fail:', JSON.stringify(e));
    }
  }

  private async stopBgTask(context: common.Context): Promise<void> {
    this.bgTaskCount_ = Math.max(0, this.bgTaskCount_ - 1);
    if (this.bgTaskCount_ > 0) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      console.info('[BookCache] bg task stopped');
    } catch (e) {
      console.warn('[BookCache] stopBgTask fail:', JSON.stringify(e));
    }
  }
}
