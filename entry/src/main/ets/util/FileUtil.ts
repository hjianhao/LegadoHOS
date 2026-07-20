/**
 * 文件工具
 */
import fileFs from '@ohos.file.fs';

export class FileUtil {
  /**
   * 读取文本文件
   */
  static async readTextFile(filePath: string): Promise<string> {
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      const stat = fileFs.statSync(filePath);
      const buf = new ArrayBuffer(stat.size);
      fileFs.readSync(file.fd, buf);
      return String.fromCharCode(...new Uint8Array(buf));
    } catch (err) {
      throw new Error(`Read text file failed: ${filePath}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[FileUtil] close read file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 写入文本文件
   */
  static async writeTextFile(filePath: string, content: string): Promise<void> {
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(filePath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      const buf = new Uint8Array(content.split('').map(c => c.charCodeAt(0)));
      fileFs.writeSync(file.fd, buf);
    } catch (err) {
      throw new Error(`Write text file failed: ${filePath}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[FileUtil] close write file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 获取文件扩展名
   */
  static getExtension(filePath: string): string {
    const dot = filePath.lastIndexOf('.');
    return dot >= 0 ? filePath.slice(dot + 1).toLowerCase() : '';
  }

  /**
   * 获取文件名（不含路径）
   */
  static getFileName(filePath: string): string {
    const slash = filePath.lastIndexOf('/');
    return slash >= 0 ? filePath.slice(slash + 1) : filePath;
  }

  /**
   * 获取文件大小
   */
  static getFileSize(filePath: string): number {
    try {
      const stat = fileFs.statSync(filePath);
      return stat.size;
    } catch {
      return 0;
    }
  }

  /**
   * 检测文件是否存在
   */
  static exists(filePath: string): boolean {
    try {
      fileFs.statSync(filePath);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * 删除文件
   */
  static async deleteFile(filePath: string): Promise<void> {
    try {
      fileFs.unlinkSync(filePath);
    } catch (err) {
      console.error('[FileUtil] Delete failed:', err);
    }
  }

  /**
   * 递归删除目录及其下所有文件和子目录。
   * HarmonyOS fileFs.rmdirSync 仅能删空目录，需先递归删子项再删目录本身。
   * 路径不存在时静默返回，不抛错。
   */
  static removeDirRecursive(dirPath: string): void {
    if (!FileUtil.exists(dirPath)) return;
    try {
      const names: string[] = fileFs.listFileSync(dirPath);
      for (const name of names) {
        const child: string = `${dirPath}${dirPath.endsWith('/') ? '' : '/'}${name}`;
        const stat = fileFs.statSync(child);
        if (stat.isDirectory()) {
          FileUtil.removeDirRecursive(child);
        } else {
          try { fileFs.unlinkSync(child); } catch (_) { /* ignore */ }
        }
      }
      fileFs.rmdirSync(dirPath);
    } catch (err) {
      console.warn('[FileUtil] removeDirRecursive failed:', dirPath, (err as Error).message);
    }
  }
}
