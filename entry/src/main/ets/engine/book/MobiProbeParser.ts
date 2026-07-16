import fileFs from '@ohos.file.fs';
import util from '@ohos.util';

export interface MobiProbeResult {
  title: string;
  author: string;
  description: string;
  version: number;
  isKf8: boolean;
  encryption: number;
}

/**
 * 仅解析导入所需的 PDB/PalmDOC/MOBI/EXTH 头，不解压正文。
 * 正文、目录及资源统一交给 foliate-js 按需解析。
 */
export class MobiProbeParser {
  static probe(filePath: string): MobiProbeResult {
    const stat = fileFs.statSync(filePath);
    if (stat.size < 96) throw new Error('无效的 MOBI/AZW 文件：文件过小');
    const probeLength = Math.min(stat.size, 1024 * 1024);
    const buffer = new ArrayBuffer(probeLength);
    const file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
    try {
      fileFs.readSync(file.fd, buffer, { offset: 0, length: probeLength });
    } finally {
      fileFs.closeSync(file);
    }
    const bytes = new Uint8Array(buffer);
    if (MobiProbeParser.ascii_(bytes, 60, 8) !== 'BOOKMOBI') {
      throw new Error('无效的 MOBI/AZW 文件：缺少 BOOKMOBI 标识');
    }
    const record0 = MobiProbeParser.u32_(bytes, 78);
    if (record0 + 260 > bytes.length) {
      throw new Error('无效的 MOBI/AZW 文件：文件头不完整');
    }
    const encryption = MobiProbeParser.u16_(bytes, record0 + 12);
    if (encryption !== 0) {
      throw new Error('暂不支持 DRM 加密的 Kindle 书籍');
    }
    const mobi = record0 + 16;
    if (MobiProbeParser.ascii_(bytes, mobi, 4) !== 'MOBI') {
      throw new Error('无效的 MOBI/AZW 文件：缺少 MOBI 文件头');
    }
    const headerLength = MobiProbeParser.u32_(bytes, mobi + 4);
    const encoding = MobiProbeParser.u32_(bytes, mobi + 12);
    const version = MobiProbeParser.u32_(bytes, mobi + 20);
    const titleOffset = MobiProbeParser.u32_(bytes, mobi + 68);
    const titleLength = MobiProbeParser.u32_(bytes, mobi + 72);
    let title = MobiProbeParser.decode_(bytes, record0 + titleOffset, titleLength, encoding);
    let author = '';
    let description = '';
    const exthFlags = MobiProbeParser.u32_(bytes, mobi + 112);
    if ((exthFlags & 0x40) !== 0) {
      const exth = mobi + headerLength;
      if (MobiProbeParser.ascii_(bytes, exth, 4) === 'EXTH') {
        const count = MobiProbeParser.u32_(bytes, exth + 8);
        let pos = exth + 12;
        for (let i = 0; i < count && pos + 8 <= bytes.length; i++) {
          const type = MobiProbeParser.u32_(bytes, pos);
          const length = MobiProbeParser.u32_(bytes, pos + 4);
          if (length < 8 || pos + length > bytes.length) break;
          const value = MobiProbeParser.decode_(bytes, pos + 8, length - 8, encoding);
          if (type === 100 && !author) author = value;
          if (type === 103 && !description) description = value;
          if (type === 503 && value) title = value;
          pos += length;
        }
      }
    }
    return { title, author, description, version, isKf8: version >= 8, encryption };
  }

  private static u16_(bytes: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 2 > bytes.length) return 0;
    return ((bytes[offset] << 8) | bytes[offset + 1]) >>> 0;
  }

  private static u32_(bytes: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return ((bytes[offset] * 0x1000000) + (bytes[offset + 1] << 16) +
      (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
  }

  private static ascii_(bytes: Uint8Array, offset: number, length: number): string {
    let result = '';
    for (let i = 0; i < length && offset + i < bytes.length; i++) {
      result += String.fromCharCode(bytes[offset + i]);
    }
    return result;
  }

  private static decode_(bytes: Uint8Array, offset: number, length: number, encoding: number): string {
    if (offset < 0 || length <= 0 || offset + length > bytes.length) return '';
    try {
      const charset = encoding === 1252 ? 'windows-1252' : 'utf-8';
      return new util.TextDecoder(charset, { fatal: false })
        .decodeToString(bytes.slice(offset, offset + length)).replace(/\0/g, '').trim();
    } catch (_e) {
      return MobiProbeParser.ascii_(bytes, offset, length).replace(/\0/g, '').trim();
    }
  }
}
