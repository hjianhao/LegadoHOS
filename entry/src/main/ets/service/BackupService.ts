/**
 * 完整备份/恢复服务
 *
 * - 鸿蒙设备互备：backup.json 全量
 * - 安卓兼容：多文件 ZIP（bookshelf.json / bookSource.json / ...）
 * - 自动备份 / 启动检测云端新备份
 */
import { common } from '@kit.AbilityKit';
import picker from '@ohos.file.picker';
import fileFs from '@ohos.file.fs';
import { WebDavService } from './WebDavService';
import { BackupCodec, BackupData, ImportResult } from './backup/BackupCodec';
import { BackupConfig, BackupSyncMode, RestoreIgnoreConfig } from './backup/BackupConfig';
import { BackupRestoreLock } from './backup/BackupRestoreLock';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { AppContextHolder } from '../util/AppContext';

export type { BackupData, ImportResult, RestoreIgnoreConfig };

export class BackupService {
  /**
   * 导出完整备份（内存对象，鸿蒙 native）
   */
  static async exportBackup(): Promise<BackupData> {
    return BackupCodec.exportHarmonyData();
  }

  /**
   * 导入备份数据（鸿蒙 native JSON）
   */
  static async importBackup(data: BackupData, ignore?: RestoreIgnoreConfig): Promise<ImportResult> {
    return BackupRestoreLock.withLock(async () => {
      const result = await BackupCodec.importHarmonyData(data, ignore);
      BackupConfig.setLastBackup(Date.now());
      return result;
    });
  }

