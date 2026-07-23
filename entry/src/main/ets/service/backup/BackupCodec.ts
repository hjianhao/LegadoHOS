/**
 * 备份编解码
 *
 * 支持两套格式：
 * 1) 鸿蒙 native：backup.json（完整、可逆）
 * 2) 安卓 Legado：多文件 ZIP（bookshelf.json / bookSource.json / ... / config.xml）
 *
 * 设计原则：
 * - 鸿蒙↔鸿蒙：native 全量
 * - 鸿蒙↔安卓：核心子集兼容（书/源/分组/书签/替换/RSS/搜索/TXT规则/设置）
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { BookTable } from '../../data/database/BookTable';
import { BookSourceTable } from '../../data/database/BookSourceTable';
import { BookmarkTable } from '../../data/database/BookmarkTable';
import { BookGroupTable } from '../../data/database/BookGroupTable';
import { ReplaceRuleTable } from '../../data/database/ReplaceRuleTable';
import { RSSSourceTable } from '../../data/database/RSSSourceTable';
import { CloudSourceTable } from '../../data/database/CloudSourceTable';
import { RdbUtil } from '../../data/database/RdbUtil';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { CloudCredentialStore } from '../../data/preferences/CloudCredentialStore';
import { Book, BookType, createDefaultBook } from '../../model/Book';
import { BookGroup, BookGroupItem } from '../../model/BookGroup';
import { Bookmark } from '../../model/Bookmark';
import { bookSourceToJsonObject, parseBookSource } from '../../model/BookSource';
import { ReplaceRule, createDefaultReplaceRule } from '../../model/ReplaceRule';
import { CloudSource, CLOUD_PROVIDER_WEBDAV, createDefaultCloudSource } from '../../model/CloudSource';
import { CloudPath } from '../cloud/CloudPath';
import { BackupConfig, RestoreIgnoreConfig } from './BackupConfig';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import zlib from '@ohos.zlib';
import { SimpleZip } from './SimpleZip';
import relationalStore from '@ohos.data.relationalStore';

export interface BackupData {
  version: string;
  exportTime: string;
  appVersion: string;
  platform?: string;
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
  /**
   * 云端书库来源（非敏感）。
   * 绝不包含 password / secret / credential 明文。
   */
  cloudSources?: Record<string, Object>[];
}

export interface ImportResult {
  books: number;
  sources: number;
  rules: number;
  groups: number;
  bookmarks: number;
  rss: number;
  settings: number;
  /** 恢复的云端书库来源数（不含密码） */
  cloudSources: number;
  /** 恢复后来源需要用户重新填写密码的数量 */
  cloudSourcesNeedPassword: number;
  skipped: number;
  errors: string[];
  format: 'harmony' | 'android' | 'unknown';
}

export interface BackupZipFile {
  tempDir: string;
  zipPath: string;
  fileName: string;
}

const TEMP_ROOT = '/data/storage/el2/base/haps/entry/files';

// 设置忽略：恢复时跳过这些 key 前缀/精确键（含所有凭证类）
const DEVICE_LOCAL_KEYS = new Set<string>([
  'webdav_password', 'webdav_pwd', 'backup_last_time', 'huks_key_material',
]);

/** 判断设置键是否为敏感凭证（绝不随备份恢复/导出） */
function isSensitiveSettingsKey(key: string): boolean {
  if (!key) {
    return false;
  }
  if (DEVICE_LOCAL_KEYS.has(key)) {
    return true;
  }
  const k = key.toLowerCase();
  if (k.indexOf('cloud_cred') >= 0 || k.indexOf('cloud-source') >= 0) {
    return true;
  }
  if (k.indexOf('password') >= 0 || k.indexOf('passwd') >= 0 || k.indexOf('_pwd') >= 0) {
    return true;
  }
  if (k.indexOf('secret') >= 0 || k.indexOf('token') >= 0 || k.indexOf('api_key') >= 0 ||
    k.indexOf('apikey') >= 0) {
    return true;
  }
  if (k.indexOf('authorization') >= 0 || k.indexOf('credential') >= 0) {
    return true;
  }
  return false;
}

function emptyImportResult(format: 'harmony' | 'android' | 'unknown'): ImportResult {
  return {
    books: 0,
    sources: 0,
    rules: 0,
    groups: 0,
    bookmarks: 0,
    rss: 0,
    settings: 0,
    cloudSources: 0,
    cloudSourcesNeedPassword: 0,
    skipped: 0,
    errors: [],
    format: format,
  };
}

interface CloudSourceImportStats {
  imported: number;
  needPassword: number;
}

export class BackupCodec {
  /** 恢复过程中的书架索引缓存，避免每本书全表扫描导致 OOM */
  private static restoreBookIndex_: Book[] | null = null;
  private static restoreUrlMap_: Map<string, Book> | null = null;
  private static restoreNameMap_: Map<string, Book> | null = null;
  private static readonly MAX_TEXT_FILE_BYTES = 40 * 1024 * 1024; // 40MB 安全上限

  // ---------------- export ----------------

  /** 导出鸿蒙完整 BackupData（内存对象） */
  static async exportHarmonyData(): Promise<BackupData> {
    const rdb = AppDatabase.getInstance().rdbStore;
    const result: BackupData = {
      version: '1.1',
      exportTime: new Date().toISOString(),
      appVersion: '1.0',
      platform: 'harmony',
    };
    const resultMap = result as unknown as Record<string, Object>;
    const fieldMap: Record<string, string> = {
      books: 'books',
      bookmarks: 'bookmarks',
      bookGroups: 'book_groups',
      bookSources: 'book_sources',
      replaceRules: 'replace_rules',
      rssSources: 'rss_sources',
      rssStars: 'rss_stars',
      rssReadRecords: 'rss_read_records',
      readRecords: 'read_records',
      readRecordDetails: 'read_record_details',
      searchHistory: 'search_keywords',
      txtTocRules: 'txt_toc_rules',
    };
    for (const [key, table] of Object.entries(fieldMap)) {
      try {
        resultMap[key] = await BackupCodec.queryAll(rdb, table) as Object;
      } catch (err) {
        console.warn(`[BackupCodec] export ${table}: ${(err as Error).message}`);
      }
    }
    try {
      const allSettings = await SettingsStore.getInstance().exportAll();
      // 导出时剥离凭证类键，防止 webdav_pwd / cloud_cred 等进入备份包
      const safeSettings: Record<string, Object> = {};
      const settingKeys = Object.keys(allSettings);
      for (let i = 0; i < settingKeys.length; i++) {
        const sk = settingKeys[i];
        if (isSensitiveSettingsKey(sk)) {
          continue;
        }
        safeSettings[sk] = allSettings[sk] as Object;
      }
      result.settings = safeSettings;
    } catch (_) { /* ok */ }
    // 云端书库来源：仅非敏感字段
    try {
      result.cloudSources = await BackupCodec.exportCloudSources_();
    } catch (e) {
      console.warn('[BackupCodec] export cloud_sources:', (e as Error).message);
    }
    return result;
  }

