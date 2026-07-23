/**
 * CloudBookBinding 仓储
 *
 * 封装 Binding 的查询、upsert、解绑与按来源清理。
 * 不发起网络请求，不删除本地 Book。
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { CloudBookBindingTable } from '../../data/database/CloudBookBindingTable';
import {
  CloudBookBinding,
  CloudBookSyncState,
  CLOUD_SYNC_CLOUD_ONLY,
  createDefaultCloudBookBinding,
} from '../../model/CloudBookBinding';
import { CloudFile } from './CloudStorageProvider';
import { CloudPath } from './CloudPath';

export class CloudBookBindingRepository {
  private table_: CloudBookBindingTable;

  constructor() {
    const db = AppDatabase.getInstance().rdbStore;
    this.table_ = new CloudBookBindingTable(db);
  }

  async get(sourceId: number, remotePath: string): Promise<CloudBookBinding | null> {
    const path = CloudPath.normalizeRemotePath(remotePath);
    return await this.table_.get(sourceId, path);
  }

  async getById(id: number): Promise<CloudBookBinding | null> {
    return await this.table_.getById(id);
  }

  async listBySource(sourceId: number): Promise<CloudBookBinding[]> {
    return await this.table_.listBySource(sourceId);
  }

  async listByBook(bookId: number): Promise<CloudBookBinding[]> {
    return await this.table_.listByBook(bookId);
  }

  async upsert(binding: CloudBookBinding): Promise<number> {
    binding.remotePath = CloudPath.normalizeRemotePath(binding.remotePath);
    if (!binding.fileName) {
      binding.fileName = CloudPath.basename(binding.remotePath);
    }
    return await this.table_.upsert(binding);
  }

  /**
   * 从远端文件元数据创建或更新 CLOUD_ONLY 绑定（尚未下载）。
   */
  async upsertFromCloudFile(sourceId: number, file: CloudFile): Promise<CloudBookBinding> {
    const remotePath = CloudPath.normalizeRemotePath(file.remotePath);
    const existing = await this.table_.get(sourceId, remotePath);
    const binding = existing ? existing : createDefaultCloudBookBinding();
    binding.sourceId = sourceId;
    binding.remotePath = remotePath;
    binding.remoteId = file.remoteId || '';
    binding.fileName = file.name || CloudPath.basename(remotePath);
    binding.size = file.size || 0;
    binding.modifiedAt = file.modifiedAt || 0;
    binding.etag = file.etag || '';
    binding.contentType = file.contentType || '';
    binding.lastCheckedAt = Date.now();
    if (!existing) {
      binding.syncState = CLOUD_SYNC_CLOUD_ONLY;
      binding.bookId = 0;
    }
    binding.id = await this.table_.upsert(binding);
    return binding;
  }

  async updateRemoteMeta(id: number, file: CloudFile, state: CloudBookSyncState): Promise<void> {
    await this.table_.updateRemoteMeta(id, file, state);
  }

  async bindBook(id: number, bookId: number, downloadedAt?: number): Promise<void> {
    const ts = downloadedAt && downloadedAt > 0 ? downloadedAt : Date.now();
    await this.table_.bindBook(id, bookId, ts);
  }

  /** 本地书删除后调用：解除所有相关 Binding。 */
  async unlinkBook(bookId: number): Promise<void> {
    await this.table_.unlinkBook(bookId);
  }

  async deleteBySource(sourceId: number): Promise<void> {
    await this.table_.deleteBySource(sourceId);
  }

  async deleteById(id: number): Promise<void> {
    await this.table_.deleteById(id);
  }

  async markError(sourceId: number, remotePath: string, message: string): Promise<void> {
    const path = CloudPath.normalizeRemotePath(remotePath);
    await this.table_.markError(sourceId, path, message);
  }
}
