/**
 * 云端来源领域模型
 *
 * 一个来源 = 一组 endpoint + 独立 rootPath + 凭证引用。
 * 同一 endpoint 可配置多个来源；敏感凭证不落本对象。
 */

/** Provider 类型；通过 Registry 按协议扩展。 */
export type CloudProviderType = string;

export const CLOUD_PROVIDER_WEBDAV: CloudProviderType = 'webdav';
/** 应用沙箱本地目录 Provider（验证 Registry 可扩展性，非外部网盘）。 */
export const CLOUD_PROVIDER_LOCAL_FOLDER: CloudProviderType = 'localfolder';
/** 百度网盘 Provider（OAuth2 + xpan API）。 */
export const CLOUD_PROVIDER_BAIDU_NETDISK: CloudProviderType = 'baidu-netdisk';
/** OPDS 1.x / 2.0 在线出版物目录（只读）。 */
export const CLOUD_PROVIDER_OPDS: CloudProviderType = 'opds';

/** 百度网盘 xpan API 根。 */
export const BAIDU_NETDISK_ENDPOINT = 'https://pan.baidu.com/rest/2.0/xpan';
/** 固定回调（须在开放平台与 module.json5 同步登记）。 */
export const BAIDU_DEFAULT_REDIRECT_URI = 'aireader://auth';
/** Project Gutenberg 官方 OPDS 1.x 根目录（包含热门、最新、随机等导航）。 */
export const PROJECT_GUTENBERG_OPDS_ENDPOINT = 'https://www.gutenberg.org/ebooks.opds/';
/** 早期内置版本使用的搜索结果页，启动时迁移到真正的根目录。 */
export const PROJECT_GUTENBERG_LEGACY_OPDS_ENDPOINT = 'https://www.gutenberg.org/ebooks/search.opds/';
export const PROJECT_GUTENBERG_SOURCE_NAME = 'Project Gutenberg';
export const PROJECT_GUTENBERG_BUILTIN_KEY = 'project-gutenberg';
export const DEFAULT_OPDS_USER_AGENT =
  'LegadoHOS/1.0 (+https://github.com/hjianhao/LegadoHOS/issues)';

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

/** 百度网盘来源的非敏感配置。OAuth 应用配置由令牌中转服务统一管理。 */
export interface BaiduNetdiskConfig {
  scope: string;
  pageSize: number;
}

/** OPDS 非敏感配置。账号密码仍只进入 CloudCredentialStore。 */
export interface OpdsCloudConfig {
  connectTimeoutMs: number;
  transferTimeoutMs: number;
  userAgent: string;
  builtin: string;
}

export interface CloudCredential {
  username: string;
  secret: string;
}

/**
 * OAuth2 凭证（v3）。
 * Access/Refresh Token 仅允许进入 CloudCredentialStore；AppSecret 永不进入 App。
 */
