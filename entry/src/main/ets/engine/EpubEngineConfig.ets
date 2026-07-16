/**
 * EPUB 阅读引擎配置
 */
import { SettingsStore } from '../data/preferences/SettingsStore';

export enum EpubEngineType {
  NOVEL = 0,
  EPUB_JS = 1,
  /** 兼容旧代码与已保存的 comic 配置。 */
  COMIC = 1,
  FOLIATE = 2,
}

export class EpubEngineConfig {
  private static readonly KEY = 'epub_engine';

  static async getEngine(): Promise<EpubEngineType> {
    try {
      const s = SettingsStore.getInstance();
      const val: string = await s.get(EpubEngineConfig.KEY, 'novel');
      if (val === 'foliate') return EpubEngineType.FOLIATE;
      return val === 'comic' || val === 'epub_js' ? EpubEngineType.EPUB_JS : EpubEngineType.NOVEL;
    } catch (_e) {
      return EpubEngineType.NOVEL;
    }
  }

  static async setEngine(type: EpubEngineType): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      const value = type === EpubEngineType.FOLIATE ? 'foliate' :
        (type === EpubEngineType.EPUB_JS ? 'epub_js' : 'novel');
      await s.put(EpubEngineConfig.KEY, value);
    } catch (_e) { /* */ }
  }
}
