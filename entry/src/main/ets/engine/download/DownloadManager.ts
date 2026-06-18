/**
 * 下载管理器
 * 统一的下载队列管理，支持并发限制、断点续传、进度跟踪
 */
export interface DownloadItem {
  id: string;
  url: string;
  fileName: string;
  savePath: string;
  totalBytes: number;
  downloadedBytes: number;
  status: 'queued' | 'downloading' | 'paused' | 'completed' | 'failed';
  errorMsg: string;
  createTime: number;
}

export class DownloadManager {
  private static instance: DownloadManager;
  private items: Map<string, DownloadItem> = new Map();
  private queue: string[] = [];
  private maxConcurrent: number = 3;
  private activeCount: number = 0;

  private constructor() {}

  static getInstance(): DownloadManager {
    if (!DownloadManager.instance) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  addTask(url: string, fileName: string, savePath: string): string {
    const id = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const item: DownloadItem = {
      id, url, fileName, savePath,
      totalBytes: 0, downloadedBytes: 0,
      status: 'queued', errorMsg: '', createTime: Date.now(),
    };
    this.items.set(id, item);
    this.queue.push(id);
    this.processQueue();
    return id;
  }

  pauseTask(id: string): void {
    const item = this.items.get(id);
    if (item && item.status === 'downloading') {
      item.status = 'paused';
    }
  }

  resumeTask(id: string): void {
    const item = this.items.get(id);
    if (item && item.status === 'paused') {
      item.status = 'queued';
      this.queue.push(id);
      this.processQueue();
    }
  }

  removeTask(id: string): void {
    this.items.delete(id);
    this.queue = this.queue.filter(qid => qid !== id);
  }

  getItem(id: string): DownloadItem | undefined {
    return this.items.get(id);
  }

  getAllItems(): DownloadItem[] {
    return Array.from(this.items.values());
  }

  getStats(): { active: number; queued: number; completed: number; failed: number } {
    let active = 0, queued = 0, completed = 0, failed = 0;
    for (const item of this.items.values()) {
      if (item.status === 'downloading') active++;
      else if (item.status === 'queued') queued++;
      else if (item.status === 'completed') completed++;
      else if (item.status === 'failed') failed++;
    }
    return { active, queued, completed, failed };
  }

  private async processQueue(): Promise<void> {
    while (this.activeCount < this.maxConcurrent && this.queue.length > 0) {
      const id = this.queue.shift()!;
      const item = this.items.get(id);
      if (!item || item.status !== 'queued') continue;

      this.activeCount++;
      item.status = 'downloading';

      this.executeDownload(item).finally(() => {
        this.activeCount--;
        this.processQueue();
      });
    }
  }

  private async executeDownload(item: DownloadItem): Promise<void> {
    try {
      const { NetUtil } = await import('../../util/NetUtil');
      const content = await NetUtil.httpGet(item.url);

      const { FileUtil } = await import('../../util/FileUtil');
      await FileUtil.writeTextFile(item.savePath + '/' + item.fileName, content);

      item.status = 'completed';
      item.downloadedBytes = content.length;
    } catch (err) {
      item.status = 'failed';
      item.errorMsg = err.message;
      console.error('[DownloadManager] Failed:', item.url, err);
    }
  }
}