export interface OAuth2Credential {
  kind: 'oauth2';
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: number;
  tokenScope: string;
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

export function createDefaultBaiduNetdiskConfig(): BaiduNetdiskConfig {
  return {
    // 百度文档与开放平台多为空格分隔；逗号在部分应用类型下也会通过
    scope: 'basic netdisk',
    pageSize: 100,
  };
}

export function createDefaultOpdsCloudConfig(): OpdsCloudConfig {
  return {
    connectTimeoutMs: 20000,
    transferTimeoutMs: 120000,
    // Project Gutenberg 要求 OPDS 客户端携带带联系地址的明确 User-Agent。
    userAgent: DEFAULT_OPDS_USER_AGENT,
    builtin: '',
  };
}

export function createEmptyCloudCredential(): CloudCredential {
  return {
    username: '',
    secret: '',
  };
}

export function createEmptyOAuth2Credential(): OAuth2Credential {
  return {
    kind: 'oauth2',
    accessToken: '',
    refreshToken: '',
    accessTokenExpiresAt: 0,
    tokenScope: '',
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
  if (t === CLOUD_PROVIDER_BAIDU_NETDISK) {
    return '百度网盘';
  }
  if (t === CLOUD_PROVIDER_OPDS) {
    return 'OPDS';
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

export function isBaiduNetdiskProvider(type: string): boolean {
  return (type || '').trim() === CLOUD_PROVIDER_BAIDU_NETDISK;
}

export function isOpdsProvider(type: string): boolean {
  return (type || '').trim() === CLOUD_PROVIDER_OPDS;
}

export function isProjectGutenbergSource(source: CloudSource): boolean {
  if (!source || !isOpdsProvider(source.providerType)) {
    return false;
  }
  const endpoint = (source.endpoint || '').trim().replace(new RegExp('/+$'), '');
  if (endpoint === PROJECT_GUTENBERG_OPDS_ENDPOINT.replace(new RegExp('/+$'), '')) {
    return true;
  }
  try {
    const cfg = JSON.parse(source.configJson || '{}') as Record<string, string | number>;
    return cfg['builtin'] === PROJECT_GUTENBERG_BUILTIN_KEY;
  } catch (_e) {
    return false;
  }
}

/** 可供用户新建的 Provider 类型；localfolder 仅保留旧数据兼容与内部演示。 */
export function listSupportedCloudProviderTypes(): string[] {
  return [CLOUD_PROVIDER_WEBDAV, CLOUD_PROVIDER_OPDS, CLOUD_PROVIDER_BAIDU_NETDISK];
}

/** 解析百度 configJson；失败返回默认值。 */
export function parseBaiduNetdiskConfig(configJson: string): BaiduNetdiskConfig {
  const defaults = createDefaultBaiduNetdiskConfig();
  if (!configJson) {
    return defaults;
  }
  try {
    const obj = JSON.parse(configJson) as Record<string, string | number>;
    if (typeof obj['scope'] === 'string' && (obj['scope'] as string).length > 0) {
      defaults.scope = obj['scope'] as string;
    }
    if (typeof obj['pageSize'] === 'number' && (obj['pageSize'] as number) > 0) {
      defaults.pageSize = obj['pageSize'] as number;
    }
  } catch (_e) {
    // ignore
  }
  return defaults;
}

export function stringifyBaiduNetdiskConfig(cfg: BaiduNetdiskConfig): string {
  const row: Record<string, string | number> = {
    'scope': cfg.scope || 'basic,netdisk',
    'pageSize': cfg.pageSize > 0 ? cfg.pageSize : 100,
  };
  return JSON.stringify(row);
}

export function parseOpdsCloudConfig(configJson: string): OpdsCloudConfig {
  const defaults = createDefaultOpdsCloudConfig();
  if (!configJson) {
    return defaults;
  }
  try {
    const obj = JSON.parse(configJson) as Record<string, string | number>;
    if (typeof obj['connectTimeoutMs'] === 'number' && (obj['connectTimeoutMs'] as number) > 0) {
      defaults.connectTimeoutMs = obj['connectTimeoutMs'] as number;
    }
    if (typeof obj['transferTimeoutMs'] === 'number' && (obj['transferTimeoutMs'] as number) > 0) {
      defaults.transferTimeoutMs = obj['transferTimeoutMs'] as number;
    }
    if (typeof obj['userAgent'] === 'string' && (obj['userAgent'] as string).trim()) {
      defaults.userAgent = (obj['userAgent'] as string).trim();
    }
    if (typeof obj['builtin'] === 'string') {
      defaults.builtin = obj['builtin'] as string;
    }
  } catch (_e) {
    // 使用默认配置
  }
  return defaults;
}

export function stringifyOpdsCloudConfig(cfg: OpdsCloudConfig): string {
  const row: Record<string, string | number> = {
    'connectTimeoutMs': cfg.connectTimeoutMs > 0 ? cfg.connectTimeoutMs : 20000,
    'transferTimeoutMs': cfg.transferTimeoutMs > 0 ? cfg.transferTimeoutMs : 120000,
    'userAgent': cfg.userAgent || createDefaultOpdsCloudConfig().userAgent,
    'builtin': cfg.builtin || '',
  };
  return JSON.stringify(row);
}
