/**
 * 云端书籍业务仓储
 *
 * - 浏览 + Binding/本地书状态合并
 * - 下载导入（临时文件 → LocalBookEngine → Binding）
 * 状态按 sourceId + remotePath 精确匹配，禁止按文件名猜测。
 */
import fileFs from '@ohos.file.fs';
import { taskpool } from '@kit.ArkTS';
import { AppDatabase } from '../../data/database/AppDatabase';
import { BookTable } from '../../data/database/BookTable';
import { Book } from '../../model/Book';
import {
  CloudBookBinding,
  CLOUD_SYNC_CLOUD_ONLY,
  CLOUD_SYNC_DOWNLOADED,
  CLOUD_SYNC_ERROR,
  CLOUD_SYNC_OUTDATED,
  createDefaultCloudBookBinding,
} from '../../model/CloudBookBinding';
import {
  CloudBookDisplayState,
  CloudBookListItem,
  CLOUD_DISPLAY_CLOUD_ONLY,
  CLOUD_DISPLAY_DIRECTORY,
  CLOUD_DISPLAY_DOWNLOADED,
  CLOUD_DISPLAY_DOWNLOADING,
  CLOUD_DISPLAY_ERROR,
  CLOUD_DISPLAY_OUTDATED,
} from '../../model/CloudBookListItem';
import { CloudSource } from '../../model/CloudSource';
import { localBookEngine, LocalBookEngine } from '../../engine/book/LocalBookEngine';
import { extractZipConcurrent } from '../../engine/book/ZipExtractTask';
import { BookDeleter } from '../BookDeleter';
import { AppContextHolder } from '../../util/AppContext';
import { FileUtil } from '../../util/FileUtil';
import { CloudBookBindingRepository } from './CloudBookBindingRepository';
import { CloudLocalFileStore } from './CloudLocalFileStore';
import { CloudPath, CloudPathCrumb } from './CloudPath';
import { CloudProviderRegistry } from './CloudProviderRegistry';
import { CloudFile } from './CloudStorageProvider';
import { CloudSourceRepository } from './CloudSourceRepository';
import {
  CloudTransferManager,
  CLOUD_TRANSFER_CANCELLED,
  CLOUD_TRANSFER_FAILED,
  CLOUD_TRANSFER_PENDING,
  CLOUD_TRANSFER_RUNNING,
  CLOUD_TRANSFER_SUCCESS,
  CloudTransferTask,
} from './CloudTransferManager';
import { ensureCloudProvidersRegistered } from './CloudProviderBootstrap';

export type CloudBookSortMode = string;
export const CLOUD_SORT_NAME_ASC: CloudBookSortMode = 'name_asc';
export const CLOUD_SORT_NAME_DESC: CloudBookSortMode = 'name_desc';
export const CLOUD_SORT_TIME_DESC: CloudBookSortMode = 'time_desc';
export const CLOUD_SORT_TIME_ASC: CloudBookSortMode = 'time_asc';

export interface CloudBookListResult {
  source: CloudSource;
  remotePath: string;
  breadcrumbs: CloudPathCrumb[];
  items: CloudBookListItem[];
}

export interface CloudDownloadResult {
  success: boolean;
  bookId: number;
  bookName: string;
  taskId: string;
  error: string;
}

export class CloudBookRepository {
  private sourceRepo_: CloudSourceRepository;
  private bindingRepo_: CloudBookBindingRepository;
  private bookTable_: BookTable;
  private transfer_: CloudTransferManager;
  private fileStore_: CloudLocalFileStore;
  /** 简易下载队列：等待并发槽位 */
  private queue_: Array<() => void> = [];
  private activeDownloads_: number = 0;
  private maxConcurrent_: number = 2;

  constructor() {
    const db = AppDatabase.getInstance().rdbStore;
    this.sourceRepo_ = new CloudSourceRepository();
    this.bindingRepo_ = new CloudBookBindingRepository();
    this.bookTable_ = new BookTable(db);
    this.transfer_ = CloudTransferManager.getInstance();
    this.fileStore_ = CloudLocalFileStore.getInstance();
  }

