/**
 * LoginInfoStore — 书源登录凭据存储（参照 Android Legado putLoginInfo/getLoginInfo）
 *
 * 按书源 URL 持久化登录信息 JSON。敏感内容存入 HarmonyOS Asset Store，
 * Preferences 只保留不含凭据的索引标记。旧版 Preferences 明文会在启动时自动迁移。
 */
import preferences from '@ohos.data.preferences';
import asset from '@ohos.security.asset';
import util from '@ohos.util';

const LOGIN_STORE_NAME = 'legado_login_info';
const ASSET_MARKER = 'asset:v1';
const ASSET_ALIAS_PREFIX = 'legado_login:';
const ASSET_NAMESPACE = 'LegadoHOS.LoginInfo';

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
          const stored = all[key] as string;
          if (stored === ASSET_MARKER) {
            const secret = await this.readAsset(key);
            if (secret) this.memoryCache_.set(key, secret);
          } else if (stored) {
            // 旧版明文：先放入内存保证当次兼容，再迁移到 Asset Store。
            this.memoryCache_.set(key, stored);
            await this.persistAsset(key, stored);
          }
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
        await this.writeAsset(sourceKey, json);
        this.prefStore_.putSync(sourceKey, ASSET_MARKER);
        this.prefStore_.flush();
      } catch (err) {
        // 安全存储不可用时仅保留内存会话，绝不回退到明文落盘。
        try {
          this.prefStore_.deleteSync(sourceKey);
          this.prefStore_.flush();
        } catch (_cleanupError) { /* 后续启动迁移会再次清理 */ }
        console.warn('[LoginInfoStore] secure persist failed, using memory only:', (err as Error).message);
      }
    }
  }

  async remove(sourceKey: string): Promise<void> {
    this.memoryCache_.delete(sourceKey);
    try {
      await asset.remove(this.assetQuery(sourceKey));
    } catch (_assetError) { /* 记录不存在时无需处理 */ }
    if (this.prefStore_) {
      try {
        this.prefStore_.deleteSync(sourceKey);
        this.prefStore_.flush();
      } catch (_e) { /* ignore */ }
    }
  }

  private async persistAsset(sourceKey: string, json: string): Promise<void> {
    if (!this.prefStore_) return;
    try {
      await this.writeAsset(sourceKey, json);
      this.prefStore_.putSync(sourceKey, ASSET_MARKER);
    } catch (err) {
      console.warn('[LoginInfoStore] legacy credential migration failed:', (err as Error).message);
      // 即使迁移失败也删除磁盘明文，当次运行仍可使用内存副本。
      try {
        this.prefStore_.deleteSync(sourceKey);
      } catch (_cleanupError) { /* 下次启动继续迁移 */ }
    }
    try {
      this.prefStore_.flush();
    } catch (_flushError) { /* 内存会话仍可用 */ }
  }

  private async writeAsset(sourceKey: string, json: string): Promise<void> {
    try {
      await asset.remove(this.assetQuery(sourceKey));
    } catch (_e) { /* 允许首次写入 */ }
    const attributes: asset.AssetMap = this.assetQuery(sourceKey);
    attributes.set(asset.Tag.SECRET, this.encode(json));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.DATA_LABEL_CRITICAL_1, this.encode(ASSET_NAMESPACE));
    try {
      await asset.add(attributes);
    } catch (err) {
      throw new Error('安全凭据写入失败：' + ((err as Error).message || String(err)));
    }
  }

  private async readAsset(sourceKey: string): Promise<string> {
    try {
      const query = this.assetQuery(sourceKey);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result = await asset.query(query);
      if (result.length === 0) return '';
      const bytes = result[0].get(asset.Tag.SECRET);
      return bytes instanceof Uint8Array ? this.decode(bytes) : '';
    } catch (_e) {
      return '';
    }
  }

  private assetQuery(sourceKey: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.encode(ASSET_ALIAS_PREFIX + sourceKey));
    return query;
  }

  private encode(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private decode(value: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(value);
  }
}