  /** 本地备份（文件选择器） */
  static async backupToLocal(context: Context): Promise<string> {
    return BackupRestoreLock.withLock(async () => {
      const policy = BackupConfig.getPolicy();
      const zipName = policy.onlyLatestBackup ? 'backup.zip' : BackupConfig.getNowZipFileName();
      const pack = await BackupCodec.createCompatibleZip(BackupConfig.getNowZipFileName());
      try {
        const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [zipName] });
        if (!uris || uris.length === 0) {
          throw new Error('已取消保存');
        }
        await BackupService.copyFile(pack.zipPath, uris[0]);
        BackupConfig.setLastBackup(Date.now());
        return zipName;
      } finally {
        BackupCodec.removeTree(pack.tempDir);
      }
    });
  }

  /** 本地恢复 */
  static async restoreFromLocal(context: common.Context, ignore?: RestoreIgnoreConfig): Promise<ImportResult | null> {
    return BackupRestoreLock.withLock(async () => {
      await BackupService.prepareStores_(context);
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.zip'];
      const uris = await new picker.DocumentViewPicker(context).select(documentSelectOptions);
      if (!uris || uris.length === 0) return null;
      const path = uris[0];
      try {
        const result = await BackupCodec.importFromZipPath(path, ignore);
        BackupConfig.setLastBackup(Date.now());
        return result;
      } catch (err) {
        throw new Error(`备份文件格式错误: ${(err as Error).message}`);
      }
    });
  }

  /** 恢复前初始化设置与云端凭证 store */
  private static async prepareStores_(context: Context): Promise<void> {
    try {
      await SettingsStore.getInstance().init(context);
    } catch (e) {
      console.warn('[Backup] SettingsStore init:', (e as Error).message);
    }
    try {
      await CloudCredentialStore.getInstance().init(context);
    } catch (e) {
      console.warn('[Backup] CloudCredentialStore init:', (e as Error).message);
    }
  }

  /** WebDAV 备份 */
  static async backupToWebDav(): Promise<string> {
    return BackupRestoreLock.withLock(async () => {
      const fileName = BackupConfig.getNowZipFileName();
      const pack = await BackupCodec.createCompatibleZip(fileName);
      try {
        const uploaded = await WebDavService.getInstance().uploadBackupFile(pack.zipPath, fileName);
        BackupConfig.setLastBackup(Date.now());
        return uploaded;
      } finally {
        BackupCodec.removeTree(pack.tempDir);
      }
    });
  }

  /** 按模式备份：local / webdav / both */
  static async backupByMode(context: Context | null, mode?: BackupSyncMode): Promise<string> {
    const m = mode || BackupConfig.getPolicy().backupSyncMode;
    if (m === 'local') {
      if (!context) throw new Error('本地备份需要 Context');
      return BackupService.backupToLocal(context);
    }
    if (m === 'webdav') {
      return BackupService.backupToWebDav();
    }
    // both
    let localName = '';
    let cloudName = '';
    if (context) {
      try {
        localName = await BackupService.backupToLocal(context);
      } catch (e) {
        console.warn('[Backup] local part failed:', (e as Error).message);
      }
    }
    try {
      cloudName = await BackupService.backupToWebDav();
    } catch (e) {
      if (!localName) throw e;
      console.warn('[Backup] webdav part failed:', (e as Error).message);
    }
    return cloudName || localName;
  }

  /** WebDAV 恢复 */
  static async restoreFromWebDav(name: string, ignore?: RestoreIgnoreConfig): Promise<ImportResult> {
    return BackupRestoreLock.withLock(async () => {
      const ctx = AppContextHolder.get();
      if (ctx) {
        await BackupService.prepareStores_(ctx);
      }
      const zipPath = await WebDavService.getInstance().downloadBackup(name);
      try {
        const result = await BackupCodec.importFromZipPath(zipPath, ignore);
        BackupConfig.setLastBackup(Date.now());
        return result;
      } finally {
        try { fileFs.unlinkSync(zipPath); } catch (_e) { /* ignore */ }
      }
    });
  }

  /**
   * 自动备份（对齐 Android Backup.autoBack）
   * - 超过 24 小时
   * - 云端尚不存在今日文件名时才上传
   */
  static async autoBack(): Promise<boolean> {
    BackupConfig.ensurePersistentProps();
    if (!BackupConfig.shouldAutoBackup()) {
      return false;
    }
    return BackupRestoreLock.withLock(async () => {
      // double-check
      if (!BackupConfig.shouldAutoBackup()) return false;
      const webdav = WebDavService.getInstance();
      if (!webdav.isConfigured()) {
        // 未配置云端：仅刷新时间戳，避免反复尝试
        BackupConfig.setLastBackup(Date.now());
        return false;
      }
      const fileName = BackupConfig.getNowZipFileName();
      try {
        const exists = await webdav.hasBackup(fileName);
        if (exists) {
          BackupConfig.setLastBackup(Date.now());
          console.info('[Backup] autoBack skip: cloud already has', fileName);
          return false;
        }
      } catch (e) {
        console.warn('[Backup] hasBackup check failed:', (e as Error).message);
      }
      const pack = await BackupCodec.createCompatibleZip(fileName);
      try {
        await webdav.uploadBackupFile(pack.zipPath, fileName);
        BackupConfig.setLastBackup(Date.now());
        console.info('[Backup] autoBack uploaded', fileName);
        return true;
      } finally {
        BackupCodec.removeTree(pack.tempDir);
      }
    });
  }

  /**
   * 启动检测云端是否有更新备份。
   * 返回需要提示恢复的文件名；无需提示则 null。
   */
  static async checkNewCloudBackup(): Promise<{ name: string; lastModified: string } | null> {
    BackupConfig.ensurePersistentProps();
    const policy = BackupConfig.getPolicy();
    if (!policy.autoCheckNewBackup) return null;
    const webdav = WebDavService.getInstance();
    if (!webdav.isConfigured()) return null;
    try {
      const latest = await webdav.lastBackup();
      if (!latest) return null;
      const remoteMs = BackupService.parseTimeMs(latest.lastModified);
      if (remoteMs <= 0) return null;
      // 比本地 lastBackup 新超过 1 分钟
      if (remoteMs - policy.lastBackup > 60 * 1000) {
        return { name: latest.name, lastModified: latest.lastModified };
      }
    } catch (e) {
      console.warn('[Backup] checkNewCloudBackup failed:', (e as Error).message);
    }
    return null;
  }

  private static parseTimeMs(value: string): number {
    if (!value) return 0;
    const trimmed = value.trim();
    if (/^\d+$/.test(trimmed)) {
      const n = Number(trimmed);
      if (!Number.isFinite(n) || n <= 0) return 0;
      return n < 1e12 ? n * 1000 : n;
    }
    const ms = Date.parse(trimmed);
    return Number.isFinite(ms) ? ms : 0;
  }

  private static async copyFile(src: string, dst: string): Promise<void> {
    let inFile: fileFs.File | null = null;
    let outFile: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(src);
      const buf = new ArrayBuffer(stat.size);
      inFile = fileFs.openSync(src, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(inFile.fd, buf);
      outFile = fileFs.openSync(dst, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY | fileFs.OpenMode.TRUNC);
      fileFs.writeSync(outFile.fd, buf);
    } catch (err) {
      throw new Error(`复制备份文件失败: ${dst}: ${(err as Error).message}`);
    } finally {
      if (inFile) {
        try { fileFs.closeSync(inFile); } catch { /* ignore */ }
      }
      if (outFile) {
        try { fileFs.closeSync(outFile); } catch { /* ignore */ }
      }
    }
  }
}
