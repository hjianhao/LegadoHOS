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
import { taskpool } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import image from '@ohos.multimedia.image';
import { BookSource } from '../model/BookSource';
import { processMangaImageConcurrent } from './MangaImageProcessTask';

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
  private static initPromise: Promise<void> | null = null;
  /** 并发下载控制 */
  private static downloading: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 最大并发下载数 */
  private static readonly MAX_CONCURRENT: number = 3;
  private static activeCount: number = 0;
  private static downloadWaiters: Array<() => void> = [];
  /** 解密/像素重排单独串行，避免多张 RGBA 大图同时驻留内存。 */
  private static readonly MAX_PROCESS_CONCURRENT: number = 1;
  private static processActiveCount: number = 0;
  private static processWaiters: Array<() => void> = [];

  /** 初始化缓存目录 */
  static async init(): Promise<void> {
    if (MangaImageLoader.initialized) return;
    if (MangaImageLoader.initPromise) return MangaImageLoader.initPromise;
    MangaImageLoader.initPromise = MangaImageLoader.initInternal_();
    try { await MangaImageLoader.initPromise; }
    finally { MangaImageLoader.initPromise = null; }
  }

  private static async initInternal_(): Promise<void> {
    try {
      if (!await fileFs.access(MangaImageLoader.cacheDir)) {
        await fileFs.mkdir(MangaImageLoader.cacheDir, true);
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
  static async isCached(url: string): Promise<boolean> {
    try {
      return await fileFs.access(MangaImageLoader.getLocalPath(url));
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
  static async load(url: string, source?: BookSource | null, onProgress?: (percent: number) => void): Promise<string> {
    if (!url) return '';

    await MangaImageLoader.init();

    const localPath: string = MangaImageLoader.getLocalPath(url);

    // 已缓存，验证缓存文件是否为有效图片（旧缓存可能存的是加密数据）
    if (await MangaImageLoader.isCached(url)) {
      if (await MangaImageLoader.isValidImageFile(localPath)) {
        return localPath;
      }
      // 缓存无效 → 删除文件，重新下载
      try { await fileFs.unlink(localPath); } catch (_) { /* ignore */ }
      console.info('[MangaImg] Invalidated stale cache for', url.substring(0, 60));
    }

    // 正在下载同一张图，复用 Promise
    const existing: Promise<string> | undefined = MangaImageLoader.downloading.get(url);
    if (existing) {
      return existing;
    }

    // 发起下载
    const downloadPromise: Promise<string> =
      MangaImageLoader.downloadWithQueue(url, source || null, localPath, onProgress);
    MangaImageLoader.downloading.set(url, downloadPromise);
    try {
      const result: string = await downloadPromise;
      return result;
    } finally {
      MangaImageLoader.downloading.delete(url);
    }
  }

  /** 检查本地缓存文件是否为有效的图片格式 */
  private static async isValidImageFile(filePath: string): Promise<boolean> {
    let file: fileFs.File | null = null;
    try {
      file = await fileFs.open(filePath, fileFs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(16);
      const readLen: number = await fileFs.read(file.fd, buf);
      if (readLen < 2) return false;
      return MangaImageLoader.isValidImageBytes(new Uint8Array(buf));
    } catch (_) {
      return false;
    } finally {
      if (file) {
        try { await fileFs.close(file); } catch (_) { /* ignore close error */ }
      }
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
  private static async downloadWithQueue(url: string, source: BookSource | null, localPath: string, onProgress?: (percent: number) => void): Promise<string> {
    await MangaImageLoader.acquireDownloadSlot_();

    try {
      // 双重检查
      if (await MangaImageLoader.isCached(url)) return localPath;

      const success: boolean = await MangaImageLoader.downloadImage(url, source, localPath, onProgress);
      if (success) {
        return localPath;
      }
      // 下载失败，返回原始 URL 让 Image 组件尝试直接加载
      return url;
    } catch (err) {
      console.warn('[MangaImg] Download failed:', url, (err as Error).message);
      return url;
    } finally {
      MangaImageLoader.releaseDownloadSlot_();
    }
  }

  private static async acquireDownloadSlot_(): Promise<void> {
    if (MangaImageLoader.activeCount >= MangaImageLoader.MAX_CONCURRENT) {
      await new Promise<void>((resolve: () => void): void => {
        MangaImageLoader.downloadWaiters.push(resolve);
      });
    }
    MangaImageLoader.activeCount++;
  }

  private static releaseDownloadSlot_(): void {
    MangaImageLoader.activeCount = Math.max(0, MangaImageLoader.activeCount - 1);
    const next: (() => void) | undefined = MangaImageLoader.downloadWaiters.shift();
    if (next) next();
  }

  private static async acquireProcessSlot_(): Promise<void> {
    if (MangaImageLoader.processActiveCount >= MangaImageLoader.MAX_PROCESS_CONCURRENT) {
      await new Promise<void>((resolve: () => void): void => {
        MangaImageLoader.processWaiters.push(resolve);
      });
    }
    MangaImageLoader.processActiveCount++;
  }

  private static releaseProcessSlot_(): void {
    MangaImageLoader.processActiveCount = Math.max(0, MangaImageLoader.processActiveCount - 1);
    const next: (() => void) | undefined = MangaImageLoader.processWaiters.shift();
    if (next) next();
  }

  /** 下载单张图片到本地 */
  private static async downloadImage(url: string, source: BookSource | null, localPath: string, onProgress?: (percent: number) => void): Promise<boolean> {
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
      const sessionCfg: rcp.SessionConfiguration = {
        requestConfiguration: {
          transfer: {
            timeout: { connectMs: 15000, transferMs: 30000 },
          },
          tracing: onProgress ? {
            httpEventsHandler: {
              onDownloadProgress: (totalSize: number, transferredSize: number): void => {
                if (totalSize > 0) {
                  onProgress(Math.min(100, Math.round(transferredSize * 100 / totalSize)));
                }
              },
            } as rcp.HttpEventsHandler,
          } as rcp.TracingConfiguration : undefined,
        },
      };
      const session: rcp.Session = rcp.createSession(sessionCfg);

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

        // 先做最小校验；后续整图处理通过 TaskPool 转移所有权，不复制大缓冲。
        const bodyBuffer: ArrayBuffer = response.body;
        const bodyLength: number = bodyBuffer.byteLength;
        const bodyBytes: Uint8Array = new Uint8Array(bodyBuffer);
        // 验证是否为有效图片数据（最小 JPEG 3 字节 / PNG 8 字节 / WebP 12 字节 / GIF 6 字节）
        if (bodyBytes.length < 3) {
          console.warn('[MangaImg] Body too small:', bodyBytes.length, 'for', url.substring(0, 80));
          return false;
        }

        // AES/XOR/Base64/像素重排全部移到 TaskPool；像素处理并发固定为 1。
        await MangaImageLoader.acquireProcessSlot_();
        let finalBuffer: ArrayBuffer;
        try {
          const task: taskpool.Task = new taskpool.Task('manga-image-process',
            processMangaImageConcurrent, url, bodyBuffer, source?.ruleBookContentImageDecode || '');
          task.setTransferList([bodyBuffer]);
          finalBuffer = await taskpool.execute(task, taskpool.Priority.LOW) as ArrayBuffer;
        } finally {
          MangaImageLoader.releaseProcessSlot_();
        }

        const finalBytes: Uint8Array = new Uint8Array(finalBuffer);
        if (!MangaImageLoader.isValidImageBytes(finalBytes)) {
          console.warn('[MangaImg] Processed data is not a supported image:', url.substring(0, 80));
          return false;
        }

        // 确保目录存在
        const dir: string = localPath.substring(0, localPath.lastIndexOf('/'));
        if (!await fileFs.access(dir)) {
          await fileFs.mkdir(dir, true);
        }

        // 写入临时文件再 rename（原子写入）
        const tempPath: string = `${localPath}.${Date.now()}.tmp`;
        let file: fileFs.File | null = null;
        let committed: boolean = false;
        try {
          file = await fileFs.open(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
          await fileFs.write(file.fd, finalBuffer);
          await fileFs.close(file);
          file = null;

          // 检查正式文件是否已存在（并发时可能另一个线程先完成了）
          try { await fileFs.unlink(localPath); } catch (_) { /* not exist */ }
          await fileFs.rename(tempPath, localPath);
          committed = true;
        } finally {
          if (file) {
            try { await fileFs.close(file); } catch (_) { /* ignore close error */ }
          }
          if (!committed) {
            try { await fileFs.unlink(tempPath); } catch (_) { /* not exist */ }
          }
        }

        console.info('[MangaImg] Downloaded:', bodyLength, 'bytes ->',
          localPath.substring(localPath.lastIndexOf('/') + 1));
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
   * 书源 imageDecode 规则解密
   *
   * QuickJS 桥不支持 ByteArray 传参，因此用正则匹配常见解密模式，
   * 匹配成功则原生执行，匹配失败则跳过。
   *
   * 支持的模式：
   * 1. java.aesBase64DecodeToString(result, key, trans, iv) -> AES 解密 Base64 数据
   * 2. java.base64Decode(result) -> Base64 解码
   * 3. XOR 模式: result.map(b => b ^ key) 或 result[i] ^= key
   */
  private static async tryImageDecodeRule(url: string, data: Uint8Array, ruleJs: string): Promise<Uint8Array> {
    // 如果已是有效图片，跳过
    if (MangaImageLoader.isValidImageBytes(data)) return data;
    if (!ruleJs || ruleJs.trim().length === 0) return data;

    console.info('[MangaImg] Trying imageDecode rule:', ruleJs.substring(0, 80));

    try {
      // 模式1: java.aesBase64DecodeToString(result, key, trans, iv)
      const aesMatch: RegExpMatchArray | null = ruleJs.match(/java\.aesBase64DecodeToString\s*\(\s*result\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/);
      if (aesMatch) {
        const key: string = aesMatch[1];
        const trans: string = aesMatch[2];
        const iv: string = aesMatch[3];
        console.info('[MangaImg] imageDecode: AES pattern, key=', key.substring(0, 16), 'trans=', trans, 'iv=', iv.substring(0, 16));
        const decoded: Uint8Array = await MangaImageLoader.aesDecrypt_(data, key, trans, iv);
        if (decoded && MangaImageLoader.isValidImageBytes(decoded)) {
          console.info('[MangaImg] imageDecode AES success:', decoded.length, 'bytes');
          return decoded;
        }
      }

      // 模式2: java.base64Decode(result) - 数据是 Base64 编码的图片
      if (ruleJs.includes('java.base64Decode') || ruleJs.includes('Base64.decode')) {
        console.info('[MangaImg] imageDecode: Base64 pattern');
        try {
          // 将 Uint8Array 转为字符串（Base64 文本）
          let b64Str: string = '';
          for (let i = 0; i < data.length; i++) b64Str += String.fromCharCode(data[i]);
          const decoded: Uint8Array = MangaImageLoader.base64Decode_(b64Str);
          if (decoded && MangaImageLoader.isValidImageBytes(decoded)) {
            console.info('[MangaImg] imageDecode Base64 success:', decoded.length, 'bytes');
            return decoded;
          }
        } catch (_) { /* not base64 text */ }
      }

      // 模式3: XOR - result.forEach((b, i) => result[i] = b ^ key) 或类似
      const xorMatch: RegExpMatchArray | null = ruleJs.match(/\^\s*(?:0x)?([0-9a-fA-F]+)|xor\s*\(\s*(?:0x)?([0-9a-fA-F]+)\s*\)/);
      if (xorMatch) {
        const xorKey: number = parseInt(xorMatch[1] || xorMatch[2] || '0', 16);
        if (xorKey > 0) {
          console.info('[MangaImg] imageDecode: XOR pattern, key=0x' + xorKey.toString(16));
          const decoded: Uint8Array = new Uint8Array(data.length);
          for (let i = 0; i < data.length; i++) {
            decoded[i] = data[i] ^ xorKey;
          }
          if (MangaImageLoader.isValidImageBytes(decoded)) {
            console.info('[MangaImg] imageDecode XOR success:', decoded.length, 'bytes');
            return decoded;
          }
        }
      }

      console.warn('[MangaImg] imageDecode rule not matched, skipping');
      return data;
    } catch (err) {
      console.warn('[MangaImg] imageDecode error:', (err as Error).message);
      return data;
    }
  }

  /** AES 解密（支持 ECB/CBC，PKCS5/PKCS7 padding） */
  private static async aesDecrypt_(data: Uint8Array, keyStr: string, trans: string, ivStr: string): Promise<Uint8Array> {
    try {
      // 将 key 字符串转为字节
      const keyBytes: Uint8Array = new Uint8Array(keyStr.length);
      for (let i = 0; i < keyStr.length; i++) {
        keyBytes[i] = keyStr.charCodeAt(i) & 0xFF;
      }
      const keySize: number = keyBytes.length === 16 ? 128 : keyBytes.length === 24 ? 192 : 256;
      const algo: string = `AES${keySize}|${trans || 'CBC'}|PKCS7`;

      const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator(`AES${keySize}`);
      const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: keyBytes });
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(algo);

      if (trans === 'ECB' || !ivStr) {
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
      } else {
        const ivBytes: Uint8Array = new Uint8Array(ivStr.length);
        for (let i = 0; i < ivStr.length; i++) {
          ivBytes[i] = ivStr.charCodeAt(i) & 0xFF;
        }
        const params: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: ivBytes } };
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      }

      const decoded: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
      return new Uint8Array(decoded.data);
    } catch (err) {
      console.warn('[MangaImg] AES decrypt error:', (err as Error).message);
      return data;
    }
  }

  /** Base64 解码 */
  private static base64Decode_(b64: string): Uint8Array {
    const lookup: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const cleanB64: string = b64.replace(/[^A-Za-z0-9+/=]/g, '');
    const len: number = cleanB64.length;
    const bytes: number[] = [];
    for (let i = 0; i < len; i += 4) {
      const c1: number = lookup.indexOf(cleanB64[i]);
      const c2: number = lookup.indexOf(cleanB64[i + 1]);
      const c3: number = lookup.indexOf(cleanB64[i + 2]);
      const c4: number = lookup.indexOf(cleanB64[i + 3]);
      if (c1 < 0 || c2 < 0) break;
      bytes.push((c1 << 2) | (c2 >> 4));
      if (c3 >= 0 && cleanB64[i + 2] !== '=') bytes.push(((c2 & 15) << 4) | (c3 >> 2));
      if (c4 >= 0 && cleanB64[i + 3] !== '=') bytes.push(((c3 & 3) << 6) | c4);
    }
    return new Uint8Array(bytes);
  }

  /**
   * 计算字符串的 MD5 hex 值
   */
  private static async md5Hex(input: string): Promise<string> {
    try {
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
    } catch (err) {
      throw new Error('[MangaImageLoader] MD5 failed: ' + (err as Error).message);
    }
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
    if (!url) return;
    MangaImageLoader.load(url, source).catch((_e: Error) => { /* ignore preload errors */ });
  }

  /**
   * 清理指定书籍的图片缓存
   * @param imageUrls 需要保留的图片 URL 列表
   */
  static async clearCacheExcept(imageUrls: string[]): Promise<void> {
    try {
      if (!await fileFs.access(MangaImageLoader.cacheDir)) return;
      const retainNames: Set<string> = new Set<string>();
      for (const url of imageUrls) {
        retainNames.add(`v${MangaImageLoader.CACHE_VERSION}_${md5Short(url)}.${getImageSuffix(url)}`);
      }
      const files: string[] = await fileFs.listFile(MangaImageLoader.cacheDir);
      for (const file of files) {
        if (!retainNames.has(file)) {
          try { await fileFs.unlink(`${MangaImageLoader.cacheDir}${file}`); } catch (_) { /* ignore */ }
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
      if (await fileFs.access(MangaImageLoader.cacheDir)) {
        const files: string[] = await fileFs.listFile(MangaImageLoader.cacheDir);
        for (const file of files) {
          try { await fileFs.unlink(`${MangaImageLoader.cacheDir}${file}`); } catch (_) { /* ignore */ }
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
      if (!await fileFs.access(MangaImageLoader.cacheDir)) return 0;
      let totalSize: number = 0;
      const files: string[] = await fileFs.listFile(MangaImageLoader.cacheDir);
      for (const file of files) {
        try {
          const stat: fileFs.Stat = await fileFs.stat(`${MangaImageLoader.cacheDir}${file}`);
          totalSize += stat.size;
        } catch (_) { /* ignore */ }
      }
      return totalSize;
    } catch (_) {
      return 0;
    }
  }
}
