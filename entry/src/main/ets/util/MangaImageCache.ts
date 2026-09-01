/**
 * 漫画图片缓存目录的轻量管理接口。
 *
 * 该文件保持为 .ts，供 CacheManager.ts 使用；MangaImageLoader.ets 负责下载，
 * 两者共享同一个 v3 目录约定，避免 JS/TS 文件直接导入 ArkTS 文件。
 */
import fileFs from '@ohos.file.fs';
import { FileUtil } from './FileUtil';

const CACHE_BASE_DIR: string = '/data/storage/el2/base/haps/entry/files/manga_cache_v3/';
const LEGACY_CACHE_DIR: string = '/data/storage/el2/base/haps/entry/files/manga_cache/';

export class MangaImageCache {
  static async getCacheSize(): Promise<number> {
    return (await MangaImageCache.getDirSize_(CACHE_BASE_DIR))
      + (await MangaImageCache.getDirSize_(LEGACY_CACHE_DIR));
  }

  static async getCacheSizeForBook(bookId: number): Promise<number> {
    if (bookId <= 0) return 0;
    return MangaImageCache.getDirSize_(CACHE_BASE_DIR + bookId + '/');
  }

  static clearCacheForBook(bookId: number): void {
    if (bookId > 0) FileUtil.removeDirRecursive(CACHE_BASE_DIR + bookId + '/');
  }

  static async clearAllCache(): Promise<void> {
    FileUtil.removeDirRecursive(CACHE_BASE_DIR);
    FileUtil.removeDirRecursive(LEGACY_CACHE_DIR);
    try { await fileFs.mkdir(CACHE_BASE_DIR, true); } catch (_) { /* ignore */ }
  }

  private static async getDirSize_(dirPath: string): Promise<number> {
    try {
      if (!await fileFs.access(dirPath)) return 0;
      const names: string[] = await fileFs.listFile(dirPath);
      let total = 0;
      for (const name of names) {
        const child = dirPath + name;
        const stat: fileFs.Stat = await fileFs.stat(child);
        if (stat.isDirectory()) total += await MangaImageCache.getDirSize_(child + '/');
        else total += stat.size;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
