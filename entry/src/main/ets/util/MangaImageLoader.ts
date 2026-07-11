/**
 * 漫画图片加载器
 *
 * 负责带自定义请求头（Referer/Cookie/UA）的图片下载与本地缓存。
 * 许多漫画源需要正确的 Referer 头才能加载图片（防盗链），
 * ArkUI 的 Image(url) 不支持自定义请求头，因此需要先下载到本地再加载。
 *
 * 缓存路径: /data/storage/el2/base/haps/entry/files/manga_cache/{md5_16(url)}.{suffix}
 */
import rcp from '@hms.collaboration.rcp';
import fileFs from '@ohos.file.fs';
import { BookSource } from '../model/BookSource';
import { NetUtil } from './NetUtil';

const CACHE_BASE_DIR: string = '/data/storage/el2/base/haps/entry/files/manga_cache/';

/** 16位 MD5（简化版，使用 URL 的 hash） */
function md5Short(url: string): string {
  let hash: number = 0;
  for (let i = 0; i < url.length; i++) {
    const c: number = url.charCodeAt(i);
    hash = ((hash << 5) - hash) + c;
    hash = hash & hash;  // 转 32bit
  }
  // 补充更多位以降低碰撞
  let hash2: number = 5381;
  for (let i = 0; i < url.length; i++) {
    hash2 = ((hash2 << 5) + hash2) + url.charCodeAt(i);
  }
  const h1: string = (hash >>> 0).toString(16).padStart(8, '0');
  const h2: string = (hash2 >>> 0).toString(16).padStart(8, '0');
  return (h1 + h2).substring(0, 16);
}

/** 从 URL 提取图片后缀 */
function getImageSuffix(url: string): string {
  try {
    const cleanUrl: string = url.split('?')[0].split('#')[0];
    const lastDot: number = cleanUrl.lastIndexOf('.');
    if (lastDot > 0) {
      const suffix: string = cleanUrl.substring(lastDot + 1).toLowerCase();
      if (suffix.length > 0 && suffix.length <= 5 && /^[a-z0-9]+$/.test(suffix)) {
        return suffix;
      }
    }
  } catch (_) { /* ignore */ }
  return 'jpg';
}

/** 解析书源 header 字段为 Record */
function parseSourceHeaders(headerStr: string): Record<string, string> {
  const headers: Record<string, string> = {};
  if (!headerStr) return headers;
  try {
    const parsed: Record<string, Object> = JSON.parse(headerStr) as Record<string, Object>;
    const keys: string[] = Object.keys(parsed);
    for (const key of keys) {
      headers[key] = String(parsed[key]);
    }
  } catch (_) { /* not JSON, ignore */ }
  return headers;
}

export class MangaImageLoader {
  private static cacheDir: string = CACHE_BASE_DIR;
  private static initialized: boolean = false;
  /** 并发下载控制 */
  private static downloading: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 最大并发下载数 */
  private static readonly MAX_CONCURRENT: number = 3;
  private static activeCount: number = 0;

  /** 初始化缓存目录 */
  static async init(): Promise<void> {
    if (MangaImageLoader.initialized) return;
    try {
      if (!fileFs.accessSync(MangaImageLoader.cacheDir)) {
        fileFs.mkdirSync(MangaImageLoader.cacheDir, true);
      }
      MangaImageLoader.initialized = true;
    } catch (err) {
      console.error('[MangaImg] Init cache dir failed:', (err as Error).message);
    }
  }

  /** 获取图片本地缓存路径 */
  static getLocalPath(url: string): string {
    return `${MangaImageLoader.cacheDir}${md5Short(url)}.${getImageSuffix(url)}`;
  }

  /** 检查图片是否已缓存 */
  static isCached(url: string): boolean {
    try {
      return fileFs.accessSync(MangaImageLoader.getLocalPath(url));
    } catch (_) {
      return false;
    }
  }