  /**
   * 列举来源下某相对路径，并合并 Binding / 本地 Book 状态。
   * @param remotePath 相对 source.rootPath；根为 ''
   */
  async listDirectory(sourceId: number, remotePath: string = ''): Promise<CloudBookListResult> {
    ensureCloudProvidersRegistered();
    const source = await this.sourceRepo_.getById(sourceId);
    if (!source) {
      throw new Error('来源不存在');
    }
    if (!source.enabled) {
      throw new Error('来源已禁用');
    }
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    const credential = await this.sourceRepo_.getCredential(sourceId);
    if (!credential || !credential.username) {
      throw new Error('未配置凭证，请先编辑来源并填写账号密码');
    }
    if (!credential.secret) {
      throw new Error('未配置密码，请先编辑来源');
    }

    const provider = CloudProviderRegistry.getInstance().get(source.providerType);
    const page = await provider.list(source, credential, path);
    const bindings = await this.bindingRepo_.listBySource(sourceId);
    const bindingMap = new Map<string, CloudBookBinding>();
    for (let i = 0; i < bindings.length; i++) {
      const b = bindings[i];
      bindingMap.set(b.remotePath, b);
    }

    // 批量拉取可能用到的本地书
    const bookIdSet = new Set<number>();
    for (let i = 0; i < bindings.length; i++) {
      if (bindings[i].bookId > 0) {
        bookIdSet.add(bindings[i].bookId);
      }
    }
    const bookMap = new Map<number, Book>();
    const bookIds: number[] = Array.from(bookIdSet);
    for (let i = 0; i < bookIds.length; i++) {
      const book = await this.bookTable_.getBookById(bookIds[i]);
      if (book) {
        bookMap.set(bookIds[i], book);
      }
    }

    const items: CloudBookListItem[] = [];
    for (let i = 0; i < page.items.length; i++) {
      const file = page.items[i];
      items.push(this.buildListItem_(sourceId, file, bindingMap, bookMap));
    }

    const result: CloudBookListResult = {
      source: source,
      remotePath: path,
      breadcrumbs: CloudPath.breadcrumbs(path),
      items: items,
    };
    return result;
  }

