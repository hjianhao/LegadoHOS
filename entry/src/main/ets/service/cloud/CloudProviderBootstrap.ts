/**
 * 云存储 Provider 集中注册（幂等）
 *
 * 新增 Provider 时在此 register，业务层只调用 ensureCloudProvidersRegistered()，
 * 不直接依赖具体协议实现。
 */
import {
  CLOUD_PROVIDER_BAIDU_NETDISK,
  CLOUD_PROVIDER_LOCAL_FOLDER,
  CLOUD_PROVIDER_WEBDAV,
} from '../../model/CloudSource';
import { BaiduNetdiskProvider } from './BaiduNetdiskProvider';
import { CloudProviderRegistry } from './CloudProviderRegistry';
import { CloudStorageProvider } from './CloudStorageProvider';
import { LocalFolderCloudProvider } from './LocalFolderCloudProvider';
import { WebDavCloudProvider } from './WebDavCloudProvider';

/** 应用启动或首次使用时调用（幂等）。 */
export function ensureCloudProvidersRegistered(): void {
  const reg = CloudProviderRegistry.getInstance();
  if (!reg.has(CLOUD_PROVIDER_WEBDAV)) {
    reg.register(CLOUD_PROVIDER_WEBDAV, (): CloudStorageProvider => new WebDavCloudProvider());
  }
  if (!reg.has(CLOUD_PROVIDER_LOCAL_FOLDER)) {
    reg.register(CLOUD_PROVIDER_LOCAL_FOLDER, (): CloudStorageProvider => new LocalFolderCloudProvider());
  }
  if (!reg.has(CLOUD_PROVIDER_BAIDU_NETDISK)) {
    reg.register(CLOUD_PROVIDER_BAIDU_NETDISK, (): CloudStorageProvider => new BaiduNetdiskProvider());
  }
}
