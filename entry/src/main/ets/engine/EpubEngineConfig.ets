/**
 * EPUB 阅读引擎配置
 */
import { SettingsStore } from '../data/preferences/SettingsStore';

export enum EpubEngineType {
  NOVEL = 0,
  COMIC = 1,
}

export class EpubEngineConfig {
  private static readonly KEY = 'epub_engine';

  static async getEngine(): Promise<EpubEngineType> {
    try {
      const s = SettingsStore.getInstance();
      const val: string = await s.get(EpubEngineConfig.KEY, 'novel');
      return val === 'comic' ? EpubEngineType.COMIC : EpubEngineType.NOVEL;
    } catch (_e) {
      return EpubEngineType.NOVEL;
    }
  }

  static async setEngine(type: EpubEngineType): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.put(EpubEngineConfig.KEY, type === EpubEngineType.COMIC ? 'comic' : 'novel');
    } catch (_e) { /* */ }
  }
}
