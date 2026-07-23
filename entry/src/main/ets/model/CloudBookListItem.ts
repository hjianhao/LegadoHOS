/**
 * 云端书籍页组合展示模型（不落库）
 */
import { Book } from './Book';
import { CloudBookBinding } from './CloudBookBinding';
import { CloudFile } from '../service/cloud/CloudStorageProvider';

/** 页面展示状态（含目录与传输瞬态）。 */
export type CloudBookDisplayState = string;

export const CLOUD_DISPLAY_DIRECTORY: CloudBookDisplayState = 'DIRECTORY';
export const CLOUD_DISPLAY_CLOUD_ONLY: CloudBookDisplayState = 'CLOUD_ONLY';
export const CLOUD_DISPLAY_DOWNLOADING: CloudBookDisplayState = 'DOWNLOADING';
export const CLOUD_DISPLAY_DOWNLOADED: CloudBookDisplayState = 'DOWNLOADED';
export const CLOUD_DISPLAY_OUTDATED: CloudBookDisplayState = 'OUTDATED';
export const CLOUD_DISPLAY_ERROR: CloudBookDisplayState = 'ERROR';

export interface CloudTransferProgress {
  received: number;
  total: number;
}

export interface CloudBookListItem {
  sourceId: number;
  file: CloudFile;
  /** 无绑定则为 null。 */
  binding: CloudBookBinding | null;
  /** 已关联且本地书存在时填充。 */
  localBook: Book | null;
  displayState: CloudBookDisplayState;
  /** 本地文件是否仍可访问（仅 DOWNLOADED/OUTDATED 有意义）。 */
  localFileExists: boolean;
  /** 扩展名是否被 LocalBookEngine 支持（目录恒 false）。 */
  importSupported: boolean;
  progress: CloudTransferProgress | null;
}

export function displayStateLabel(state: CloudBookDisplayState): string {
  if (state === CLOUD_DISPLAY_DIRECTORY) {
    return '目录';
  }
  if (state === CLOUD_DISPLAY_DOWNLOADING) {
    return '下载中';
  }
  if (state === CLOUD_DISPLAY_DOWNLOADED) {
    return '已下载';
  }
  if (state === CLOUD_DISPLAY_OUTDATED) {
    return '可更新';
  }
  if (state === CLOUD_DISPLAY_ERROR) {
    return '错误';
  }
  return '云端';
}

export function formatFileSize(size: number): string {
  if (!size || size <= 0) {
    return '';
  }
  if (size < 1024) {
    return size + ' B';
  }
  if (size < 1024 * 1024) {
    return (size / 1024).toFixed(1) + ' KB';
  }
  if (size < 1024 * 1024 * 1024) {
    return (size / (1024 * 1024)).toFixed(1) + ' MB';
  }
  return (size / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

export function formatModifiedAt(ms: number): string {
  if (!ms || ms <= 0) {
    return '';
  }
  const d = new Date(ms);
  const y = d.getFullYear();
  const m = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  const hh = d.getHours().toString().padStart(2, '0');
  const mm = d.getMinutes().toString().padStart(2, '0');
  return y + '-' + m + '-' + day + ' ' + hh + ':' + mm;
}
