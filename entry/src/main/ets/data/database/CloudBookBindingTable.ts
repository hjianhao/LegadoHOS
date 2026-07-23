/**
 * cloud_book_bindings 表 DAO
 *
 * 冲突键：(source_id, remote_path)
 * book_id=0 表示未绑定本地书。
 */
import relationalStore from '@ohos.data.relationalStore';
import {
  CloudBookBinding,
  CloudBookSyncState,
  CLOUD_SYNC_CLOUD_ONLY,
  CLOUD_SYNC_ERROR,
  createDefaultCloudBookBinding,
} from '../../model/CloudBookBinding';
import { CloudFile } from '../../service/cloud/CloudStorageProvider';
import { RdbUtil } from './RdbUtil';

export const CLOUD_BOOK_BINDINGS_TABLE = 'cloud_book_bindings';

export const CloudBookBindingTableCreate = `
  CREATE TABLE IF NOT EXISTS cloud_book_bindings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    book_id INTEGER NOT NULL DEFAULT 0,
    remote_path TEXT NOT NULL,
    remote_id TEXT NOT NULL DEFAULT '',
    file_name TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    modified_at INTEGER NOT NULL DEFAULT 0,
    etag TEXT NOT NULL DEFAULT '',
    content_type TEXT NOT NULL DEFAULT '',
    downloaded_at INTEGER NOT NULL DEFAULT 0,
    last_checked_at INTEGER NOT NULL DEFAULT 0,
    last_synced_at INTEGER NOT NULL DEFAULT 0,
    sync_state TEXT NOT NULL DEFAULT 'CLOUD_ONLY',
    last_error TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(source_id, remote_path)
  );
`;

export const CloudBookBindingIndexBookId = `
  CREATE INDEX IF NOT EXISTS idx_cloud_bindings_book_id
  ON cloud_book_bindings(book_id);
`;

export const CloudBookBindingIndexSourceId = `
  CREATE INDEX IF NOT EXISTS idx_cloud_bindings_source_id
  ON cloud_book_bindings(source_id);
`;

export class CloudBookBindingTable {
  static readonly TABLE_NAME = CLOUD_BOOK_BINDINGS_TABLE;
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async get(sourceId: number, remotePath: string): Promise<CloudBookBinding | null> {
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('source_id', sourceId);
    predicates.equalTo('remote_path', remotePath);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const list = this.toList_(rs);
    return list.length > 0 ? list[0] : null;
  }

