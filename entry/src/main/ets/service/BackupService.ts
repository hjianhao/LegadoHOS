/**
 * 完整备份/恢复服务
 *
 * 从数据库和设置存储导出/导入完整数据。
 * 格式：backup.json 打包为 ZIP。
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { WebDavService } from './WebDavService';
import { RdbUtil } from '../data/database/RdbUtil';
import relationalStore from '@ohos.data.relationalStore';
import picker from '@ohos.file.picker';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import zlib from '@ohos.zlib';
import { common } from '@kit.AbilityKit';

export interface BackupData {
  version: string;
  exportTime: string;
  appVersion: string;
  books?: Record<string, Object>[];
  bookmarks?: Record<string, Object>[];
  bookGroups?: Record<string, Object>[];
  bookSources?: Record<string, Object>[];
  replaceRules?: Record<string, Object>[];
  rssSources?: Record<string, Object>[];
  rssStars?: Record<string, Object>[];
  rssReadRecords?: Record<string, Object>[];
  readRecords?: Record<string, Object>[];
  readRecordDetails?: Record<string, Object>[];
  searchHistory?: Record<string, Object>[];
  txtTocRules?: Record<string, Object>[];
  settings?: Record<string, Object>;
}

export interface ImportResult {
  books: number;
  sources: number;
  rules: number;
  errors: string[];
}

export class BackupService {
  private static readonly TEMP_ROOT = '/data/storage/el2/base/haps/entry/files';

  /**
   * 导出完整备份
   */
  static async exportBackup(): Promise<BackupData> {
    const rdb = AppDatabase.getInstance().rdbStore;
    const result: BackupData = { version: '1.0', exportTime: new Date().toISOString(), appVersion: '1.0' };
    const resultMap: Record<string, Object> = result as unknown as Record<string, Object>;

    const tables = [
      'books', 'bookmarks', 'book_groups', 'book_sources', 'replace_rules',
      'rss_sources', 'rss_stars', 'rss_read_records', 'read_records',
      'read_record_details', 'search_history', 'txt_toc_rules',
    ];
    const fieldMap: Record<string, string> = {
      books: 'books', bookmarks: 'bookmarks', bookGroups: 'book_groups',
      bookSources: 'book_sources', replaceRules: 'replace_rules',
      rssSources: 'rss_sources', rssStars: 'rss_stars',
      rssReadRecords: 'rss_read_records', readRecords: 'read_records',
      readRecordDetails: 'read_record_details', searchHistory: 'search_history',
      txtTocRules: 'txt_toc_rules',
    };

    for (const [key, table] of Object.entries(fieldMap)) {
      try {
        const rows = await BackupService.queryAll(rdb, table);
        resultMap[key] = rows as Object;
      } catch (err) {
        console.warn(`[Backup] Export ${table}: ${(err as Error).message}`);
      }
    }

    try {
      const store = SettingsStore.getInstance();
      result.settings = await store.exportAll();
    } catch (_) { /* ok */ }

    return result;
  }

  /**
   * 导入备份
   */
  static async importBackup(data: BackupData): Promise<ImportResult> {
    const rdb = AppDatabase.getInstance().rdbStore;
    const result: ImportResult = { books: 0, sources: 0, rules: 0, errors: [] };

    const restoreMap: Array<{ key: keyof BackupData; table: string; countKey: 'books' | 'sources' | 'rules' }> = [
      { key: 'bookSources', table: 'book_sources', countKey: 'sources' },
      { key: 'replaceRules', table: 'replace_rules', countKey: 'rules' },
      { key: 'books', table: 'books', countKey: 'books' },
      { key: 'bookmarks', table: 'bookmarks', countKey: 'books' },
      { key: 'bookGroups', table: 'book_groups', countKey: 'books' },
      { key: 'rssSources', table: 'rss_sources', countKey: 'books' },
      { key: 'rssStars', table: 'rss_stars', countKey: 'books' },
      { key: 'rssReadRecords', table: 'rss_read_records', countKey: 'books' },
      { key: 'readRecords', table: 'read_records', countKey: 'books' },
      { key: 'readRecordDetails', table: 'read_record_details', countKey: 'books' },
      { key: 'searchHistory', table: 'search_history', countKey: 'books' },
      { key: 'txtTocRules', table: 'txt_toc_rules', countKey: 'books' },
    ];

    for (const { key, table, countKey } of restoreMap) {
      const items = data[key] as Record<string, Object>[] | undefined;
      if (!items || items.length === 0) continue;
      for (const item of items) {
        try {
          const bucket = item as relationalStore.ValuesBucket;
          await rdb.insert(table, bucket);
          result[countKey]++;
        } catch (err) {
          result.errors.push(`${table}: ${(err as Error).message}`);
        }
      }
    }

    if (data.settings) {
      try {
        const store = SettingsStore.getInstance();
        await store.importAll(data.settings as Record<string, Object>);
      } catch (_) { /* ok */ }
    }

    console.info(`[Backup] Imported: ${result.books} items, ${result.sources} sources, ${result.rules} rules`);
    return result;
  }

  /** 本地备份 */
  static async backupToLocal(context: Context): Promise<void> {
    const data = await BackupService.exportBackup();
    const json = JSON.stringify(data);
    const name = `backup_${new Date().toISOString().slice(0, 10)}.zip`;
    const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
    if (!uris || uris.length === 0) return;
    const backupFile = await BackupService.createBackupZip(json);
    try {
      await BackupService.copyFile(backupFile.zipPath, uris[0]);
    } finally {
      BackupService.removeTree(backupFile.tempDir);
    }
  }

  /** 本地恢复 */
  static async restoreFromLocal(context: common.Context): Promise<ImportResult | null> {
    const documentSelectOptions = new picker.DocumentSelectOptions();
    documentSelectOptions.fileSuffixFilters = ['.zip'];
    const uris = await new picker.DocumentViewPicker(context).select(documentSelectOptions);
    if (!uris || uris.length === 0) return null;
    const path = uris[0];

    try {
      const jsonStr = await BackupService.readBackupJsonFromZip(path);
      return await BackupService.importBackup(JSON.parse(jsonStr));
    } catch (err) {
      throw new Error(`备份文件格式错误: ${(err as Error).message}`);
    }
  }

  /** WebDAV 备份 */
  static async backupToWebDav(): Promise<string> {
    const data = await BackupService.exportBackup();
    const backupFile = await BackupService.createBackupZip(JSON.stringify(data));
    try {
      return await WebDavService.getInstance().uploadBackupFile(backupFile.zipPath);
    } finally {
      BackupService.removeTree(backupFile.tempDir);
    }
  }

  /** WebDAV 恢复 */
  static async restoreFromWebDav(name: string): Promise<ImportResult> {
    const zipPath = await WebDavService.getInstance().downloadBackup(name);
    const jsonStr = await BackupService.readBackupJsonFromZip(zipPath);
    return await BackupService.importBackup(JSON.parse(jsonStr));
  }

  // ---- 工具方法 ----

  private static async queryAll(rdb: relationalStore.RdbStore, table: string): Promise<Record<string, Object>[]> {
    const result: Record<string, Object>[] = [];
    const rs = await RdbUtil.querySql(rdb, `SELECT * FROM ${table}`, []);
    try {
      while (RdbUtil.next(rs)) {
        const row: Record<string, Object> = {};
        const colCount = rs.columnCount;
        for (let i = 0; i < colCount; i++) {
          const colName = rs.getColumnName(i);
          const val = RdbUtil.stringAt(rs, i);
          if (val !== null) row[colName] = val as Object;
        }
        result.push(row);
      }
    } catch (err) {
      throw new Error(`Query backup table failed: ${table}: ${(err as Error).message}`);
    } finally {
      RdbUtil.close(rs);
    }
    return result;
  }

  private static async createBackupZip(json: string): Promise<{ tempDir: string; zipPath: string }> {
    const tempDir = BackupService.createTempDir('backup_export');
    const jsonPath = `${tempDir}/backup.json`;
    const zipPath = `${tempDir}/backup.zip`;
    await BackupService.writeFileText(jsonPath, json);
    try {
      await zlib.compressFile(jsonPath, zipPath, {});
    } catch (err) {
      throw new Error(`压缩备份失败: ${(err as Error).message}`);
    }
    return { tempDir, zipPath };
  }

  private static async readBackupJsonFromZip(zipPath: string): Promise<string> {
    const tempDir = BackupService.createTempDir('backup_restore');
    try {
      try {
        await zlib.decompressFile(zipPath, tempDir, {});
      } catch (err) {
        throw new Error(`解压备份失败: ${(err as Error).message}`);
      }
      const backupJsonPath = BackupService.findFileByName(tempDir, 'backup.json');
      if (!backupJsonPath) {
        throw new Error('backup.json not found in backup');
      }
      const jsonStr = await BackupService.readFileText(backupJsonPath);
      if (!jsonStr) {
        throw new Error('backup.json is empty');
      }
      return jsonStr;
    } finally {
      BackupService.removeTree(tempDir);
    }
  }

  private static createTempDir(prefix: string): string {
    const tempDir = `${BackupService.TEMP_ROOT}/${prefix}_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    try {
      fileFs.mkdirSync(tempDir, true);
      return tempDir;
    } catch (err) {
      throw new Error(`创建备份临时目录失败: ${tempDir}: ${(err as Error).message}`);
    }
  }

  private static findFileByName(dir: string, fileName: string): string | null {
    let files: string[];
    try {
      files = fileFs.listFileSync(dir);
    } catch (err) {
      console.warn('[Backup] list temp dir failed:', dir, (err as Error).message);
      return null;
    }
    for (const item of files) {
      const path = `${dir}/${item}`;
      try {
        const stat = fileFs.statSync(path);
        if (stat.isDirectory()) {
          const child = BackupService.findFileByName(path, fileName);
          if (child) return child;
        } else if (item === fileName) {
          return path;
        }
      } catch (err) {
        console.warn('[Backup] inspect temp entry failed:', path, (err as Error).message);
      }
    }
    return null;
  }

  private static removeTree(path: string): void {
    try {
      const stat = fileFs.statSync(path);
      if (stat.isDirectory()) {
        const files = fileFs.listFileSync(path);
        for (const item of files) {
          BackupService.removeTree(`${path}/${item}`);
        }
        fileFs.rmdirSync(path);
      } else {
        fileFs.unlinkSync(path);
      }
    } catch (_err) {
      // 清理临时文件失败不影响备份/恢复结果
    }
  }

  private static async writeFileText(path: string, text: string): Promise<void> {
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(text);
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(path, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      fileFs.writeSync(file.fd, data.buffer as ArrayBuffer);
    } catch (err) {
      throw new Error(`写入文件失败: ${path}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[Backup] close file failed:', (err as Error).message);
        }
      }
    }
  }

  private static async copyFile(src: string, dst: string): Promise<void> {
    const bytes = BackupService.readFileBytes(src);
    let outFile: fileFs.File | null = null;
    try {
      outFile = fileFs.openSync(dst, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      fileFs.writeSync(outFile.fd, bytes.buffer as ArrayBuffer);
    } catch (err) {
      throw new Error(`复制备份文件失败: ${dst}: ${(err as Error).message}`);
    } finally {
      if (outFile) {
        try {
          fileFs.closeSync(outFile);
        } catch (err) {
          console.warn('[Backup] close copy target failed:', (err as Error).message);
        }
      }
    }
  }

  private static readFileBytes(path: string): Uint8Array {
    let file: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      file = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(file.fd, buf);
      return new Uint8Array(buf);
    } catch (err) {
      throw new Error(`读取文件失败: ${path}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[Backup] close read file failed:', (err as Error).message);
        }
      }
    }
  }

  private static async readFileText(path: string): Promise<string | null> {
    let file: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      if (stat.size > 10 * 1024 * 1024) return null;
      const buf = new ArrayBuffer(stat.size);
      file = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(file.fd, buf);
      const decoder = new util.TextDecoder('utf-8', { fatal: false });
      return decoder.decodeToString(new Uint8Array(buf));
    } catch {
      return null;
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[Backup] close text file failed:', (err as Error).message);
        }
      }
    }
  }
}
