/**
 * 完整备份/恢复服务
 *
 * 从数据库和设置存储导出/导入完整数据。
 * 格式：JSON 打包为 ZIP，兼容 Legado 备份格式。
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ZipWriter } from '../util/ZipWriter';
import { ZipReader } from '../util/ZipReader';
import { WebDavService } from './WebDavService';
import { RdbUtil } from '../data/database/RdbUtil';
import relationalStore from '@ohos.data.relationalStore';
import picker from '@ohos.file.picker';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';

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
  bookSourcesCache?: Record<string, Object>[];
  settings?: Record<string, Object>;
}

export interface ImportResult {
  books: number;
  sources: number;
  rules: number;
  errors: string[];
}

export class BackupService {
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
      'read_record_details', 'search_history', 'txt_toc_rules', 'book_sources_cache',
    ];
    const fieldMap: Record<string, string> = {
      books: 'books', bookmarks: 'bookmarks', bookGroups: 'book_groups',
      bookSources: 'book_sources', replaceRules: 'replace_rules',
      rssSources: 'rss_sources', rssStars: 'rss_stars',
      rssReadRecords: 'rss_read_records', readRecords: 'read_records',
      readRecordDetails: 'read_record_details', searchHistory: 'search_history',
      txtTocRules: 'txt_toc_rules', bookSourcesCache: 'book_sources_cache',
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
      { key: 'bookSourcesCache', table: 'book_sources_cache', countKey: 'books' },
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
  static async backupToLocal(): Promise<void> {
    const data = await BackupService.exportBackup();
    const json = JSON.stringify(data);
    const name = `backup_${new Date().toISOString().slice(0, 10)}.zip`;
    const uris = await new picker.DocumentViewPicker().save({ newFileNames: [name] });
    if (!uris || uris.length === 0) return;
    const zip = new ZipWriter();
    zip.addTextFile('backup.json', json);
    await zip.saveTo(uris[0]);
  }

  /** 本地恢复 */
  static async restoreFromLocal(): Promise<ImportResult | null> {
    const uris = await new picker.DocumentViewPicker().select();
    if (!uris || uris.length === 0) return null;
    const path = uris[0];

    // 尝试直接 JSON
    try {
      const text = await BackupService.readFileText(path);
      const data = JSON.parse(text) as BackupData;
      if (data.books || data.bookSources) return await BackupService.importBackup(data);
    } catch { /* try next */ }

    // ZIP 格式（通过 ZipReader 读取）
    try {
      const reader = new ZipReader(path);
      await reader.open();
      const entry = reader.findEntry('backup.json');
      if (!entry) { reader.close(); throw new Error('no backup.json'); }
      const jsonStr = await reader.extractText(entry);
      reader.close();
      if (jsonStr) return await BackupService.importBackup(JSON.parse(jsonStr));
    } catch (err) {
      throw new Error(`备份文件格式错误: ${(err as Error).message}`);
    }
    throw new Error('未能解析备份文件');
  }

  /** WebDAV 备份 */
  static async backupToWebDav(): Promise<string> {
    const data = await BackupService.exportBackup();
    const zip = new ZipWriter();
    zip.addTextFile('backup.json', JSON.stringify(data));
    return await WebDavService.getInstance().uploadBackupZip(zip);
  }

  /** WebDAV 恢复 */
  static async restoreFromWebDav(name: string): Promise<ImportResult> {
    const zipPath = await WebDavService.getInstance().downloadBackup(name);
    const reader = new ZipReader(zipPath);
    await reader.open();
    const entry = reader.findEntry('backup.json');
    if (!entry) { reader.close(); throw new Error('backup.json not found'); }
    const jsonStr = await reader.extractText(entry);
    reader.close();
    return await BackupService.importBackup(JSON.parse(jsonStr));
  }

  // ---- 工具方法 ----

  private static async queryAll(rdb: relationalStore.RdbStore, table: string): Promise<Record<string, Object>[]> {
    const result: Record<string, Object>[] = [];
    const rs = await RdbUtil.querySql(rdb, `SELECT * FROM ${table}`, []);
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
    RdbUtil.close(rs);
    return result;
  }

  private static async readFileText(path: string): Promise<string | null> {
    try {
      const stat = fileFs.statSync(path);
      if (stat.size > 10 * 1024 * 1024) return null;
      const buf = new ArrayBuffer(stat.size);
      const fd = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY).fd;
      fileFs.readSync(fd, buf);
      fileFs.closeSync(fd);
      const decoder = new util.TextDecoder('utf-8', { fatal: false });
      return decoder.decodeToString(new Uint8Array(buf));
    } catch { return null; }
  }
}
