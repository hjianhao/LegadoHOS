/**
 * 设置存储
 * 基于 @ohos.data.preferences
 * 敏感数据（API Key 等）使用 HUKS 加密存储
 */
import preferences from '@ohos.data.preferences';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const SETTINGS_STORE_NAME = 'legado_settings';
const HUKS_AI_KEY_ALIAS = 'legado_ai_api_key';

/** HUKS 密文包装 */
interface EncryptedPayload {
  iv: string;
  ciphertext: string;
  authTag: string;
}

/** 可切换的 AI 供应商/模型配置（apiKey 仅在内存中为明文）。 */
export interface AiProviderProfile {
  id: string;
  name: string;
  provider: string;
  endpoint: string;
  apiKey: string;
  model: string;
  /** 单次模型请求超时（秒）。 */
  timeoutSeconds: number;
}

interface StoredAiProviderProfile {
  id: string;
  name: string;
  provider: string;
  endpoint: string;
  encryptedApiKey: string;
  model: string;
  timeoutSeconds?: number;
}

export function normalizeAiTimeoutSeconds(value: number | undefined): number {
  if (value === undefined || isNaN(value) || value <= 0) return 120;
  return Math.floor(value);
}

export function detectAiProvider(endpoint: string): string {
  if (endpoint.includes('deepseek.com')) return 'deepseek';
  if (endpoint.includes('openrouter.ai')) return 'openrouter';
  if (endpoint.includes('siliconflow.cn')) return 'silicon';
  if (endpoint.includes('localhost:11434') || endpoint.includes(':11434/')) return 'ollama';
  if (endpoint.includes('openai.com')) return 'openai';
  return 'custom';
}

export function upsertAiProfile(profiles: AiProviderProfile[], profile: AiProviderProfile): AiProviderProfile[] {
  const exists = profiles.some((item: AiProviderProfile): boolean => item.id === profile.id);
  if (!exists) return [...profiles, profile];
  return profiles.map((item: AiProviderProfile): AiProviderProfile => item.id === profile.id ? profile : item);
}

export class SettingsStore {
  private static instance: SettingsStore;
  private prefStore_: preferences.Preferences | null = null;
  private cryptoReady_: boolean = false;
  private memoryCache_: Map<string, Object> = new Map();

  private constructor() {}

  static getInstance(): SettingsStore {
    if (!SettingsStore.instance) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  async init(context: Context): Promise<void> {
    // 如果已经初始化过，直接返回（避免重复创建 Preferences 实例）
    if (this.prefStore_) return;
    try {
      this.prefStore_ = await preferences.getPreferences(context, SETTINGS_STORE_NAME);
    } catch (err) {
      console.error('[SettingsStore] init failed:', (err as Error).message);
      throw err;
    }
    // cipher 初始化失败不影响设置读写
    await this.initCipher_();
  }

  private async initCipher_(): Promise<void> {
    try {
      await this.createSymKey_();
      this.cryptoReady_ = true;
    } catch (_e) {
      /* 降级：明文存储（加密组件不可用时自动回退） */
      console.warn('[SettingsStore] HUKS init failed, falling back to plaintext');
      this.cryptoReady_ = false;
    }
  }

  /** 创建指定模式的 Cipher 实例 */
  private async createCipher_(mode: cryptoFramework.CryptoMode): Promise<cryptoFramework.Cipher> {
    try {
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const keyData = await this.getEncKeyMaterial_();
      const symKey = await symKeyGenerator.convertKey({ data: keyData });
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      await cipher.init(mode, symKey, null);
      return cipher;
    } catch (err) {
      throw new Error('[SettingsStore] create cipher failed: ' + (err as Error).message);
    }
  }

  private async createSymKey_(): Promise<cryptoFramework.SymKey> {
    try {
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const keyData = await this.getEncKeyMaterial_();
      return await symKeyGenerator.convertKey({ data: keyData });
    } catch (e) {
      throw new Error('[SettingsStore] create symmetric key failed: ' + (e as Error).message);
    }
  }

  /** 从 preferences 获取或生成固定密钥材料 */
  private async getEncKeyMaterial_(): Promise<Uint8Array> {
    try {
      const stored = await this.get('huks_key_material', '') as string;
      if (stored.length === 32) {
        const bytes = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
          bytes[i] = stored.charCodeAt(i);
        }
        return bytes;
      }
      // 首次生成：使用 UUID + timestamp 构造 32 字节种子
      const seed = cryptoFramework.createRandom().generateRandomSync(16);
      const chars: string[] = [];
      for (let i = 0; i < 32; i++) {
        const b = seed[i % 16];
        chars.push(String.fromCharCode((b % 95) + 32));
      }
      const keyStr = chars.join('');
      await this.put('huks_key_material', keyStr);
      const bytes = new Uint8Array(32);
      for (let i = 0; i < 32; i++) {
        bytes[i] = keyStr.charCodeAt(i);
      }
      return bytes;
    } catch (_e) {
      // 极端回退：32 字节随机数据
      const bytes = new Uint8Array(32);
      try {
        const randomGen = cryptoFramework.createRandom();
        const randomData = await randomGen.generateRandom(32);
        for (let i = 0; i < 32; i++) {
          bytes[i] = randomData.data[i];
        }
      } catch (_ignored) {
        for (let i = 0; i < 32; i++) {
          bytes[i] = (Date.now() + i) & 0xFF;
        }
      }
      return bytes;
    }
  }

