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
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import image from '@ohos.multimedia.image';
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

  /** 缓存版本号（变更后自动失效旧缓存） */
  private static readonly CACHE_VERSION: number = 2;

  /** 获取图片本地缓存路径 */
  static getLocalPath(url: string): string {
    return `${MangaImageLoader.cacheDir}v${MangaImageLoader.CACHE_VERSION}_${md5Short(url)}.${getImageSuffix(url)}`;
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

    // 已缓存，验证缓存文件是否为有效图片（旧缓存可能存的是加密数据）
    if (MangaImageLoader.isCached(url)) {
      if (MangaImageLoader.isValidImageFile(localPath)) {
        return localPath;
      }
      // 缓存无效 → 删除文件，重新下载
      try { fileFs.unlinkSync(localPath); } catch (_) { /* ignore */ }
      console.info('[MangaImg] Invalidated stale cache for', url.substring(0, 60));
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

  /** 检查本地缓存文件是否为有效的图片格式 */
  private static isValidImageFile(filePath: string): boolean {
    try {
      const file: fileFs.File = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(16);
        const readLen: number = fileFs.readSync(file.fd, buf);
        if (readLen < 2) return false;
        const bytes: Uint8Array = new Uint8Array(buf);
        return MangaImageLoader.isValidImageBytes(bytes);
      } finally {
        fileFs.closeSync(file);
      }
    } catch (_) {
      return false;
    }
  }

  /** 检查字节是否为有效图片魔数 */
  private static isValidImageBytes(bytes: Uint8Array): boolean {
    if (bytes.length < 2) return false;
    return (bytes[0] === 0xFF && bytes[1] === 0xD8) ||    // JPEG
      (bytes[0] === 0x89 && bytes[1] === 0x50) ||         // PNG
      (bytes[0] === 0x47 && bytes[1] === 0x49) ||         // GIF
      (bytes[0] === 0x52 && bytes[1] === 0x49);           // WebP/RIFF
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

        // 尝试解密图片（部分漫画源使用 AES 加密图片，自动检测魔数决定是否解密）
        let finalBytes: Uint8Array = await MangaImageLoader.tryDecryptImage(bodyBytes);

        // 尝试竖条重组解密（禁漫天堂等源的图片打乱加密）
        finalBytes = await MangaImageLoader.tryUnscrambleImage(url, finalBytes);

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
          const writeBuffer: ArrayBuffer = finalBytes.buffer.slice(finalBytes.byteOffset, finalBytes.byteOffset + finalBytes.byteLength);
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
   * 检测图片是否已加密，如果是则用预置算法解密。
   *
   * 当前支持：AES-256-CBC/PKCS7 解密（漫蛙等漫画源通用格式）
   * - IV = 密文前 16 字节
   * - 密钥 = '0B6666A0-BB59-1381-B746-a0E4C9AC' 的 ASCII 字节（32 字节 = AES-256）
   */
  private static async tryDecryptImage(data: Uint8Array): Promise<Uint8Array> {
    // 检查图片魔数，判断是否为有效图片格式
    if (data.length >= 2 && MangaImageLoader.isValidImageBytes(data)) {
      return data; // 已经是有效图片，无需解密
    }

    // 数据不是标准图片格式，尝试 AES-256-CBC 解密
    if (data.length < 17) { // 至少需要 16 字节 IV + 1 字节数据
      console.warn('[MangaImg] Encrypted data too short, length:', data.length);
      return data;
    }

    try {
      // IV = 前 16 字节
      const iv: Uint8Array = data.slice(0, 16);
      const ciphertext: Uint8Array = data.slice(16);

      // 密钥 = 字符串 ASCII 字节（AES-256 需 32 字节）
      const keyStr: string = '0B6666A0-BB59-1381-B746-a0E4C9AC';
      const keyBytes: Uint8Array = new Uint8Array(keyStr.length);
      for (let i = 0; i < keyStr.length; i++) {
        keyBytes[i] = keyStr.charCodeAt(i) & 0xFF;
      }

      // 使用 cryptoFramework 解密
      const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: keyBytes });
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
      const params: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv },
      };
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      const decoded: cryptoFramework.DataBlob = await cipher.doFinal({ data: ciphertext });
      console.info('[MangaImg] Decrypted:', decoded.data.length, 'bytes (was', data.length, 'bytes encrypted)');
      return new Uint8Array(decoded.data);
    } catch (err) {
      console.warn('[MangaImg] Decrypt failed:', (err as Error).message, 'returning raw data');
      return data;
    }
  }

  /**
   * 计算字符串的 MD5 hex 值
   */
  private static async md5Hex(input: string): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
    const bytes: Uint8Array = new Uint8Array(input.length);
    for (let i = 0; i < input.length; i++) {
      bytes[i] = input.charCodeAt(i) & 0xFF;
    }
    await md.update({ data: bytes });
    const result = await md.digest();
    const hex: string[] = [];
    for (let i = 0; i < result.data.length; i++) {
      hex.push((result.data[i] & 0xFF).toString(16).padStart(2, '0'));
    }
    return hex.join('');
  }

  /**
   * 禁漫天堂图片竖条重组解密
   *
   * 禁漫将图片切成 num 条水平条并打乱顺序，解密就是反向重排。
   * 算法从源的 imageDecode 规则提取：
   * - 从 URL 提取 bookId 和 imgId: /photos\/(\d+)\/(\d+)/
   * - GIF 或 bookId < 220980 不解密
   - bookId > 421925: num = (md5(bookId+imgId) 最后字符 % 8 + 1) * 2
   - bookId >= 268850: num = (md5(bookId+imgId) 最后字符 % 10 + 1) * 2
   - 否则: num = 10
   * - 将图片分成 num 条，每条高度 y=floor(H/num)，余数 r=H%num
   * - 从下到上反向绘制条带
   */
  private static async tryUnscrambleImage(url: string, data: Uint8Array): Promise<Uint8Array> {
    // 从 URL 提取 bookId 和 imgId
    const match: RegExpMatchArray | null = url.match(/photos\/(\d+)\/(\d+)/);
    if (!match) return data; // 不是禁漫图片 URL

    const bookId: number = parseInt(match[1], 10);
    const imgId: string = match[2];

    // GIF 或旧图不解密
    if (url.toLowerCase().includes('.gif') || bookId < 220980) {
      return data;
    }

    // 计算分割条数 num
    let num: number;
    const md5Str: string = await MangaImageLoader.md5Hex(bookId + imgId);
    const lastCharCode: number = md5Str.charCodeAt(md5Str.length - 1);
    if (bookId > 421925) {
      num = (lastCharCode % 8 + 1) * 2;
    } else if (bookId >= 268850) {
      num = (lastCharCode % 10 + 1) * 2;
    } else {
      num = 10;
    }

    try {
      // 解码图片
      const buffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const imageSource: image.ImageSource = image.createImageSource(buffer);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;

      // 读取像素数据（RGBA，每像素 4 字节）
      const pixelBytes: ArrayBuffer = new ArrayBuffer(width * height * 4);
      await pixelMap.readPixelsToBuffer(pixelBytes);
      const srcPixels: Uint8Array = new Uint8Array(pixelBytes);

      // 按条带反向重排
      const dstPixels: Uint8Array = new Uint8Array(width * height * 4);
      const y: number = Math.floor(height / num);
      const remainder: number = height % num;

      for (let i = 1; i <= num; i++) {
        const h: number = (i === num) ? remainder : 0;
        const srcStartRow: number = y * (i - 1);
        const dstStartRow: number = height - y * i - h;
        const rowsToCopy: number = y + h;
        const srcOffset: number = srcStartRow * width * 4;
        const dstOffset: number = dstStartRow * width * 4;
        const copyLen: number = rowsToCopy * width * 4;
        dstPixels.set(srcPixels.subarray(srcOffset, srcOffset + copyLen), dstOffset);
      }

      // 写回新 PixelMap
      const dstPixelMap: image.PixelMap = await image.createPixelMap(dstPixels.buffer,
        { size: { width: width, height: height } } as image.InitializationOptions);
      await dstPixelMap.writeBufferToPixels(dstPixels.buffer);

      // 编码为 JPEG
      const imagePacker: image.ImagePacker = image.createImagePacker();
      const packedData: ArrayBuffer = await imagePacker.packToData(dstPixelMap,
        { format: 'image/jpeg', quality: 90 } as image.PackingOption);
      imagePacker.release();
      pixelMap.release();
      dstPixelMap.release();
      imageSource.release();

      console.info('[MangaImg] Unscrambled: bookId=' + bookId + ' num=' + num +
        ' size=' + width + 'x' + height + ' -> ' + packedData.byteLength + ' bytes');
      return new Uint8Array(packedData);
    } catch (err) {
      console.warn('[MangaImg] Unscramble failed:', (err as Error).message, 'bookId=' + bookId);
      return data;
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
