/**
 * 本地书与云端文件的关联（CloudBookBinding）
 *
 * 稳定唯一键：(sourceId, remotePath)
 * bookId=0 表示未绑定本地书（云端尚未下载，或本地已删）。
 */

/** 持久化同步状态（DOWNLOADING 为进程内瞬态，不写库）。 */
export type CloudBookSyncState = string;

export const CLOUD_SYNC_CLOUD_ONLY: CloudBookSyncState = 'CLOUD_ONLY';
export const CLOUD_SYNC_DOWNLOADED: CloudBookSyncState = 'DOWNLOADED';
export const CLOUD_SYNC_OUTDATED: CloudBookSyncState = 'OUTDATED';
export const CLOUD_SYNC_ERROR: CloudBookSyncState = 'ERROR';

export interface CloudBookBinding {
  id: number;
  sourceId: number;
  /** 已下载导入时指向 books.id；0 表示未绑定。 */
  bookId: number;
  remotePath: string;
  remoteId: string;
  fileName: string;
  size: number;
  modifiedAt: number;
  etag: string;
  contentType: string;
  downloadedAt: number;
  lastCheckedAt: number;
  lastSyncedAt: number;
  syncState: CloudBookSyncState;
  lastError: string;
  createdAt: number;
  updatedAt: number;
}

export function createDefaultCloudBookBinding(): CloudBookBinding {
  const now = Date.now();
  return {
    id: 0,
    sourceId: 0,
    bookId: 0,
    remotePath: '',
    remoteId: '',
    fileName: '',
    size: 0,
    modifiedAt: 0,
    etag: '',
    contentType: '',
    downloadedAt: 0,
    lastCheckedAt: 0,
    lastSyncedAt: 0,
    syncState: CLOUD_SYNC_CLOUD_ONLY,
    lastError: '',
    createdAt: now,
    updatedAt: now,
  };
}

export function isCloudBookBound(binding: CloudBookBinding): boolean {
  return binding.bookId > 0;
}
