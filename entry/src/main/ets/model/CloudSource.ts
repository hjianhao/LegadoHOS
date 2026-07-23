/**
 * 云端来源领域模型
 *
 * 一个来源 = 一组 endpoint + 独立 rootPath + 凭证引用。
 * 同一 endpoint 可配置多个来源；敏感凭证不落本对象。
 */

/** Provider 类型；webdav 为首期，localfolder 为阶段 7 扩展示例。 */
export type CloudProviderType = string;

export const CLOUD_PROVIDER_WEBDAV: CloudProviderType = 'webdav';
/** 应用沙箱本地目录 Provider（验证 Registry 可扩展性，非外部网盘）。 */
export const CLOUD_PROVIDER_LOCAL_FOLDER: CloudProviderType = 'localfolder';

export interface CloudSource {
  id: number;
  name: string;
  providerType: CloudProviderType;
  /** 服务根地址；不包含 rootPath。 */
  endpoint: string;
  /** 相对 endpoint 的独立根目录；'' 表示 endpoint 自身。 */
  rootPath: string;
  /** 非敏感配置 JSON（超时、字符集等）。 */
  configJson: string;
  /** SettingsStore 中的凭证命名空间键，不保存密码本身。 */
  credentialRef: string;
  enabled: boolean;
  sortNumber: number;
  createdAt: number;
  updatedAt: number;
}

/** WebDAV 非敏感配置（用户名/密码不在此）。 */
export interface WebDavCloudConfig {
  connectTimeoutMs: number;
  transferTimeoutMs: number;
  charset: string;
}

/** 本地目录 Provider 非敏感配置。 */
export interface LocalFolderCloudConfig {
  /** list 分页大小；默认 50。 */
  pageSize: number;
  /**
   * 若为 true，则 credential.secret 作为访问口令，不匹配则拒绝操作。
   * 默认 false（开放访问，secret 仅作占位）。
   */
  requireToken: boolean;
}

export interface CloudCredential {
  username: string;
  secret: string;
}

export function createDefaultCloudSource(): CloudSource {
  const now = Date.now();
  return {
    id: 0,
    name: '',
    providerType: CLOUD_PROVIDER_WEBDAV,
    endpoint: '',
    rootPath: '',
    configJson: '{}',
    credentialRef: '',
    enabled: true,
    sortNumber: 0,
    createdAt: now,
    updatedAt: now,
  };
}

export function createDefaultWebDavCloudConfig(): WebDavCloudConfig {
  return {
    connectTimeoutMs: 15000,
    transferTimeoutMs: 60000,
    charset: 'utf-8',
  };
}

export function createDefaultLocalFolderCloudConfig(): LocalFolderCloudConfig {
  return {
    pageSize: 50,
    requireToken: false,
  };
}

export function createEmptyCloudCredential(): CloudCredential {
  return {
    username: '',
    secret: '',
  };
}

/** UI / 列表展示用名称。 */
export function cloudProviderDisplayName(type: string): string {
  const t = (type || '').trim();
  if (t === CLOUD_PROVIDER_WEBDAV) {
    return 'WebDAV';
  }
  if (t === CLOUD_PROVIDER_LOCAL_FOLDER) {
    return '本地演示目录';
  }
  return t || '未知';
}

export function isLocalFolderProvider(type: string): boolean {
  return (type || '').trim() === CLOUD_PROVIDER_LOCAL_FOLDER;
}

export function isWebDavProvider(type: string): boolean {
  const t = (type || '').trim();
  return !t || t === CLOUD_PROVIDER_WEBDAV;
}

/** 已支持的 Provider 类型（供编辑页选择）。 */
export function listSupportedCloudProviderTypes(): string[] {
  return [CLOUD_PROVIDER_WEBDAV, CLOUD_PROVIDER_LOCAL_FOLDER];
}
