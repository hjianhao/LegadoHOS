/**
 * 云端传输任务管理（进程内瞬态）
 *
 * - 任务键：sourceId + remotePath
 * - 全局并发默认 2
 * - DOWNLOADING 不写 Binding 持久状态
 */
export type CloudTransferKind = string;
export const CLOUD_TRANSFER_DOWNLOAD: CloudTransferKind = 'download';
export const CLOUD_TRANSFER_UPLOAD: CloudTransferKind = 'upload';

export type CloudTransferStatus = string;
export const CLOUD_TRANSFER_PENDING: CloudTransferStatus = 'pending';
export const CLOUD_TRANSFER_RUNNING: CloudTransferStatus = 'running';
export const CLOUD_TRANSFER_SUCCESS: CloudTransferStatus = 'success';
export const CLOUD_TRANSFER_FAILED: CloudTransferStatus = 'failed';
export const CLOUD_TRANSFER_CANCELLED: CloudTransferStatus = 'cancelled';

// re-export aliases for callers

export interface CloudTransferTask {
  taskId: string;
  kind: CloudTransferKind;
  sourceId: number;
  remotePath: string;
  fileName: string;
  status: CloudTransferStatus;
  received: number;
  total: number;
  error: string;
  bookId: number;
  createdAt: number;
  updatedAt: number;
}

export type CloudTransferListener = (task: CloudTransferTask) => void;

export class CloudTransferManager {
  private static instance: CloudTransferManager | null = null;
  private tasks_: Map<string, CloudTransferTask> = new Map();
  private listeners_: CloudTransferListener[] = [];
  private maxConcurrent_: number = 2;
  private runningCount_: number = 0;
  private seq_: number = 0;

  private constructor() {}

  static getInstance(): CloudTransferManager {
    if (!CloudTransferManager.instance) {
      CloudTransferManager.instance = new CloudTransferManager();
    }
    return CloudTransferManager.instance;
  }

  setMaxConcurrent(n: number): void {
    this.maxConcurrent_ = n > 0 ? n : 2;
  }

  subscribe(listener: CloudTransferListener): void {
    if (this.listeners_.indexOf(listener) < 0) {
      this.listeners_.push(listener);
    }
  }

  unsubscribe(listener: CloudTransferListener): void {
    const next: CloudTransferListener[] = [];
    for (let i = 0; i < this.listeners_.length; i++) {
      if (this.listeners_[i] !== listener) {
        next.push(this.listeners_[i]);
      }
    }
    this.listeners_ = next;
  }

  static taskKey(sourceId: number, remotePath: string): string {
    return sourceId + '|' + (remotePath || '');
  }

  getTask(sourceId: number, remotePath: string): CloudTransferTask | null {
    return this.tasks_.get(CloudTransferManager.taskKey(sourceId, remotePath)) || null;
  }

  getTaskById(taskId: string): CloudTransferTask | null {
    const keys = Array.from(this.tasks_.keys());
    for (let i = 0; i < keys.length; i++) {
      const t = this.tasks_.get(keys[i]);
      if (t && t.taskId === taskId) {
        return t;
      }
    }
    return null;
  }

  listActive(): CloudTransferTask[] {
    const out: CloudTransferTask[] = [];
    this.tasks_.forEach((t: CloudTransferTask) => {
      if (t.status === CLOUD_TRANSFER_PENDING || t.status === CLOUD_TRANSFER_RUNNING) {
        out.push(t);
      }
    });
    return out;
  }

  isActive(sourceId: number, remotePath: string): boolean {
    const t = this.getTask(sourceId, remotePath);
    return !!(t && (t.status === CLOUD_TRANSFER_PENDING || t.status === CLOUD_TRANSFER_RUNNING));
  }

  /**
   * 创建或返回已有下载任务。
   * 同一文件已有活动任务时返回已有句柄，不重复创建。
   */
  beginDownload(sourceId: number, remotePath: string, fileName: string): CloudTransferTask {
    const key = CloudTransferManager.taskKey(sourceId, remotePath);
    const existing = this.tasks_.get(key);
    if (existing &&
      (existing.status === CLOUD_TRANSFER_PENDING || existing.status === CLOUD_TRANSFER_RUNNING)) {
      return existing;
    }
    this.seq_++;
    const now = Date.now();
    const task: CloudTransferTask = {
      taskId: 'dl_' + now.toString(36) + '_' + this.seq_.toString(36),
      kind: CLOUD_TRANSFER_DOWNLOAD,
      sourceId: sourceId,
      remotePath: remotePath,
      fileName: fileName || '',
      status: CLOUD_TRANSFER_PENDING,
      received: 0,
      total: 0,
      error: '',
      bookId: 0,
      createdAt: now,
      updatedAt: now,
    };
    this.tasks_.set(key, task);
    this.emit_(task);
    return task;
  }

