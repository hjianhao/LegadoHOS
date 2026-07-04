/**
 * 应用主题入口 — 支持浅色/深色/跟随系统
 *
 * 使用 AppStorage 传播 isDark，UI 组件通过 @StorageLink('isDark') 响应。
 * 设置页通过 setMode() 切换，MainAbility 调用 init() 初始化。
 */
import { ThemeConfig, ThemeMode, createDefaultTheme } from './ThemeMode';
import { ColorScheme, AppColorScheme } from './ColorScheme';
import { SettingsStore } from '../data/preferences/SettingsStore';

export class AppTheme {
  private static instance: AppTheme;
  private config_: ThemeConfig = createDefaultTheme();
  private colorScheme_: AppColorScheme | null = null;
  private isDark_: boolean = false;
  private listeners_: Array<(scheme: AppColorScheme, isDark: boolean) => void> = [];
  private inited_: boolean = false;

  private constructor() {}

  static getInstance(): AppTheme {
    if (!AppTheme.instance) {
      AppTheme.instance = new AppTheme();
    }
    return AppTheme.instance;
  }

  get config(): ThemeConfig { return this.config_; }
  get colorScheme(): AppColorScheme {
    return this.colorScheme_ || ColorScheme.resolve(this.config_, this.isDark_);
  }
  get isDark(): boolean { return this.isDark_; }
  get mode(): ThemeMode { return this.config_.mode; }

  /**
   * 初始化：从 SettingsStore 读取已保存的模式，监听系统色模式变化
   */
  async init(context: Context): Promise<void> {
    if (this.inited_) return;
    this.inited_ = true;

    try {
      const store = SettingsStore.getInstance();
      await store.init(context);
      const savedMode = await store.getThemeMode();
      if (savedMode === 'light') this.config_.mode = ThemeMode.LIGHT;
      else if (savedMode === 'dark') this.config_.mode = ThemeMode.DARK;
      else this.config_.mode = ThemeMode.SYSTEM;
    } catch (_e) {
      console.warn('[AppTheme] Load saved theme failed, using default');
    }

    this.resolveColorScheme();
    // 同步到 AppStorage
    AppStorage.setOrCreate<boolean>('isDark', this.isDark_);
  }

  /**
   * 切换主题模式（设置页调用）
   */
  async setMode(mode: ThemeMode): Promise<void> {
    this.config_.mode = mode;
    // 持久化
    try {
      const store = SettingsStore.getInstance();
      await store.setThemeMode(mode);
    } catch (_e) { /* ignore */ }

    if (mode === ThemeMode.LIGHT) {
      this.setDarkMode(false);
    } else if (mode === ThemeMode.DARK) {
      this.setDarkMode(true);
    } else {
      this.setDarkMode(false);
    }
  }

  /**
   * 设置亮/暗状态（内部用，不持久化）
   */
  private setDarkMode(isDark: boolean): void {
    this.isDark_ = isDark;
    this.resolveColorScheme();
    AppStorage.set<boolean>('isDark', isDark);
  }

  /**
   * 监听主题变化
   */
  onChange(callback: (scheme: AppColorScheme, isDark: boolean) => void): void {
    this.listeners_.push(callback);
  }

  private resolveColorScheme(): void {
    const isDark = this.config_.mode === ThemeMode.SYSTEM
      ? this.isDark_
      : this.config_.mode === ThemeMode.DARK;
    this.colorScheme_ = ColorScheme.resolve(this.config_, isDark);
    this.isDark_ = isDark;

    for (const listener of this.listeners_) {
      listener(this.colorScheme_, isDark);
    }
  }
}
