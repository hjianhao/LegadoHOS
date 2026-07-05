/**
 * 应用主题 — 只有浅色/深色两套。跟随系统 = 自动根据系统设定选择。
 * 通过 AppStorage('isDark') 传播给所有 @StorageLink 组件。
 */
import { ThemeConfig, ThemeMode, createDefaultTheme } from './ThemeMode';
import { ColorScheme, AppColorScheme } from './ColorScheme';
import { SettingsStore } from '../data/preferences/SettingsStore';

const KEY = 'theme_mode';

export class AppTheme {
  private static instance: AppTheme;
  private config_: ThemeConfig = createDefaultTheme();
  private colorScheme_: AppColorScheme | null = null;
  private isDark_: boolean = false;
  private listeners_: Array<(isDark: boolean) => void> = [];
  private inited_: boolean = false;

  private constructor() {}

  static getInstance(): AppTheme {
    if (!AppTheme.instance) AppTheme.instance = new AppTheme();
    return AppTheme.instance;
  }

  get isDark(): boolean { return this.isDark_; }

  /** 是否跟随系统（设置页读这个展示 UI 状态） */
  get isFollowSystem(): boolean { return this.config_.mode === ThemeMode.SYSTEM; }

  get colorScheme(): AppColorScheme {
    return this.colorScheme_ || ColorScheme.resolve(this.config_, this.isDark_);
  }

  /**
   * 初始化：从 SettingsStore 读取已保存的模式
   */
  async init(context: Context): Promise<void> {
    if (this.inited_) return;
    this.inited_ = true;
    try {
      const store = SettingsStore.getInstance();
      await store.init(context);
      const savedMode = await store.getThemeMode();
      if (savedMode === 'light') { this.config_.mode = ThemeMode.LIGHT; this.isDark_ = false; }
      else if (savedMode === 'dark') { this.config_.mode = ThemeMode.DARK; this.isDark_ = true; }
      else { this.config_.mode = ThemeMode.SYSTEM; this.isDark_ = false; }
    } catch (_e) { /* default to light */ }
    this.apply_();
  }

  /**
   * 手动切换亮/暗（不切换模式，仅临时覆盖）
   */
  setDarkMode(dark: boolean): void {
    this.config_.mode = dark ? ThemeMode.DARK : ThemeMode.LIGHT;
    this.isDark_ = dark;
    this.apply_();
    this.save_();
  }

  /**
   * 系统色模式变化回调（由 MainAbility.onConfigurationUpdate 触发）
   */
  onSystemColorChange(colorMode: number): void {
    // 0=DARK, 1=LIGHT
    if (this.config_.mode === ThemeMode.SYSTEM) {
      this.isDark_ = (colorMode === 0);
      this.apply_();
    }
  }

  /**
   * 切换为跟随系统
   */
  setFollowSystem(): void {
    this.config_.mode = ThemeMode.SYSTEM;
    // 读取当前系统模式
    let sysDark = false;
    try {
      const ctx = (AppStorage.get<object>('abilityContext') as Record<string, Object>);
      if (ctx && typeof ctx['config'] === 'object') {
        const cfg = ctx['config'] as Record<string, number>;
        sysDark = cfg['colorMode'] === 0; // 0=DARK
      }
    } catch (_e) { /* keep false */ }
    this.isDark_ = sysDark;
    this.apply_();
    this.save_();
  }

  /**
   * 监听主题变化
   */
  onChange(callback: (isDark: boolean) => void): void {
    this.listeners_.push(callback);
  }

  /** @deprecated 兼容旧页面，请用 isDark + isFollowSystem */
  get mode(): ThemeMode { return this.config_.mode; }
  /** @deprecated 兼容旧页面，请用 setDarkMode / setFollowSystem */
  async setMode(mode: ThemeMode): Promise<void> {
    if (mode === ThemeMode.LIGHT) this.setDarkMode(false);
    else if (mode === ThemeMode.DARK) this.setDarkMode(true);
    else this.setFollowSystem();
  }

  private apply_(): void {
    this.colorScheme_ = ColorScheme.resolve(this.config_, this.isDark_);
    AppStorage.set<boolean>('isDark', this.isDark_);
    AppStorage.set<boolean>('isFollowSystem', this.config_.mode === ThemeMode.SYSTEM);
    for (const listener of this.listeners_) listener(this.isDark_);
  }

  private save_(): void {
    try {
      SettingsStore.getInstance().setThemeMode(this.config_.mode);
    } catch (_e) { /* ignore */ }
  }
}