  /**
   * 获取图片的本地路径，如果未缓存则下载。
   * 返回本地文件路径（成功）或空字符串（失败）或原始 URL（回退）。
   *
   * @param url 图片 URL
   * @param source 书源（用于提取 Referer/Cookie/UA）
   * @returns 本地路径或原始 URL
   */
  static async load(url: string, source?: BookSource | null): Promise<string> {
    if (!url) return '';

    await MangaImageLoader.init();

    const localPath: string = MangaImageLoader.getLocalPath(url);

    // 已缓存，直接返回
    if (MangaImageLoader.isCached(url)) {
      return localPath;
    }

    // 正在下载同一张图，复用 Promise
    const existing: Promise<string> | undefined = MangaImageLoader.downloading.get(url);
    if (existing) {
      return existing;
    }

    // 发起下载
    const downloadPromise: Promise<string> = MangaImageLoader.downloadWithQueue(url, source, localPath);
    MangaImageLoader.downloading.set(url, downloadPromise);
    try {
      const result: string = await downloadPromise;
      return result;
    } finally {
      MangaImageLoader.downloading.delete(url);
    }
  }

  /** 带并发队列的下载 */
  private static async downloadWithQueue(url: string, source: BookSource | null, localPath: string): Promise<string> {
    // 等待并发槽
    while (MangaImageLoader.activeCount >= MangaImageLoader.MAX_CONCURRENT) {
      await new Promise<void>((resolve: Function) => setTimeout(resolve, 50));
    }
    MangaImageLoader.activeCount++;

    try {
      // 双重检查
      if (MangaImageLoader.isCached(url)) return localPath;

      const success: boolean = await MangaImageLoader.downloadImage(url, source, localPath);
      if (success) {
        return localPath;
      }
      // 下载失败，返回原始 URL 让 Image 组件尝试直接加载
      return url;
    } catch (err) {
      console.warn('[MangaImg] Download failed:', url, (err as Error).message);
      return url;
    } finally {
      MangaImageLoader.activeCount--;
    }
  }