  markRunning(taskId: string): void {
    const t = this.getTaskById(taskId);
    if (!t) {
      return;
    }
    t.status = CLOUD_TRANSFER_RUNNING;
    t.updatedAt = Date.now();
    this.runningCount_++;
    this.emit_(t);
  }

  updateProgress(taskId: string, received: number, total: number): void {
    const t = this.getTaskById(taskId);
    if (!t) {
      return;
    }
    t.received = received;
    t.total = total > 0 ? total : t.total;
    t.updatedAt = Date.now();
    this.emit_(t);
  }

  markSuccess(taskId: string, bookId: number): void {
    const t = this.getTaskById(taskId);
    if (!t) {
      return;
    }
    if (t.status === CLOUD_TRANSFER_RUNNING) {
      this.runningCount_ = Math.max(0, this.runningCount_ - 1);
    }
    t.status = CLOUD_TRANSFER_SUCCESS;
    t.bookId = bookId;
    t.error = '';
    t.updatedAt = Date.now();
    this.emit_(t);
  }

  markFailed(taskId: string, error: string): void {
    const t = this.getTaskById(taskId);
    if (!t) {
      return;
    }
    if (t.status === CLOUD_TRANSFER_RUNNING) {
      this.runningCount_ = Math.max(0, this.runningCount_ - 1);
    }
    t.status = CLOUD_TRANSFER_FAILED;
    t.error = error || '失败';
    t.updatedAt = Date.now();
    this.emit_(t);
  }

  markCancelled(taskId: string): void {
    const t = this.getTaskById(taskId);
    if (!t) {
      return;
    }
    if (t.status === CLOUD_TRANSFER_RUNNING) {
      this.runningCount_ = Math.max(0, this.runningCount_ - 1);
    }
    t.status = CLOUD_TRANSFER_CANCELLED;
    t.error = '已取消';
    t.updatedAt = Date.now();
    this.emit_(t);
  }

  /** 请求取消：仅标记，下载循环需检查 isCancelled */
  requestCancel(sourceId: number, remotePath: string): void {
    const t = this.getTask(sourceId, remotePath);
    if (!t) {
      return;
    }
    if (t.status === CLOUD_TRANSFER_PENDING || t.status === CLOUD_TRANSFER_RUNNING) {
      this.markCancelled(t.taskId);
    }
  }

  isCancelled(taskId: string): boolean {
    const t = this.getTaskById(taskId);
    return !!(t && t.status === CLOUD_TRANSFER_CANCELLED);
  }

  canStartMore(): boolean {
    return this.runningCount_ < this.maxConcurrent_;
  }

  getRunningCount(): number {
    return this.runningCount_;
  }

  /** 清理已完成任务（可选，避免 Map 无限增长） */
  pruneFinished(olderThanMs: number = 5 * 60 * 1000): void {
    const now = Date.now();
    const keys = Array.from(this.tasks_.keys());
    for (let i = 0; i < keys.length; i++) {
      const t = this.tasks_.get(keys[i]);
      if (!t) {
        continue;
      }
      if (t.status === CLOUD_TRANSFER_SUCCESS || t.status === CLOUD_TRANSFER_FAILED ||
        t.status === CLOUD_TRANSFER_CANCELLED) {
        if (now - t.updatedAt > olderThanMs) {
          this.tasks_.delete(keys[i]);
        }
      }
    }
  }

  private emit_(task: CloudTransferTask): void {
    // 拷贝快照，避免监听方改到内部对象
    const snap: CloudTransferTask = {
      taskId: task.taskId,
      kind: task.kind,
      sourceId: task.sourceId,
      remotePath: task.remotePath,
      fileName: task.fileName,
      status: task.status,
      received: task.received,
      total: task.total,
      error: task.error,
      bookId: task.bookId,
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
    };
    for (let i = 0; i < this.listeners_.length; i++) {
      try {
        this.listeners_[i](snap);
      } catch (e) {
        console.warn('[CloudTransferManager] listener error:', (e as Error).message);
      }
    }
  }
}
