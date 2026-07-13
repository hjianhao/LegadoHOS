/**
 * 字体管理器
 *
 * 管理阅读页可选字体列表，包含系统字体和用户导入的自定义字体。
 * 自定义字体通过 DocumentViewPicker 选择后复制到应用沙箱 <filesDir>/fonts/ 目录，
 * 再通过 UIContext.getFont().registerFont() 注册为可用字体族。
 *
 * 支持格式：.ttf、.otf（HarmonyOS 官方明确支持的格式）
 */
import { Font, UIContext } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { SettingsStore } from '../data/preferences/SettingsStore';

/** 字体信息 */
export interface FontInfo {
  /** 唯一标识 */
  id: string;
  /** 显示名称（如 "思源宋体"） */
  name: string;
  /** 注册的 familyName，供 .fontFamily() 使用 */
  familyName: string;
  /** 字体类型 */
  type: 'system' | 'custom';
  /** 自定义字体的沙箱路径（系统字体为 undefined） */
  filePath?: string;
}

/** 持久化的自定义字体元数据 */
interface CustomFontMeta {
  id: string;
  name: string;
  familyName: string;
  filePath: string;
}

/** 字体文件沙箱目录名 */
const FONTS_DIR_NAME = 'fonts';

export class FontManager {
  private static instance: FontManager;
  private registeredFonts: Set<string> = new Set<string>();
  private customFonts: FontInfo[] = [];
  private context: common.Context | null = null;

  /** 系统字体（无需注册，直接可用） */
  private readonly systemFonts: FontInfo[] = [
    { id: 'system',    name: '系统默认', familyName: 'HarmonyOS Sans', type: 'system' },
    { id: 'serif',     name: '衬线',     familyName: 'serif',         type: 'system' },
    { id: 'monospace', name: '等宽',     familyName: 'monospace',     type: 'system' },
  ];

  private constructor() {}

  static getInstance(): FontManager {
    if (!FontManager.instance) {
      FontManager.instance = new FontManager();
    }
    return FontManager.instance;
  }

  /**
   * 初始化：保存 context 并从 SettingsStore 加载已保存的自定义字体元数据
   */
  async init(context: common.Context): Promise<void> {
    this.context = context;
    await this.loadCustomFonts();
  }

  /**
   * 从 SettingsStore 加载已保存的自定义字体元数据
   * 检查文件是否仍存在，移除已丢失的条目
   */
  private async loadCustomFonts(): Promise<void> {
    try {
      const json = await SettingsStore.getInstance().getCustomFonts();
      const metaList: CustomFontMeta[] = JSON.parse(json) as CustomFontMeta[];
      if (!Array.isArray(metaList)) return;

      const valid: CustomFontMeta[] = [];
      for (const meta of metaList) {
        try {
          if (meta.filePath && fileIo.accessSync(meta.filePath)) {
            valid.push(meta);
          }
        } catch (_) {
          /* 文件不存在，跳过 */
        }
      }

      this.customFonts = valid.map((m: CustomFontMeta): FontInfo => ({
        id: m.id,
        name: m.name,
        familyName: m.familyName,
        type: 'custom',
        filePath: m.filePath,
      }));

      // 如果有字体被移除，持久化更新后的列表
      if (valid.length !== metaList.length) {
        await this.persistCustomFonts();
      }
    } catch (_e) {
      this.customFonts = [];
    }
  }

  /**
   * 注册单个字体（导入后立即注册）
   * 注册成功后尝试从字体文件读取真实名称更新到 FontInfo
   */
  registerOne(uiContext: UIContext, fontInfo: FontInfo): boolean {
    if (!fontInfo.filePath) return false;
    if (this.registeredFonts.has(fontInfo.familyName)) return true;
    try {
      const familySrc = this.toFileUri(fontInfo.filePath);
      uiContext.getFont().registerFont({
        familyName: fontInfo.familyName,
        familySrc: familySrc,
      });
      this.registeredFonts.add(fontInfo.familyName);

      // 注册成功后尝试读取字体文件中的真实名称
      const realName = this.getFontDisplayName(uiContext, fontInfo.familyName);
      if (realName) {
        fontInfo.name = realName;
        // 异步持久化更新后的名称
        this.persistCustomFonts().catch(() => {});
      }

      return true;
    } catch (e) {
      console.error(`[FontManager] Register failed for ${fontInfo.familyName}:`, (e as Error).message);
      return false;
    }
  }

