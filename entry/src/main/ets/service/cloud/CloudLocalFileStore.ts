/**
 * 云端书籍本地文件：临时目录、唯一最终路径、原子移动、失败清理
 */
import fileFs from '@ohos.file.fs';
import { AppContextHolder } from '../../util/AppContext';
import { FileUtil } from '../../util/FileUtil';

const TMP_SUBDIR = 'cloudbook/.tmp';
const BOOKS_SUBDIR = 'books';

export class CloudLocalFileStore {
  private static instance: CloudLocalFileStore | null = null;

  private constructor() {}

  static getInstance(): CloudLocalFileStore {
    if (!CloudLocalFileStore.instance) {
      CloudLocalFileStore.instance = new CloudLocalFileStore();
    }
    return CloudLocalFileStore.instance;
  }

  private filesRoot_(): string {
    const ctx = AppContextHolder.get();
    if (!ctx || !ctx.filesDir) {
      throw new Error('缺少应用 Context，无法访问本地文件目录');
    }
    return ctx.filesDir;
  }

  /** files/cloudbook/.tmp */
  getTempDir(): string {
    return this.filesRoot_() + '/' + TMP_SUBDIR;
  }

  /** files/books */
  getBooksDir(): string {
    return this.filesRoot_() + '/' + BOOKS_SUBDIR;
  }

  ensureDirs(): void {
    this.ensureDir_(this.getTempDir());
    this.ensureDir_(this.getBooksDir());
  }

  /**
   * 启动时清理超过 maxAgeMs 的 .part 临时文件。
   */
  cleanupStaleTempFiles(maxAgeMs: number = 24 * 60 * 60 * 1000): void {
    try {
      const dir = this.getTempDir();
      if (!FileUtil.exists(dir)) {
        return;
      }
      const now = Date.now();
      const names: string[] = fileFs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (!name.endsWith('.part')) {
          continue;
        }
        const full = dir + '/' + name;
        try {
          const st = fileFs.statSync(full);
          const mtime = st.mtime ? st.mtime * 1000 : 0;
          if (mtime > 0 && now - mtime > maxAgeMs) {
            fileFs.unlinkSync(full);
            console.info('[CloudLocalFileStore] cleaned stale temp:', name);
          }
        } catch (_e) { /* ignore single file */ }
      }
    } catch (e) {
      console.warn('[CloudLocalFileStore] cleanup failed:', (e as Error).message);
    }
  }

  /** 分配临时下载路径：.../cloudbook/.tmp/<taskId>.part */
  allocTempPath(taskId: string): string {
    this.ensureDirs();
    const safe = (taskId || 'task').replace(new RegExp('[^a-zA-Z0-9_-]', 'g'), '_');
    return this.getTempDir() + '/' + safe + '.part';
  }

  /**
   * 最终路径：files/books/cloud_<sourceId>_<pathHash>_<safeName>
   * 保证不同来源/路径互不覆盖。
   */
  allocFinalBookPath(sourceId: number, remotePath: string, fileName: string): string {
    this.ensureDirs();
    const hash = CloudLocalFileStore.pathHash_(sourceId + '|' + remotePath);
    const safeName = CloudLocalFileStore.sanitizeFileName_(fileName || 'book.bin');
    return this.getBooksDir() + '/cloud_' + sourceId + '_' + hash + '_' + safeName;
  }

  /** 原子 rename；失败时 copyFileSync + 删源 */
  atomicMove(fromPath: string, toPath: string): void {
    try {
      try {
        if (fileFs.accessSync(toPath)) {
          fileFs.unlinkSync(toPath);
        }
      } catch (_e) { /* ok */ }
      fileFs.renameSync(fromPath, toPath);
      return;
    } catch (e) {
      console.warn('[CloudLocalFileStore] rename failed, fallback copy:', (e as Error).message);
    }
    try {
      try {
        if (fileFs.accessSync(toPath)) {
          fileFs.unlinkSync(toPath);
        }
      } catch (_e2) { /* ok */ }
      fileFs.copyFileSync(fromPath, toPath);
      try {
        fileFs.unlinkSync(fromPath);
      } catch (_e3) { /* ignore */ }
    } catch (e2) {
      throw new Error('移动文件失败: ' + ((e2 as Error).message || String(e2)));
    }
  }

  deleteIfExists(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (fileFs.accessSync(path)) {
        fileFs.unlinkSync(path);
      }
    } catch (_e) { /* ignore */ }
  }

  fileSize(path: string): number {
    try {
      return fileFs.statSync(path).size;
    } catch (_e) {
      return 0;
    }
  }

  private ensureDir_(dir: string): void {
    try {
      if (!fileFs.accessSync(dir)) {
        fileFs.mkdirSync(dir, true);
      }
    } catch (_e) {
      try {
        fileFs.mkdirSync(dir, true);
      } catch (e2) {
        console.warn('[CloudLocalFileStore] mkdir failed:', dir, (e2 as Error).message);
      }
    }
  }

  private static sanitizeFileName_(name: string): string {
    let n = (name || 'book').replace(new RegExp('[\\\\/:*?"<>|]', 'g'), '_');
    n = n.replace(new RegExp('\\s+', 'g'), ' ').trim();
    if (!n) {
      n = 'book.bin';
    }
    if (n.length > 80) {
      const dot = n.lastIndexOf('.');
      if (dot > 0 && n.length - dot <= 10) {
        const ext = n.substring(dot);
        n = n.substring(0, 80 - ext.length) + ext;
      } else {
        n = n.substring(0, 80);
      }
    }
    return n;
  }

  /** 简单稳定哈希（非加密），用于文件名 */
  private static pathHash_(s: string): string {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    // 无符号 32 位 → hex
    let u = h >>> 0;
    let hex = u.toString(16);
    while (hex.length < 8) {
      hex = '0' + hex;
    }
    return hex;
  }
}
