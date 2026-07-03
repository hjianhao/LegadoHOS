/**
 * 纯 ArkTS ZIP 文件写入器
 *
 * 创建标准 ZIP 文件，兼容 ZipReader 格式。
 * 仅支持 STORED（无压缩）模式。
 *
 * ZIP 格式:
 * ┌──────────────────┐
 * │ Local File Header│  ← 每个文件条目
 * │ File Data        │
 * ├──────────────────┤
 * │ ... 更多条目 ...  │
 * ├──────────────────┤
 * │ Central Directory│
 * │ Header           │  ← 每个条目的索引
 * ├──────────────────┤
 * │ End of Central   │
 * │ Directory Record │  ← ZIP 文件尾
 * └──────────────────┘
 */
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';

interface ZipEntryData {
  fileName: string;
  data: Uint8Array;
  crc32: number;
  uncompressedSize: number;
}

export class ZipWriter {
  private entries: ZipEntryData[] = [];
  private encoder: util.TextEncoder = new util.TextEncoder();

  /**
   * 添加文本文件
   */
  addTextFile(name: string, text: string): void {
    const data = this.encoder.encodeInto(text);
    this.entries.push({
      fileName: name.replace(/\\/g, '/'),
      data,
      crc32: this.calculateCrc32(data),
      uncompressedSize: data.length,
    });
  }

  /**
   * 添加二进制文件
   */
  addFile(name: string, data: Uint8Array): void {
    this.entries.push({
      fileName: name.replace(/\\/g, '/'),
      data,
      crc32: this.calculateCrc32(data),
      uncompressedSize: data.length,
    });
  }

  /**
   * 构建 ZIP 文件并保存到路径
   */
  async saveTo(filePath: string): Promise<void> {
    const zipData = this.build();
    const file = fileFs.openSync(filePath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
    try {
      fileFs.writeSync(file.fd, zipData.buffer as ArrayBuffer);
    } finally {
      fileFs.closeSync(file);
    }
  }

  /**
   * 构建 ZIP 文件字节数组
   */
  build(): Uint8Array {
    const localHeaders: Uint8Array[] = [];
    const centralHeaders: Uint8Array[] = [];
    let offset = 0;

    for (const entry of this.entries) {
      const nameBytes = this.encoder.encodeInto(entry.fileName);

      // Local File Header
      const localHeader = this.buildLocalHeader(entry, nameBytes);
      localHeaders.push(localHeader);
      localHeaders.push(entry.data);
      offset += localHeader.length + entry.data.length;

      // Central Directory Header
      const centralHeader = this.buildCentralHeader(entry, nameBytes);
      centralHeaders.push(centralHeader);
    }

    const centralDirOffset = offset;
    const centralDirSize = centralHeaders.reduce((s, h) => s + h.length, 0);

    // EOCD
    const eocd = this.buildEocd(this.entries.length, centralDirSize, centralDirOffset);

    // 拼接
    const totalLen = offset + centralDirSize + eocd.length;
    const result = new Uint8Array(totalLen);
    let pos = 0;

    for (const buf of localHeaders) { result.set(buf, pos); pos += buf.length; }
    for (const buf of centralHeaders) { result.set(buf, pos); pos += buf.length; }
    result.set(eocd, pos);

    return result;
  }

  private buildLocalHeader(entry: ZipEntryData, nameBytes: Uint8Array): Uint8Array {
    const buf = new Uint8Array(30 + nameBytes.length);
    this.writeU32(buf, 0, 0x04034b50);
    this.writeU16(buf, 4, 20);
    this.writeU16(buf, 6, 0);
    this.writeU16(buf, 8, 0); // STORED
    this.writeU16(buf, 10, 0);
    this.writeU16(buf, 12, 0);
    this.writeU32(buf, 14, entry.crc32);
    this.writeU32(buf, 18, entry.data.length);
    this.writeU32(buf, 22, entry.data.length);
    this.writeU16(buf, 26, nameBytes.length);
    this.writeU16(buf, 28, 0);
    buf.set(nameBytes, 30);
    return buf;
  }

  private buildCentralHeader(entry: ZipEntryData, nameBytes: Uint8Array): Uint8Array {
    const buf = new Uint8Array(46 + nameBytes.length);
    this.writeU32(buf, 0, 0x02014b50);
    this.writeU16(buf, 4, 20);
    this.writeU16(buf, 6, 20);
    this.writeU16(buf, 8, 0);
    this.writeU16(buf, 10, 0); // STORED
    this.writeU16(buf, 12, 0);
    this.writeU16(buf, 14, 0);
    this.writeU32(buf, 16, entry.crc32);
    this.writeU32(buf, 20, entry.data.length);
    this.writeU32(buf, 24, entry.data.length);
    this.writeU16(buf, 28, nameBytes.length);
    this.writeU16(buf, 30, 0);
    this.writeU16(buf, 32, 0);
    this.writeU16(buf, 34, 0);
    this.writeU16(buf, 36, 0);
    this.writeU32(buf, 38, 0);
    this.writeU32(buf, 42, 0);
    buf.set(nameBytes, 46);
    return buf;
  }

  private buildEocd(totalEntries: number, centralDirSize: number, centralDirOffset: number): Uint8Array {
    const buf = new Uint8Array(22);
    this.writeU32(buf, 0, 0x06054b50);
    this.writeU16(buf, 4, 0);
    this.writeU16(buf, 6, 0);
    this.writeU16(buf, 8, totalEntries);
    this.writeU16(buf, 10, totalEntries);
    this.writeU32(buf, 12, centralDirSize);
    this.writeU32(buf, 16, centralDirOffset);
    this.writeU16(buf, 20, 0);
    return buf;
  }

  private calculateCrc32(data: Uint8Array): number {
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (let j = 0; j < 8; j++) {
        crc = (crc >>> 1) ^ (crc & 1 ? 0xEDB88320 : 0);
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  private writeU16(buf: Uint8Array, offset: number, value: number): void {
    buf[offset] = value & 0xFF;
    buf[offset + 1] = (value >>> 8) & 0xFF;
  }

  private writeU32(buf: Uint8Array, offset: number, value: number): void {
    buf[offset] = value & 0xFF;
    buf[offset + 1] = (value >>> 8) & 0xFF;
    buf[offset + 2] = (value >>> 16) & 0xFF;
    buf[offset + 3] = (value >>> 24) & 0xFF;
  }
}
