/**
 * LoginInfoStore — 书源登录凭据存储（参照 Android Legado putLoginInfo/getLoginInfo）
 *
 * 按书源 URL 持久化登录信息 JSON（{"账号":"...","密码":"..."}）。
 * Android 用 AES 加密，这里用 preferences 应用沙箱存储（与 SettingsStore 同级安全级别）。
 */
import preferences from '@ohos.data.preferences';

const LOGIN_STORE_NAME = 'legado_login_info';

export class LoginInfoStore {
  private static instance: LoginInfoStore;
  private prefStore_: preferences.Preferences | null = null;
  /** sourceUrl → 登录信息 JSON 字符串 */
  private memoryCache_: Map<string, string> = new Map();

  private constructor() {}

  static getInstance(): LoginInfoStore {
    if (!LoginInfoStore.instance) {
      LoginInfoStore.instance = new LoginInfoStore();
    }
    return LoginInfoStore.instance;
  }

  async init(context: Context): Promise<void> {
    if (this.prefStore_) return;
    try {
      this.prefStore_ = await preferences.getPreferences(context, LOGIN_STORE_NAME);
      const all = this.prefStore_.getAllSync() as Record<string, Object>;
      for (const key of Object.keys(all)) {
        if (typeof all[key] === 'string') {
          this.memoryCache_.set(key, all[key] as string);
        }
      }
      console.info('[LoginInfoStore] init OK,', this.memoryCache_.size, 'sources loaded');
    } catch (err) {
      console.error('[LoginInfoStore] init failed:', (err as Error).message);
    }
  }

  /** 同步获取登录信息 JSON（无则返回空串） */
  get(sourceKey: string): string {
    if (!sourceKey) return '';
    return this.memoryCache_.get(sourceKey) || '';
  }

  async put(sourceKey: string, json: string): Promise<void> {
    if (!sourceKey) return;
    if (!json) {
      await this.remove(sourceKey);
      return;
    }
    this.memoryCache_.set(sourceKey, json);
    if (this.prefStore_) {
      try {
        this.prefStore_.putSync(sourceKey, json);
        this.prefStore_.flush();
      } catch (err) {
        console.warn('[LoginInfoStore] persist failed:', (err as Error).message);
      }
    }
  }

  async remove(sourceKey: string): Promise<void> {
    this.memoryCache_.delete(sourceKey);
    if (this.prefStore_) {
      try {
        this.prefStore_.deleteSync(sourceKey);
        this.prefStore_.flush();
      } catch (_e) { /* ignore */ }
    }
  }
}
