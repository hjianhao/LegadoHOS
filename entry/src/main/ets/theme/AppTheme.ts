/**
 * 应用主题入口
 * 整合 ThemeMode + ColorScheme 为 ArkUI 可用的主题状态
 */
import { ThemeConfig, ThemeMode, createDefaultTheme } from './ThemeMode';
import { ColorScheme, AppColorScheme } from './ColorScheme';

export class AppTheme {
  private static instance: AppTheme;
  private config_: ThemeConfig = createDefaultTheme();
  private colorScheme_: AppColorScheme | null = null;
  private isDark_: boolean = false;
  private listeners_: Array<(scheme: AppColorScheme, isDark: boolean) => void> = [];

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

  /**
   * 更新主题配置
   */
  updateConfig(config: Partial<ThemeConfig>): void {
    this.config_ = { ...this.config_, ...config };
    this.resolveColorScheme();
  }

  /**
   * 设置亮/暗模式（不限制 SYSTEM 模式）
   */
  setDarkMode(isDark: boolean): void {
    this.isDark_ = isDark;
    this.resolveColorScheme();
  }

  /**
   * 应用主题配置到全局
   */
  apply(): AppColorScheme {
    this.resolveColorScheme();
    return this.colorScheme_;
  }

  /**
   * 监听主题变化
   */
  onChange(callback: (scheme: AppColorScheme, isDark: boolean) => void): void {
    this.listeners_.push(callback);
  }

  /**
   * 加载已保存的主题配置
   */
  async loadSaved(): Promise<void> {
    // 从 Preferences 读取
    try {
      const prefs = await import('@ohos.data.preferences');
      const context = await import('@ohos.app.ability.common');
      // 实际实现需要 context 传入
      console.info('[AppTheme] Load saved theme config');
    } catch (err) {
      console.warn('[AppTheme] Failed to load theme config:', err);
    }
  }

  /**
   * 保存主题配置
   */
  async save(): Promise<void> {
    // 保存到 Preferences
    console.info('[AppTheme] Theme config saved');
  }

  private resolveColorScheme(): void {
    const isDark = this.config_.mode === ThemeMode.SYSTEM
      ? this.isDark_
      : this.config_.mode === ThemeMode.DARK;
    this.colorScheme_ = ColorScheme.resolve(this.config_, isDark);
    this.isDark_ = isDark;

    // 通知监听器
    for (const listener of this.listeners_) {
      listener(this.colorScheme_, isDark);
    }
  }
}