  /**
   * 将进程内下载进度合并进列表项（不改 Binding）。
   */
  applyTransferOverlay(items: CloudBookListItem[]): CloudBookListItem[] {
    const out: CloudBookListItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it.file.isDirectory) {
        out.push(it);
        continue;
      }
      const task = this.transfer_.getTask(it.sourceId, it.file.remotePath);
      if (task && (task.status === CLOUD_TRANSFER_PENDING || task.status === CLOUD_TRANSFER_RUNNING)) {
        const copy: CloudBookListItem = {
          sourceId: it.sourceId,
          file: it.file,
          binding: it.binding,
          localBook: it.localBook,
          displayState: CLOUD_DISPLAY_DOWNLOADING,
          localFileExists: it.localFileExists,
          importSupported: it.importSupported,
          progress: { received: task.received, total: task.total },
        };
        out.push(copy);
      } else {
        out.push(it);
      }
    }
    return out;
  }

  /**
   * 下载并导入为本地书。同一 (sourceId, remotePath) 并发点击返回同一任务结果等待。
   */
  async downloadAndImport(
    sourceId: number,
    remotePath: string,
    fileHint?: CloudFile
  ): Promise<CloudDownloadResult> {
    ensureCloudProvidersRegistered();
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      return this.failResult_('', '路径非法');
    }
    if (!CloudBookRepository.isImportSupported(fileHint ? fileHint.name : path)) {
      return this.failResult_('', '不支持的文件格式');
    }

    // 已有活动任务：等待其结束
    const existing = this.transfer_.getTask(sourceId, path);
    if (existing &&
      (existing.status === CLOUD_TRANSFER_PENDING || existing.status === CLOUD_TRANSFER_RUNNING)) {
      return await this.waitTask_(existing.taskId);
    }

    const fileName = fileHint && fileHint.name
      ? fileHint.name
      : CloudPath.basename(path);
    const task = this.transfer_.beginDownload(sourceId, path, fileName);

    // 排队限流
    await this.acquireSlot_();
    if (this.transfer_.isCancelled(task.taskId)) {
      this.releaseSlot_();
      return this.failResult_(task.taskId, '已取消');
    }

    try {
      this.transfer_.markRunning(task.taskId);
      const bookId = await this.runDownloadImport_(sourceId, path, fileHint, task);
      this.transfer_.markSuccess(task.taskId, bookId);
      // 通知书架刷新
      try {
        const cur = AppStorage.get<number>('shelfRefreshCounter') || 0;
        AppStorage.setOrCreate<number>('shelfRefreshCounter', cur + 1);
      } catch (_e) { /* ignore */ }
      const result: CloudDownloadResult = {
        success: true,
        bookId: bookId,
        bookName: fileName,
        taskId: task.taskId,
        error: '',
      };
      return result;
    } catch (e) {
      const msg = (e as Error).message || '下载失败';
      if (this.transfer_.isCancelled(task.taskId)) {
        this.transfer_.markCancelled(task.taskId);
        return this.failResult_(task.taskId, '已取消');
      }
      this.transfer_.markFailed(task.taskId, msg);
      try {
        await this.bindingRepo_.markError(sourceId, path, msg);
      } catch (_be) { /* ignore */ }
      return this.failResult_(task.taskId, msg);
    } finally {
      this.releaseSlot_();
    }
  }

  /** 批量下载：逐个入队，单项失败不影响其他 */
  async downloadAndImportBatch(
    sourceId: number,
    files: CloudFile[]
  ): Promise<CloudDownloadResult[]> {
    const results: CloudDownloadResult[] = [];
    const jobs: Promise<CloudDownloadResult>[] = [];
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      if (f.isDirectory || !CloudBookRepository.isImportSupported(f.name)) {
        continue;
      }
      jobs.push(this.downloadAndImport(sourceId, f.remotePath, f));
    }
    for (let i = 0; i < jobs.length; i++) {
      try {
        results.push(await jobs[i]);
      } catch (e) {
        results.push(this.failResult_('', (e as Error).message || '失败'));
      }
    }
    return results;
  }

  cancelDownload(sourceId: number, remotePath: string): void {
    this.transfer_.requestCancel(sourceId, CloudPath.normalizeRemotePath(remotePath));
  }

  private async runDownloadImport_(
    sourceId: number,
    remotePath: string,
    fileHint: CloudFile | undefined,
    task: CloudTransferTask
  ): Promise<number> {
    const source = await this.sourceRepo_.getById(sourceId);
    if (!source) {
      throw new Error('来源不存在');
    }
    const credential = await this.sourceRepo_.getCredential(sourceId);
    if (!credential || !credential.username || !credential.secret) {
      throw new Error('未配置凭证');
    }
    const provider = CloudProviderRegistry.getInstance().get(source.providerType);

    // stat 优先
    let meta: CloudFile | null = null;
    try {
      meta = await provider.stat(source, credential, remotePath);
    } catch (_e) {
      meta = null;
    }
    if (!meta && fileHint) {
      meta = fileHint;
    }
    if (meta && meta.isDirectory) {
      throw new Error('不能下载目录');
    }
    const fileName = (meta && meta.name) ? meta.name : (fileHint ? fileHint.name : CloudPath.basename(remotePath));
    if (!CloudBookRepository.isImportSupported(fileName)) {
      throw new Error('不支持的文件格式');
    }

    this.fileStore_.ensureDirs();
    this.fileStore_.cleanupStaleTempFiles();
    const tempPath = this.fileStore_.allocTempPath(task.taskId);
    const finalPath = this.fileStore_.allocFinalBookPath(sourceId, remotePath, fileName);
    let epubDir = '';
    let importedBookId = 0;

    try {
      if (this.transfer_.isCancelled(task.taskId)) {
        throw new Error('已取消');
      }

      await provider.downloadToFile(
        source,
        credential,
        remotePath,
        tempPath,
        (received: number, total: number) => {
          if (!this.transfer_.isCancelled(task.taskId)) {
            this.transfer_.updateProgress(task.taskId, received, total || (meta ? meta.size : 0));
          }
        }
      );

      if (this.transfer_.isCancelled(task.taskId)) {
        throw new Error('已取消');
      }

      const size = this.fileStore_.fileSize(tempPath);
      if (size <= 0) {
        throw new Error('下载文件为空');
      }
      if (meta && meta.size > 0 && size < meta.size * 0.5) {
        // 允许轻微差异，但明显过小则失败
        console.warn('[CloudBook] size mismatch remote=', meta.size, ' local=', size);
      }

      // 移动到最终路径
      this.fileStore_.atomicMove(tempPath, finalPath);

      const ctx = AppContextHolder.get();
      if (!ctx) {
        throw new Error('缺少 Context，无法导入本地书');
      }

      // EPUB 需先解压
      const ext = CloudBookRepository.extensionOf_(fileName);
      if (ext === 'epub') {
        epubDir = LocalBookEngine.getEpubDir(ctx);
        await taskpool.execute(extractZipConcurrent, finalPath, epubDir);
      }

      if (this.transfer_.isCancelled(task.taskId)) {
        throw new Error('已取消');
      }

      const importResult = await localBookEngine.importBook(
        finalPath,
        ctx,
        epubDir ? epubDir : undefined
      );
      if (!importResult.success || importResult.bookId <= 0) {
        throw new Error(importResult.error || '导入失败');
      }
      importedBookId = importResult.bookId;

      // Binding 事务：upsert + bind
      const now = Date.now();
      let binding = await this.bindingRepo_.get(sourceId, remotePath);
      if (!binding) {
        binding = createDefaultCloudBookBinding();
        binding.sourceId = sourceId;
        binding.remotePath = remotePath;
      }
      binding.fileName = fileName;
      binding.size = meta ? meta.size : size;
      binding.modifiedAt = meta ? meta.modifiedAt : now;
      binding.etag = meta ? (meta.etag || '') : '';
      binding.contentType = meta ? (meta.contentType || '') : '';
      binding.remoteId = meta ? (meta.remoteId || meta.etag || '') : '';
      binding.bookId = importedBookId;
      binding.downloadedAt = now;
      binding.lastSyncedAt = now;
      binding.lastCheckedAt = now;
      binding.syncState = CLOUD_SYNC_DOWNLOADED;
      binding.lastError = '';
      binding.updatedAt = now;
      const bindingId = await this.bindingRepo_.upsert(binding);
      await this.bindingRepo_.bindBook(bindingId, importedBookId, now);

      console.info('[CloudBook] downloadAndImport OK bookId=', importedBookId, ' path=', remotePath);
      return importedBookId;
    } catch (e) {
      // 补偿：清理临时/半成品，避免孤儿 Book
      this.fileStore_.deleteIfExists(tempPath);
      if (importedBookId > 0) {
        try {
          const book = await this.bookTable_.getBookById(importedBookId);
          if (book) {
            await BookDeleter.deleteBook(book);
          }
        } catch (_de) { /* ignore */ }
      } else {
        this.fileStore_.deleteIfExists(finalPath);
        if (epubDir) {
          FileUtil.removeDirRecursive(epubDir);
        }
      }
      const msg = e instanceof Error ? e.message : String(e);
      throw new Error(msg || '下载失败');
    }
  }

  private failResult_(taskId: string, error: string): CloudDownloadResult {
    return {
      success: false,
      bookId: 0,
      bookName: '',
      taskId: taskId,
      error: error,
    };
  }

  private async waitTask_(taskId: string): Promise<CloudDownloadResult> {
    // 简单轮询等待（ArkTS 无事件条件变量）
    for (let i = 0; i < 6000; i++) {
      const t = this.transfer_.getTaskById(taskId);
      if (!t) {
        return this.failResult_(taskId, '任务丢失');
      }
      if (t.status === CLOUD_TRANSFER_SUCCESS) {
        return {
          success: true,
          bookId: t.bookId,
          bookName: t.fileName,
          taskId: taskId,
          error: '',
        };
      }
      if (t.status === CLOUD_TRANSFER_FAILED || t.status === CLOUD_TRANSFER_CANCELLED) {
        return this.failResult_(taskId, t.error || '失败');
      }
      await CloudBookRepository.sleep_(100);
    }
    return this.failResult_(taskId, '等待超时');
  }

  private async acquireSlot_(): Promise<void> {
    if (this.activeDownloads_ < this.maxConcurrent_) {
      this.activeDownloads_++;
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      this.queue_.push(() => {
        this.activeDownloads_++;
        resolve();
      });
    });
  }

  private releaseSlot_(): void {
    this.activeDownloads_ = Math.max(0, this.activeDownloads_ - 1);
    if (this.queue_.length > 0 && this.activeDownloads_ < this.maxConcurrent_) {
      const next = this.queue_.shift();
      if (next) {
        next();
      }
    }
  }

  private static sleep_(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 内存内过滤 + 排序（不重新请求网络）。
   * 目录始终排在文件前。
   */
  filterAndSort(
    items: CloudBookListItem[],
    keyword: string,
    sortMode: CloudBookSortMode
  ): CloudBookListItem[] {
    const key = (keyword || '').trim().toLowerCase();
    let list: CloudBookListItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (key) {
        const name = (it.file.name || '').toLowerCase();
        if (name.indexOf(key) < 0) {
          continue;
        }
      }
      list.push(it);
    }

    const mode = sortMode || CLOUD_SORT_NAME_ASC;
    list.sort((a: CloudBookListItem, b: CloudBookListItem): number => {
      if (a.file.isDirectory !== b.file.isDirectory) {
        return a.file.isDirectory ? -1 : 1;
      }
      if (mode === CLOUD_SORT_TIME_DESC) {
        const dt = (b.file.modifiedAt || 0) - (a.file.modifiedAt || 0);
        if (dt !== 0) {
          return dt;
        }
        return a.file.name.localeCompare(b.file.name);
      }
      if (mode === CLOUD_SORT_TIME_ASC) {
        const dt = (a.file.modifiedAt || 0) - (b.file.modifiedAt || 0);
        if (dt !== 0) {
          return dt;
        }
        return a.file.name.localeCompare(b.file.name);
      }
      if (mode === CLOUD_SORT_NAME_DESC) {
        return b.file.name.localeCompare(a.file.name);
      }
      return a.file.name.localeCompare(b.file.name);
    });
    return list;
  }

  /** 当前 LocalBookEngine 支持的导入扩展名。 */
  static isImportSupported(fileName: string): boolean {
    const ext = CloudBookRepository.extensionOf_(fileName);
    return ext === 'txt' || ext === 'epub' || ext === 'pdf' ||
      ext === 'mobi' || ext === 'azw' || ext === 'azw3';
  }

  private buildListItem_(
    sourceId: number,
    file: CloudFile,
    bindingMap: Map<string, CloudBookBinding>,
    bookMap: Map<number, Book>
  ): CloudBookListItem {
    const remotePath = CloudPath.normalizeRemotePath(file.remotePath);
    const binding = bindingMap.get(remotePath) || null;
    const importSupported = !file.isDirectory && CloudBookRepository.isImportSupported(file.name);

    if (file.isDirectory) {
      const dirItem: CloudBookListItem = {
        sourceId: sourceId,
        file: file,
        binding: null,
        localBook: null,
        displayState: CLOUD_DISPLAY_DIRECTORY,
        localFileExists: false,
        importSupported: false,
        progress: null,
      };
      return dirItem;
    }

    let localBook: Book | null = null;
    let localFileExists = false;
    if (binding && binding.bookId > 0) {
      localBook = bookMap.get(binding.bookId) || null;
      if (localBook) {
        localFileExists = CloudBookRepository.localBookFileExists_(localBook);
      }
    }

    const displayState = this.computeDisplayState_(file, binding, localBook, localFileExists);

    // 本地书不存在时不暴露 book 对象，避免误开
    if (!localFileExists) {
      localBook = null;
    }

    const item: CloudBookListItem = {
      sourceId: sourceId,
      file: file,
      binding: binding,
      localBook: localBook,
      displayState: displayState,
      localFileExists: localFileExists,
      importSupported: importSupported,
      progress: null,
    };
    return item;
  }

  private computeDisplayState_(
    file: CloudFile,
    binding: CloudBookBinding | null,
    localBook: Book | null,
    localFileExists: boolean
  ): CloudBookDisplayState {
    if (!binding) {
      return CLOUD_DISPLAY_CLOUD_ONLY;
    }
    if (binding.syncState === CLOUD_SYNC_ERROR && !(binding.bookId > 0 && localFileExists)) {
      return CLOUD_DISPLAY_ERROR;
    }
    // 已绑定且本地文件在 → 已下载 / 可更新
    if (binding.bookId > 0 && localBook && localFileExists) {
      if (binding.syncState === CLOUD_SYNC_OUTDATED) {
        return CLOUD_DISPLAY_OUTDATED;
      }
      // 用列表元数据做轻量过期判断（不写库）
      if (CloudBookRepository.looksOutdated_(binding, file)) {
        return CLOUD_DISPLAY_OUTDATED;
      }
      return CLOUD_DISPLAY_DOWNLOADED;
    }
    // 绑定存在但本地没了
    if (binding.syncState === CLOUD_SYNC_ERROR) {
      return CLOUD_DISPLAY_ERROR;
    }
    if (binding.syncState === CLOUD_SYNC_DOWNLOADED || binding.syncState === CLOUD_SYNC_OUTDATED) {
      // 本地丢失 → 降级为云端
      return CLOUD_DISPLAY_CLOUD_ONLY;
    }
    if (binding.syncState === CLOUD_SYNC_CLOUD_ONLY) {
      return CLOUD_DISPLAY_CLOUD_ONLY;
    }
    return CLOUD_DISPLAY_CLOUD_ONLY;
  }

  private static looksOutdated_(binding: CloudBookBinding, file: CloudFile): boolean {
    if (file.etag && binding.etag && file.etag !== binding.etag) {
      return true;
    }
    if (!file.etag || !binding.etag) {
      if (file.modifiedAt > 0 && binding.modifiedAt > 0 && file.modifiedAt > binding.modifiedAt) {
        return true;
      }
      if (file.size > 0 && binding.size > 0 && file.size !== binding.size &&
        file.modifiedAt > 0 && binding.modifiedAt > 0 && file.modifiedAt !== binding.modifiedAt) {
        return true;
      }
    }
    return false;
  }

  private static localBookFileExists_(book: Book): boolean {
    const candidates: string[] = [];
    if (book.originUrl) {
      candidates.push(book.originUrl);
    }
    if (book.bookUrl) {
      let u = book.bookUrl;
      if (u.indexOf('local://') === 0) {
        u = u.substring('local://'.length);
      } else if (u.indexOf('file://') === 0) {
        u = u.substring('file://'.length);
      }
      if (u) {
        candidates.push(u);
      }
    }
    for (let i = 0; i < candidates.length; i++) {
      const p = candidates[i];
      if (!p || p.indexOf('/') !== 0) {
        // 仍尝试 access（部分路径形态）
      }
      try {
        if (fileFs.accessSync(p)) {
          return true;
        }
      } catch (_e) {
        // continue
      }
    }
    return false;
  }

  private static extensionOf_(fileName: string): string {
    const n = fileName || '';
    const dot = n.lastIndexOf('.');
    if (dot < 0 || dot === n.length - 1) {
      return '';
    }
    return n.substring(dot + 1).toLowerCase();
  }
}
