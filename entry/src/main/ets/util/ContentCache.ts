/**
 * 章节内容缓存（对齐 Android Legado .nb 文件方案）
 *
 * 缓存层级：文件系统 → 数据库 → 内存
 * - 文件系统：持久化最可靠，重启不丢失
 * - 数据库：ChapterTable.content 列（备选持久化）
 * - 内存：ReadPage.chapterContentCache（最快）
 *
 * 缓存目录结构：
 *   {cacheDir}/book_content/{bookId}/{index}-{md5(title)}.nb
 */

import fileIo from '@ohos.file.fs';

const CACHE_DIR_NAME = 'book_content';

/** 简易字符串哈希（替代完整 MD5，用于文件名） */
function simpleHash(str: string): string {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const chr = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + chr;
    hash |= 0; // Convert to 32bit integer
  }
  return Math.abs(hash).toString(36);
}

export class ContentCache {
  /**
   * 从文件缓存中读取章节内容
   * @returns 内容字符串，未缓存时返回 null
   */
  static async getFromFile(cacheDir: string, bookId: number, index: number, title: string): Promise<string | null> {
    try {
      const filePath = ContentCache.buildPath(cacheDir, bookId, index, title);
      const file = await fileIo.open(filePath, 0o0); // 只读
      const stat = await fileIo.stat(filePath);
      const buf = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, buf);
      fileIo.close(file);
      return String.fromCharCode(...new Uint8Array(buf));
    } catch (_e) {
      return null; // 文件不存在或读取失败
    }
  }

  /**
   * 将章节内容写入文件缓存
   */
  static async saveToFile(cacheDir: string, bookId: number, index: number, title: string, content: string): Promise<void> {
    try {
      const dir = ContentCache.buildDir(cacheDir, bookId);
      // 确保目录存在
      await fileIo.mkdir(dir, true);
      const filePath = ContentCache.buildPath(cacheDir, bookId, index, title);
      const file = await fileIo.open(filePath, 0o100 | 0o2); // O_CREAT | O_RDWR
      await fileIo.write(file.fd, content);
      fileIo.close(file);
    } catch (_e) { /* ignore file errors */ }
  }

  /**
   * 删除某本书的所有文件缓存
   */
  static async clearBookCache(cacheDir: string, bookId: number): Promise<void> {
    try {
      const dir = ContentCache.buildDir(cacheDir, bookId);
      await fileIo.rmdir(dir);
    } catch (_e) { /* ignore */ }
  }

  /**
   * 检查某章节是否有文件缓存
   */
  static async hasFile(cacheDir: string, bookId: number, index: number, title: string): Promise<boolean> {
    try {
      const filePath = ContentCache.buildPath(cacheDir, bookId, index, title);
      const stat = await fileIo.stat(filePath);
      return stat.size > 0;
    } catch (_e) {
      return false;
    }
  }

  private static buildDir(cacheDir: string, bookId: number): string {
    return cacheDir + '/' + CACHE_DIR_NAME + '/' + bookId;
  }

  private static buildPath(cacheDir: string, bookId: number, index: number, title: string): string {
    const dir = ContentCache.buildDir(cacheDir, bookId);
    const paddedIndex = String(index).padStart(5, '0');
    const hash = simpleHash(title);
    return dir + '/' + paddedIndex + '-' + hash + '.nb';
  }
}
