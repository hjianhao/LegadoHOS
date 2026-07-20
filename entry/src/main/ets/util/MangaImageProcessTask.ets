/**
 * 漫画图片后台处理任务。
 *
 * 所有可能随图片尺寸线性增长的 CPU/内存操作都在 TaskPool 线程执行，
 * 避免阻塞 ArkUI 主线程。输入/输出 ArrayBuffer 由 TaskPool 转移所有权，
 * 不在线程之间复制整张图片。
 */
import { taskpool } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import image from '@ohos.multimedia.image';

@Concurrent
export async function processMangaImageConcurrent(url: string, input: ArrayBuffer,
  ruleJs: string): Promise<ArrayBuffer> {
  /** 解码后最多允许 1600 万像素；重排峰值内存约为像素数的 16~20 倍。 */
  const maxDecodedPixels: number = 16 * 1024 * 1024;
  let data: Uint8Array = new Uint8Array(input);
  let validImage: boolean = data.length >= 2 &&
    ((data[0] === 0xFF && data[1] === 0xD8) ||
      (data[0] === 0x89 && data[1] === 0x50) ||
      (data[0] === 0x47 && data[1] === 0x49) ||
      (data[0] === 0x52 && data[1] === 0x49));

  // 非标准图片先尝试通用 AES-256-CBC 解密。
  if (!validImage && data.length >= 17) {
    try {
      const iv: Uint8Array = data.slice(0, 16);
      const ciphertext: Uint8Array = data.slice(16);
      const keyStr: string = '0B6666A0-BB59-1381-B746-a0E4C9AC';
      const keyBytes: Uint8Array = new Uint8Array(keyStr.length);
      for (let i = 0; i < keyStr.length; i++) {
        keyBytes[i] = keyStr.charCodeAt(i) & 0xFF;
      }
      const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: keyBytes });
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
      const params: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv },
      };
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      const decoded: cryptoFramework.DataBlob = await cipher.doFinal({ data: ciphertext });
      const candidate: Uint8Array = new Uint8Array(decoded.data);
      const candidateValid: boolean = candidate.length >= 2 &&
        ((candidate[0] === 0xFF && candidate[1] === 0xD8) ||
          (candidate[0] === 0x89 && candidate[1] === 0x50) ||
          (candidate[0] === 0x47 && candidate[1] === 0x49) ||
          (candidate[0] === 0x52 && candidate[1] === 0x49));
      if (candidateValid) {
        data = candidate;
        validImage = true;
      }
    } catch (_) { /* 不是通用 AES 图片，继续尝试书源规则 */ }
  }

  // 书源 imageDecode：仅处理当前已支持且可安全识别的常见模式。
  if (!validImage && ruleJs && ruleJs.trim().length > 0) {
    const aesMatch: RegExpMatchArray | null = ruleJs.match(/java\.aesBase64DecodeToString\s*\(\s*result\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/);
    if (aesMatch) {
      try {
        const keyStr: string = aesMatch[1];
        const trans: string = aesMatch[2] || 'CBC';
        const ivStr: string = aesMatch[3];
        const keyBytes: Uint8Array = new Uint8Array(keyStr.length);
        for (let i = 0; i < keyStr.length; i++) keyBytes[i] = keyStr.charCodeAt(i) & 0xFF;
        const keySize: number = keyBytes.length === 16 ? 128 : keyBytes.length === 24 ? 192 : 256;
        const generator: cryptoFramework.SymKeyGenerator =
          cryptoFramework.createSymKeyGenerator(`AES${keySize}`);
        const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: keyBytes });
        const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(`AES${keySize}|${trans}|PKCS7`);
        if (trans === 'ECB' || !ivStr) {
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
        } else {
          const ivBytes: Uint8Array = new Uint8Array(ivStr.length);
          for (let i = 0; i < ivStr.length; i++) ivBytes[i] = ivStr.charCodeAt(i) & 0xFF;
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey,
            { algName: 'IvParamsSpec', iv: { data: ivBytes } } as cryptoFramework.IvParamsSpec);
        }
        const decoded: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
        data = new Uint8Array(decoded.data);
      } catch (_) { /* 保留原数据 */ }
    } else if (ruleJs.includes('java.base64Decode') || ruleJs.includes('Base64.decode')) {
      const lookup: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      let b64: string = '';
      for (let i = 0; i < data.length; i++) b64 += String.fromCharCode(data[i]);
      b64 = b64.replace(/[^A-Za-z0-9+/=]/g, '');
      const bytes: number[] = [];
      for (let i = 0; i < b64.length; i += 4) {
        const c1: number = lookup.indexOf(b64[i]);
        const c2: number = lookup.indexOf(b64[i + 1]);
        const c3: number = lookup.indexOf(b64[i + 2]);
        const c4: number = lookup.indexOf(b64[i + 3]);
        if (c1 < 0 || c2 < 0) break;
        bytes.push((c1 << 2) | (c2 >> 4));
        if (c3 >= 0 && b64[i + 2] !== '=') bytes.push(((c2 & 15) << 4) | (c3 >> 2));
        if (c4 >= 0 && b64[i + 3] !== '=') bytes.push(((c3 & 3) << 6) | c4);
      }
      data = new Uint8Array(bytes);
    } else {
      const xorMatch: RegExpMatchArray | null =
        ruleJs.match(/\^\s*(?:0x)?([0-9a-fA-F]+)|xor\s*\(\s*(?:0x)?([0-9a-fA-F]+)\s*\)/);
      if (xorMatch) {
        const xorKey: number = parseInt(xorMatch[1] || xorMatch[2] || '0', 16);
        if (xorKey > 0) {
          const decoded: Uint8Array = new Uint8Array(data.length);
          for (let i = 0; i < data.length; i++) decoded[i] = data[i] ^ xorKey;
          data = decoded;
        }
      }
    }
    validImage = data.length >= 2 &&
      ((data[0] === 0xFF && data[1] === 0xD8) ||
        (data[0] === 0x89 && data[1] === 0x50) ||
        (data[0] === 0x47 && data[1] === 0x49) ||
        (data[0] === 0x52 && data[1] === 0x49));
  }

  // 禁漫天堂竖条重排。
  const match: RegExpMatchArray | null = url.match(/photos\/(\d+)\/(\d+)/);
  if (validImage && match && !url.toLowerCase().includes('.gif')) {
    const bookId: number = parseInt(match[1], 10);
    if (bookId >= 220980) {
      const imgId: string = match[2];
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      const mdInput: string = bookId + imgId;
      const mdBytes: Uint8Array = new Uint8Array(mdInput.length);
      for (let i = 0; i < mdInput.length; i++) mdBytes[i] = mdInput.charCodeAt(i) & 0xFF;
      await md.update({ data: mdBytes });
      const mdResult: cryptoFramework.DataBlob = await md.digest();
      const lastByte: number = mdResult.data[mdResult.data.length - 1] & 0xFF;
      // 原算法取 MD5 hex 的最后字符 charCode，而不是最后一个字节本身。
      const lastNibble: number = lastByte & 0x0F;
      const lastCharCode: number = lastNibble < 10 ? 48 + lastNibble : 87 + lastNibble;
      let num: number = 10;
      if (bookId > 421925) num = (lastCharCode % 8 + 1) * 2;
      else if (bookId >= 268850) num = (lastCharCode % 10 + 1) * 2;

      let imageSource: image.ImageSource | null = null;
      let pixelMap: image.PixelMap | null = null;
      let dstPixelMap: image.PixelMap | null = null;
      let imagePacker: image.ImagePacker | null = null;
      try {
        const sourceBuffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
        imageSource = image.createImageSource(sourceBuffer);
        pixelMap = await imageSource.createPixelMap();
        const info: image.ImageInfo = await pixelMap.getImageInfo();
        const width: number = info.size.width;
        const height: number = info.size.height;
        const pixels: number = width * height;
        if (width <= 0 || height <= 0 || !Number.isSafeInteger(pixels) || pixels > maxDecodedPixels) {
          throw new Error(`漫画图片尺寸超出安全限制: ${width}x${height}`);
        }

        const pixelBytes: ArrayBuffer = new ArrayBuffer(pixels * 4);
        await pixelMap.readPixelsToBuffer(pixelBytes);
        const srcPixels: Uint8Array = new Uint8Array(pixelBytes);
        const dstPixels: Uint8Array = new Uint8Array(pixels * 4);
        const stripHeight: number = Math.floor(height / num);
        const remainder: number = height % num;
        for (let i = 1; i <= num; i++) {
          const extra: number = i === num ? remainder : 0;
          const srcStartRow: number = stripHeight * (i - 1);
          const dstStartRow: number = height - stripHeight * i - extra;
          const rowsToCopy: number = stripHeight + extra;
          const srcOffset: number = srcStartRow * width * 4;
          const dstOffset: number = dstStartRow * width * 4;
          const copyLen: number = rowsToCopy * width * 4;
          dstPixels.set(srcPixels.subarray(srcOffset, srcOffset + copyLen), dstOffset);
        }

        dstPixelMap = await image.createPixelMap(dstPixels.buffer,
          { size: { width: width, height: height } } as image.InitializationOptions);
        imagePacker = image.createImagePacker();
        const packed: ArrayBuffer = await imagePacker.packToData(dstPixelMap,
          { format: 'image/jpeg', quality: 90 } as image.PackingOption);
        return packed;
      } finally {
        try { if (imagePacker) imagePacker.release(); } catch (_) { /* ignore release error */ }
        try { if (dstPixelMap) dstPixelMap.release(); } catch (_) { /* ignore release error */ }
        try { if (pixelMap) pixelMap.release(); } catch (_) { /* ignore release error */ }
        try { if (imageSource) imageSource.release(); } catch (_) { /* ignore release error */ }
      }
    }
  }

  return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
}
