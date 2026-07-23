/**
 * 云存储 Provider 抽象
 *
 * 仅负责协议：认证、列举、元数据、上传、下载、删除、建目录。
 * 不包含 UI、Book 入库或 Binding 业务。
 */
import { CloudCredential, CloudProviderType, CloudSource } from '../../model/CloudSource';

export interface CloudFile {
  /** 相对于 CloudSource.rootPath，例如 '小说/三体.epub'。 */
  remotePath: string;
  name: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: number;
  etag: string;
  contentType: string;
  remoteId: string;
}

export interface CloudListPage {
  items: CloudFile[];
  /** 分页型网盘的下一页游标；无分页时为空。 */
  nextCursor: string;
}

export interface CloudProviderCapabilities {
  canCreateDirectory: boolean;
  canDelete: boolean;
  canMove: boolean;
  supportsEtag: boolean;
  supportsRangeDownload: boolean;
}

export function createEmptyCloudFile(): CloudFile {
  return {
    remotePath: '',
    name: '',
    isDirectory: false,
    size: 0,
    modifiedAt: 0,
    etag: '',
    contentType: '',
    remoteId: '',
  };
}

export function createEmptyCloudListPage(): CloudListPage {
  return {
    items: [],
    nextCursor: '',
  };
}

export function defaultCloudProviderCapabilities(): CloudProviderCapabilities {
  return {
    canCreateDirectory: false,
    canDelete: false,
    canMove: false,
    supportsEtag: false,
    supportsRangeDownload: false,
  };
}

/**
 * 协议实现接口。
 * 阶段 1 仅定义契约；WebDAV 实现见阶段 2。
 */
export interface CloudStorageProvider {
  readonly type: CloudProviderType;

  getCapabilities(): CloudProviderCapabilities;

  testConnection(source: CloudSource, credential: CloudCredential): Promise<void>;

  list(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    cursor?: string
  ): Promise<CloudListPage>;

  stat(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<CloudFile | null>;

  downloadToFile(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    tempPath: string,
    onProgress?: (received: number, total: number) => void
  ): Promise<void>;

  uploadFile(
    source: CloudSource,
    credential: CloudCredential,
    localPath: string,
    remotePath: string,
    onProgress?: (sent: number, total: number) => void
  ): Promise<CloudFile>;

  createDirectory?(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void>;

  delete?(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void>;
}
