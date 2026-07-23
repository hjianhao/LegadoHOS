import deviceInfo from '@ohos.deviceInfo';
/**
 * 备份/WebDAV 配置项（对齐 Android BackupConfig）
 *
 * 说明：
 * - WebDAV 账号密码等连接配置仍由 WebDavService / SettingsStore 管理
 * - 本类聚焦备份策略：自动备份、设备名、仅保留最新、恢复忽略、同步模式
 */
export type BackupSyncMode = 'local' | 'webdav' | 'both';

export interface RestoreIgnoreConfig {
  readConfig: boolean;
  themeMode: boolean;
  themeConfig: boolean;
  coverConfig: boolean;
  bookshelfLayout: boolean;
  showRss: boolean;
  threadCount: boolean;
  localBook: boolean;
}

export interface BackupPolicyConfig {
  deviceName: string;
  onlyLatestBackup: boolean;
  autoBackup: boolean;
  autoCheckNewBackup: boolean;
  backupSyncMode: BackupSyncMode;
  lastBackup: number;
  ignore: RestoreIgnoreConfig;
}

const DEFAULT_IGNORE: RestoreIgnoreConfig = {
  readConfig: false,
  themeMode: false,
  themeConfig: false,
  coverConfig: false,
  bookshelfLayout: false,
  showRss: false,
  threadCount: false,
  localBook: false,
};

function ensureProps(): void {
  PersistentStorage.persistProp('backup_device_name', '');
  PersistentStorage.persistProp('backup_only_latest', true);
  PersistentStorage.persistProp('backup_auto', true);
  PersistentStorage.persistProp('backup_auto_check_new', true);
  PersistentStorage.persistProp('backup_sync_mode', 'both');
  PersistentStorage.persistProp('backup_last_time', 0);
  PersistentStorage.persistProp('backup_ignore_json', JSON.stringify(DEFAULT_IGNORE));
  // 兼容旧开关：自动同步默认映射到自动全量备份
  PersistentStorage.persistProp('webdav_auto_sync', false);
  PersistentStorage.persistProp('webdav_path', 'legado');
}

export class BackupConfig {
  static ensurePersistentProps(): void {
    ensureProps();
  }

  static getPolicy(): BackupPolicyConfig {
    ensureProps();
    const ignore = BackupConfig.getIgnoreConfig();
    const modeRaw = AppStorage.get<string>('backup_sync_mode') || 'both';
    const mode: BackupSyncMode =
      (modeRaw === 'local' || modeRaw === 'webdav' || modeRaw === 'both') ? modeRaw : 'both';
    // 若用户只开了旧 auto_sync，也视为开启自动备份
    const autoLegacy = AppStorage.get<boolean>('webdav_auto_sync') ?? false;
    const autoBackup = (AppStorage.get<boolean>('backup_auto') ?? true) || autoLegacy;
    return {
      deviceName: BackupConfig.resolveDeviceName(),
      onlyLatestBackup: AppStorage.get<boolean>('backup_only_latest') ?? true,
      autoBackup: autoBackup,
      autoCheckNewBackup: AppStorage.get<boolean>('backup_auto_check_new') ?? true,
      backupSyncMode: mode,
      lastBackup: Number(AppStorage.get<number>('backup_last_time') || 0),
      ignore: ignore,
    };
  }

  static setDeviceName(name: string): void {
    ensureProps();
    AppStorage.setOrCreate<string>('backup_device_name', name.trim());
  }

  static setOnlyLatestBackup(v: boolean): void {
    ensureProps();
    AppStorage.setOrCreate<boolean>('backup_only_latest', v);
  }

  static setAutoBackup(v: boolean): void {
    ensureProps();
    AppStorage.setOrCreate<boolean>('backup_auto', v);
    // 同步旧开关，避免 UI 分裂
    AppStorage.setOrCreate<boolean>('webdav_auto_sync', v);
  }

  static setAutoCheckNewBackup(v: boolean): void {
    ensureProps();
    AppStorage.setOrCreate<boolean>('backup_auto_check_new', v);
  }

  static setBackupSyncMode(mode: BackupSyncMode): void {
    ensureProps();
    AppStorage.setOrCreate<string>('backup_sync_mode', mode);
  }

  static setLastBackup(ts: number): void {
    ensureProps();
    AppStorage.setOrCreate<number>('backup_last_time', ts);
  }

  static getIgnoreConfig(): RestoreIgnoreConfig {
    ensureProps();
    try {
      const raw = AppStorage.get<string>('backup_ignore_json') || '';
      if (!raw) return { ...DEFAULT_IGNORE };
      const parsed = JSON.parse(raw) as Partial<RestoreIgnoreConfig>;
      return {
        readConfig: !!parsed.readConfig,
        themeMode: !!parsed.themeMode,
        themeConfig: !!parsed.themeConfig,
        coverConfig: !!parsed.coverConfig,
        bookshelfLayout: !!parsed.bookshelfLayout,
        showRss: !!parsed.showRss,
        threadCount: !!parsed.threadCount,
        localBook: !!parsed.localBook,
      };
    } catch {
      return { ...DEFAULT_IGNORE };
    }
  }

  static saveIgnoreConfig(cfg: RestoreIgnoreConfig): void {
    ensureProps();
    AppStorage.setOrCreate<string>('backup_ignore_json', JSON.stringify(cfg));
  }

  /**
   * 解析备份设备名：
   * 1) 用户手动覆盖（backup_device_name 非空）优先
   * 2) 否则自动取系统 marketName / productModel / brand
   */
  static resolveDeviceName(): string {
    ensureProps();
    const manual = (AppStorage.get<string>('backup_device_name') || '').trim();
    if (manual) return manual;
    return BackupConfig.detectSystemDeviceName();
  }

  /** 是否使用了用户手动覆盖（非自动） */
  static isDeviceNameManual(): boolean {
    ensureProps();
    return (AppStorage.get<string>('backup_device_name') || '').trim().length > 0;
  }

  /** 从系统读取设备名，失败则回落 phone/tablet 等类型 */
  static detectSystemDeviceName(): string {
    try {
      const market = (deviceInfo.marketName || '').trim();
      const model = (deviceInfo.productModel || '').trim();
      const brand = (deviceInfo.brand || '').trim();
      const type = (deviceInfo.deviceType || '').trim();
      let name = market || model || (brand ? `${brand}${model || type || ''}` : '') || type || 'harmony';
      // 文件名安全化：空白改下划线，去掉路径非法字符
      name = name.replace(/\s+/g, '_').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '');
      // 过长截断，避免 WebDAV/文件系统问题
      if (name.length > 32) name = name.substring(0, 32);
      return name || 'harmony';
    } catch (_e) {
      return 'harmony';
    }
  }

  /** 清空手动覆盖，恢复自动设备名 */
  static clearManualDeviceName(): void {
    ensureProps();
    AppStorage.setOrCreate<string>('backup_device_name', '');
  }

    /** 生成安卓同款文件名：backup{yyyy-MM-dd}[-device].zip */
  static getNowZipFileName(date: Date = new Date()): string {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    const device = BackupConfig.resolveDeviceName();
    const safeDevice = device.replace(/\s+/g, '_').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '').trim();
    if (safeDevice) {
      return `backup${y}-${m}-${d}-${safeDevice}.zip`;
    }
    return `backup${y}-${m}-${d}.zip`;
  }

  static shouldAutoBackup(now: number = Date.now()): boolean {
    const policy = BackupConfig.getPolicy();
    if (!policy.autoBackup) return false;
    const dayMs = 24 * 60 * 60 * 1000;
    return policy.lastBackup + dayMs < now;
  }
}
