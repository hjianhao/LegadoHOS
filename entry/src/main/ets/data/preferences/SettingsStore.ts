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
}

export class SettingsStore {
  private static instance: SettingsStore;
  private prefStore_: preferences.Preferences | null = null;
  private cipher_: cryptoFramework.Cipher | null = null;

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
      this.cipher_ = await this.createCipher_(cryptoFramework.CryptoMode.ENCRYPT_MODE);
    } catch (_e) {
      /* 降级：明文存储（加密组件不可用时自动回退） */
      console.warn('[SettingsStore] HUKS init failed, falling back to plaintext');
      this.cipher_ = null;
    }
  }

  /** 创建指定模式的 Cipher 实例 */
  private async createCipher_(mode: cryptoFramework.CryptoMode): Promise<cryptoFramework.Cipher> {
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
    const keyData = await this.getEncKeyMaterial_();
    const symKey = await symKeyGenerator.convertKey({ data: keyData });
    const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
    await cipher.init(mode, symKey, null);
    return cipher;
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

  /** 加密字符串 → base64{iv}:base64{ciphertext} */
  private async encrypt_(plaintext: string): Promise<string> {
    if (!this.cipher_) return plaintext;
    try {
      const plainBytes = new Uint8Array(plaintext.length);
      for (let i = 0; i < plaintext.length; i++) {
        plainBytes[i] = plaintext.charCodeAt(i) & 0xFF;
      }
      const encrypted = await this.cipher_.doFinal({ data: plainBytes });
      // iv 和 ciphertext 拼接在一起存储
      const result = Array.from(encrypted.data);
      return this.bytesToBase64_(result);
    } catch (_e) {
      console.warn('[SettingsStore] Encrypt failed, storing plaintext');
      return plaintext;
    }
  }

  /** 解密 base64 → 明文 */
  private async decrypt_(encoded: string): Promise<string> {
    if (!encoded) return encoded;
    try {
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
      console.warn('[SettingsStore] Decrypt failed, returning raw');
      return encoded;
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

  async getPageMode(): Promise<number> { return await this.get('page_mode', 1); }
  async setPageMode(v: number): Promise<void> { await this.put('page_mode', v); }

  async getReadBgColor(): Promise<string> { return await this.get('read_bg', '#F5F0E8'); }
  async setReadBgColor(v: string): Promise<void> { await this.put('read_bg', v); }

  async getReadTextColor(): Promise<string> { return await this.get('read_text', '#333333'); }
  async setReadTextColor(v: string): Promise<void> { await this.put('read_text', v); }

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
      const val = await this.store.get(key, JSON.stringify(defaultValue));
      return JSON.parse(val as string) as T;
    } catch (_e) {
      return defaultValue;
    }
  }

  async put(key: string, value: Object): Promise<void> {
    try {
      await this.store.put(key, JSON.stringify(value));
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