  /** 下载单张图片到本地 */
  private static async downloadImage(url: string, source: BookSource | null, localPath: string): Promise<boolean> {
    try {
      // 构建请求头
      const headers: Record<string, string> = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8',
      };

      // 注入书源头
      if (source) {
        const sourceUrl: string = source.sourceUrl || '';
        if (sourceUrl) {
          headers['Referer'] = sourceUrl;
        }
        // 解析书源自定义 header
        const sourceHeaders: Record<string, string> = parseSourceHeaders(source.header || '');
        const keys: string[] = Object.keys(sourceHeaders);
        for (const key of keys) {
          headers[key] = sourceHeaders[key];
        }
      }

      // 使用 rcp 下载（获取 ArrayBuffer）
      const session: rcp.Session = rcp.createSession({
        requestConfiguration: {
          transfer: {
            timeout: { connectMs: 15000, transferMs: 30000 },
          },
        },
      });

      try {
        const request: rcp.Request = new rcp.Request(
          url,
          'GET' as rcp.HttpMethod,
          headers as rcp.RequestHeaders,
          '',
        );
        const response: rcp.Response = await session.fetch(request);

        if (response.statusCode < 200 || response.statusCode >= 400) {
          console.warn('[MangaImg] HTTP', response.statusCode, 'for', url.substring(0, 80));
          return false;
        }

        if (!response.body) {
          console.warn('[MangaImg] Empty body for', url.substring(0, 80));
          return false;
        }

        // 写入本地文件（二进制安全）
        const bodyBytes: Uint8Array = new Uint8Array(response.body);
        // 验证是否为有效图片数据（最小 JPEG 3 字节 / PNG 8 字节 / WebP 12 字节 / GIF 6 字节）
        if (bodyBytes.length < 3) {
          console.warn('[MangaImg] Body too small:', bodyBytes.length, 'for', url.substring(0, 80));
          return false;
        }

        // 确保目录存在
        const dir: string = localPath.substring(0, localPath.lastIndexOf('/'));
        if (!fileFs.accessSync(dir)) {
          fileFs.mkdirSync(dir, true);
        }

        // 写入临时文件再 rename（原子写入）
        const tempPath: string = `${localPath}.${Date.now()}.tmp`;
        const file: fileFs.File = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
        try {
          // 使用 slice 确保 byteOffset 正确，避免 view 指向大 buffer 的某个切片时写入多余数据
          const writeBuffer: ArrayBuffer = bodyBytes.buffer.slice(bodyBytes.byteOffset, bodyBytes.byteOffset + bodyBytes.byteLength);
          fileFs.writeSync(file.fd, writeBuffer);
        } finally {
          fileFs.closeSync(file);
        }

        // 检查正式文件是否已存在（并发时可能另一个线程先完成了）
        try { fileFs.unlinkSync(localPath); } catch (_) { /* not exist */ }
        fileFs.renameSync(tempPath, localPath);

        console.info('[MangaImg] Downloaded:', bodyBytes.length, 'bytes ->', localPath.substring(localPath.lastIndexOf('/') + 1));
        return true;
      } finally {
        session.close();
      }
    } catch (err) {
      console.warn('[MangaImg] Download error:', (err as Error).message, 'url:', url.substring(0, 80));
      return false;
    }
  }

  /**
   * 预加载图片（下载到缓存但不返回路径，不阻塞调用方）
   */
  static preload(url: string, source?: BookSource | null): void {
    if (!url || MangaImageLoader.isCached(url)) return;
    MangaImageLoader.load(url, source).catch((_e: Error) => { /* ignore preload errors */ });
  }

  /**
   * 清理指定书籍的图片缓存
   * @param imageUrls 需要保留的图片 URL 列表
   */
  static async clearCacheExcept(imageUrls: string[]): Promise<void> {
    try {
      if (!fileFs.accessSync(MangaImageLoader.cacheDir)) return;
      const retainNames: Set<string> = new Set<string>();
      for (const url of imageUrls) {
        retainNames.add(`${md5Short(url)}.${getImageSuffix(url)}`);
      }
      const files: string[] = fileFs.listFileSync(MangaImageLoader.cacheDir);
      for (const file of files) {
        if (!retainNames.has(file)) {
          try { fileFs.unlinkSync(`${MangaImageLoader.cacheDir}${file}`); } catch (_) { /* ignore */ }
        }
      }
    } catch (err) {
      console.warn('[MangaImg] Clear cache failed:', (err as Error).message);
    }
  }

  /**
   * 清空全部漫画图片缓存
   */
  static async clearAllCache(): Promise<void> {
    try {
      if (fileFs.accessSync(MangaImageLoader.cacheDir)) {
        const files: string[] = fileFs.listFileSync(MangaImageLoader.cacheDir);
        for (const file of files) {
          try { fileFs.unlinkSync(`${MangaImageLoader.cacheDir}${file}`); } catch (_) { /* ignore */ }
        }
        console.info('[MangaImg] Cleared all cache:', files.length, 'files');
      }
    } catch (err) {
      console.warn('[MangaImg] Clear all cache failed:', (err as Error).message);
    }
  }

  /**
   * 获取缓存大小（字节）
   */
  static async getCacheSize(): Promise<number> {
    try {
      if (!fileFs.accessSync(MangaImageLoader.cacheDir)) return 0;
      let totalSize: number = 0;
      const files: string[] = fileFs.listFileSync(MangaImageLoader.cacheDir);
      for (const file of files) {
        try {
          const stat: fileFs.Stat = fileFs.statSync(`${MangaImageLoader.cacheDir}${file}`);
          totalSize += stat.size;
        } catch (_) { /* ignore */ }
      }
      return totalSize;
    } catch (_) {
      return 0;
    }
  }
}
