/**
 * 云端书库多来源凭证存储（独立 Preferences，不经 SettingsStore）
 *
 * 历史问题：经 SettingsStore.putSecret 双层 JSON + 加密链路不稳定，
 * 导致凭证读回为空，随后 update 又用空值覆盖。
 *
 * 现方案：
 * - 独立 store：legado_cloud_credentials
 * - 键：ref 规范化后的字符串（去掉冒号，避免部分 Preferences 实现异常）
 * - 值：JSON { username, secret }，UTF-8 安全序列化
 * - 必须 init(context) 后使用
 */
import preferences from '@ohos.data.preferences';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { CloudCredential, createEmptyCloudCredential } from '../../model/CloudSource';

const STORE_NAME = 'legado_cloud_credentials';
const KEY_PREFIX = 'cc_';

interface CloudCredentialPayload {
  username: string;
  secret: string;
  v: number;
}

export class CloudCredentialStore {
  private static instance: CloudCredentialStore | null = null;
  private pref_: preferences.Preferences | null = null;
  private memory_: Map<string, CloudCredentialPayload> = new Map();
  private initPromise_: Promise<void> | null = null;

  private constructor() {}

  static getInstance(): CloudCredentialStore {
    if (!CloudCredentialStore.instance) {
      CloudCredentialStore.instance = new CloudCredentialStore();
    }
    return CloudCredentialStore.instance;
  }

  async init(context: Context): Promise<void> {
    if (this.pref_) {
      return;
    }
    if (this.initPromise_) {
      await this.initPromise_;
      return;
    }
    this.initPromise_ = this.doInit_(context);
    try {
      await this.initPromise_;
    } finally {
      this.initPromise_ = null;
    }
  }

  private async doInit_(context: Context): Promise<void> {
    try {
      this.pref_ = await preferences.getPreferences(context, STORE_NAME);
      // 预热到内存，避免后续同步路径丢数据
      try {
        const all = this.pref_.getAllSync() as Record<string, Object>;
        const keys = Object.keys(all);
        for (let i = 0; i < keys.length; i++) {
          const k = keys[i];
          if (!k.startsWith(KEY_PREFIX)) {
            continue;
          }
          const raw = all[k];
          if (typeof raw === 'string' && (raw as string).length > 0) {
            const payload = this.parsePayload_(raw as string);
            if (payload) {
              this.memory_.set(k, payload);
            }
          }
        }
      } catch (e) {
        console.warn('[CloudCredentialStore] preload failed:', (e as Error).message);
      }
      console.info('[CloudCredentialStore] init OK, memory keys=', this.memory_.size);
    } catch (err) {
      this.pref_ = null;
      console.error('[CloudCredentialStore] init failed:', (err as Error).message);
      throw new Error('云端凭证存储初始化失败: ' + (err as Error).message);
    }
  }

  isReady(): boolean {
    return this.pref_ !== null;
  }

  /**
   * 生成新的 credentialRef（落库用）。
   * 格式：cloud-source-<hex>，避免冒号便于 Preferences / 日志处理。
   */
  generateCredentialRef(): string {
    try {
      const randomData = cryptoFramework.createRandom().generateRandomSync(16);
      const bytes = randomData.data;
      let hex = '';
      for (let i = 0; i < bytes.length; i++) {
        const h = bytes[i].toString(16);
        hex += h.length === 1 ? '0' + h : h;
      }
      return 'cloud-source-' + hex;
    } catch (_e) {
      const t = Date.now().toString(36);
      const r = Math.floor(Math.random() * 1e9).toString(36);
      return 'cloud-source-' + t + r;
    }
  }

  async setCloudCredential(ref: string, credential: CloudCredential): Promise<void> {
    const key = this.prefKey_(ref);
    if (!key) {
      throw new Error('credentialRef 不能为空');
    }
    this.ensureReady_();
    const payload: CloudCredentialPayload = {
      username: credential.username || '',
      secret: credential.secret || '',
      v: 1,
    };
    const json = JSON.stringify(payload);
    this.memory_.set(key, payload);
    try {
      await this.pref_!.put(key, json);
      await this.pref_!.flush();
      console.info('[CloudCredentialStore] saved ref=', this.safeRef_(ref),
        ' userLen=', payload.username.length, ' secretLen=', payload.secret.length);
    } catch (e) {
      this.memory_.delete(key);
      throw new Error('保存凭证失败: ' + ((e as Error).message || String(e)));
    }
  }

  async getCloudCredential(ref: string): Promise<CloudCredential | null> {
    const key = this.prefKey_(ref);
    if (!key) {
      return null;
    }
    // 允许仅内存命中（极端：pref 暂未 flush 完成）
    const mem = this.memory_.get(key);
    if (mem) {
      return this.toCredential_(mem);
    }
    if (!this.pref_) {
      console.warn('[CloudCredentialStore] get before init, ref=', this.safeRef_(ref));
      return null;
    }
    try {
      const raw = await this.pref_.get(key, '') as string;
      if (!raw) {
        // 兼容旧键：cloud_cred:cloud-source:xxx（曾用 SettingsStore 路径）
        return null;
      }
      const payload = this.parsePayload_(raw);
      if (!payload) {
        return null;
      }
      this.memory_.set(key, payload);
      return this.toCredential_(payload);
    } catch (e) {
      console.warn('[CloudCredentialStore] get failed:', this.safeRef_(ref), (e as Error).message);
      return null;
    }
  }

  async deleteCloudCredential(ref: string): Promise<void> {
    const key = this.prefKey_(ref);
    if (!key) {
      return;
    }
    this.memory_.delete(key);
    if (!this.pref_) {
      return;
    }
    try {
      await this.pref_.delete(key);
      await this.pref_.flush();
    } catch (e) {
      console.warn('[CloudCredentialStore] delete failed:', this.safeRef_(ref), (e as Error).message);
    }
  }

  /** 是否已有非空密码（编辑页提示用，不回显明文）。 */
  async hasSecret(ref: string): Promise<boolean> {
    const cred = await this.getCloudCredential(ref);
    return !!(cred && cred.secret && cred.secret.length > 0);
  }

  private toCredential_(payload: CloudCredentialPayload): CloudCredential {
    const cred = createEmptyCloudCredential();
    cred.username = payload.username || '';
    cred.secret = payload.secret || '';
    return cred;
  }

  private parsePayload_(raw: string): CloudCredentialPayload | null {
    try {
      const parsed = JSON.parse(raw) as CloudCredentialPayload;
      if (!parsed || typeof parsed !== 'object') {
        return null;
      }
      const payload: CloudCredentialPayload = {
        username: typeof parsed.username === 'string' ? parsed.username : '',
        secret: typeof parsed.secret === 'string' ? parsed.secret : '',
        v: 1,
      };
      return payload;
    } catch (_e) {
      return null;
    }
  }

  private prefKey_(ref: string): string {
    let r = (ref || '').trim();
    if (!r) {
      return '';
    }
    // 统一去掉前缀与冒号，生成稳定 Preferences 键
    if (r.indexOf('cloud_cred:') === 0) {
      r = r.substring('cloud_cred:'.length);
    }
    // cloud-source:hex 或 cloud-source-hex → cloud_source_hex
    r = r.replace(new RegExp(':', 'g'), '-');
    return KEY_PREFIX + r;
  }

  private ensureReady_(): void {
    if (!this.pref_) {
      throw new Error('CloudCredentialStore 未初始化，请先 init(context)');
    }
  }

  private safeRef_(ref: string): string {
    const r = (ref || '').trim();
    if (r.length <= 24) {
      return r;
    }
    return r.substring(0, 24) + '...';
  }
}
