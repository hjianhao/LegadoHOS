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
/** 百度网盘 Provider（OAuth2 + xpan API）。 */
export const CLOUD_PROVIDER_BAIDU_NETDISK: CloudProviderType = 'baidu-netdisk';

/** 百度网盘 xpan API 根。 */
export const BAIDU_NETDISK_ENDPOINT = 'https://pan.baidu.com/rest/2.0/xpan';
/** 默认回调（须在开放平台与 module.json5 同步登记）。 */
export const BAIDU_DEFAULT_REDIRECT_URI = 'aireader://auth';
/** 项目登记的默认 AppKey（公开 client_id，非密钥）。 */
export const BAIDU_DEFAULT_APP_KEY = 'QgvMzblpDjr1g31yeRj2qhoeq7MguJ6h';
/**
 * 与默认 AppKey 配对的 Secret（仅本机开发配置；用户可在编辑页覆盖）。
 * 若开放平台重置过 Secret，须改此处或编辑页填写新值。
 */
export const BAIDU_DEFAULT_APP_SECRET = 'FeLNtCtep7BC2tUgQ1ZX8gNW6dpo0i5j';

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

/** 百度网盘非敏感配置（AppSecret / Token 不在此）。 */
export interface BaiduNetdiskConfig {
  appKey: string;
  redirectUri: string;
  scope: string;
  pageSize: number;
}

export interface CloudCredential {
  username: string;
  secret: string;
}

/**
 * OAuth2 凭证（v2）。
 * clientSecret / accessToken / refreshToken 仅允许进入 CloudCredentialStore。
 */
export interface OAuth2Credential {
  kind: 'oauth2';
  clientSecret: string;
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
    appKey: BAIDU_DEFAULT_APP_KEY,
    redirectUri: BAIDU_DEFAULT_REDIRECT_URI,
    // 百度文档与开放平台多为空格分隔；逗号在部分应用类型下也会通过
    scope: 'basic netdisk',
    pageSize: 100,
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
    clientSecret: '',
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

/** 已支持的 Provider 类型（供编辑页选择）。 */
export function listSupportedCloudProviderTypes(): string[] {
  return [CLOUD_PROVIDER_WEBDAV, CLOUD_PROVIDER_LOCAL_FOLDER, CLOUD_PROVIDER_BAIDU_NETDISK];
}

/** 解析百度 configJson；失败返回默认值。 */
export function parseBaiduNetdiskConfig(configJson: string): BaiduNetdiskConfig {
  const defaults = createDefaultBaiduNetdiskConfig();
  if (!configJson) {
    return defaults;
  }
  try {
    const obj = JSON.parse(configJson) as Record<string, string | number>;
    if (typeof obj['appKey'] === 'string' && (obj['appKey'] as string).length > 0) {
      defaults.appKey = obj['appKey'] as string;
    }
    if (typeof obj['redirectUri'] === 'string' && (obj['redirectUri'] as string).length > 0) {
      defaults.redirectUri = obj['redirectUri'] as string;
    }
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
    'appKey': cfg.appKey || '',
    'redirectUri': cfg.redirectUri || BAIDU_DEFAULT_REDIRECT_URI,
    'scope': cfg.scope || 'basic,netdisk',
    'pageSize': cfg.pageSize > 0 ? cfg.pageSize : 100,
  };
  return JSON.stringify(row);
}