  /**
   * 注册所有自定义字体并尝试读取真实字体名称
   */
  registerAll(uiContext: UIContext): void {
    const fontManager: Font = uiContext.getFont();
    let nameChanged = false;
    for (const font of this.customFonts) {
      if (!font.filePath) continue;
      if (this.registeredFonts.has(font.familyName)) continue;
      try {
        const familySrc = this.toFileUri(font.filePath);
        fontManager.registerFont({
          familyName: font.familyName,
          familySrc: familySrc,
        });
        this.registeredFonts.add(font.familyName);
        console.info(`[FontManager] Registered: ${font.familyName} -> ${familySrc}`);

        // 读取字体文件中的真实名称
        const realName = this.getFontDisplayName(uiContext, font.familyName);
        if (realName && realName !== font.name) {
          font.name = realName;
          nameChanged = true;
        }
      } catch (e) {
        console.error(`[FontManager] Register failed for ${font.familyName}:`, (e as Error).message);
      }
    }
    if (nameChanged) {
      this.persistCustomFonts().catch(() => {});
    }
  }

  /**
   * 通过 Font.getFontByName 读取字体文件中的真实名称
   * 需要字体已注册才能查询
   */
  getFontDisplayName(uiContext: UIContext, familyName: string): string {
    try {
      const info = uiContext.getFont().getFontByName(familyName);
      if (info && info.fullName) {
        return info.fullName;
      }
      if (info && info.family) {
        return info.family;
      }
    } catch (_e) {
      /* 查询失败，保持原名称 */
    }
    return '';
  }

  /**
   * 从 picker URI 导入字体文件
   * 1. 从 URI 读取文件数据
   * 2. 复制到 <filesDir>/fonts/<name>
   * 3. 生成 familyName 并注册
   * 4. 持久化元数据
   *
   * @returns 导入成功返回 FontInfo，失败返回 null
   */
  async importFont(uri: string): Promise<FontInfo | null> {
    if (!this.context) {
      console.error('[FontManager] Not initialized, call init() first');
      return null;
    }

    try {
      // 从 URI 中提取文件名
      const fileName = this.extractFileName(uri);
      if (!fileName) {
        console.error('[FontManager] Cannot extract file name from URI:', uri);
        return null;
      }

      // 校验格式
      const ext = fileName.toLowerCase().match(/\.(ttf|otf)$/);
      if (!ext) {
        console.error('[FontManager] Unsupported font format:', fileName);
        return null;
      }

      // 去掉扩展名作为显示名称
      const displayName = fileName.replace(/\.[^.]+$/, '');

      // 生成唯一 familyName
      const familyName = this.generateFamilyName(displayName);

      // 目标路径
      const fontsDir = this.getFontsDir();
      try {
        fileIo.mkdirSync(fontsDir, true);
      } catch (_) {
        /* 目录可能已存在 */
      }
      const destPath = `${fontsDir}/${fileName}`;

      // 从 URI 读取文件并复制到沙箱
      const srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(srcFile.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(srcFile.fd, buf);
        fileIo.closeSync(srcFile);

        // 写入目标文件
        const destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(destFile.fd, buf);
        fileIo.closeSync(destFile);
      } catch (e) {
        fileIo.closeSync(srcFile);
        throw e;
      }

      // 生成唯一 ID
      const id = `custom_${Date.now()}_${Math.abs(this.simpleHash(fileName)).toString(36)}`;

      const fontInfo: FontInfo = {
        id,
        name: displayName,
        familyName,
        type: 'custom',
        filePath: destPath,
      };

      // 添加到内存列表
      this.customFonts.push(fontInfo);

      // 持久化
      await this.persistCustomFonts();

      console.info(`[FontManager] Imported: ${displayName} -> ${destPath}`);
      return fontInfo;
    } catch (e) {
      console.error('[FontManager] Import failed:', (e as Error).message);
      return null;
    }
  }

  /**
   * 删除自定义字体
   * 1. 删除沙箱文件
   * 2. 从内存列表移除
   * 3. 持久化更新
   *
   * 注意：registerFont 注册的字体在当前进程内无法取消注册，
   * 但删除文件和元数据后，下次重启不会再注册。
   * 当前进程内已注册的字体仍可使用，但用户不会再选到它。
   */
  async removeFont(id: string): Promise<void> {
    const idx = this.customFonts.findIndex((f: FontInfo) => f.id === id);
    if (idx < 0) return;

    const font = this.customFonts[idx];

    // 删除沙箱文件
    if (font.filePath) {
      try {
        fileIo.unlinkSync(font.filePath);
      } catch (e) {
        console.warn(`[FontManager] Delete file failed: ${font.filePath}`, (e as Error).message);
      }
    }

    // 从内存列表移除
    this.customFonts.splice(idx, 1);

    // 从已注册集合移除（虽然进程内无法取消注册，但标记为未注册）
    this.registeredFonts.delete(font.familyName);

    // 持久化
    await this.persistCustomFonts();

    console.info(`[FontManager] Removed: ${font.name} (${font.familyName})`);
  }

