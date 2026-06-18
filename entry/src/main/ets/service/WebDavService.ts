/**
 * WebDAV 同步服务
 *
 * 实现阅读进度同步和备份/恢复功能。
 * 兼容 Legado 的 WebDAV 数据格式。
 *
 * WebDAV 协议基于 HTTP 扩展，支持：
 * - PROPFIND（列表）
 * - GET（下载）
 * - PUT（上传）
 * - MKCOL（创建目录）
 */
import { NetUtil } from '../util/NetUtil';

export interface WebDavConfig {
  serverUrl: string;
  username: string;
  password: string;
  path: string;            // 同步根路径
  autoSync: boolean;
  syncInterval: number;    // 分钟
}

export class WebDavService {
  private static instance: WebDavService;
  private config: WebDavConfig | null = null;

  private constructor() {}

  static getInstance(): WebDavService {
    if (!WebDavService.instance) {
      WebDavService.instance = new WebDavService();
    }
    return WebDavService.instance;
  }

  /**
   * 配置 WebDAV
   */
  configure(config: WebDavConfig): void {
    this.config = config;
  }

  /**
   * 上传阅读进度
   */
  async uploadProgress(bookId: number, progress: string): Promise<void> {
    if (!this.config) throw new Error('WebDAV not configured');

    const url = `${this.config.serverUrl}${this.config.path}/progress_${bookId}.json`;
    const auth = this.getAuthHeader();

    await NetUtil.httpPut(url, progress, {
      ...auth,
      'Content-Type': 'application/json',
    });
  }

  /**
   * 下载阅读进度
   */
  async downloadProgress(bookId: number): Promise<string | null> {
    if (!this.config) return null;

    const url = `${this.config.serverUrl}${this.config.path}/progress_${bookId}.json`;
    const auth = this.getAuthHeader();

    try {
      return await NetUtil.httpGet(url, auth);
    } catch {
      return null;
    }
  }

  /**
   * 上传备份（全量）
   */
  async uploadBackup(data: string): Promise<void> {
    if (!this.config) throw new Error('WebDAV not configured');

    const url = `${this.config.serverUrl}${this.config.path}/backup.json`;
    const auth = this.getAuthHeader();

    await NetUtil.httpPut(url, data, {
      ...auth,
      'Content-Type': 'application/json',
    });
  }

  /**
   * 下载备份
   */
  async downloadBackup(): Promise<string | null> {
    if (!this.config) return null;

    const url = `${this.config.serverUrl}${this.config.path}/backup.json`;
    const auth = this.getAuthHeader();

    try {
      return await NetUtil.httpGet(url, auth);
    } catch {
      return null;
    }
  }

  /**
   * 同步所有进度（双向）
   */
  async syncAll(localProgress: Record<number, string>): Promise<Record<number, string>> {
    const merged: Record<number, string> = { ...localProgress };

    for (const bookIdStr of Object.keys(localProgress)) {
      const bookId = parseInt(bookIdStr);
      const remote = await this.downloadProgress(bookId);
      if (remote) {
        // 取最新的（简单策略：取进度更大的）
        const local = localProgress[bookId];
        try {
          const localP = JSON.parse(local).progress || 0;
          const remoteP = JSON.parse(remote).progress || 0;
          if (remoteP > localP) {
            merged[bookId] = remote;
          } else if (localP > remoteP) {
            await this.uploadProgress(bookId, local);
          }
        } catch {
          merged[bookId] = local;
        }
      }
    }

    return merged;
  }

  private getAuthHeader(): Record<string, string> {
    if (!this.config) return {};
    const credentials = `${this.config.username}:${this.config.password}`;
    const encoded = this.base64Encode(credentials);
    return {
      'Authorization': `Basic ${encoded}`,
    };
  }

  private base64Encode(str: string): string {
    const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    const bytes = new Uint8Array(str.split('').map(c => c.charCodeAt(0)));
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i], b1 = bytes[i + 1] || 0, b2 = bytes[i + 2] || 0;
      result += b64[b0 >> 2];
      result += b64[((b0 & 3) << 4) | (b1 >> 4)];
      result += (i + 1 < bytes.length) ? b64[((b1 & 0xF) << 2) | (b2 >> 6)] : '=';
      result += (i + 2 < bytes.length) ? b64[b2 & 0x3F] : '=';
    }
    return result;
  }
}