  /** 导出 cloud_sources 非敏感配置（无密码、无 credential_ref 明文） */
  private static async exportCloudSources_(): Promise<Record<string, Object>[]> {
    const table = new CloudSourceTable(AppDatabase.getInstance().rdbStore);
    const list = await table.listAll();
    const out: Record<string, Object>[] = [];
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      const row: Record<string, Object> = {
        'name': s.name,
        'providerType': s.providerType || CLOUD_PROVIDER_WEBDAV,
        'endpoint': s.endpoint,
        'rootPath': s.rootPath || '',
        'configJson': s.configJson || '{}',
        'enabled': s.enabled ? 1 : 0,
        'sortNumber': s.sortNumber,
      };
      out.push(row);
    }
    return out;
  }

  /**
   * 创建兼容安卓的 ZIP：
   * - 多文件安卓结构（可被安卓恢复）
   * - 同时附带 backup.json（鸿蒙完整恢复）
   */
  static async createCompatibleZip(fileName?: string): Promise<BackupZipFile> {
    const harmony = await BackupCodec.exportHarmonyData();
    const tempDir = BackupCodec.createTempDir('backup_export');
    const workDir = `${tempDir}/payload`;
    fileFs.mkdirSync(workDir, true);

    // 1) 鸿蒙完整块
    await BackupCodec.writeText(`${workDir}/backup.json`, JSON.stringify(harmony));
    // 2) 安卓兼容块
    await BackupCodec.writeAndroidFiles(workDir, harmony);

    const zipName = fileName || BackupConfig.getNowZipFileName();
    const zipPath = `${tempDir}/${zipName}`;
    // 使用自研 STORE ZIP，确保多文件结构稳定（兼容 Android ZipUtils）
    const zip = new SimpleZip();
    const files = BackupCodec.listFilesRecursive(workDir, '');
    for (const rel of files) {
      zip.addFile(rel, `${workDir}/${rel}`);
    }
    zip.writeTo(zipPath);
    return { tempDir, zipPath, fileName: zipName };
  }

  private static listFilesRecursive(dir: string, prefix: string): string[] {
    const out: string[] = [];
    let items: string[] = [];
    try {
      items = fileFs.listFileSync(dir);
    } catch {
      return out;
    }
    for (const item of items) {
      const path = `${dir}/${item}`;
      const rel = prefix ? `${prefix}/${item}` : item;
      try {
        const st = fileFs.statSync(path);
        if (st.isDirectory()) {
          out.push(...BackupCodec.listFilesRecursive(path, rel));
        } else {
          out.push(rel);
        }
      } catch { /* skip */ }
    }
    return out;
  }

  // ---------------- import ----------------

  static async importFromZipPath(zipPath: string, ignore?: RestoreIgnoreConfig): Promise<ImportResult> {
    const tempDir = BackupCodec.createTempDir('backup_restore');
    try {
      try {
        await zlib.decompressFile(zipPath, tempDir, {});
      } catch (err) {
        throw new Error(`解压备份失败: ${(err as Error).message}`);
      }
      return await BackupCodec.importFromDir(tempDir, ignore);
    } finally {
      BackupCodec.removeTree(tempDir);
    }
  }

  static async importFromDir(dir: string, ignore?: RestoreIgnoreConfig): Promise<ImportResult> {
    const ignoreCfg = ignore || BackupConfig.getIgnoreConfig();
    try {
      await BackupCodec.beginRestoreIndex_(AppDatabase.getInstance().rdbStore);
      const harmonyPath = BackupCodec.findFileByName(dir, 'backup.json');
      const androidBookshelf = BackupCodec.findFileByName(dir, 'bookshelf.json');
      const androidSource = BackupCodec.findFileByName(dir, 'bookSource.json');

      if (androidBookshelf || androidSource) {
        // 优先按安卓多文件恢复（即使也有 backup.json）
        // 若同时有 backup.json，额外用它补齐鸿蒙私有 settings / 云端书库来源
        const result = await BackupCodec.importAndroidDir(dir, ignoreCfg);
        if (harmonyPath) {
          try {
            // 安卓包里附带的 backup.json 可能极大，超限则跳过 settings 合并
            const st = fileFs.statSync(harmonyPath);
            if (st.size <= 8 * 1024 * 1024) {
              const text = await BackupCodec.readText(harmonyPath);
              const data = JSON.parse(text) as BackupData;
              if (data.settings) {
                result.settings += await BackupCodec.importSettings(data.settings, ignoreCfg);
              }
              if (Array.isArray(data.cloudSources) && data.cloudSources.length > 0) {
                try {
                  const cloudResult = await BackupCodec.importCloudSources_(data.cloudSources);
                  result.cloudSources = cloudResult.imported;
                  result.cloudSourcesNeedPassword = cloudResult.needPassword;
                  BackupCodec.markCloudCredentialHint_(cloudResult.needPassword);
                } catch (ce) {
                  result.errors.push(`cloud_sources: ${(ce as Error).message}`);
                }
              }
            } else {
              result.errors.push(`harmony settings skipped: backup.json too large (${st.size})`);
            }
          } catch (e) {
            result.errors.push(`harmony settings: ${(e as Error).message}`);
          }
        }
        result.format = 'android';
        return result;
      }

      if (harmonyPath) {
        const text = await BackupCodec.readText(harmonyPath);
        const data = JSON.parse(text) as BackupData;
        const result = await BackupCodec.importHarmonyData(data, ignoreCfg);
        result.format = 'harmony';
        return result;
      }

      throw new Error('无法识别备份格式（缺少 backup.json / bookshelf.json）');
    } finally {
      BackupCodec.endRestoreIndex_();
    }
  }

  // ---------------- harmony import with upsert ----------------

  static async importHarmonyData(data: BackupData, ignore?: RestoreIgnoreConfig): Promise<ImportResult> {
    const ignoreCfg = ignore || BackupConfig.getIgnoreConfig();
    const result: ImportResult = emptyImportResult('harmony');
    const rdb = AppDatabase.getInstance().rdbStore;
    const bookTable = new BookTable(rdb);
    const sourceTable = new BookSourceTable(rdb);
    const groupTable = new BookGroupTable(rdb);
    const bookmarkTable = new BookmarkTable(rdb);
    const replaceTable = new ReplaceRuleTable(rdb);
    const rssTable = new RSSSourceTable(rdb);

    // groups first
    if (Array.isArray(data.bookGroups)) {
      for (const row of data.bookGroups) {
        try {
          const item = BackupCodec.rowToGroup(row);
          if (item.id < BookGroup.CUSTOM) {
            result.skipped++;
            continue;
          }
          const existing = await groupTable.getGroupById(item.id);
          if (existing) {
            await groupTable.updateGroup(item);
          } else {
            // 直接插入指定 id
            await RdbUtil.insert(rdb, BookGroupTable.TABLE_NAME, {
              'id': item.id,
              'name': item.name,
              '"order"': item.order,
              'cover': item.cover || '',
              'enable_refresh': item.enableRefresh ? 1 : 0,
              'is_show': item.show ? 1 : 0,
              'is_private': item.isPrivate ? 1 : 0,
              'book_sort': item.bookSort,
              'create_time': Date.now(),
              'update_time': Date.now(),
            });
          }
          result.groups++;
        } catch (e) {
          result.errors.push(`book_groups: ${(e as Error).message}`);
        }
      }
    }

    // sources
    if (Array.isArray(data.bookSources)) {
      for (const row of data.bookSources) {
        try {
          const raw = BackupCodec.normalizeSourceRow(row);
          const count = await sourceTable.importSources(JSON.stringify([raw]));
          result.sources += count;
        } catch (e) {
          result.errors.push(`book_sources: ${(e as Error).message}`);
        }
      }
    }

    // books
    if (Array.isArray(data.books)) {
      for (const row of data.books) {
        try {
          const book = BackupCodec.rowToBook(row);
          if (BackupCodec.shouldSkipLocalBook(book, ignoreCfg.localBook)) {
            result.skipped++;
            continue;
          }
          const n = await BackupCodec.upsertBook(bookTable, book);
          result.books += n;
        } catch (e) {
          result.errors.push(`books: ${(e as Error).message}`);
        }
      }
    }

    // bookmarks
    if (Array.isArray(data.bookmarks)) {
      for (const row of data.bookmarks) {
        try {
          const bm = BackupCodec.rowToBookmark(row);
          // 无稳定主键时直接插入（按内容去重成本高）
          await bookmarkTable.insert(bm);
          result.bookmarks++;
        } catch (e) {
          result.errors.push(`bookmarks: ${(e as Error).message}`);
        }
      }
    }

    // replace rules
    if (Array.isArray(data.replaceRules)) {
      for (const row of data.replaceRules) {
        try {
          const rule = BackupCodec.rowToReplaceRule(row);
          if (rule.id > 0) {
            try {
              await replaceTable.update(rule);
              result.rules++;
              continue;
            } catch (_e) { /* fallthrough insert */ }
          }
          rule.id = 0;
          await replaceTable.insert(rule);
          result.rules++;
        } catch (e) {
          result.errors.push(`replace_rules: ${(e as Error).message}`);
        }
      }
    }

    // rss sources
    if (Array.isArray(data.rssSources)) {
      for (const row of data.rssSources) {
        try {
          await BackupCodec.upsertRssSource(rssTable, rdb, row);
          result.rss++;
        } catch (e) {
          result.errors.push(`rss_sources: ${(e as Error).message}`);
        }
      }
    }

    // other simple tables: insert-ignore style
    const simpleTables: Array<{ key: keyof BackupData; table: string }> = [
      { key: 'rssStars', table: 'rss_stars' },
      { key: 'rssReadRecords', table: 'rss_read_records' },
      { key: 'readRecords', table: 'read_records' },
      { key: 'readRecordDetails', table: 'read_record_details' },
      { key: 'searchHistory', table: 'search_keywords' },
      { key: 'txtTocRules', table: 'txt_toc_rules' },
    ];
    for (const item of simpleTables) {
      const rows = data[item.key] as Record<string, Object>[] | undefined;
      if (!rows || rows.length === 0) continue;
      for (const row of rows) {
        try {
          await BackupCodec.insertRowIgnore(rdb, item.table, row);
        } catch (e) {
          result.errors.push(`${item.table}: ${(e as Error).message}`);
        }
      }
    }

    if (data.settings) {
      result.settings += await BackupCodec.importSettings(data.settings, ignoreCfg);
    }
    // 云端书库来源（无密码）
    if (Array.isArray(data.cloudSources) && data.cloudSources.length > 0) {
      try {
        const cloudResult = await BackupCodec.importCloudSources_(data.cloudSources);
        result.cloudSources = cloudResult.imported;
        result.cloudSourcesNeedPassword = cloudResult.needPassword;
      } catch (e) {
        result.errors.push(`cloud_sources: ${(e as Error).message}`);
      }
    }
    BackupCodec.markCloudCredentialHint_(result.cloudSourcesNeedPassword);
    return result;
  }

  /**
   * 恢复云端书库来源配置。
   * - 永不恢复密码
   * - 按 endpoint + rootPath 匹配已有来源
   * - 新来源生成新 credentialRef，密码需用户补填
   */
  private static async importCloudSources_(
    rows: Record<string, Object>[]
  ): Promise<CloudSourceImportStats> {
    // 凭证 store 若未 init，generateCredentialRef 仍可用；get 时可能无密码
    try {
      if (!CloudCredentialStore.getInstance().isReady()) {
        console.warn('[BackupCodec] CloudCredentialStore not ready; sources restored without secrets');
      }
    } catch (_e) { /* ignore */ }
    const table = new CloudSourceTable(AppDatabase.getInstance().rdbStore);
    const existing = await table.listAll();
    let imported = 0;
    let needPassword = 0;
    const now = Date.now();

    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      try {
        const name = String(row['name'] ?? row['source_name'] ?? '').trim();
        let endpoint = String(row['endpoint'] ?? row['serverUrl'] ?? '').trim();
        let rootPath = String(row['rootPath'] ?? row['root_path'] ?? '');
        if (!name || !endpoint) {
          continue;
        }
        try {
          rootPath = CloudPath.normalizeRootPath(rootPath);
        } catch (_pe) {
          rootPath = (rootPath || '').replace(new RegExp('^/+|/+$', 'g'), '');
        }
        // 规范化 endpoint 末尾斜杠
        while (endpoint.length > 8 && endpoint.endsWith('/')) {
          endpoint = endpoint.substring(0, endpoint.length - 1);
        }
        if (!new RegExp('^https?://', 'i').test(endpoint)) {
          endpoint = 'https://' + endpoint;
        }
        const providerType = String(row['providerType'] ?? row['provider_type'] ?? CLOUD_PROVIDER_WEBDAV);
        const configJson = String(row['configJson'] ?? row['config_json'] ?? '{}');
        const enabledRaw = row['enabled'];
        const enabled = enabledRaw === false || enabledRaw === 0 || enabledRaw === '0' ? false : true;
        const sortNumber = Number(row['sortNumber'] ?? row['sort_number'] ?? i) || i;

        let matched: CloudSource | null = null;
        for (let j = 0; j < existing.length; j++) {
          const e = existing[j];
          const ep = (e.endpoint || '').replace(new RegExp('/+$'), '');
          if (ep === endpoint && (e.rootPath || '') === rootPath) {
            matched = e;
            break;
          }
        }

        if (matched) {
          matched.name = name;
          matched.providerType = providerType || matched.providerType;
          matched.endpoint = endpoint;
          matched.rootPath = rootPath;
          matched.configJson = configJson || '{}';
          matched.enabled = enabled;
          matched.sortNumber = sortNumber;
          matched.updatedAt = now;
          if (!matched.credentialRef) {
            matched.credentialRef = CloudCredentialStore.getInstance().generateCredentialRef();
          }
          await table.update(matched);
          imported++;
          // 检查是否已有密码
          let hasSecret = false;
          try {
            if (CloudCredentialStore.getInstance().isReady()) {
              const cred = await CloudCredentialStore.getInstance()
                .getCloudCredential(matched.credentialRef);
              hasSecret = !!(cred && cred.secret);
            }
          } catch (_ce) {
            hasSecret = false;
          }
          if (!hasSecret) {
            needPassword++;
          }
        } else {
          const source = createDefaultCloudSource();
          source.name = name;
          source.providerType = providerType || CLOUD_PROVIDER_WEBDAV;
          source.endpoint = endpoint;
          source.rootPath = rootPath;
          source.configJson = configJson || '{}';
          source.enabled = enabled;
          source.sortNumber = sortNumber;
          source.credentialRef = CloudCredentialStore.getInstance().generateCredentialRef();
          source.createdAt = now;
          source.updatedAt = now;
          source.id = await table.insert(source);
          existing.push(source);
          imported++;
          needPassword++;
        }
      } catch (e) {
        console.warn('[BackupCodec] import cloud source failed:', (e as Error).message);
      }
    }
    const stats: CloudSourceImportStats = {
      imported: imported,
      needPassword: needPassword,
    };
    return stats;
  }

  private static markCloudCredentialHint_(needPassword: number): void {
    try {
      AppStorage.setOrCreate<number>('cloud_sources_need_password', needPassword);
      if (needPassword > 0) {
        AppStorage.setOrCreate<boolean>('cloud_sources_show_password_hint', true);
      }
    } catch (_e) { /* ignore */ }
  }

  // ---------------- android import ----------------

  private static async importAndroidDir(dir: string, ignore: RestoreIgnoreConfig): Promise<ImportResult> {
    const result: ImportResult = emptyImportResult('android');
    const rdb = AppDatabase.getInstance().rdbStore;
    const bookTable = new BookTable(rdb);
    const sourceTable = new BookSourceTable(rdb);
    const groupTable = new BookGroupTable(rdb);
    const bookmarkTable = new BookmarkTable(rdb);
    const replaceTable = new ReplaceRuleTable(rdb);
    const rssTable = new RSSSourceTable(rdb);

    // bookSource.json
    const sourcePath = BackupCodec.findFileByName(dir, 'bookSource.json');
    if (sourcePath) {
      try {
        const text = await BackupCodec.readText(sourcePath);
        const count = await sourceTable.importSources(text);
        result.sources += count;
      } catch (e) {
        result.errors.push(`bookSource.json: ${(e as Error).message}`);
      }
    }

    // bookGroup.json
    const groupPath = BackupCodec.findFileByName(dir, 'bookGroup.json');
    if (groupPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(groupPath));
        for (const raw of list) {
          const groupId = Number(raw['groupId'] ?? raw['id'] ?? 0);
          const name = String(raw['groupName'] ?? raw['name'] ?? '');
          if (!name) continue;
          // 安卓系统组是负数 id，鸿蒙自定义组 >= 10；只导入正数自定义组
          if (groupId > 0 && groupId < BookGroup.CUSTOM) {
            result.skipped++;
            continue;
          }
          const item: BookGroupItem = {
            id: groupId >= BookGroup.CUSTOM ? groupId : 0,
            name: name,
            order: Number(raw['order'] ?? 0),
            cover: String(raw['cover'] ?? ''),
            isSystem: false,
            enableRefresh: raw['enableRefresh'] !== false,
            show: raw['show'] !== false,
            isPrivate: !!raw['isPrivate'],
            bookSort: Number(raw['bookSort'] ?? -1),
          };
          if (item.id >= BookGroup.CUSTOM) {
            const existing = await groupTable.getGroupById(item.id);
            if (existing) await groupTable.updateGroup(item);
            else {
              await RdbUtil.insert(rdb, BookGroupTable.TABLE_NAME, {
                'id': item.id,
                'name': item.name,
                '"order"': item.order,
                'cover': item.cover || '',
                'enable_refresh': item.enableRefresh ? 1 : 0,
                'is_show': item.show ? 1 : 0,
                'is_private': item.isPrivate ? 1 : 0,
                'book_sort': item.bookSort,
                'create_time': Date.now(),
                'update_time': Date.now(),
              });
            }
          } else {
            // 无有效 id：按名称新建
            await groupTable.insertGroup(item.name);
          }
          result.groups++;
        }
      } catch (e) {
        result.errors.push(`bookGroup.json: ${(e as Error).message}`);
      }
    }

    // bookshelf.json
    const bookPath = BackupCodec.findFileByName(dir, 'bookshelf.json');
    if (bookPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(bookPath));
        for (const raw of list) {
          try {
            const book = BackupCodec.androidBookToHarmony(raw);
            if (BackupCodec.shouldSkipLocalBook(book, ignore.localBook)) {
              result.skipped++;
              continue;
            }
            result.books += await BackupCodec.upsertBook(bookTable, book);
          } catch (e) {
            result.errors.push(`bookshelf item: ${(e as Error).message}`);
          }
        }
      } catch (e) {
        result.errors.push(`bookshelf.json: ${(e as Error).message}`);
      }
    }

    // bookmark.json
    const bmPath = BackupCodec.findFileByName(dir, 'bookmark.json');
    if (bmPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(bmPath));
        for (const raw of list) {
          const bm: Bookmark = {
            id: 0,
            bookId: 0,
            bookName: String(raw['bookName'] ?? ''),
            bookAuthor: String(raw['bookAuthor'] ?? ''),
            chapterIndex: Number(raw['chapterIndex'] ?? 0),
            chapterName: String(raw['chapterName'] ?? ''),
            chapterPos: Number(raw['chapterPos'] ?? 0),
            text: String(raw['bookText'] ?? raw['text'] ?? ''),
            note: String(raw['content'] ?? raw['note'] ?? ''),
            createTime: Number(raw['time'] ?? Date.now()),
            updateTime: Number(raw['time'] ?? Date.now()),
          };
          // 尝试关联 bookId
          if (bm.bookName) {
            const book = await bookTable.getBookByName(bm.bookName, bm.bookAuthor);
            if (book) bm.bookId = book.id;
          }
          await bookmarkTable.insert(bm);
          result.bookmarks++;
        }
      } catch (e) {
        result.errors.push(`bookmark.json: ${(e as Error).message}`);
      }
    }

    // replaceRule.json
    const rrPath = BackupCodec.findFileByName(dir, 'replaceRule.json');
    if (rrPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(rrPath));
        for (const raw of list) {
          const rule = createDefaultReplaceRule();
          rule.id = Number(raw['id'] ?? 0);
          rule.name = String(raw['name'] ?? '');
          rule.group = String(raw['group'] ?? '');
          rule.pattern = String(raw['pattern'] ?? '');
          rule.replacement = String(raw['replacement'] ?? '');
          rule.scope = String(raw['scope'] ?? '');
          rule.scopeTitle = !!raw['scopeTitle'];
          rule.scopeContent = raw['scopeContent'] !== false;
          rule.excludeScope = String(raw['excludeScope'] ?? '');
          rule.isEnabled = raw['isEnabled'] !== false;
          rule.isRegex = raw['isRegex'] !== false;
          rule.timeoutMillisecond = Number(raw['timeoutMillisecond'] ?? 3000);
          rule.order = Number(raw['order'] ?? raw['sortOrder'] ?? 0);
          if (rule.id > 0) {
            try {
              await replaceTable.update(rule);
              result.rules++;
              continue;
            } catch (_e) { /* insert */ }
          }
          rule.id = 0;
          await replaceTable.insert(rule);
          result.rules++;
        }
      } catch (e) {
        result.errors.push(`replaceRule.json: ${(e as Error).message}`);
      }
    }

    // rssSources.json
    const rssPath = BackupCodec.findFileByName(dir, 'rssSources.json');
    if (rssPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(rssPath));
        for (const raw of list) {
          await BackupCodec.upsertRssSource(rssTable, rdb, raw as Record<string, Object>);
          result.rss++;
        }
      } catch (e) {
        result.errors.push(`rssSources.json: ${(e as Error).message}`);
      }
    }

    // searchHistory.json
    const shPath = BackupCodec.findFileByName(dir, 'searchHistory.json');
    if (shPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(shPath));
        for (const raw of list) {
          const word = String(raw['word'] ?? raw['keyword'] ?? '');
          if (!word) continue;
          try {
            await BackupCodec.upsertSearchKeyword_(rdb, word, Number(raw['usage'] ?? 1), Number(raw['lastUseTime'] ?? Date.now()));
          } catch (_e) { /* ignore dup */ }
        }
      } catch (e) {
        result.errors.push(`searchHistory.json: ${(e as Error).message}`);
      }
    }

    // txtTocRule.json
    const tocPath = BackupCodec.findFileByName(dir, 'txtTocRule.json');
    if (tocPath) {
      try {
        const list = BackupCodec.parseJsonArray(await BackupCodec.readText(tocPath));
        for (const raw of list) {
          try {
            await RdbUtil.insert(rdb, 'txt_toc_rules', {
              'rule_name': String(raw['name'] ?? raw['rule_name'] ?? ''),
              'rule_pattern': String(raw['rule'] ?? raw['rule_pattern'] ?? ''),
              'is_enabled': raw['enable'] === false ? 0 : 1,
              'sort_order': Number(raw['serialNumber'] ?? raw['sort_order'] ?? 0),
              'create_time': Date.now(),
            } as relationalStore.ValuesBucket);
          } catch (_e) { /* ignore */ }
        }
      } catch (e) {
        result.errors.push(`txtTocRule.json: ${(e as Error).message}`);
      }
    }

    // config.xml -> settings
    const cfgPath = BackupCodec.findFileByName(dir, 'config.xml');
    if (cfgPath) {
      try {
        const xml = await BackupCodec.readText(cfgPath);
        const map = BackupCodec.parseConfigXml(xml);
        result.settings += await BackupCodec.importSettings(map, ignore);
      } catch (e) {
        result.errors.push(`config.xml: ${(e as Error).message}`);
      }
    }

    return result;
  }

  // ---------------- android export helpers ----------------

  private static async writeAndroidFiles(workDir: string, harmony: BackupData): Promise<void> {
    // bookshelf
    const books = (harmony.books || []).map((row) => BackupCodec.harmonyBookRowToAndroid(row));
    await BackupCodec.writeText(`${workDir}/bookshelf.json`, JSON.stringify(books));

    // bookSource：优先标准 JSON
    const sourceObjs: Object[] = [];
    if (Array.isArray(harmony.bookSources)) {
      for (const row of harmony.bookSources) {
        try {
          // 若有 raw_json 直接用
          const rawJson = String(row['raw_json'] ?? row['rawJson'] ?? '');
          if (rawJson) {
            sourceObjs.push(JSON.parse(rawJson));
            continue;
          }
          const src = parseBookSource(BackupCodec.normalizeSourceRow(row));
          sourceObjs.push(bookSourceToJsonObject(src));
        } catch (_e) {
          sourceObjs.push(BackupCodec.normalizeSourceRow(row));
        }
      }
    }
    await BackupCodec.writeText(`${workDir}/bookSource.json`, JSON.stringify(sourceObjs));

    // bookGroup
    const groups = (harmony.bookGroups || []).map((row) => {
      return {
        groupId: Number(row['id'] ?? 0),
        groupName: String(row['name'] ?? ''),
        cover: String(row['cover'] ?? ''),
        order: Number(row['order'] ?? row['"order"'] ?? 0),
        enableRefresh: Number(row['enable_refresh'] ?? 1) === 1,
        show: Number(row['is_show'] ?? 1) === 1,
        bookSort: Number(row['book_sort'] ?? -1),
        isPrivate: Number(row['is_private'] ?? 0) === 1,
      };
    });
    await BackupCodec.writeText(`${workDir}/bookGroup.json`, JSON.stringify(groups));

    // bookmark
    const bms = (harmony.bookmarks || []).map((row) => {
      return {
        time: Number(row['create_time'] ?? Date.now()),
        bookName: String(row['book_name'] ?? ''),
        bookAuthor: String(row['book_author'] ?? ''),
        chapterIndex: Number(row['chapter_index'] ?? 0),
        chapterPos: Number(row['chapter_pos'] ?? 0),
        chapterName: String(row['chapter_name'] ?? ''),
        bookText: String(row['text'] ?? ''),
        content: String(row['note'] ?? ''),
      };
    });
    await BackupCodec.writeText(`${workDir}/bookmark.json`, JSON.stringify(bms));

    // replaceRule
    const rules = (harmony.replaceRules || []).map((row) => {
      return {
        id: Number(row['id'] ?? 0),
        name: String(row['rule_name'] ?? row['name'] ?? ''),
        group: String(row['rule_group'] ?? row['group'] ?? ''),
        pattern: String(row['pattern'] ?? ''),
        replacement: String(row['replacement'] ?? ''),
        scope: String(row['scope'] ?? ''),
        scopeTitle: Number(row['scope_title'] ?? 0) === 1 || !!row['scopeTitle'],
        scopeContent: (row['scope_content'] === undefined && row['scopeContent'] === undefined)
          ? true
          : (Number(row['scope_content'] ?? 1) === 1 || !!row['scopeContent']),
        excludeScope: String(row['exclude_scope'] ?? row['excludeScope'] ?? ''),
        isEnabled: Number(row['is_enabled'] ?? 1) === 1,
        isRegex: Number(row['is_regex'] ?? 1) === 1,
        timeoutMillisecond: Number(row['timeout_millisecond'] ?? 3000),
        order: Number(row['sort_order'] ?? row['order'] ?? 0),
      };
    });
    await BackupCodec.writeText(`${workDir}/replaceRule.json`, JSON.stringify(rules));

    // rss
    await BackupCodec.writeText(`${workDir}/rssSources.json`, JSON.stringify(harmony.rssSources || []));
    await BackupCodec.writeText(`${workDir}/rssStar.json`, JSON.stringify(harmony.rssStars || []));

    // search / txt
    const search = (harmony.searchHistory || []).map((row) => {
      return {
        word: String(row['word'] ?? row['keyword'] ?? ''),
        usage: Number(row['usage'] ?? 1),
        lastUseTime: Number(row['last_use_time'] ?? row['create_time'] ?? Date.now()),
      };
    });
    await BackupCodec.writeText(`${workDir}/searchHistory.json`, JSON.stringify(search));

    const toc = (harmony.txtTocRules || []).map((row) => {
      return {
        id: Number(row['id'] ?? 0),
        name: String(row['rule_name'] ?? row['name'] ?? ''),
        rule: String(row['rule_pattern'] ?? row['rule'] ?? ''),
        example: '',
        serialNumber: Number(row['sort_order'] ?? row['serial_number'] ?? 0),
        enable: Number(row['is_enabled'] ?? row['enable'] ?? 1) === 1,
      };
    });
    await BackupCodec.writeText(`${workDir}/txtTocRule.json`, JSON.stringify(toc));

    // 空壳兼容文件，避免安卓侧缺文件告警
    const emptyArrays = [
      'readRecord.json', 'readRecordDetail.json', 'readRecordSession.json',
      'sourceSub.json', 'httpTTS.json', 'keyboardAssists.json', 'dictRule.json', 'servers.json',
    ];
    for (const name of emptyArrays) {
      await BackupCodec.writeText(`${workDir}/${name}`, '[]');
    }

    // config.xml from settings
    const xml = BackupCodec.settingsToConfigXml(harmony.settings || {});
    await BackupCodec.writeText(`${workDir}/config.xml`, xml);
  }

  // ---------------- mapping helpers ----------------

  private static harmonyBookRowToAndroid(row: Record<string, Object>): Record<string, Object> {
    const originUrl = String(row['origin_url'] ?? row['originUrl'] ?? '');
    const originName = String(row['origin'] ?? '');
    const type = Number(row['type'] ?? 0);
    return {
      bookUrl: String(row['book_url'] ?? row['bookUrl'] ?? ''),
      tocUrl: String(row['toc_url'] ?? row['tocUrl'] ?? ''),
      origin: originUrl || originName || 'loc_book',
      originName: originName,
      name: String(row['name'] ?? ''),
      author: String(row['author'] ?? ''),
      kind: String(row['kind'] ?? ''),
      coverUrl: String(row['cover_url'] ?? row['coverUrl'] ?? ''),
      customCoverUrl: String(row['custom_cover_path'] ?? row['customCoverPath'] ?? ''),
      intro: String(row['introduce'] ?? row['intro'] ?? ''),
      remark: String(row['remark'] ?? ''),
      charset: String(row['charset'] ?? ''),
      type: type,
      group: Number(row['group_id'] ?? row['groupId'] ?? 0),
      latestChapterTitle: String(row['latest_chapter_title'] ?? ''),
      totalChapterNum: Number(row['total_chapter_num'] ?? row['chapter_count'] ?? 0),
      durChapterTitle: String(row['dur_chapter_title'] ?? ''),
      durChapterIndex: Number(row['dur_chapter_index'] ?? 0),
      durChapterPos: Number(row['dur_chapter_pos'] ?? 0),
      durChapterTime: Number(row['last_open_time'] ?? Date.now()),
      wordCount: String(row['word_count'] ?? ''),
      canUpdate: Number(row['can_update'] ?? 1) !== 0,
      order: Number(row['book_order'] ?? row['order'] ?? 0),
      variable: '',
    };
  }

  private static androidBookToHarmony(raw: Record<string, Object>): Book {
    const book = createDefaultBook();
    book.bookUrl = String(raw['bookUrl'] ?? '');
    book.tocUrl = String(raw['tocUrl'] ?? '');
    const origin = String(raw['origin'] ?? '');
    const originName = String(raw['originName'] ?? '');
    // 安卓 origin 常为书源 URL；originName 为显示名。
    // 部分源会带登录账号后缀：http://xxx.com##@账号 ，需要剥掉再匹配书源。
    const cleanOrigin = BackupCodec.stripSourceAccountSuffix_(origin);
    const cleanOriginName = BackupCodec.stripSourceAccountSuffix_(originName);
    book.originUrl = cleanOrigin.startsWith('http') || cleanOrigin.includes('://')
      ? cleanOrigin
      : (cleanOriginName.startsWith('http') ? cleanOriginName : cleanOrigin);
    book.origin = cleanOriginName || cleanOrigin;
    book.name = String(raw['name'] ?? '');
    book.author = String(raw['author'] ?? '');
    book.kind = String(raw['kind'] ?? '');
    book.coverUrl = String(raw['coverUrl'] ?? '');
    book.customCoverPath = String(raw['customCoverUrl'] ?? '');
    book.introduce = String(raw['intro'] ?? raw['customIntro'] ?? '');
    book.remark = String(raw['remark'] ?? '');
    book.charset = String(raw['charset'] ?? '');
    book.type = Number(raw['type'] ?? 0) as BookType;
    book.groupId = Number(raw['group'] ?? 0);
    if (book.groupId < 0) book.groupId = BookGroup.ALL;
    book.latestChapterTitle = String(raw['latestChapterTitle'] ?? '');
    book.totalChapterNum = Number(raw['totalChapterNum'] ?? 0);
    book.chapterCount = book.totalChapterNum;
    book.durChapterTitle = String(raw['durChapterTitle'] ?? '');
    book.durChapterIndex = Number(raw['durChapterIndex'] ?? 0);
    book.durChapterPos = Number(raw['durChapterPos'] ?? 0);
    book.lastOpenTime = Number(raw['durChapterTime'] ?? 0);
    book.wordCount = String(raw['wordCount'] ?? '');
    book.canUpdate = raw['canUpdate'] !== false;
    book.order = Number(raw['order'] ?? 0);
    book.isShelf = true;
    book.isAudio = book.type === BookType.AUDIO;
    book.isManga = book.type === BookType.MANGA;
    book.updateTime = Date.now();
    book.createTime = Date.now();
    return book;
  }

  /**
   * 恢复书籍：
   * - 在线书：按 bookUrl upsert（整本更新，进度取更靠后者）
   * - 本地书：若本机已有同一本，只同步阅读进度，不覆盖元数据/路径/分组等
   * - 本地书：若本机没有且文件存在，新增完整记录
   */
  private static async upsertBook(bookTable: BookTable, book: Book): Promise<number> {
    const now = Date.now();
    book.updateTime = now;
    book.isShelf = true;

    const existing = await BackupCodec.findExistingBook(bookTable, book);
    if (existing) {
      // 本地书：已存在时只恢复进度（用户要求，避免覆盖本地元数据）
      if (BackupCodec.isLocalBook(book) || BackupCodec.isLocalBook(existing)) {
        await BackupCodec.mergeProgressOnly(bookTable, existing, book, now);
        BackupCodec.indexRestoredBook_(existing);
        return 1;
      }

      // 在线书：整本更新，但保留更靠后的本地进度
      book.id = existing.id;
      book.createTime = existing.createTime || now;
      const merged = BackupCodec.pickNewerProgress(existing, book);
      book.durChapterIndex = merged.durChapterIndex;
      book.durChapterPos = merged.durChapterPos;
      book.durChapterTitle = merged.durChapterTitle;
      await bookTable.updateBook(book);
      BackupCodec.indexRestoredBook_(book);
      return 1;
    }

    if (!book.createTime) book.createTime = now;
    book.id = 0;
    // 鸿蒙本地书规范：bookUrl 统一为 local://绝对路径
    if (BackupCodec.isLocalBook(book)) {
      const path = BackupCodec.resolveLocalBookPath(book);
      if (path) {
        if (!book.bookUrl || !book.bookUrl.startsWith('local://')) {
          book.bookUrl = `local://${path}`;
        }
        if (!book.originUrl) book.originUrl = path;
        if (!book.origin) book.origin = '本地';
        book.canUpdate = false;
      }
    }
    const newId = await bookTable.insertBook(book);
    book.id = newId > 0 ? newId : book.id;
    BackupCodec.indexRestoredBook_(book);
    return 1;
  }

  /**
   * 判断云端/备份记录与本地是否同一本书。
   *
   * 优先级：
   * 1) bookUrl 精确/归一化匹配（安卓主键语义）
   * 2) 本地书：规范化文件路径匹配（兼容 local://、file://、裸路径）
   * 3) 网络书弱匹配：书名+作者（双方都不是本地书）
   * 4) 本地书弱匹配：书名+作者，且本地已有记录也是本地书
   *
   * 说明：
   * - 安卓恢复只看 bookUrl，所以同名同作者但详情页 URL 不同会变成两本。
   * - 鸿蒙对网络书额外用“书名+作者”兜底，避免换源/URL 微调导致重复书架。
   * - 若用户刻意保留同名不同源两本，恢复时仍可能被合并；这是有意取舍。
   */
  private static async findExistingBook(bookTable: BookTable, book: Book): Promise<Book | null> {
    const urlCandidates = BackupCodec.bookUrlCandidates(book);
    for (const url of urlCandidates) {
      try {
        const hit = await bookTable.getBookByUrl(url);
        if (hit) return hit;
      } catch (_e) { /* continue */ }
    }

    // 使用恢复索引做 URL 归一化 / 书名作者匹配（O(1)），避免每本书全表扫描
    const fromIndex = BackupCodec.findFromRestoreIndex_(book);
    if (fromIndex) return fromIndex;

    const name = (book.name || '').trim();
    const author = (book.author || '').trim();
    if (!name) return null;

    // 网络书：书名+作者兜底（索引未命中时再查库）
    if (!BackupCodec.isLocalBook(book)) {
      try {
        const byName = await bookTable.getBookByName(name, author);
        if (byName && !BackupCodec.isLocalBook(byName)) {
          BackupCodec.indexRestoredBook_(byName);
          return byName;
        }
      } catch (_e) { /* ignore */ }
      return null;
    }

    // 本地书：路径后再书名+作者
    const path = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(book));
    if (path) {
      const pathUrls = [
        `local://${path}`,
        path,
        `file://${path}`,
      ];
      for (const url of pathUrls) {
        try {
          const hit = await bookTable.getBookByUrl(url);
          if (hit) return hit;
        } catch (_e) { /* continue */ }
      }
    }

    try {
      const byName = await bookTable.getBookByName(name, author);
      if (byName && BackupCodec.isLocalBook(byName)) {
        const p1 = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(book));
        const p2 = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(byName));
        if (!p1 || !p2 || p1 === p2) {
          return byName;
        }
      }
    } catch (_e) { /* ignore */ }
    return null;
  }

  private static bookUrlCandidates(book: Book): string[] {
    const out: string[] = [];
    const add = (v: string) => {
      const s = (v || '').trim();
      if (!s) return;
      if (out.indexOf(s) < 0) out.push(s);
      const norm = BackupCodec.normalizeBookUrl(s);
      if (norm && out.indexOf(norm) < 0) out.push(norm);
    };
    add(book.bookUrl || '');
    // 兼容安卓路径型 bookUrl 与鸿蒙 local:// 形态互转
    const path = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(book));
    if (path) {
      add(`local://${path}`);
      add(path);
      add(`file://${path}`);
    }
    return out;
  }

  /** 生成用于判重的身份键集合 */
  private static identityKeys(book: Book): string[] {
    const keys: string[] = [];
    const add = (k: string) => {
      const s = (k || '').trim();
      if (!s) return;
      if (keys.indexOf(s) < 0) keys.push(s);
    };
    add(BackupCodec.normalizeBookUrl(book.bookUrl || ''));
    if (BackupCodec.isLocalBook(book)) {
      const path = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(book));
      if (path) {
        add(`path:${path}`);
        add(BackupCodec.normalizeBookUrl(`local://${path}`));
      }
    } else {
      // 网络书：name+author 作为弱身份
      const name = (book.name || '').trim().toLowerCase();
      const author = (book.author || '').trim().toLowerCase();
      if (name) add(`na:${name}::${author}`);
      const originUrl = BackupCodec.normalizeBookUrl(book.originUrl || '');
      if (originUrl) add(`origin:${originUrl}`);
    }
    return keys;
  }

  private static identityKeysOverlap(a: string[], b: string[]): boolean {
    if (a.length === 0 || b.length === 0) return false;
    for (const x of a) {
      if (b.indexOf(x) >= 0) return true;
    }
    return false;
  }

  /** 归一化网络/本地 bookUrl，便于比较 */
  private static normalizeBookUrl(url: string): string {
    let u = (url || '').trim();
    if (!u) return '';
    // 去空白与常见追踪参数噪音前，先处理协议大小写
    // 本地路径类
    if (u.startsWith('local://') || u.startsWith('file://') || u.startsWith('/')) {
      return BackupCodec.normalizeLocalPath(u);
    }
    try {
      // 手工归一化，避免依赖 URL 解析 API 差异
      u = u.split('\\').join('/');
      // scheme 小写
      const m = u.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/(.*)$/);
      if (m) {
        const scheme = m[1].toLowerCase();
        let rest = m[2];
        // host 小写
        const slash = rest.indexOf('/');
        let host = slash >= 0 ? rest.substring(0, slash) : rest;
        let path = slash >= 0 ? rest.substring(slash) : '';
        host = host.toLowerCase();
        // 去默认端口
        if (host.endsWith(':80') && scheme === 'http') host = host.substring(0, host.length - 3);
        if (host.endsWith(':443') && scheme === 'https') host = host.substring(0, host.length - 4);
        // 去尾 /
        while (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
        // 去掉常见无意义 query
        const q = path.indexOf('?');
        if (q >= 0) {
          // 保留 query（不同 query 可能是不同书），只去掉 hash
          const h = path.indexOf('#');
          if (h >= 0) path = path.substring(0, h);
        } else {
          const h = path.indexOf('#');
          if (h >= 0) path = path.substring(0, h);
        }
        u = `${scheme}://${host}${path}`;
      } else {
        while (u.length > 1 && u.endsWith('/')) u = u.substring(0, u.length - 1);
      }
    } catch (_e) {
      // keep raw
    }
    return u;
  }

  private static normalizeLocalPath(path: string): string {
    let p = (path || '').trim();
    if (!p) return '';
    if (p.startsWith('local://')) p = p.substring('local://'.length);
    if (p.startsWith('file://')) p = p.substring('file://'.length);
    // 去掉多余重复斜杠（保留开头 /）
    p = p.split('\\').join('/');
    while (p.indexOf('//') >= 0) {
      p = p.split('//').join('/');
    }
    // 去掉末尾 /
    if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
    return p;
  }

  private static pickNewerProgress(local: Book, incoming: Book): {
    durChapterIndex: number;
    durChapterPos: number;
    durChapterTitle: string;
  } {
    if (local.durChapterIndex > incoming.durChapterIndex ||
      (local.durChapterIndex === incoming.durChapterIndex && local.durChapterPos > incoming.durChapterPos)) {
      return {
        durChapterIndex: local.durChapterIndex,
        durChapterPos: local.durChapterPos,
        durChapterTitle: local.durChapterTitle || '',
      };
    }
    return {
      durChapterIndex: incoming.durChapterIndex,
      durChapterPos: incoming.durChapterPos,
      durChapterTitle: incoming.durChapterTitle || local.durChapterTitle || '',
    };
  }

  /** 本地书已存在：只写进度相关字段 */
  private static async mergeProgressOnly(
    bookTable: BookTable,
    existing: Book,
    incoming: Book,
    now: number
  ): Promise<void> {
    const merged = BackupCodec.pickNewerProgress(existing, incoming);
    // 进度没有变化则不写库
    if (merged.durChapterIndex === existing.durChapterIndex &&
      merged.durChapterPos === existing.durChapterPos &&
      (merged.durChapterTitle || '') === (existing.durChapterTitle || '')) {
      return;
    }
    const url = existing.bookUrl || incoming.bookUrl;
    if (!url) return;
    await bookTable.updateReadingProgress(
      url,
      merged.durChapterIndex,
      merged.durChapterTitle || existing.durChapterTitle || '',
      existing.totalChapterNum || existing.chapterCount || 0,
      merged.durChapterPos
    );
    // updateReadingProgress 已更新 last_open_time/update_time；这里无需整本 update
    void now;
  }

  /** 去掉安卓源 URL 上的 ##@账号 / ##注释 后缀 */
  private static stripSourceAccountSuffix_(value: string): string {
    const s = (value || '').trim();
    if (!s) return '';
    const idx = s.indexOf('##');
    if (idx >= 0) return s.substring(0, idx).trim();
    return s;
  }

  private static isLocalBook(book: Book): boolean {
    const origin = (book.origin || '').toLowerCase();
    const url = (book.bookUrl || '').toLowerCase();
    const originUrl = (book.originUrl || '').toLowerCase();
    return origin === '本地' || origin === 'loc_book' || origin.includes('local') ||
      url.startsWith('local://') || url.startsWith('file://') || url.startsWith('/') ||
      originUrl.startsWith('/') || originUrl.startsWith('file://') || originUrl.startsWith('local://');
  }

  /**
   * 解析本地书实际文件路径。
   * 鸿蒙本地书：bookUrl=local:///path，originUrl=原始路径
   * 安卓本地书：bookUrl 常为完整文件路径，origin=loc_book
   */
  private static resolveLocalBookPath(book: Book): string {
    const candidates: string[] = [];
    const push = (v: string) => {
      const s = (v || '').trim();
      if (!s) return;
      if (s.startsWith('local://')) candidates.push(s.substring('local://'.length));
      else if (s.startsWith('file://')) candidates.push(s.substring('file://'.length));
      else candidates.push(s);
    };
    push(book.bookUrl || '');
    push(book.originUrl || '');
    push(book.tocUrl || '');
    for (const c of candidates) {
      // 只要像绝对路径就用
      if (c.startsWith('/') || c.indexOf(':/') >= 0) {
        return c;
      }
    }
    return candidates.length > 0 ? candidates[0] : '';
  }

  /** 本地书文件是否真实存在；无法判定路径时视为不存在（宁可不恢复） */
  private static localBookFileExists(book: Book): boolean {
    const path = BackupCodec.resolveLocalBookPath(book);
    if (!path) return false;
    try {
      const st = fileFs.statSync(path);
      return !!st && !st.isDirectory();
    } catch (_e) {
      return false;
    }
  }

  /**
   * 恢复本地书策略：
   * - 用户勾选忽略本地书：全部跳过
   * - 否则：仅当本地文件仍存在时才恢复（避免恢复出打不开的“幽灵书”）
   * 这与安卓默认不同：安卓默认会恢复记录，文件缺失也可进书架。
   */
  private static shouldSkipLocalBook(book: Book, ignoreLocalBook: boolean): boolean {
    if (!BackupCodec.isLocalBook(book)) return false;
    if (ignoreLocalBook) return true;
    return !BackupCodec.localBookFileExists(book);
  }

  private static rowToBook(row: Record<string, Object>): Book {
    // 兼容 snake_case 行 与 camel 模型
    if (row['book_url'] !== undefined || row['cover_url'] !== undefined) {
      const book = createDefaultBook();
      book.id = Number(row['id'] ?? 0);
      book.name = String(row['name'] ?? '');
      book.author = String(row['author'] ?? '');
      book.coverUrl = String(row['cover_url'] ?? '');
      book.customCoverPath = String(row['custom_cover_path'] ?? '');
      book.bookUrl = String(row['book_url'] ?? '');
      book.origin = String(row['origin'] ?? '');
      book.originUrl = String(row['origin_url'] ?? '');
      book.type = Number(row['type'] ?? 0) as BookType;
      book.groupId = Number(row['group_id'] ?? 0);
      book.tocUrl = String(row['toc_url'] ?? '');
      book.chapterCount = Number(row['chapter_count'] ?? 0);
      book.totalChapterNum = Number(row['total_chapter_num'] ?? 0);
      book.latestChapterTitle = String(row['latest_chapter_title'] ?? '');
      book.durChapterTitle = String(row['dur_chapter_title'] ?? '');
      book.durChapterIndex = Number(row['dur_chapter_index'] ?? 0);
      book.durChapterPos = Number(row['dur_chapter_pos'] ?? 0);
      book.durChapterProgress = Number(row['dur_chapter_progress'] ?? 0);
      book.isRead = Number(row['is_read'] ?? 0) === 1;
      book.isAudio = Number(row['is_audio'] ?? 0) === 1;
      book.isManga = Number(row['is_manga'] ?? 0) === 1;
      book.isShelf = Number(row['is_shelf'] ?? 1) === 1;
      book.order = Number(row['book_order'] ?? 0);
      book.canUpdate = Number(row['can_update'] ?? 1) !== 0;
      book.kind = String(row['kind'] ?? '');
      book.wordCount = String(row['word_count'] ?? '');
      book.introduce = String(row['introduce'] ?? '');
      book.remark = String(row['remark'] ?? '');
      book.lastUpdateTime = String(row['last_update_time'] ?? '');
      book.lastOpenTime = Number(row['last_open_time'] ?? 0);
      book.createTime = Number(row['create_time'] ?? 0);
      book.updateTime = Number(row['update_time'] ?? 0);
      book.syncTime = Number(row['sync_time'] ?? 0);
      book.charset = String(row['charset'] ?? '');
      return book;
    }
    // already model-like
    return Object.assign(createDefaultBook(), row as Partial<Book>);
  }

  private static rowToGroup(row: Record<string, Object>): BookGroupItem {
    return {
      id: Number(row['id'] ?? 0),
      name: String(row['name'] ?? ''),
      order: Number(row['order'] ?? row['"order"'] ?? 0),
      cover: String(row['cover'] ?? ''),
      isSystem: false,
      enableRefresh: Number(row['enable_refresh'] ?? 1) === 1,
      show: Number(row['is_show'] ?? 1) === 1,
      isPrivate: Number(row['is_private'] ?? 0) === 1,
      bookSort: Number(row['book_sort'] ?? -1),
    };
  }

  private static rowToBookmark(row: Record<string, Object>): Bookmark {
    return {
      id: 0,
      bookId: Number(row['book_id'] ?? row['bookId'] ?? 0),
      bookName: String(row['book_name'] ?? row['bookName'] ?? ''),
      bookAuthor: String(row['book_author'] ?? row['bookAuthor'] ?? ''),
      chapterIndex: Number(row['chapter_index'] ?? row['chapterIndex'] ?? 0),
      chapterName: String(row['chapter_name'] ?? row['chapterName'] ?? ''),
      chapterPos: Number(row['chapter_pos'] ?? row['chapterPos'] ?? 0),
      text: String(row['text'] ?? ''),
      note: String(row['note'] ?? ''),
      createTime: Number(row['create_time'] ?? row['createTime'] ?? Date.now()),
      updateTime: Number(row['update_time'] ?? row['updateTime'] ?? Date.now()),
    };
  }

  private static rowToReplaceRule(row: Record<string, Object>): ReplaceRule {
    const rule = createDefaultReplaceRule();
    rule.id = Number(row['id'] ?? 0);
    rule.name = String(row['rule_name'] ?? row['name'] ?? '');
    rule.group = String(row['rule_group'] ?? row['group'] ?? '');
    rule.pattern = String(row['pattern'] ?? '');
    rule.replacement = String(row['replacement'] ?? '');
    rule.scope = String(row['scope'] ?? '');
    rule.scopeTitle = Number(row['scope_title'] ?? 0) === 1 || !!row['scopeTitle'];
    rule.scopeContent = (row['scope_content'] === undefined && row['scopeContent'] === undefined)
      ? true
      : (Number(row['scope_content'] ?? 1) === 1 || !!row['scopeContent']);
    rule.excludeScope = String(row['exclude_scope'] ?? row['excludeScope'] ?? '');
    rule.isEnabled = Number(row['is_enabled'] ?? 1) === 1 && row['isEnabled'] !== false;
    rule.isRegex = Number(row['is_regex'] ?? 1) === 1 && row['isRegex'] !== false;
    rule.timeoutMillisecond = Number(row['timeout_millisecond'] ?? row['timeoutMillisecond'] ?? 3000);
    rule.order = Number(row['sort_order'] ?? row['order'] ?? 0);
    return rule;
  }

  private static normalizeSourceRow(row: Record<string, Object>): Record<string, Object> {
    // DB snake_case -> parseBookSource 可识别
    if (row['source_url'] !== undefined || row['source_name'] !== undefined) {
      return {
        bookSourceName: row['source_name'],
        bookSourceUrl: row['source_url'],
        bookSourceType: row['source_type'],
        bookSourceGroup: row['source_group'],
        enabled: Number(row['enabled'] ?? 1) === 1,
        weight: row['weight'],
        customOrder: row['custom_order'],
        rawJson: row['raw_json'],
        coverDecodeJs: row['cover_decode_js'],
        lastUpdateTime: row['update_time'],
        // 若有 raw_json，importSources 会优先用完整 JSON
      };
    }
    return row;
  }

  private static async upsertRssSource(
    _rssTable: RSSSourceTable,
    rdb: relationalStore.RdbStore,
    row: Record<string, Object>
  ): Promise<void> {
    // 尽量走表 API；若结构是 snake_case 直接 insert/replace
    const sourceUrl = String(row['sourceUrl'] ?? row['source_url'] ?? '');
    if (!sourceUrl) throw new Error('rss sourceUrl empty');
    const bucket: relationalStore.ValuesBucket = {};
    // 复制已知列
    const map: Record<string, string> = {
      sourceUrl: 'source_url', source_url: 'source_url',
      sourceName: 'source_name', source_name: 'source_name',
      sourceIcon: 'source_icon', source_icon: 'source_icon',
      sourceGroup: 'source_group', source_group: 'source_group',
      sourceComment: 'source_comment', source_comment: 'source_comment',
      enabled: 'enabled',
      variableComment: 'variable_comment', variable_comment: 'variable_comment',
      jsLib: 'js_lib', js_lib: 'js_lib',
      enabledCookieJar: 'enabled_cookie_jar', enabled_cookie_jar: 'enabled_cookie_jar',
      concurrentRate: 'concurrent_rate', concurrent_rate: 'concurrent_rate',
      header: 'header',
      loginUrl: 'login_url', login_url: 'login_url',
      loginUi: 'login_ui', login_ui: 'login_ui',
      loginCheckJs: 'login_check_js', login_check_js: 'login_check_js',
      coverDecodeJs: 'cover_decode_js', cover_decode_js: 'cover_decode_js',
      sortUrl: 'sort_url', sort_url: 'sort_url',
      singleUrl: 'single_url', single_url: 'single_url',
      articleStyle: 'article_style', article_style: 'article_style',
      ruleArticles: 'rule_articles', rule_articles: 'rule_articles',
      ruleNextPage: 'rule_next_page', rule_next_page: 'rule_next_page',
      ruleTitle: 'rule_title', rule_title: 'rule_title',
      rulePubDate: 'rule_pub_date', rule_pub_date: 'rule_pub_date',
      ruleDescription: 'rule_description', rule_description: 'rule_description',
      ruleImage: 'rule_image', rule_image: 'rule_image',
      ruleLink: 'rule_link', rule_link: 'rule_link',
      ruleContent: 'rule_content', rule_content: 'rule_content',
      customOrder: 'custom_order', custom_order: 'custom_order',
      lastUpdateTime: 'last_update_time', last_update_time: 'last_update_time',
    };
    for (const [k, col] of Object.entries(map)) {
      if (row[k] === undefined || row[k] === null) continue;
      const v = row[k];
      if (typeof v === 'boolean') bucket[col] = v ? 1 : 0;
      else bucket[col] = v as relationalStore.ValueType;
    }
    bucket['source_url'] = sourceUrl;
    // delete + insert 模拟 upsert
    try {
      const p = new relationalStore.RdbPredicates('rss_sources');
      p.equalTo('source_url', sourceUrl);
      await RdbUtil.delete(rdb, p);
    } catch (_e) { /* ok */ }
    await RdbUtil.insert(rdb, 'rss_sources', bucket);
  }

  private static async importSettings(map: Record<string, Object>, ignore: RestoreIgnoreConfig): Promise<number> {
    const filtered: Record<string, Object> = {};
    let count = 0;
    for (const [key, value] of Object.entries(map)) {
      if (DEVICE_LOCAL_KEYS.has(key)) continue;
      if (isSensitiveSettingsKey(key)) continue;
      if (ignore.readConfig && BackupCodec.isReadConfigKey(key)) continue;
      if (ignore.themeMode && (key === 'themeMode' || key === 'isDark' || key === 'theme_mode')) continue;
      if (ignore.themeConfig && BackupCodec.isThemeConfigKey(key)) continue;
      if (ignore.coverConfig && key.toLowerCase().includes('cover')) continue;
      if (ignore.bookshelfLayout && key.toLowerCase().includes('bookshelf')) continue;
      if (ignore.showRss && key.toLowerCase().includes('showrss')) continue;
      if (ignore.threadCount && key.toLowerCase().includes('thread')) continue;
      // 安卓 webdav 键映射到鸿蒙
      if (key === 'web_dav_url' || key === 'webDavUrl') {
        AppStorage.setOrCreate<string>('webdav_url', String(value ?? ''));
        filtered['webdav_url'] = value;
        count++;
        continue;
      }
      if (key === 'web_dav_account' || key === 'webDavAccount') {
        AppStorage.setOrCreate<string>('webdav_user', String(value ?? ''));
        filtered['webdav_user'] = value;
        count++;
        continue;
      }
      if (key === 'webDavDir' || key === 'web_dav_dir') {
        AppStorage.setOrCreate<string>('webdav_path', String(value ?? 'legado'));
        filtered['webdav_path'] = value;
        count++;
        continue;
      }
      if (key === 'webDavDeviceName') {
        BackupConfig.setDeviceName(String(value ?? ''));
        count++;
        continue;
      }
      if (key === 'syncBookProgress') {
        AppStorage.setOrCreate<boolean>('webdav_sync_progress', value !== false && value !== 'false' && value !== 0);
        count++;
        continue;
      }
      if (key === 'onlyLatestBackup') {
        BackupConfig.setOnlyLatestBackup(value !== false && value !== 'false' && value !== 0);
        count++;
        continue;
      }
      filtered[key] = value;
      count++;
    }
    if (Object.keys(filtered).length > 0) {
      await SettingsStore.getInstance().importAll(filtered as Record<string, Object>);
    }
    return count;
  }

  private static isReadConfigKey(key: string): boolean {
    const k = key.toLowerCase();
    return k.includes('readstyle') || k.includes('read_config') || k.includes('font') ||
      k.includes('pagespeed') || k.includes('clickaction') || k.includes('sharelayout') ||
      k.includes('hidestatus') || k.includes('hidenavigation');
  }

  private static isThemeConfigKey(key: string): boolean {
    const k = key.toLowerCase();
    return k.includes('theme') || k.includes('color') || k.includes('bgimage') || k.includes('palette');
  }

  private static settingsToConfigXml(settings: Record<string, Object>): string {
    const lines: string[] = [];
    lines.push(`<?xml version='1.0' encoding='utf-8' standalone='yes' ?>`);
    lines.push('<map>');
    for (const [key, value] of Object.entries(settings)) {
      if (value === null || value === undefined) continue;
      // 安卓 config.xml 也不写入凭证
      if (isSensitiveSettingsKey(key)) continue;
      if (typeof value === 'boolean') {
        lines.push(`    <boolean name="${BackupCodec.escapeXml(key)}" value="${value}" />`);
      } else if (typeof value === 'number') {
        if (Number.isInteger(value)) {
          if (Math.abs(value) > 0x7fffffff) {
            lines.push(`    <long name="${BackupCodec.escapeXml(key)}" value="${value}" />`);
          } else {
            lines.push(`    <int name="${BackupCodec.escapeXml(key)}" value="${value}" />`);
          }
        } else {
          lines.push(`    <float name="${BackupCodec.escapeXml(key)}" value="${value}" />`);
        }
      } else if (typeof value === 'string') {
        lines.push(`    <string name="${BackupCodec.escapeXml(key)}">${BackupCodec.escapeXml(value)}</string>`);
      } else {
        // 对象/数组序列化为 string，安卓侧可能忽略
        lines.push(`    <string name="${BackupCodec.escapeXml(key)}">${BackupCodec.escapeXml(JSON.stringify(value))}</string>`);
      }
    }
    lines.push('</map>');
    return lines.join('\n');
  }

  private static parseConfigXml(xml: string): Record<string, Object> {
    const map: Record<string, Object> = {};
    // string
    const strRe = /<string\s+name="([^"]+)">([\s\S]*?)<\/string>/g;
    let m: RegExpExecArray | null;
    while ((m = strRe.exec(xml)) !== null) {
      map[m[1]] = BackupCodec.unescapeXml(m[2]);
    }
    const boolRe = /<boolean\s+name="([^"]+)"\s+value="(true|false)"\s*\/>/g;
    while ((m = boolRe.exec(xml)) !== null) {
      map[m[1]] = m[2] === 'true';
    }
    const intRe = /<int\s+name="([^"]+)"\s+value="([^"]+)"\s*\/>/g;
    while ((m = intRe.exec(xml)) !== null) {
      map[m[1]] = parseInt(m[2], 10);
    }
    const longRe = /<long\s+name="([^"]+)"\s+value="([^"]+)"\s*\/>/g;
    while ((m = longRe.exec(xml)) !== null) {
      map[m[1]] = parseInt(m[2], 10);
    }
    const floatRe = /<float\s+name="([^"]+)"\s+value="([^"]+)"\s*\/>/g;
    while ((m = floatRe.exec(xml)) !== null) {
      map[m[1]] = parseFloat(m[2]);
    }
    return map;
  }

  // ---------------- fs / util ----------------

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
    } finally {
      RdbUtil.close(rs);
    }
    return result;
  }

  private static async insertRowIgnore(
    rdb: relationalStore.RdbStore,
    table: string,
    row: Record<string, Object>
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {};
    for (const [k, v] of Object.entries(row)) {
      if (v === undefined || v === null) continue;
      // 跳过自增 id=0
      if (k === 'id' && (v === 0 || v === '0')) continue;
      bucket[k] = v as relationalStore.ValueType;
    }
    try {
      await RdbUtil.insert(rdb, table, bucket);
    } catch (_e) {
      // ignore conflicts
    }
  }

  private static parseJsonArray(text: string): Record<string, Object>[] {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed as Record<string, Object>[];
    if (parsed && typeof parsed === 'object') return [parsed as Record<string, Object>];
    return [];
  }

  static createTempDir(prefix: string): string {
    const tempDir = `${TEMP_ROOT}/${prefix}_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    fileFs.mkdirSync(tempDir, true);
    return tempDir;
  }

  static findFileByName(dir: string, fileName: string): string | null {
    let files: string[];
    try {
      files = fileFs.listFileSync(dir);
    } catch {
      return null;
    }
    for (const item of files) {
      const path = `${dir}/${item}`;
      try {
        const stat = fileFs.statSync(path);
        if (stat.isDirectory()) {
          const child = BackupCodec.findFileByName(path, fileName);
          if (child) return child;
        } else if (item === fileName) {
          return path;
        }
      } catch { /* skip */ }
    }
    return null;
  }

  static removeTree(path: string): void {
    try {
      const stat = fileFs.statSync(path);
      if (stat.isDirectory()) {
        const files = fileFs.listFileSync(path);
        for (const item of files) {
          BackupCodec.removeTree(`${path}/${item}`);
        }
        fileFs.rmdirSync(path);
      } else {
        fileFs.unlinkSync(path);
      }
    } catch { /* ignore */ }
  }

  private static async writeText(path: string, text: string): Promise<void> {
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(text);
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(path, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY | fileFs.OpenMode.TRUNC);
      fileFs.writeSync(file.fd, data.buffer as ArrayBuffer);
    } finally {
      if (file) {
        try { fileFs.closeSync(file); } catch { /* ignore */ }
      }
    }
  }

  private static async readText(path: string): Promise<string> {
    let file: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      if (stat.size > BackupCodec.MAX_TEXT_FILE_BYTES) {
        throw new Error(`备份文件过大: ${path} (${stat.size} bytes)`);
      }
      const buf = new ArrayBuffer(stat.size);
      file = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(file.fd, buf);
      return BackupCodec.bytesToUtf8(new Uint8Array(buf));
    } finally {
      if (file) {
        try { fileFs.closeSync(file); } catch { /* ignore */ }
      }
    }
  }

  private static escapeXml(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  private static unescapeXml(s: string): string {
    return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
  }

  /**
   * 高效 UTF-8 解码。
   * 旧实现逐字符 + 字符串拼接，大书源 JSON（数 MB）会直接 OOM。
   */
  private static bytesToUtf8(bytes: Uint8Array): string {
    // 优先系统 TextDecoder（原生实现，避免 JS 逐字节拼字符串 OOM）
    try {
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (_e1) {
      try {
        const decoder2 = util.TextDecoder.create('utf-8');
        return decoder2.decodeToString(bytes);
      } catch (_e2) {
        // fall through
      }
    }

    // 分块解码兜底，避免一次超大字符串拼接
    const chunks: string[] = [];
    const chunkSize = 256 * 1024;
    let i = 0;
    while (i < bytes.length) {
      const end = Math.min(i + chunkSize, bytes.length);
      // 避免把多字节字符切断：回退到码点起始
      let realEnd = end;
      if (end < bytes.length) {
        while (realEnd > i && (bytes[realEnd] & 0xc0) === 0x80) {
          realEnd--;
        }
        if (realEnd === i) realEnd = end;
      }
      chunks.push(BackupCodec.bytesToUtf8Chunk_(bytes.subarray(i, realEnd)));
      i = realEnd;
    }
    return chunks.join('');
  }

  private static bytesToUtf8Chunk_(bytes: Uint8Array): string {
    const out: string[] = [];
    let i = 0;
    while (i < bytes.length) {
      const c = bytes[i++];
      if (c < 0x80) {
        out.push(String.fromCharCode(c));
      } else if ((c & 0xe0) === 0xc0 && i < bytes.length) {
        const c2 = bytes[i++];
        out.push(String.fromCharCode(((c & 0x1f) << 6) | (c2 & 0x3f)));
      } else if ((c & 0xf0) === 0xe0 && i + 1 < bytes.length) {
        const c2 = bytes[i++];
        const c3 = bytes[i++];
        out.push(String.fromCharCode(((c & 0x0f) << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f)));
      } else if (i + 2 < bytes.length) {
        const c2 = bytes[i++];
        const c3 = bytes[i++];
        const c4 = bytes[i++];
        let cp = ((c & 0x07) << 18) | ((c2 & 0x3f) << 12) | ((c3 & 0x3f) << 6) | (c4 & 0x3f);
        cp -= 0x10000;
        out.push(String.fromCharCode(0xd800 + ((cp >> 10) & 0x3ff), 0xdc00 + (cp & 0x3ff)));
      }
    }
    return out.join('');
  }

  // ---- restore index helpers ----

  private static async beginRestoreIndex_(rdb: relationalStore.RdbStore): Promise<void> {
    BackupCodec.restoreBookIndex_ = [];
    BackupCodec.restoreUrlMap_ = new Map<string, Book>();
    BackupCodec.restoreNameMap_ = new Map<string, Book>();
    try {
      const bookTable = new BookTable(rdb);
      const all = await bookTable.getAllShelfBooks();
      for (const b of all) {
        BackupCodec.indexRestoredBook_(b);
      }
      console.info('[BackupCodec] restore index ready, books=', all.length);
    } catch (e) {
      console.warn('[BackupCodec] build restore index failed:', (e as Error).message);
    }
  }

  private static endRestoreIndex_(): void {
    BackupCodec.restoreBookIndex_ = null;
    BackupCodec.restoreUrlMap_ = null;
    BackupCodec.restoreNameMap_ = null;
  }

  private static indexRestoredBook_(book: Book): void {
    if (!BackupCodec.restoreUrlMap_ || !BackupCodec.restoreNameMap_) return;
    if (!BackupCodec.restoreBookIndex_) BackupCodec.restoreBookIndex_ = [];
    BackupCodec.restoreBookIndex_.push(book);
    for (const url of BackupCodec.bookUrlCandidates(book)) {
      const n = BackupCodec.normalizeBookUrl(url);
      if (n) BackupCodec.restoreUrlMap_.set(n, book);
      if (url) BackupCodec.restoreUrlMap_.set(url, book);
    }
    const name = (book.name || '').trim().toLowerCase();
    const author = (book.author || '').trim().toLowerCase();
    if (name) {
      BackupCodec.restoreNameMap_.set(`${name}::${author}`, book);
    }
  }

  private static findFromRestoreIndex_(book: Book): Book | null {
    if (!BackupCodec.restoreUrlMap_ || !BackupCodec.restoreNameMap_) return null;
    for (const url of BackupCodec.bookUrlCandidates(book)) {
      const hit = BackupCodec.restoreUrlMap_.get(url) ||
        BackupCodec.restoreUrlMap_.get(BackupCodec.normalizeBookUrl(url));
      if (hit) return hit;
    }
    const name = (book.name || '').trim().toLowerCase();
    const author = (book.author || '').trim().toLowerCase();
    if (!name) return null;
    // 网络书：允许按书名作者命中
    if (!BackupCodec.isLocalBook(book)) {
      const hit = BackupCodec.restoreNameMap_.get(`${name}::${author}`);
      if (hit && !BackupCodec.isLocalBook(hit)) return hit;
      return null;
    }
    // 本地书：书名作者命中且本地也是本地书
    const hit = BackupCodec.restoreNameMap_.get(`${name}::${author}`);
    if (hit && BackupCodec.isLocalBook(hit)) {
      const p1 = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(book));
      const p2 = BackupCodec.normalizeLocalPath(BackupCodec.resolveLocalBookPath(hit));
      if (!p1 || !p2 || p1 === p2) return hit;
    }
    return null;
  }

  private static async upsertSearchKeyword_(
    rdb: relationalStore.RdbStore,
    word: string,
    usage: number,
    lastUseTime: number
  ): Promise<void> {
    try {
      const p = new relationalStore.RdbPredicates('search_keywords');
      p.equalTo('word', word);
      const rs = await RdbUtil.query(rdb, p, []);
      const exists = RdbUtil.next(rs);
      RdbUtil.close(rs);
      if (exists) {
        const up = new relationalStore.RdbPredicates('search_keywords');
        up.equalTo('word', word);
        await RdbUtil.update(rdb, {
          'usage': usage,
          'last_use_time': lastUseTime,
        }, up);
      } else {
        await RdbUtil.insert(rdb, 'search_keywords', {
          'word': word,
          'usage': usage,
          'last_use_time': lastUseTime,
        } as relationalStore.ValuesBucket);
      }
    } catch (_e) {
      // 搜索历史失败不阻断恢复
    }
  }
}