  /**
   * 批量删除自定义字体
   */
  async removeFonts(ids: string[]): Promise<void> {
    for (const id of ids) {
      const idx = this.customFonts.findIndex((f: FontInfo) => f.id === id);
      if (idx < 0) continue;
      const font = this.customFonts[idx];
      if (font.filePath) {
        try { fileIo.unlinkSync(font.filePath); } catch (_e) { /* ignore */ }
      }
      this.customFonts.splice(idx, 1);
      this.registeredFonts.delete(font.familyName);
    }
    await this.persistCustomFonts();
    console.info(`[FontManager] Batch removed ${ids.length} fonts`);
  }

  /**
   * 重命名自定义字体
   */
  async renameFont(id: string, newName: string): Promise<void> {
    if (!newName.trim()) return;
    const font = this.customFonts.find((f: FontInfo) => f.id === id);
    if (font) {
      font.name = newName.trim();
      await this.persistCustomFonts();
      console.info(`[FontManager] Renamed font ${id}: ${font.name}`);
    }
  }

  /**
   * 获取全部可选字体（系统 + 自定义）
   */
  getAllFonts(): FontInfo[] {
    return [...this.systemFonts, ...this.customFonts];
  }

  /**
   * 按 familyName 查找字体
   */
  findByFamilyName(familyName: string): FontInfo | undefined {
    return this.getAllFonts().find((f: FontInfo) => f.familyName === familyName);
  }

  /**
   * 检查 familyName 是否已存在（用于去重）
   */
  hasFamilyName(familyName: string): boolean {
    return this.customFonts.some((f: FontInfo) => f.familyName === familyName);
  }

  // ===== 私有方法 =====

  /**
   * 将沙箱文件路径转换为文件 URI
   *
   * registerFont 的 familySrc 当为 string 时，需要以 file:/// 前缀开头
   * 才能被识别为文件路径而非资源路径。标准格式：file:///absolute/path
   */
  private toFileUri(filePath: string): string {
    if (filePath.startsWith('file://')) {
      return filePath;
    }
    return `file://${filePath}`;
  }

  /** 获取沙箱 fonts 目录路径 */
  private getFontsDir(): string {
    if (!this.context) throw new Error('FontManager not initialized');
    return `${this.context.filesDir}/${FONTS_DIR_NAME}`;
  }

  /** 持久化自定义字体列表到 SettingsStore */
  private async persistCustomFonts(): Promise<void> {
    const metaList: CustomFontMeta[] = this.customFonts.map((f: FontInfo): CustomFontMeta => ({
      id: f.id,
      name: f.name,
      familyName: f.familyName,
      filePath: f.filePath!,
    }));
    await SettingsStore.getInstance().setCustomFonts(JSON.stringify(metaList));
  }

  /** 从 URI 提取文件名 */
  private extractFileName(uri: string): string {
    // URI 格式通常是 file://docs/storage/.../FileName.ttf 或类似
    // 取最后一段作为文件名
    const decoded = decodeURIComponent(uri);
    const lastSlash = decoded.lastIndexOf('/');
    if (lastSlash >= 0 && lastSlash < decoded.length - 1) {
      return decoded.substring(lastSlash + 1);
    }
    return '';
  }

  /** 生成唯一的 familyName */
  private generateFamilyName(displayName: string): string {
    // 用文件名生成基础 familyName，确保不含特殊字符
    const base = displayName.replace(/[^a-zA-Z0-9\u4e00-\u9fa5]/g, '_');
    let familyName = `Custom_${base}`;
    let suffix = 1;
    while (this.hasFamilyName(familyName)) {
      familyName = `Custom_${base}_${suffix}`;
      suffix++;
    }
    return familyName;
  }

  /** 简易字符串哈希（用于生成 ID） */
  private simpleHash(str: string): number {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
      const chr = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + chr;
      hash |= 0;
    }
    return hash;
  }
}
