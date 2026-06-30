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