  /** 使用显式随机 IV 的 AES-GCM 加密，格式为 v2:{iv}:{ciphertext}:{authTag}。 */
  private async encrypt_(plaintext: string): Promise<string> {
    if (!this.cryptoReady_) return plaintext;
    try {
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      const symKey = await this.createSymKey_();
      const randomData = await cryptoFramework.createRandom().generateRandom(12);
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: randomData.data },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(0) },
      };
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
      const plainBytes = new Uint8Array(plaintext.length);
      for (let i = 0; i < plaintext.length; i++) {
        plainBytes[i] = plaintext.charCodeAt(i) & 0xFF;
      }
      const encrypted = await cipher.update({ data: plainBytes });
      const tag = await cipher.doFinal(null);
      const payload: EncryptedPayload = {
        iv: this.bytesToBase64_(Array.from(randomData.data)),
        ciphertext: this.bytesToBase64_(Array.from(encrypted.data)),
        authTag: this.bytesToBase64_(Array.from(tag.data)),
      };
      return 'v2:' + payload.iv + ':' + payload.ciphertext + ':' + payload.authTag;
    } catch (_e) {
      console.warn('[SettingsStore] Encrypt failed, storing plaintext');
      return plaintext;
    }
  }

  /** 解密 base64 → 明文 */
  private async decrypt_(encoded: string): Promise<string> {
    if (!encoded) return encoded;
    if (encoded.startsWith('v2:')) {
      try {
        const parts = encoded.split(':');
        if (parts.length !== 4) return '';
        const payload: EncryptedPayload = { iv: parts[1], ciphertext: parts[2], authTag: parts[3] };
        const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
        const symKey = await this.createSymKey_();
        const params: cryptoFramework.GcmParamsSpec = {
          algName: 'GcmParamsSpec',
          iv: { data: new Uint8Array(this.base64ToBytes_(payload.iv)) },
          aad: { data: new Uint8Array(0) },
          authTag: { data: new Uint8Array(this.base64ToBytes_(payload.authTag)) },
        };
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
        const updated = await cipher.update({ data: new Uint8Array(this.base64ToBytes_(payload.ciphertext)) });
        const finalData = await cipher.doFinal(null);
        const bytes = Array.from(updated.data).concat(Array.from(finalData.data));
        let result = '';
        for (let i = 0; i < bytes.length; i++) result += String.fromCharCode(bytes[i]);
        return result;
      } catch (_e) {
        console.warn('[SettingsStore] Decrypt v2 failed');
        return '';
      }
    }
    try {
      // 兼容旧版本未带格式前缀的密文；成功读取后，下次保存会自动升级为 v2。
      // 创建解密专用的 Cipher 实例
      const cipher = await this.createCipher_(cryptoFramework.CryptoMode.DECRYPT_MODE);
      const bytes = this.base64ToBytes_(encoded);
      const decrypted = await cipher.doFinal({ data: new Uint8Array(bytes) });
      let result = '';
      for (let i = 0; i < decrypted.data.length; i++) {
        result += String.fromCharCode(decrypted.data[i]);
      }
      return result;
    } catch (_e) {
      // 加密组件不可用时旧版本可能曾降级为明文；只保留明显不是 Base64 密文的值。
      console.warn('[SettingsStore] Legacy decrypt failed');
      return /^[A-Za-z0-9+/]+={0,2}$/.test(encoded) ? '' : encoded;
    }
  }

  private bytesToBase64_(bytes: number[]): string {
    const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i];
      const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      result += CHARS.charAt(b0 >> 2);
      result += CHARS.charAt(((b0 & 3) << 4) | (b1 >> 4));
      result += i + 1 < bytes.length ? CHARS.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      result += i + 2 < bytes.length ? CHARS.charAt(b2 & 63) : '=';
    }
    return result;
  }

  private base64ToBytes_(b64: string): number[] {
    const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const result: number[] = [];
    for (let i = 0; i < b64.length; i += 4) {
      const c0 = CHARS.indexOf(b64.charAt(i));
      const c1 = CHARS.indexOf(b64.charAt(i + 1));
      const c2 = i + 2 < b64.length && b64.charAt(i + 2) !== '=' ? CHARS.indexOf(b64.charAt(i + 2)) : -1;
      const c3 = i + 3 < b64.length && b64.charAt(i + 3) !== '=' ? CHARS.indexOf(b64.charAt(i + 3)) : -1;
      result.push((c0 << 2) | (c1 >> 4));
      if (c2 >= 0) result.push(((c1 & 15) << 4) | (c2 >> 2));
      if (c3 >= 0) result.push(((c2 & 3) << 6) | c3);
    }
    return result;
  }

  private get store(): preferences.Preferences {
    if (!this.prefStore_) throw new Error('SettingsStore not initialized');
    return this.prefStore_;
  }

  // ---- 阅读设置 ----
  async getFontSize(): Promise<number> { return await this.get('font_size', 18); }
  async setFontSize(v: number): Promise<void> { await this.put('font_size', v); }

  async getFontFamily(): Promise<string> { return await this.get('font_family', 'HarmonyOS Sans'); }
  async setFontFamily(v: string): Promise<void> { await this.put('font_family', v); }

  /** 自定义字体元数据列表（JSON 字符串） */
  async getCustomFonts(): Promise<string> { return await this.get('custom_fonts', '[]'); }
  async setCustomFonts(json: string): Promise<void> { await this.put('custom_fonts', json); }

  async getLineHeight(): Promise<number> { return await this.get('line_height', 1.5); }
  async setLineHeight(v: number): Promise<void> { await this.put('line_height', v); }

  async getReadBgColor(): Promise<string> { return await this.get('read_bg', '#F5F0E8'); }
  async setReadBgColor(v: string): Promise<void> { await this.put('read_bg', v); }

  async getReadTextColor(): Promise<string> { return await this.get('read_text', '#333333'); }
  async setReadTextColor(v: string): Promise<void> { await this.put('read_text', v); }

  async getReadNightMode(): Promise<boolean> { return await this.get('read_night_mode', false); }
  async setReadNightMode(v: boolean): Promise<void> { await this.put('read_night_mode', v); }

  async getReadFollowTheme(): Promise<boolean> { return await this.get('read_follow_theme', true); }
  async setReadFollowTheme(v: boolean): Promise<void> { await this.put('read_follow_theme', v); }

  async getIndentSize(): Promise<number> { return await this.get('indent_size', 2); }
  async setIndentSize(v: number): Promise<void> { await this.put('indent_size', v); }

  async getLetterSpacing(): Promise<number> { return await this.get('letter_spacing', 0.5); }
  async setLetterSpacing(v: number): Promise<void> { await this.put('letter_spacing', v); }

  async getParagraphSpacing(): Promise<number> { return await this.get('para_spacing', 10); }
  async setParagraphSpacing(v: number): Promise<void> { await this.put('para_spacing', v); }

  async getFontWeight(): Promise<number> { return await this.get('font_weight', 1); }
  async setFontWeight(v: number): Promise<void> { await this.put('font_weight', v); }

  async getPaddingTop(): Promise<number> { return await this.get('padding_top', 24); }
  async setPaddingTop(v: number): Promise<void> { await this.put('padding_top', v); }

  async getPaddingBottom(): Promise<number> { return await this.get('padding_bottom', 24); }
  async setPaddingBottom(v: number): Promise<void> { await this.put('padding_bottom', v); }

  async getPaddingLeft(): Promise<number> { return await this.get('padding_left', 20); }
  async setPaddingLeft(v: number): Promise<void> { await this.put('padding_left', v); }

  async getPaddingRight(): Promise<number> { return await this.get('padding_right', 20); }
  async setPaddingRight(v: number): Promise<void> { await this.put('padding_right', v); }

  async getChineseMode(): Promise<string> { return await this.get('chinese_mode', 'original'); }
  async setChineseMode(v: string): Promise<void> { await this.put('chinese_mode', v); }

  async getZhFormat(): Promise<boolean> { return await this.get('zh_format', true); }
  async setZhFormat(v: boolean): Promise<void> { await this.put('zh_format', v); }

  /** 替换净化全局开关（默认开；关闭时阅读页跳过用户规则替换） */
  async getReplaceEnabled(): Promise<boolean> { return await this.get('replace_enabled', true); }
  async setReplaceEnabled(v: boolean): Promise<void> { await this.put('replace_enabled', v); }

  // ---- 主题设置 ----
  async getThemeMode(): Promise<string> { return await this.get('theme_mode', 'system'); }
  async setThemeMode(v: string): Promise<void> { await this.put('theme_mode', v); }

  async getPresetPalette(): Promise<string> { return await this.get('palette', 'default'); }
  async setPresetPalette(v: string): Promise<void> { await this.put('palette', v); }

  async getAmoledBlack(): Promise<boolean> { return await this.get('amoled_black', false); }
  async setAmoledBlack(v: boolean): Promise<void> { await this.put('amoled_black', v); }

  // ---- 通用 ----
  async get<T>(key: string, defaultValue: T): Promise<T> {
    try {
      if (this.memoryCache_.has(key)) {
        return this.memoryCache_.get(key) as T;
      }
      const val = await this.store.get(key, JSON.stringify(defaultValue));
      return JSON.parse(val as string) as T;
    } catch (_e) {
      return defaultValue;
    }
  }

  async put(key: string, value: Object): Promise<void> {
    try {
      this.memoryCache_.set(key, value);
      await this.store.put(key, JSON.stringify(value));
      await this.store.flush();
    } catch (err) {
      throw err;
    }
  }

  async putMany(values: Record<string, Object>): Promise<void> {
    try {
      const keys = Object.keys(values);
      for (const key of keys) {
        this.memoryCache_.set(key, values[key]);
        await this.store.put(key, JSON.stringify(values[key]));
      }
      await this.store.flush();
    } catch (err) {
      throw err;
    }
  }

  // ---- AI 配置（API Key 使用 HUKS 加密存储） ----
  async getAiEndpoint(): Promise<string> { return await this.get('ai_endpoint', 'https://api.openai.com/v1/chat/completions'); }
  async setAiEndpoint(v: string): Promise<void> { await this.put('ai_endpoint', v); }

  async getAiApiKey(): Promise<string> {
    const encoded = await this.get('ai_api_key', '') as string;
    if (!encoded) return '';
    return await this.decrypt_(encoded);
  }
  async setAiApiKey(v: string): Promise<void> {
    const encoded = await this.encrypt_(v);
    await this.put('ai_api_key', encoded);
  }

  async getAiModel(): Promise<string> { return await this.get('ai_model', 'gpt-3.5-turbo'); }
  async setAiModel(v: string): Promise<void> { await this.put('ai_model', v); }

  async getAiTimeoutSeconds(): Promise<number> {
    return normalizeAiTimeoutSeconds(await this.get<number>('ai_timeout_seconds', 120));
  }
  async setAiTimeoutSeconds(v: number): Promise<void> {
    await this.put('ai_timeout_seconds', normalizeAiTimeoutSeconds(v));
  }

  /** 读取全部 AI 配置；首次升级时把原有单配置迁移为第一条记录。 */
  async getAiProfiles(): Promise<AiProviderProfile[]> {
    const raw = await this.get<string>('ai_profiles', '');
    if (raw) {
      try {
        const stored = JSON.parse(raw) as StoredAiProviderProfile[];
        const profiles: AiProviderProfile[] = [];
        for (const item of stored) {
          profiles.push({
            id: item.id,
            name: item.name,
            provider: item.provider,
            endpoint: item.endpoint,
            apiKey: item.encryptedApiKey ? await this.decrypt_(item.encryptedApiKey) : '',
            model: item.model,
            timeoutSeconds: normalizeAiTimeoutSeconds(item.timeoutSeconds),
          });
        }
        if (profiles.length > 0) return profiles;
      } catch (_e) {
        console.warn('[SettingsStore] Invalid AI profiles, falling back to legacy config');
      }
    }

    const endpoint = await this.getAiEndpoint();
    const legacy: AiProviderProfile = {
      id: 'ai_' + Date.now().toString(),
      name: '默认配置',
      provider: detectAiProvider(endpoint),
      endpoint: endpoint,
      apiKey: await this.getAiApiKey(),
      model: await this.getAiModel(),
      timeoutSeconds: await this.getAiTimeoutSeconds(),
    };
    await this.saveAiProfiles([legacy]);
    await this.put('ai_active_profile_id', legacy.id);
    return [legacy];
  }

  /** 保存配置列表；每条 API Key 独立加密。 */
  async saveAiProfiles(profiles: AiProviderProfile[]): Promise<void> {
    const stored: StoredAiProviderProfile[] = [];
    for (const profile of profiles) {
      stored.push({
        id: profile.id,
        name: profile.name,
        provider: profile.provider,
        endpoint: profile.endpoint,
        encryptedApiKey: profile.apiKey ? await this.encrypt_(profile.apiKey) : '',
        model: profile.model,
        timeoutSeconds: normalizeAiTimeoutSeconds(profile.timeoutSeconds),
      });
    }
    await this.put('ai_profiles', JSON.stringify(stored));
  }

  async getActiveAiProfileId(): Promise<string> {
    return await this.get('ai_active_profile_id', '');
  }

  /** 激活一条配置，并同步旧的全局键，让现有 AI 功能无需改动即可使用。 */
  async activateAiProfile(profile: AiProviderProfile): Promise<void> {
    await this.setAiEndpoint(profile.endpoint);
    await this.setAiApiKey(profile.apiKey);
    await this.setAiModel(profile.model);
    await this.setAiTimeoutSeconds(profile.timeoutSeconds);
    await this.put('ai_active_profile_id', profile.id);
  }

  /** 龙空推书分析历史（JSON，页面只保留最近 10 次）。 */
  async getLkongAnalysisHistory(): Promise<string> { return await this.get('lkong_analysis_history', '[]'); }
  async setLkongAnalysisHistory(json: string): Promise<void> { await this.put('lkong_analysis_history', json); }

  // ---- WebDAV 配置（密码使用 HUKS 加密存储） ----
  async getWebDavPassword(): Promise<string> {
    const encoded = await this.get('webdav_pwd', '') as string;
    if (!encoded) return '';
    return await this.decrypt_(encoded);
  }
  async setWebDavPassword(v: string): Promise<void> {
    const encoded = await this.encrypt_(v);
    await this.put('webdav_pwd', encoded);
  }

  // ---- 书架设置 ----
  async getBookGroupStyle(): Promise<number> { return await this.get('book_group_style', 0); }
  async setBookGroupStyle(v: number): Promise<void> { await this.put('book_group_style', v); }

  async getBookshelfSortMode(): Promise<number> { return await this.get('bookshelf_sort_mode', 0); }
  async setBookshelfSortMode(v: number): Promise<void> { await this.put('bookshelf_sort_mode', v); }

  async getBookshelfSortOrder(): Promise<number> { return await this.get('bookshelf_sort_order', 0); }
  async setBookshelfSortOrder(v: number): Promise<void> { await this.put('bookshelf_sort_order', v); }

  async getBookshelfLayoutMode(): Promise<number> { return await this.get('bookshelf_layout_mode', 0); }
  async setBookshelfLayoutMode(v: number): Promise<void> { await this.put('bookshelf_layout_mode', v); }

  async getBookshelfLayoutGrid(): Promise<number> { return await this.get('bookshelf_layout_grid', 3); }
  async setBookshelfLayoutGrid(v: number): Promise<void> { await this.put('bookshelf_layout_grid', v); }

  async getBookshelfGridStyle(): Promise<number> { return await this.get('bookshelf_grid_style', 0); }
  async setBookshelfGridStyle(v: number): Promise<void> { await this.put('bookshelf_grid_style', v); }

  async getBookshelfShowDivider(): Promise<boolean> { return await this.get('bookshelf_show_divider', true); }
  async setBookshelfShowDivider(v: boolean): Promise<void> { await this.put('bookshelf_show_divider', v); }

  async getBookshelfCoverWidth(): Promise<number> { return await this.get('bookshelf_cover_width', 84); }
  async setBookshelfCoverWidth(v: number): Promise<void> { await this.put('bookshelf_cover_width', v); }

  async getBookshelfCompact(): Promise<boolean> { return await this.get('bookshelf_compact', false); }
  async setBookshelfCompact(v: boolean): Promise<void> { await this.put('bookshelf_compact', v); }

  async getBookshelfCoverShadow(): Promise<boolean> { return await this.get('bookshelf_cover_shadow', false); }
  async setBookshelfCoverShadow(v: boolean): Promise<void> { await this.put('bookshelf_cover_shadow', v); }

  async getShowUnread(): Promise<boolean> { return await this.get('show_unread', true); }
  async setShowUnread(v: boolean): Promise<void> { await this.put('show_unread', v); }

  async getBookshelfShowTip(): Promise<boolean> { return await this.get('bookshelf_show_tip', true); }
  async setBookshelfShowTip(v: boolean): Promise<void> { await this.put('bookshelf_show_tip', v); }

  async getShowBookIntro(): Promise<boolean> { return await this.get('show_book_intro', true); }
  async setShowBookIntro(v: boolean): Promise<void> { await this.put('show_book_intro', v); }

  async getBookshelfShowTag(): Promise<boolean> { return await this.get('bookshelf_show_tag', true); }
  async setBookshelfShowTag(v: boolean): Promise<void> { await this.put('bookshelf_show_tag', v); }

  async getBookshelfShowLatestChapter(): Promise<boolean> { return await this.get('bookshelf_show_latest', true); }
  async setBookshelfShowLatestChapter(v: boolean): Promise<void> { await this.put('bookshelf_show_latest', v); }

  async getBookshelfIntroMaxLines(): Promise<number> { return await this.get('bookshelf_intro_lines', 2); }
  async setBookshelfIntroMaxLines(v: number): Promise<void> { await this.put('bookshelf_intro_lines', v); }

  async getAutoUpdate(): Promise<boolean> { return await this.get('auto_update', true); }
  async setAutoUpdate(v: boolean): Promise<void> { await this.put('auto_update', v); }

  async getBookshelfTitleMaxLines(): Promise<number> { return await this.get('bookshelf_title_lines', 2); }
  async setBookshelfTitleMaxLines(v: number): Promise<void> { await this.put('bookshelf_title_lines', v); }

  async getShowLastUpdateTime(): Promise<boolean> { return await this.get('show_last_update', true); }
  async setShowLastUpdateTime(v: boolean): Promise<void> { await this.put('show_last_update', v); }

  async getBookshelfRefreshLimit(): Promise<number> { return await this.get('bookshelf_refresh_limit', 0); }
  async setBookshelfRefreshLimit(v: number): Promise<void> { await this.put('bookshelf_refresh_limit', v); }

  async getSearchHistory(): Promise<string[]> { return await this.get<string[]>('search_history', []); }
  async setSearchHistory(history: string[]): Promise<void> { await this.put('search_history', history); }

  // ---- 换源设置 ----
  async getChangeSourceCheckAuthor(): Promise<boolean> { return await this.get('change_source_check_author', true); }
  async setChangeSourceCheckAuthor(v: boolean): Promise<void> { await this.put('change_source_check_author', v); }

  // ---- 缓存设置 ----
  async getAutoCacheSize(): Promise<number> { return await this.get('auto_cache_size', 10); }
  async setAutoCacheSize(v: number): Promise<void> { await this.put('auto_cache_size', v); }

  // ---- TTS 朗读设置 ----
  async getTtsSpeed(): Promise<number> { return await this.get('tts_speed', 1.0); }
  async setTtsSpeed(v: number): Promise<void> { await this.put('tts_speed', v); }

  /** TTS 引擎类型: 'system' | 'sherpa-onnx' */
  async getTtsEngine(): Promise<string> { return await this.get('tts_engine', 'system'); }
  async setTtsEngine(v: string): Promise<void> { await this.put('tts_engine', v); }

  /** sherpa-onnx speaker ID (0-102)，默认 50（青年男声·云希） */
  async getTtsSherpaSid(): Promise<number> { return await this.get('tts_sherpa_sid', 50); }
  async setTtsSherpaSid(v: number): Promise<void> { await this.put('tts_sherpa_sid', v); }

  /** 离线模型类型: 'kokoro' | 'vits' */
  async getTtsModelType(): Promise<string> { return await this.get('tts_model_type', 'kokoro'); }
  async setTtsModelType(v: string): Promise<void> { await this.put('tts_model_type', v); }

  /** 离线模型是否已下载到沙箱 */
  async getTtsModelDownloaded(): Promise<boolean> { return await this.get('tts_model_downloaded', false); }
  async setTtsModelDownloaded(v: boolean): Promise<void> { await this.put('tts_model_downloaded', v); }

  /** Azure TTS 端点，需填写完整合成接口地址 */
  async getTtsAzureEndpoint(): Promise<string> {
    return await this.get('tts_azure_endpoint', 'https://japaneast.tts.speech.microsoft.com/cognitiveservices/v1');
  }
  async setTtsAzureEndpoint(v: string): Promise<void> { await this.put('tts_azure_endpoint', v); }

  /** Azure Speech Key（使用加密存储，失败时按既有策略降级明文） */
  async getTtsAzureKey(): Promise<string> {
    const encoded = await this.get('tts_azure_key', '') as string;
    if (!encoded) return '';
    return await this.decrypt_(encoded);
  }
  async setTtsAzureKey(v: string): Promise<void> {
    const encoded = await this.encrypt_(v);
    await this.put('tts_azure_key', encoded);
  }

  async getTtsAzureVoice(): Promise<string> { return await this.get('tts_azure_voice', 'zh-CN-XiaoxiaoNeural'); }
  async setTtsAzureVoice(v: string): Promise<void> { await this.put('tts_azure_voice', v); }

  // ---- 触控区域 ----
  private readonly ZONE_KEYS_: string[] = [
    'click_tl', 'click_tc', 'click_tr',
    'click_ml', 'click_mc', 'click_mr',
    'click_bl', 'click_bc', 'click_br',
  ];
  private readonly DEFAULT_ACTIONS_: number[] = [4,2,3,2,0,1,2,1,1];

  async getClickAction(zone: number): Promise<number> {
    return await this.get(this.ZONE_KEYS_[zone], this.DEFAULT_ACTIONS_[zone]);
  }
  async setClickAction(zone: number, action: number): Promise<void> {
    await this.put(this.ZONE_KEYS_[zone], action);
  }

  // ---- 漫画阅读设置 ----

  /** 漫画阅读方向：0=条漫, 1=左->右, 2=右->左 */
  async getComicReadMode(): Promise<number> { return await this.get('comic_read_mode', 0); }
  async setComicReadMode(mode: number): Promise<void> { await this.put('comic_read_mode', mode); }

  /** 漫画单页全屏模式开关（独立于阅读方向） */
  async getComicSinglePageMode(): Promise<boolean> { return await this.get('comic_single_page', false); }
  async setComicSinglePageMode(on: boolean): Promise<void> { await this.put('comic_single_page', on); }

  /** 漫画自动阅读速度（秒，每次翻页间隔） */
  async getComicAutoReadSpeed(): Promise<number> { return await this.get('comic_auto_read_speed', 3); }
  async setComicAutoReadSpeed(speed: number): Promise<void> { await this.put('comic_auto_read_speed', speed); }

  /** 漫画色彩滤镜亮度（0-100, 50=默认） */
  async getComicBrightness(): Promise<number> { return await this.get('comic_brightness', 50); }
  async setComicBrightness(v: number): Promise<void> { await this.put('comic_brightness', v); }

  /** 漫画条漫侧边留白百分比（0-20） */
  async getComicSidePadding(): Promise<number> { return await this.get('comic_side_padding', 0); }
  async setComicSidePadding(v: number): Promise<void> { await this.put('comic_side_padding', v); }

  /** 漫画图片预加载数量 */
  async getComicPreloadNum(): Promise<number> { return await this.get('comic_preload_num', 3); }
  async setComicPreloadNum(n: number): Promise<void> { await this.put('comic_preload_num', n); }

  /** 漫画触控区域 key 前缀 */
  private readonly COMIC_ZONE_KEYS_: string[] = [
    'comic_click_tl', 'comic_click_tc', 'comic_click_tr',
    'comic_click_ml', 'comic_click_mc', 'comic_click_mr',
    'comic_click_bl', 'comic_click_bc', 'comic_click_br',
  ];
  private readonly COMIC_DEFAULT_ACTIONS_: number[] = [4,2,3, 2,0,1, 2,1,1];

  async getComicClickAction(zone: number): Promise<number> {
    return await this.get(this.COMIC_ZONE_KEYS_[zone], this.COMIC_DEFAULT_ACTIONS_[zone]);
  }
  async setComicClickAction(zone: number, action: number): Promise<void> {
    await this.put(this.COMIC_ZONE_KEYS_[zone], action);
  }

  // ---- 备份/恢复设置 ----

  /** 导出所有设置键值 */
  async exportAll(): Promise<Record<string, any>> {
    const all: Record<string, any> = {};
    try {
      const keys = await this.getAllKeys();
      for (const key of keys) {
        try {
          const val = await this.store.get(key, '');
          if (val) {
            try { all[key] = JSON.parse(val as string); } catch { all[key] = val; }
          }
        } catch (_) { /* skip unreadable */ }
      }
    } catch (_) { /* ignore */ }
    return all;
  }

  /** 批量导入设置键值 */
  async importAll(map: Record<string, any>): Promise<void> {
    for (const [key, value] of Object.entries(map)) {
      try {
        this.memoryCache_.set(key, value as Object);
        await this.store.put(key, JSON.stringify(value));
      } catch (_) { /* skip unwritable */ }
    }
    try { await this.store.flush(); } catch (_) { /* ignore */ }
  }

  /** 获取所有设置键 */
  async getAllKeys(): Promise<string[]> {
    try {
      // Preferences API 使用 getAll 返回所有键值对
      const all = await this.store.getAll();
      return Object.keys(all);
    } catch {
      return [];
    }
  }
}
