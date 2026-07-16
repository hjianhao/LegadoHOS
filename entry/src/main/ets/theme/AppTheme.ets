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
  async init(context: Context, systemDark: boolean): Promise<void> {
    if (this.inited_) return;
    this.inited_ = true;
    try {
      const store = SettingsStore.getInstance();
      await store.init(context);
      const savedMode = await store.getThemeMode();
      if (savedMode === 'light') { this.config_.mode = ThemeMode.LIGHT; this.isDark_ = false; }
      else if (savedMode === 'dark') { this.config_.mode = ThemeMode.DARK; this.isDark_ = true; }
      else { this.config_.mode = ThemeMode.SYSTEM; this.isDark_ = systemDark; }
    } catch (_e) {
      this.config_.mode = ThemeMode.SYSTEM;
      this.isDark_ = systemDark;
    }
    this.apply_();
    // 保存系统色模式，供 setFollowSystem() 读取
    AppStorage.setOrCreate<number>('systemColorMode', systemDark ? 0 : 1);
    console.info('[AppTheme] init done: mode=' + this.config_.mode + ', isDark=' + this.isDark_);
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
    AppStorage.setOrCreate<number>('systemColorMode', colorMode);
    console.info('[AppTheme] onSystemColorChange: colorMode=' + colorMode + ', currentMode=' + this.config_.mode);
    if (this.config_.mode === ThemeMode.SYSTEM) {
      const dark = (colorMode === 0);
      if (dark !== this.isDark_) {
        this.isDark_ = dark;
        this.apply_();
        console.info('[AppTheme] system color changed: isDark=' + this.isDark_);
      }
    }
  }

  /**
   * 切换为跟随系统
   */
  setFollowSystem(): void {
    this.config_.mode = ThemeMode.SYSTEM;
    const colorMode = AppStorage.get<number>('systemColorMode');
    this.isDark_ = (colorMode === 0); // 0=DARK, 1=LIGHT
    this.apply_();
    this.save_();
    console.info('[AppTheme] setFollowSystem: isDark=' + this.isDark_);
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
    console.info("[AppTheme] apply: isDark=" + this.isDark_ + " background=" + ColorScheme.resolve(this.config_, this.isDark_).background);
    this.colorScheme_ = ColorScheme.resolve(this.config_, this.isDark_);
    AppStorage.set<boolean>('isDark', this.isDark_);
    AppStorage.set<boolean>('isFollowSystem', this.config_.mode === ThemeMode.SYSTEM);
    AppStorage.set<AppColorScheme>('colorScheme', this.colorScheme_);
    for (const listener of this.listeners_) listener(this.isDark_);
  }

  private save_(): void {
    SettingsStore.getInstance().setThemeMode(this.config_.mode).catch(() => {});
  }
}
