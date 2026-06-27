/**
 * 应用级 Context 持有者
 *
 * 避免 TTSPlayer 与 ReadAloudService 之间的循环依赖。
 * 在 MainAbility.onCreate 中设置，全局可用。
 */
export class AppContextHolder {
  private static ctx_: Context | null = null;

  static set(ctx: Context): void {
    AppContextHolder.ctx_ = ctx;
  }

  static get(): Context | null {
    return AppContextHolder.ctx_;
  }
}
