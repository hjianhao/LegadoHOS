/**
 * 加密工具
 * 提供书源脚本需要的 MD5/SHA 等加密功能
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export class CryptoUtil {
  /**
   * MD5 哈希
   */
  static md5(str: string): string {
    // 简化实现——生产环境应使用 @ohos.security.crypto
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return Math.abs(hash).toString(16).padStart(8, '0');
  }

  /**
   * Base64 编码
   */
  static base64Encode(str: string): string {
    const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    const bytes = new Uint8Array(str.split('').map(c => c.charCodeAt(0)));
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i], b1 = bytes[i + 1] || 0, b2 = bytes[i + 2] || 0;
      result += b64[b0 >> 2];
      result += b64[((b0 & 3) << 4) | (b1 >> 4)];
      result += (i + 1 < bytes.length) ? b64[((b1 & 0xF) << 2) | (b2 >> 6)] : '=';
      result += (i + 2 < bytes.length) ? b64[b2 & 0x3F] : '=';
    }
    return result;
  }

  /**
   * Base64 解码
   */
  static base64Decode(str: string): string {
    const bytes = CryptoUtil.base64ToBytes(str);
    // UTF-8 解码：Multi-byte sequences → proper JS string
    let result = '';
    let i = 0;
    while (i < bytes.length) {
      const b1 = bytes[i++] & 0xff;
      if (b1 < 0x80) {
        result += String.fromCharCode(b1);
      } else if ((b1 & 0xe0) === 0xc0) {
        const b2 = bytes[i++] & 0xff;
        result += String.fromCharCode(((b1 & 0x1f) << 6) | (b2 & 0x3f));
      } else if ((b1 & 0xf0) === 0xe0) {
        const b2 = bytes[i++] & 0xff;
        const b3 = bytes[i++] & 0xff;
        result += String.fromCharCode(((b1 & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f));
      } else if ((b1 & 0xf8) === 0xf0) {
        const b2 = bytes[i++] & 0xff;
        const b3 = bytes[i++] & 0xff;
        const b4 = bytes[i++] & 0xff;
        const cp = ((b1 & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
        const high = 0xd800 + ((cp - 0x10000) >> 10);
        const low = 0xdc00 + ((cp - 0x10000) & 0x3ff);
        result += String.fromCharCode(high, low);
      }
    }
    return result;
  }

  /**
   * Legado 兼容：java.aesBase64DecodeToString(content, key, "AES/CBC/PKCS5Padding", iv)
   */
  static async aesBase64DecodeToString(encoded: string, key: string, transformation: string, iv: string): Promise<string> {
    if (!encoded || !key) return encoded || '';
    try {
      const keyBytes = CryptoUtil.stringToBytes(key);
      const ivBytes = CryptoUtil.stringToBytes(iv || '');
      const keyBits = keyBytes.length * 8;
      if (keyBits !== 128 && keyBits !== 192 && keyBits !== 256) return encoded;
      const upper = (transformation || '').toUpperCase();
      const mode = upper.includes('/CBC/') ? 'CBC' : 'CBC';
      const padding = upper.includes('NOPADDING') ? 'NoPadding' : 'PKCS7';
      const generator = cryptoFramework.createSymKeyGenerator('AES' + keyBits);
      const symKey = await generator.convertKey({ data: keyBytes });
      const cipher = cryptoFramework.createCipher('AES' + keyBits + '|' + mode + '|' + padding);
      const params = {
        algName: 'IvParamsSpec',
        iv: { data: ivBytes }
      } as cryptoFramework.IvParamsSpec;
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      const decoded = await cipher.doFinal({ data: CryptoUtil.base64ToBytes(encoded) });
      return CryptoUtil.bytesToString(decoded.data);
    } catch (_e) {
      return encoded;
    }
  }

  private static stringToBytes(str: string): Uint8Array {
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
      bytes[i] = str.charCodeAt(i) & 0xFF;
    }
    return bytes;
  }

  private static bytesToString(bytes: Uint8Array): string {
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }

  private static base64ToBytes(str: string): Uint8Array {
    const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const clean = str.replace(/\s/g, '').replace(/=+$/, '');
    const out: number[] = [];
    for (let i = 0; i < clean.length; i += 4) {
      const b0 = Math.max(0, b64.indexOf(clean.charAt(i)));
      const b1 = Math.max(0, b64.indexOf(clean.charAt(i + 1)));
      const b2 = Math.max(0, b64.indexOf(clean.charAt(i + 2)));
      const b3 = Math.max(0, b64.indexOf(clean.charAt(i + 3)));
      out.push((b0 << 2) | (b1 >> 4));
      if (i + 2 < clean.length) out.push(((b1 & 0xF) << 4) | (b2 >> 2));
      if (i + 3 < clean.length) out.push(((b2 & 3) << 6) | b3);
    }
    return new Uint8Array(out);
  }
}
