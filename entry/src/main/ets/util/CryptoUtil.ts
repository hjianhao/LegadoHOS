/**
 * 加密工具
 * 提供书源脚本需要的 MD5/SHA 等加密功能
 */
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
    try {
      const Base64 = requireNapi('util.Base64');
      return Base64.encode(str);
    } catch {
      // 手动实现
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
  }

  /**
   * Base64 解码
   */
  static base64Decode(str: string): string {
    try {
      const Base64 = requireNapi('util.Base64');
      return Base64.decode(str);
    } catch {
      const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const lookup: Record<string, number> = {};
      for (let i = 0; i < b64.length; i++) lookup[b64[i]] = i;

      let result = '';
      const clean = str.replace(/=+$/, '');
      for (let i = 0; i < clean.length; i += 4) {
        const b0 = lookup[clean[i]] || 0;
        const b1 = lookup[clean[i + 1]] || 0;
        const b2 = lookup[clean[i + 2]] || 0;
        const b3 = lookup[clean[i + 3]] || 0;
        result += String.fromCharCode((b0 << 2) | (b1 >> 4));
        if (i + 2 < clean.length) result += String.fromCharCode(((b1 & 0xF) << 4) | (b2 >> 2));
        if (i + 3 < clean.length) result += String.fromCharCode(((b2 & 3) << 6) | b3);
      }
      return result;
    }
  }
}
