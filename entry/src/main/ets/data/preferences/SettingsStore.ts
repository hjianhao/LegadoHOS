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

  async getPageMode(): Promise<number> { return await this.get('page_mode', 0); }
  async setPageMode(v: number): Promise<void> { await this.put('page_mode', v); }

  async getReadBgColor(): Promise<string> { return await this.get('read_bg', '#F5F0E8'); }
  async setReadBgColor(v: string): Promise<void> { await this.put('read_bg', v); }

  async getReadTextColor(): Promise<string> { return await this.get('read_text', '#333333'); }
  async setReadTextColor(v: string): Promise<void> { await this.put('read_text', v); }

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

  async put(key: string, value: any): Promise<void> {
    await this.store.put(key, JSON.stringify(value));
    await this.store.flush();
  }
}
