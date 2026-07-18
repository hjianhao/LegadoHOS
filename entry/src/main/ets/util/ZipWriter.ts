/**
 * 最小 ZIP 写入器（STORED 不压缩）
 *
 * 为 EPUB 导出设计：
 * - 条目顺序完全可控（epub 规范要求 mimetype 为第一个条目且不压缩）
 * - @ohos.zlib 只有 compressFile（整包压缩），无法控制条目顺序与单条目压缩方式，
 *   也没有 buffer 级 raw-deflate API，因此 v1 全部条目 STORED（规范合法，体积略大）。
 *   后续若引入 pako/fflate 可在 addEntry 内补充 DEFLATE。
 */
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';

interface ZipEntryRecord {
  nameBytes: Uint8Array;
  crc32: number;
  size: number;
  offset: number;
  dosTime: number;
  dosDate: number;
}

export class ZipWriter {
  private fd_: number;
  private entries_: ZipEntryRecord[] = [];
  private offset_: number = 0;
  private closed_: boolean = false;
  private encoder_: util.TextEncoder = new util.TextEncoder();

  private constructor(fd: number) {
    this.fd_ = fd;
  }

  /** 打开目标文件（会清空已有内容） */
  static open(path: string): ZipWriter {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    return new ZipWriter(file.fd);
  }

  /** 添加文本条目（UTF-8 编码，STORED） */
  async addText(name: string, text: string): Promise<void> {
    await this.addStored(name, this.encoder_.encodeInto(text));
  }

  /** 添加二进制条目（STORED） */
  async addStored(name: string, data: Uint8Array): Promise<void> {
    if (this.closed_) throw new Error('ZipWriter already closed');
    const nameBytes = this.encoder_.encodeInto(name);
    const crc = ZipWriter.crc32(data);
    const now = new Date();
    const dosTime = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
    const dosDate = (((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate()) & 0xFFFF;

    // Local file header（30 字节定长 + 文件名）
    const header = new Uint8Array(30);
    const v = new DataView(header.buffer);
    v.setUint32(0, 0x04034B50, true);   // local file header signature
    v.setUint16(4, 20, true);           // version needed to extract
    v.setUint16(6, 0x0800, true);       // flags: bit 11 = UTF-8 文件名
    v.setUint16(8, 0, true);            // method: 0 = STORED
    v.setUint16(10, dosTime, true);
    v.setUint16(12, dosDate, true);
    v.setUint32(14, crc, true);
    v.setUint32(18, data.length, true); // compressed size
    v.setUint32(22, data.length, true); // uncompressed size
    v.setUint16(26, nameBytes.length, true);
    v.setUint16(28, 0, true);           // extra field length
    this.writeBytes_(header);
    this.writeBytes_(nameBytes);
    this.writeBytes_(data);

    this.entries_.push({
      nameBytes: nameBytes, crc32: crc, size: data.length,
      offset: this.offset_, dosTime: dosTime, dosDate: dosDate,
    });
    this.offset_ += 30 + nameBytes.length + data.length;
  }

  /** 写中央目录与结尾记录，关闭文件 */
  async finish(): Promise<void> {
    if (this.closed_) return;
    const cdStart = this.offset_;

    for (const e of this.entries_) {
      const rec = new Uint8Array(46);
      const v = new DataView(rec.buffer);
      v.setUint32(0, 0x02014B50, true);  // central file header signature
      v.setUint16(4, 20, true);          // version made by
      v.setUint16(6, 20, true);          // version needed
      v.setUint16(8, 0x0800, true);      // flags: UTF-8
      v.setUint16(10, 0, true);          // method: STORED
      v.setUint16(12, e.dosTime, true);
      v.setUint16(14, e.dosDate, true);
      v.setUint32(16, e.crc32, true);
      v.setUint32(20, e.size, true);     // compressed size
      v.setUint32(24, e.size, true);     // uncompressed size
      v.setUint16(28, e.nameBytes.length, true);
      // 30: extra len(2) / comment len(2) / disk(2) / int attr(2) 全 0
      v.setUint32(38, 0, true);          // external attributes
      v.setUint32(42, e.offset, true);   // local header 偏移
      this.writeBytes_(rec);
      this.writeBytes_(e.nameBytes);
      this.offset_ += 46 + e.nameBytes.length;
    }

    const cdSize = this.offset_ - cdStart;
    const eocd = new Uint8Array(22);
    const ev = new DataView(eocd.buffer);
    ev.setUint32(0, 0x06054B50, true);   // end of central dir signature
    // 4..7: disk 编号与中央目录所在盘，均 0
    ev.setUint16(8, this.entries_.length, true);
    ev.setUint16(10, this.entries_.length, true);
    ev.setUint32(12, cdSize, true);
    ev.setUint32(16, cdStart, true);
    ev.setUint16(20, 0, true);           // comment length
    this.writeBytes_(eocd);

    this.closed_ = true;
    fileIo.closeSync(this.fd_);
  }

  /** 异常路径上也尽量关闭文件 */
  abort(): void {
    if (this.closed_) return;
    this.closed_ = true;
    try { fileIo.closeSync(this.fd_); } catch (_e) {}
  }

  private writeBytes_(data: Uint8Array): void {
    const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    fileIo.writeSync(this.fd_, buf);
  }

  // ============================================================
  // CRC32（ZIP 标准多项式 0xEDB88320）
  // ============================================================
  private static crcTable_: Uint32Array | null = null;

  private static crc32(data: Uint8Array): number {
    if (!ZipWriter.crcTable_) {
      const table = new Uint32Array(256);
      for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) {
          c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        }
        table[n] = c >>> 0;
      }
      ZipWriter.crcTable_ = table;
    }
    const table = ZipWriter.crcTable_;
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < data.length; i++) {
      crc = (crc >>> 8) ^ table[(crc ^ data[i]) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}
