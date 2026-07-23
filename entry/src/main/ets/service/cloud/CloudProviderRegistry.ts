/**
 * CloudProvider 注册与路由
 *
 * 按 providerType 返回实现。阶段 1 仅骨架；阶段 2 注册 WebDavCloudProvider。
 */
import { CloudProviderType } from '../../model/CloudSource';
import { CloudStorageProvider } from './CloudStorageProvider';

export type CloudProviderFactory = () => CloudStorageProvider;

export class CloudProviderRegistry {
  private static instance: CloudProviderRegistry | null = null;
  private factories_: Map<string, CloudProviderFactory> = new Map();
  private cache_: Map<string, CloudStorageProvider> = new Map();

  private constructor() {}

  static getInstance(): CloudProviderRegistry {
    if (!CloudProviderRegistry.instance) {
      CloudProviderRegistry.instance = new CloudProviderRegistry();
    }
    return CloudProviderRegistry.instance;
  }

  /** 注册 Provider 工厂（同 type 覆盖）。 */
  register(type: CloudProviderType, factory: CloudProviderFactory): void {
    const key = (type || '').trim();
    if (!key) {
      throw new Error('providerType 不能为空');
    }
    this.factories_.set(key, factory);
    // 清除旧缓存实例，确保下次 get 使用新工厂
    this.cache_.delete(key);
  }

  has(type: CloudProviderType): boolean {
    return this.factories_.has((type || '').trim());
  }

  /** 已注册的类型列表。 */
  listTypes(): string[] {
    const keys: string[] = [];
    this.factories_.forEach((_v: CloudProviderFactory, k: string) => {
      keys.push(k);
    });
    return keys;
  }

  get(type: CloudProviderType): CloudStorageProvider {
    const key = (type || '').trim();
    if (!key) {
      throw new Error('providerType 不能为空');
    }
    const cached = this.cache_.get(key);
    if (cached) {
      return cached;
    }
    const factory = this.factories_.get(key);
    if (!factory) {
      throw new Error('未注册的云存储 Provider: ' + key);
    }
    const provider = factory();
    this.cache_.set(key, provider);
    return provider;
  }

  /** 测试用：清空注册表。 */
  clearForTest(): void {
    this.factories_.clear();
    this.cache_.clear();
  }
}
