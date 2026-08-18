/**
 * WebView UA 统一管理
 *
 * 各 WebView 场景（验证码/登录交互弹窗、AI 导入预览、后台隐藏抓取）此前
 * 各自维护 UA 常量，版本不一致（Chrome 120 vs 124）且默认模式不统一。
 * 这里统一常量与默认模式解析：
 * - 桌面/移动 UA 固定同一 Chrome 版本（120），避免站点按版本分流；
 * - 全局设置项 webview_ua_mode（auto/mobile/desktop）可覆盖各场景默认值；
 *   auto 时各场景用自己的默认（验证码界面默认移动、AI 导入默认桌面）。
 */
export class WebUserAgent {
  /** 桌面 Chrome UA（与 Android Legado 后台 WebView 一致的默认桌面 UA）。 */
  static readonly DESKTOP: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /** 移动 Chrome UA；与桌面 UA 同一 Chrome 版本，避免站点按版本分流。 */
  static readonly MOBILE: string =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /** 全局显示模式设置 key：'auto' | 'mobile' | 'desktop'，默认 'auto'。 */
  static readonly MODE_PREF_KEY: string = 'webview_ua_mode';

  /**
   * 按全局设置解析某个场景的默认是否桌面模式。
   * @param desktopByDefault 该场景在 auto 模式下的默认值（true=桌面）
   */
  static isDesktopMode(desktopByDefault: boolean): boolean {
    try {
      const mode = AppStorage.get<string>(WebUserAgent.MODE_PREF_KEY) || 'auto';
      if (mode === 'mobile') return false;
      if (mode === 'desktop') return true;
    } catch (_e) { /* AppStorage 不可用时用场景默认 */ }
    return desktopByDefault;
  }
}

// 全局持久化：跨应用重启记住 webview_ua_mode（auto/mobile/desktop）。
PersistentStorage.persistProp(WebUserAgent.MODE_PREF_KEY, 'auto');
