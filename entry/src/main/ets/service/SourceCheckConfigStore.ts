import { SettingsStore } from '../data/preferences/SettingsStore';
import { CheckConfig, normalizeCheckConfig } from './SourceChecker';

const PREFIX = 'source_check_';

export class SourceCheckConfigStore {
  static async load(): Promise<CheckConfig> {
    const store = SettingsStore.getInstance();
    const defaultConcurrency = AppStorage.get<number>('searchConcurrency') || 16;
    return normalizeCheckConfig({
      keyword: await store.get<string>(PREFIX + 'keyword', '我的'),
      timeout: await store.get<number>(PREFIX + 'timeout', 180000),
      checkSearch: await store.get<boolean>(PREFIX + 'search', true),
      checkDiscovery: await store.get<boolean>(PREFIX + 'discovery', true),
      checkInfo: await store.get<boolean>(PREFIX + 'info', true),
      checkCategory: await store.get<boolean>(PREFIX + 'category', true),
      checkContent: await store.get<boolean>(PREFIX + 'content', true),
      concurrency: await store.get<number>(PREFIX + 'concurrency', defaultConcurrency),
    });
  }

  static async save(config: CheckConfig): Promise<void> {
    const normalized = normalizeCheckConfig(config);
    await SettingsStore.getInstance().putMany({
      [PREFIX + 'keyword']: normalized.keyword,
      [PREFIX + 'timeout']: normalized.timeout,
      [PREFIX + 'search']: normalized.checkSearch,
      [PREFIX + 'discovery']: normalized.checkDiscovery,
      [PREFIX + 'info']: normalized.checkInfo,
      [PREFIX + 'category']: normalized.checkCategory,
      [PREFIX + 'content']: normalized.checkContent,
      [PREFIX + 'concurrency']: normalized.concurrency,
    });
  }
}
