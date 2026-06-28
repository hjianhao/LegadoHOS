/**
 * 设置存储
 * 基于 @ohos.data.preferences
 */
import preferences from '@ohos.data.preferences';

const SETTINGS_STORE_NAME = 'legado_settings';

export class SettingsStore {
  private static instance: SettingsStore;
  private prefStore_: preferences.Preferences | null = null;

  private constructor() {}

  static getInstance(): SettingsStore {
    if (!SettingsStore.instance) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  async init(context: Context): Promise<void> {
    this.prefStore_ = await preferences.getPreferences(context, SETTINGS_STORE_NAME);
  }

  private get store(): preferences.Preferences {
    if (!this.prefStore_) throw new Error('SettingsStore not initialized');
    return this.prefStore_;
  }

  // ---- 阅读设置 ----
  async getFontSize(): Promise<number> { return await this.get('font_size', 18); }
  async setFontSize(v: number): Promise<void> { await this.put('font_size', v); }

  async getFontFamily(): Promise<string> { return await this.get('font_family', '默认'); }
  async setFontFamily(v: string): Promise<void> { await this.put('font_family', v); }

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
    const val = await this.store.get(key, JSON.stringify(defaultValue));
    return JSON.parse(val as string) as T;
  }

  async put(key: string, value: Object): Promise<void> {
    await this.store.put(key, JSON.stringify(value));
    await this.store.flush();
  }

  // ---- 搜索历史 ----
  async getSearchHistory(): Promise<string[]> { return await this.get<string[]>('search_history', []); }
  async setSearchHistory(history: string[]): Promise<void> { await this.put('search_history', history); }

  // ---- 缓存设置 ----
  async getAutoCacheSize(): Promise<number> { return await this.get('auto_cache_size', 10); }
  async setAutoCacheSize(v: number): Promise<void> { await this.put('auto_cache_size', v); }

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
}
