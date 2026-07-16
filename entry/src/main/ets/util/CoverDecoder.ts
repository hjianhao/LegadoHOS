/**
 * 封面解密工具
 *
 * 兼容 Android Legado 的 coverDecodeJs 字段。
 * 支持标准 Legado JS 代码格式，如：
 *   java.createSymmetricCrypto("AES/CBC/PKCS5Padding", key, iv).decrypt(result)
 *   java.aesBase64DecodeToString(result, key, trans, iv)
 *
 * 实现策略（与 MangaImageLoader.tryImageDecodeRule 一致）：
 * 1. 正则匹配优先：识别常见解密模式，直接用 cryptoFramework 原生解密
 * 2. JS 执行兜底：正则不匹配时，将数据 base64 编码后通过 QuickJS 执行
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';

export class CoverDecoder {
  /**
   * 解密封面图片
   * @param data 加密的图片字节数据
   * @param jsCode coverDecodeJs JS 代码（标准 Legado 格式）
   * @param src 图片 URL
   * @returns 解密后的图片字节，失败返回 null
   */
  static async decrypt(data: Uint8Array, jsCode: string, src: string): Promise<Uint8Array | null> {
    if (!jsCode || jsCode.trim().length === 0) return null;
    if (!data || data.length === 0) return null;

    // 如果已经是有效图片，不需要解密
    if (CoverDecoder.isValidImage(data)) return data;

    // 路径1: 正则匹配常见解密模式
    const regexResult = await CoverDecoder.decryptWithRegex(data, jsCode);
    if (regexResult && CoverDecoder.isValidImage(regexResult)) {
      console.info('[CoverDecoder] Regex decrypt OK, size=' + regexResult.length);
      return regexResult;
    }

    // 路径2: 通过 QuickJS 执行 JS 代码
    const jsResult = await CoverDecoder.decryptWithJs(data, jsCode, src);
    if (jsResult && CoverDecoder.isValidImage(jsResult)) {
      console.info('[CoverDecoder] JS decrypt OK, size=' + jsResult.length);
      return jsResult;
    }

    console.warn('[CoverDecoder] All decrypt methods failed');
    return null;
  }

  /**
   * 正则匹配常见 Legado 解密模式，原生执行
   * 支持的模式：
   * 1. java.createSymmetricCrypto("trans", key, iv).decrypt(result)
   * 2. java.aesBase64DecodeToString(result, key, trans, iv)
   * 3. java.base64Decode(result)
   * 4. XOR 模式
   */
  private static async decryptWithRegex(data: Uint8Array, jsCode: string): Promise<Uint8Array | null> {
    try {
      // 模式1: java.createSymmetricCrypto("trans", key, iv).decrypt(result)
      // key/iv 可以是字符串字面量，也可以是 base64 编码的字符串
      const cryptoMatch = jsCode.match(
        /java\.createSymmetricCrypto\s*\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]*)['"]\s*(?:,\s*['"]([^'"]*)['"]\s*)?\s*\)\s*\.decrypt\s*\(\s*result\s*\)/
      );
      if (cryptoMatch) {
        const trans = cryptoMatch[1];  // e.g. "AES/CBC/PKCS5Padding"
        const keyStr = cryptoMatch[2]; // key 字符串
        const ivStr = cryptoMatch[3] || ''; // iv 字符串（可选）

        console.info('[CoverDecoder] createSymmetricCrypto pattern: trans=' + trans +
          ' keyLen=' + keyStr.length + ' ivLen=' + ivStr.length);

        // 解析 transformation: "AES/CBC/PKCS5Padding" -> mode=CBC, padding=PKCS7
        const transUpper = trans.toUpperCase();
        const mode = transUpper.includes('/ECB/') ? 'ECB' : 'CBC';
        const isNoPadding = transUpper.includes('NOPADDING');

        // key 转字节（ASCII fold，与 Android Legado hutool 一致）
        const keyBytes = CoverDecoder.stringToBytes(keyStr);
        const keySize = keyBytes.length === 16 ? 128 : keyBytes.length === 24 ? 192 : 256;

        let ciphertext: Uint8Array;
        let ivBytes: Uint8Array | null = null;

        if (mode === 'ECB' || !ivStr) {
          // 无 IV：IV = 密文前 16 字节（搬山人等网站的常见模式）
          if (data.length <= 16) return null;
          ivBytes = data.slice(0, 16);
          ciphertext = data.slice(16);
        } else {
          ivBytes = CoverDecoder.stringToBytes(ivStr);
          ciphertext = data;
        }

        const algo = `AES${keySize}|${mode}|${isNoPadding ? 'NoPadding' : 'PKCS7'}`;
        const generator = cryptoFramework.createSymKeyGenerator(`AES${keySize}`);
        const symKey = await generator.convertKey({ data: keyBytes });
        const cipher = cryptoFramework.createCipher(algo);

        if (mode === 'ECB') {
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
        } else {
          const params: cryptoFramework.IvParamsSpec = {
            algName: 'IvParamsSpec',
            iv: { data: ivBytes }
          };
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
        }

        const decoded = await cipher.doFinal({ data: ciphertext });
        return new Uint8Array(decoded.data);
      }

      // 模式2: java.aesBase64DecodeToString(result, key, trans, iv)
      const aesMatch = jsCode.match(
        /java\.aesBase64DecodeToString\s*\(\s*result\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/
      );
      if (aesMatch) {
        const key = aesMatch[1];
        const trans = aesMatch[2];
        const iv = aesMatch[3];
        console.info('[CoverDecoder] aesBase64DecodeToString pattern: key=' + key.substring(0, 16));
        // 注意：此模式中 result 是 base64 字符串，但封面场景下 result 是原始字节
        // 如果数据不是 base64 文本，尝试直接 AES 解密（IV = 前16字节）
        const keyBytes = CoverDecoder.stringToBytes(key);
        const keySize = keyBytes.length === 16 ? 128 : keyBytes.length === 24 ? 192 : 256;
        const ivBytes = iv ? CoverDecoder.stringToBytes(iv) : data.slice(0, 16);
        const ciphertext = iv ? data : data.slice(16);
        const transUpper = trans.toUpperCase();
        const mode = transUpper.includes('/ECB/') ? 'ECB' : 'CBC';
        const algo = `AES${keySize}|${mode}|PKCS7`;
        const generator = cryptoFramework.createSymKeyGenerator(`AES${keySize}`);
        const symKey = await generator.convertKey({ data: keyBytes });
        const cipher = cryptoFramework.createCipher(algo);
        if (mode === 'ECB') {
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
        } else {
          const params: cryptoFramework.IvParamsSpec = {
            algName: 'IvParamsSpec',
            iv: { data: ivBytes }
          };
          await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
        }
        const decoded = await cipher.doFinal({ data: ciphertext });
        return new Uint8Array(decoded.data);
      }

      // 模式3: java.base64Decode(result) - 数据是 Base64 编码的图片
      if (jsCode.includes('java.base64Decode') || jsCode.includes('Base64.decode')) {
        try {
          const b64Str = CoverDecoder.bytesToString(data);
          const decoded = CoverDecoder.base64Decode(b64Str);
          if (decoded && CoverDecoder.isValidImage(decoded)) return decoded;
        } catch (_) { /* not base64 text */ }
      }

      // 模式4: XOR
      const xorMatch = jsCode.match(/\^\s*(?:0x)?([0-9a-fA-F]+)|xor\s*\(\s*(?:0x)?([0-9a-fA-F]+)\s*\)/);
      if (xorMatch) {
        const xorKey = parseInt(xorMatch[1] || xorMatch[2] || '0', 16);
        if (xorKey > 0) {
          const decoded = new Uint8Array(data.length);
          for (let i = 0; i < data.length; i++) {
            decoded[i] = data[i] ^ xorKey;
          }
          if (CoverDecoder.isValidImage(decoded)) return decoded;
        }
      }

      return null;
    } catch (err) {
      console.warn('[CoverDecoder] Regex decrypt error:', (err as Error).message);
      return null;
    }
  }

  /**
   * 通过 QuickJS 执行 coverDecodeJs JS 代码（base64 桥接）
   * 将加密数据 base64 编码后注入 result 变量，执行 JS，返回值作为解密后的 base64
   */
  private static async decryptWithJs(data: Uint8Array, jsCode: string, src: string): Promise<Uint8Array | null> {
    try {
      // 将加密数据编码为 base64
      const b64Data = CoverDecoder.base64Encode(data);

      // 构造 JS 脚本：注入 result（base64）、src，执行 coverDecodeJs
      // 末尾不加分号允许 coverDecodeJs 本身就是表达式
      const script = `var result = ${JSON.stringify(b64Data)}; var src = ${JSON.stringify(src)}; (${jsCode})`;

      console.info('[CoverDecoder] Executing JS, script length=' + script.length);

      const evalResult = await JsExpressionEvaluator.evaluate(script, { baseUrl: src });
      if (!evalResult || evalResult === 'null' || evalResult === 'undefined') {
        console.warn('[CoverDecoder] JS returned empty');
        return null;
      }

      // JS 返回值应该是 base64 编码的解密后数据
      // 去掉可能的引号
      let b64Result = evalResult;
      if (b64Result.startsWith('"') && b64Result.endsWith('"')) {
        b64Result = b64Result.slice(1, -1);
      }

      const decoded = CoverDecoder.base64Decode(b64Result);
      return decoded;
    } catch (err) {
      console.warn('[CoverDecoder] JS decrypt error:', (err as Error).message);
      return null;
    }
  }

  /** 检查是否为有效图片格式 */
  private static isValidImage(bytes: Uint8Array): boolean {
    if (bytes.length < 4) return false;
    return (bytes[0] === 0xFF && bytes[1] === 0xD8) ||           // JPEG
      (bytes[0] === 0x89 && bytes[1] === 0x50) ||                // PNG
      (bytes[0] === 0x47 && bytes[1] === 0x49) ||                // GIF
      (bytes[0] === 0x52 && bytes[1] === 0x49);                  // WebP/RIFF
  }

  /** 字符串转字节（ASCII fold，与 Android Legado hutool 一致） */
  private static stringToBytes(str: string): Uint8Array {
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
      bytes[i] = str.charCodeAt(i) & 0xFF;
    }
    return bytes;
  }

  /** 字节转字符串（Latin-1） */
  private static bytesToString(bytes: Uint8Array): string {
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }

  /** Base64 编码 */
  private static base64Encode(bytes: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i];
      const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const triple = (a << 16) | (b << 8) | c;
      result += chars.charAt((triple >> 18) & 0x3F);
      result += chars.charAt((triple >> 12) & 0x3F);
      result += i + 1 < bytes.length ? chars.charAt((triple >> 6) & 0x3F) : '=';
      result += i + 2 < bytes.length ? chars.charAt(triple & 0x3F) : '=';
    }
    return result;
  }

  /** Base64 解码 */
  private static base64Decode(b64: string): Uint8Array {
    const lookup = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const clean = b64.replace(/[^A-Za-z0-9+/=]/g, '');
    const bytes: number[] = [];
    for (let i = 0; i < clean.length; i += 4) {
      const c1 = lookup.indexOf(clean[i]);
      const c2 = lookup.indexOf(clean[i + 1]);
      const c3 = lookup.indexOf(clean[i + 2]);
      const c4 = lookup.indexOf(clean[i + 3]);
      if (c1 < 0 || c2 < 0) break;
      bytes.push((c1 << 2) | (c2 >> 4));
      if (c3 >= 0 && clean[i + 2] !== '=') bytes.push(((c2 & 0xF) << 4) | (c3 >> 2));
      if (c4 >= 0 && clean[i + 3] !== '=') bytes.push(((c3 & 0x3) << 6) | c4);
    }
    return new Uint8Array(bytes);
  }
}
