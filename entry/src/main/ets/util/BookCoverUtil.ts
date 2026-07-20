/**
 * 书籍封面工具
 * 支持网络封面下载、本地封面缓存、默认封面生成
 */
import fileFs from '@ohos.file.fs';
import { NetUtil } from './NetUtil';
import { FileUtil } from './FileUtil';
import { AppDatabase } from '../data/database/AppDatabase';

export class BookCoverUtil {
  private static cacheDir: string = '/data/storage/el2/base/haps/entry/files/covers/';

  /**
   * 初始化封面缓存目录
   */
  static async init(): Promise<void> {
    try {
      if (!FileUtil.exists(this.cacheDir)) {
        fileFs.mkdirSync(this.cacheDir, true);
      }
    } catch (err) {
      console.error('[BookCover] Init failed:', err);
    }
  }

  /**
   * 获取封面路径
   * 优先本地缓存，否则下载
   */
  static async getCoverPath(bookId: number, coverUrl: string): Promise<string> {
    const localPath = `${this.cacheDir}${bookId}.jpg`;

    // 本地有缓存
    if (FileUtil.exists(localPath)) {
      return localPath;
    }

    // 下载封面
    if (coverUrl) {
      try {
        const imageData = await NetUtil.httpGet(coverUrl);
        await FileUtil.writeTextFile(localPath, imageData);
        return localPath;
      } catch (err) {
        console.warn('[BookCover] Download failed:', coverUrl);
      }
    }

    return '';
  }

  /**
   * 清除封面缓存
   */
  static async clearCache(): Promise<void> {
    try {
      if (FileUtil.exists(this.cacheDir)) {
        fileFs.rmdirSync(this.cacheDir);
        fileFs.mkdirSync(this.cacheDir, true);
      }
    } catch (err) {
      console.error('[BookCover] Clear cache failed:', err);
    }
  }

  /**
   * 清除单本书的封面缓存（删书/清缓存时调用）
   */
  static async clearCacheForBook(bookId: number): Promise<void> {
    try {
      const localPath = `${this.cacheDir}${bookId}.jpg`;
      if (FileUtil.exists(localPath)) {
        fileFs.unlinkSync(localPath);
      }
    } catch (err) {
      console.warn('[BookCover] Clear cache for book failed:', bookId, (err as Error).message);
    }
  }

  /**
   * 获取封面缓存大小
   */
  static async getCacheSize(): Promise<number> {
    try {
      if (!FileUtil.exists(this.cacheDir)) return 0;

      let totalSize = 0;
      const files = fileFs.listFileSync(this.cacheDir);
      for (const file of files) {
        totalSize += FileUtil.getFileSize(`${this.cacheDir}${file}`);
      }
      return totalSize;
    } catch {
      return 0;
    }
  }

  /**
   * 生成默认封面颜色（基于书名 hash）
   */
  static generateDefaultColor(bookName: string): string {
    const colors = [
      '#0078D7', '#2E7D32', '#FF8F00', '#D81B60',
      '#1565C0', '#455A64', '#5B8C5A', '#8D6E63',
      '#00BCD4', '#FF5722', '#7B1FA2', '#00897B',
    ];
    let hash = 0;
    for (let i = 0; i < bookName.length; i++) {
      hash = bookName.charCodeAt(i) + ((hash << 5) - hash);
    }
    return colors[Math.abs(hash) % colors.length];
  }
}
