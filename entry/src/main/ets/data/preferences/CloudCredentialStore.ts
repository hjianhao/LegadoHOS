/**
 * 云端书库多来源凭证存储（独立 Preferences，不经 SettingsStore）
 *
 * - 独立 store：legado_cloud_credentials
 * - v1 basic：{ username, secret, v: 1 }
 * - v2 oauth2：{ kind: 'oauth2', clientSecret, accessToken, refreshToken, ... , v: 2 }
 * - Token / clientSecret 永不进入备份与日志
 */
import preferences from '@ohos.data.preferences';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  CloudCredential,
  createEmptyCloudCredential,
  createEmptyOAuth2Credential,
  OAuth2Credential,
} from '../../model/CloudSource';

const STORE_NAME = 'legado_cloud_credentials';
const KEY_PREFIX = 'cc_';

interface BasicCredentialPayload {
  username: string;
  secret: string;
  v: number;
  kind?: string;
}

interface OAuth2CredentialPayload {
  kind: string;
  clientSecret: string;
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: number;
  tokenScope: string;
  v: number;
}

type AnyPayload = BasicCredentialPayload | OAuth2CredentialPayload;

export class CloudCredentialStore {
  private static instance: CloudCredentialStore | null = null;
  private pref_: preferences.Preferences | null = null;
  private memory_: Map<string, AnyPayload> = new Map();
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
            const payload = this.parseAnyPayload_(raw as string);
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
    const payload: BasicCredentialPayload = {
      username: credential.username || '',
      secret: credential.secret || '',
      v: 1,
      kind: 'basic',
    };
    await this.writePayload_(key, ref, payload);
  }

  async setOAuth2Credential(ref: string, oauth: OAuth2Credential): Promise<void> {
    const key = this.prefKey_(ref);
    if (!key) {
      throw new Error('credentialRef 不能为空');
    }
    this.ensureReady_();
    const payload: OAuth2CredentialPayload = {
      kind: 'oauth2',
      clientSecret: oauth.clientSecret || '',
      accessToken: oauth.accessToken || '',
      refreshToken: oauth.refreshToken || '',
      accessTokenExpiresAt: oauth.accessTokenExpiresAt || 0,
      tokenScope: oauth.tokenScope || '',
      v: 2,
    };
    await this.writePayload_(key, ref, payload);
    console.info('[CloudCredentialStore] saved oauth2 ref=', this.safeRef_(ref),
      ' hasAccess=', payload.accessToken.length > 0,
      ' hasRefresh=', payload.refreshToken.length > 0,
      ' exp=', payload.accessTokenExpiresAt);
  }

  async getCloudCredential(ref: string): Promise<CloudCredential | null> {
    const payload = await this.getPayload_(ref);
    if (!payload) {
      return null;
    }
    if (this.isOAuth2Payload_(payload)) {
      // 兼容路径：把 accessToken 映射到 secret，便于旧校验逻辑
      const o = payload as OAuth2CredentialPayload;
      const cred = createEmptyCloudCredential();
      cred.username = 'oauth2';
      cred.secret = o.accessToken || '';
      return cred;
    }
    return this.toBasicCredential_(payload as BasicCredentialPayload);
  }

  async getOAuth2Credential(ref: string): Promise<OAuth2Credential | null> {
    const payload = await this.getPayload_(ref);
    if (!payload || !this.isOAuth2Payload_(payload)) {
      return null;
    }
    const o = payload as OAuth2CredentialPayload;
    const cred = createEmptyOAuth2Credential();
    cred.clientSecret = o.clientSecret || '';
    cred.accessToken = o.accessToken || '';
    cred.refreshToken = o.refreshToken || '';
    cred.accessTokenExpiresAt = o.accessTokenExpiresAt || 0;
    cred.tokenScope = o.tokenScope || '';
    return cred;
  }

  async hasOAuth2(ref: string): Promise<boolean> {
    const o = await this.getOAuth2Credential(ref);
    return !!(o && o.accessToken && o.accessToken.length > 0);
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

  async hasSecret(ref: string): Promise<boolean> {
    const o = await this.getOAuth2Credential(ref);
    if (o && o.accessToken) {
      return true;
    }
    const cred = await this.getCloudCredential(ref);
    return !!(cred && cred.secret && cred.secret.length > 0);
  }

  private async writePayload_(key: string, ref: string, payload: AnyPayload): Promise<void> {
    const json = JSON.stringify(payload);
    this.memory_.set(key, payload);
    try {
      await this.pref_!.put(key, json);
      await this.pref_!.flush();
    } catch (e) {
      this.memory_.delete(key);
      throw new Error('保存凭证失败: ' + ((e as Error).message || String(e)));
    }
  }

  private async getPayload_(ref: string): Promise<AnyPayload | null> {
    const key = this.prefKey_(ref);
    if (!key) {
      return null;
    }
    const mem = this.memory_.get(key);
    if (mem) {
      return mem;
    }
    if (!this.pref_) {
      console.warn('[CloudCredentialStore] get before init, ref=', this.safeRef_(ref));
      return null;
    }
    try {
      const raw = await this.pref_.get(key, '') as string;
      if (!raw) {
        return null;
      }
      const payload = this.parseAnyPayload_(raw);
      if (!payload) {
        return null;
      }
      this.memory_.set(key, payload);
      return payload;
    } catch (e) {
      console.warn('[CloudCredentialStore] get failed:', this.safeRef_(ref), (e as Error).message);
      return null;
    }
  }

  private isOAuth2Payload_(payload: AnyPayload): boolean {
    const p = payload as OAuth2CredentialPayload;
    return p.kind === 'oauth2' || p.v === 2;
  }

  private toBasicCredential_(payload: BasicCredentialPayload): CloudCredential {
    const cred = createEmptyCloudCredential();
    cred.username = payload.username || '';
    cred.secret = payload.secret || '';
    return cred;
  }

  private parseAnyPayload_(raw: string): AnyPayload | null {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (!parsed || typeof parsed !== 'object') {
        return null;
      }
      const kind = typeof parsed['kind'] === 'string' ? parsed['kind'] as string : '';
      const v = typeof parsed['v'] === 'number' ? parsed['v'] as number : 1;
      if (kind === 'oauth2' || v === 2) {
        const payload: OAuth2CredentialPayload = {
          kind: 'oauth2',
          clientSecret: typeof parsed['clientSecret'] === 'string' ? parsed['clientSecret'] as string : '',
          accessToken: typeof parsed['accessToken'] === 'string' ? parsed['accessToken'] as string : '',
          refreshToken: typeof parsed['refreshToken'] === 'string' ? parsed['refreshToken'] as string : '',
          accessTokenExpiresAt: typeof parsed['accessTokenExpiresAt'] === 'number'
            ? parsed['accessTokenExpiresAt'] as number : 0,
          tokenScope: typeof parsed['tokenScope'] === 'string' ? parsed['tokenScope'] as string : '',
          v: 2,
        };
        return payload;
      }
      const basic: BasicCredentialPayload = {
        username: typeof parsed['username'] === 'string' ? parsed['username'] as string : '',
        secret: typeof parsed['secret'] === 'string' ? parsed['secret'] as string : '',
        v: 1,
        kind: 'basic',
      };
      return basic;
    } catch (_e) {
      return null;
    }
  }

  private prefKey_(ref: string): string {
    let r = (ref || '').trim();
    if (!r) {
      return '';
    }
    if (r.indexOf('cloud_cred:') === 0) {
      r = r.substring('cloud_cred:'.length);
    }
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