  async getById(id: number): Promise<CloudBookBinding | null> {
    if (id <= 0) {
      return null;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const list = this.toList_(rs);
    return list.length > 0 ? list[0] : null;
  }

  async listBySource(sourceId: number): Promise<CloudBookBinding[]> {
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('source_id', sourceId);
    predicates.orderByAsc('remote_path');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toList_(rs);
  }

  async listByBook(bookId: number): Promise<CloudBookBinding[]> {
    if (bookId <= 0) {
      return [];
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.orderByAsc('source_id');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toList_(rs);
  }

  /**
   * 以 (source_id, remote_path) 为冲突键 upsert。
   * @returns binding id
   */
  async upsert(binding: CloudBookBinding): Promise<number> {
    const existing = await this.get(binding.sourceId, binding.remotePath);
    const now = Date.now();
    if (existing) {
      binding.id = existing.id;
      binding.createdAt = existing.createdAt > 0 ? existing.createdAt : now;
      binding.updatedAt = now;
      const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
      predicates.equalTo('id', existing.id);
      await RdbUtil.update(this.rdbStore, this.toRow_(binding), predicates);
      return existing.id;
    }
    binding.createdAt = binding.createdAt > 0 ? binding.createdAt : now;
    binding.updatedAt = now;
    const id = await RdbUtil.insert(this.rdbStore, CloudBookBindingTable.TABLE_NAME, this.toRow_(binding));
    binding.id = id;
    return id;
  }

  async updateRemoteMeta(id: number, file: CloudFile, state: CloudBookSyncState): Promise<void> {
    if (id <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.rdbStore, {
      'remote_id': file.remoteId || '',
      'file_name': file.name || '',
      'size': file.size || 0,
      'modified_at': file.modifiedAt || 0,
      'etag': file.etag || '',
      'content_type': file.contentType || '',
      'sync_state': state || CLOUD_SYNC_CLOUD_ONLY,
      'last_error': '',
      'last_checked_at': Date.now(),
      'updated_at': Date.now(),
    }, predicates);
  }

  async bindBook(id: number, bookId: number, downloadedAt: number): Promise<void> {
    if (id <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.rdbStore, {
      'book_id': bookId,
      'downloaded_at': downloadedAt,
      'last_synced_at': downloadedAt,
      'sync_state': bookId > 0 ? 'DOWNLOADED' : CLOUD_SYNC_CLOUD_ONLY,
      'last_error': '',
      'updated_at': Date.now(),
    }, predicates);
  }

  /** 本地书删除后解除绑定：book_id 置 0，状态回 CLOUD_ONLY。 */
  async unlinkBook(bookId: number): Promise<void> {
    if (bookId <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await RdbUtil.update(this.rdbStore, {
      'book_id': 0,
      'sync_state': CLOUD_SYNC_CLOUD_ONLY,
      'downloaded_at': 0,
      'updated_at': Date.now(),
    }, predicates);
  }

  async deleteBySource(sourceId: number): Promise<void> {
    if (sourceId <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('source_id', sourceId);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async deleteById(id: number): Promise<void> {
    if (id <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async markError(sourceId: number, remotePath: string, message: string): Promise<void> {
    const existing = await this.get(sourceId, remotePath);
    const now = Date.now();
    if (existing) {
      const predicates = new relationalStore.RdbPredicates(CloudBookBindingTable.TABLE_NAME);
      predicates.equalTo('id', existing.id);
      await RdbUtil.update(this.rdbStore, {
        'sync_state': CLOUD_SYNC_ERROR,
        'last_error': message || '',
        'updated_at': now,
      }, predicates);
      return;
    }
    const binding = createDefaultCloudBookBinding();
    binding.sourceId = sourceId;
    binding.remotePath = remotePath;
    binding.fileName = remotePath.indexOf('/') >= 0
      ? remotePath.substring(remotePath.lastIndexOf('/') + 1)
      : remotePath;
    binding.syncState = CLOUD_SYNC_ERROR;
    binding.lastError = message || '';
    binding.createdAt = now;
    binding.updatedAt = now;
    await this.upsert(binding);
  }

  private toRow_(binding: CloudBookBinding): relationalStore.ValuesBucket {
    return {
      'source_id': binding.sourceId,
      'book_id': binding.bookId > 0 ? binding.bookId : 0,
      'remote_path': binding.remotePath,
      'remote_id': binding.remoteId || '',
      'file_name': binding.fileName || '',
      'size': binding.size || 0,
      'modified_at': binding.modifiedAt || 0,
      'etag': binding.etag || '',
      'content_type': binding.contentType || '',
      'downloaded_at': binding.downloadedAt || 0,
      'last_checked_at': binding.lastCheckedAt || 0,
      'last_synced_at': binding.lastSyncedAt || 0,
      'sync_state': binding.syncState || CLOUD_SYNC_CLOUD_ONLY,
      'last_error': binding.lastError || '',
      'created_at': binding.createdAt,
      'updated_at': binding.updatedAt,
    };
  }

  private toList_(rs: relationalStore.ResultSet): CloudBookBinding[] {
    const list: CloudBookBinding[] = [];
    while (RdbUtil.next(rs)) {
      const item = createDefaultCloudBookBinding();
      item.id = RdbUtil.long(rs, 'id');
      item.sourceId = RdbUtil.long(rs, 'source_id');
      item.bookId = RdbUtil.long(rs, 'book_id');
      item.remotePath = RdbUtil.string(rs, 'remote_path') || '';
      item.remoteId = RdbUtil.string(rs, 'remote_id') || '';
      item.fileName = RdbUtil.string(rs, 'file_name') || '';
      item.size = RdbUtil.long(rs, 'size');
      item.modifiedAt = RdbUtil.long(rs, 'modified_at');
      item.etag = RdbUtil.string(rs, 'etag') || '';
      item.contentType = RdbUtil.string(rs, 'content_type') || '';
      item.downloadedAt = RdbUtil.long(rs, 'downloaded_at');
      item.lastCheckedAt = RdbUtil.long(rs, 'last_checked_at');
      item.lastSyncedAt = RdbUtil.long(rs, 'last_synced_at');
      item.syncState = RdbUtil.string(rs, 'sync_state') || CLOUD_SYNC_CLOUD_ONLY;
      item.lastError = RdbUtil.string(rs, 'last_error') || '';
      item.createdAt = RdbUtil.long(rs, 'created_at');
      item.updatedAt = RdbUtil.long(rs, 'updated_at');
      list.push(item);
    }
    RdbUtil.close(rs);
    return list;
  }
}
