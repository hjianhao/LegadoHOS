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

/** 可由 .ets 调用方注入的后台 CRC32 实现。 */
export type ZipCrc32Provider = (input: ArrayBuffer) => Promise<number>;

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
  /** 当前输出路径；异常退出时用于删除本次新建的半成品。 */
  private path_: string;
  /** 只有目标文件原本不存在时才删除，避免覆盖已有文件失败后误删用户原文件。 */
  private removeOnAbort_: boolean;
  private entries_: ZipEntryRecord[] = [];
  private offset_: number = 0;
  private closed_: boolean = false;
  private encoder_: util.TextEncoder = new util.TextEncoder();
  private static crc32Provider_: ZipCrc32Provider | null = null;

  private constructor(fd: number, path: string, removeOnAbort: boolean) {
    this.fd_ = fd;
    this.path_ = path;
    this.removeOnAbort_ = removeOnAbort;
  }

  /** 打开目标文件（会清空已有内容）；覆盖既有 URI 时不要再次请求 CREATE。 */
  static open(path: string, overwriteExisting: boolean = false): ZipWriter {
    let file: fileIo.File;
    // 先探测目标是否已经存在。即使调用方未要求覆盖，也不要在异常路径上
    // 把一个竞态出现的既有文件误删掉。
    let targetExisted: boolean = false;
    try {
      const probe = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      targetExisted = true;
      fileIo.closeSync(probe);
    } catch (_e) { /* 新文件或文件提供方不支持探测，继续按创建流程处理 */ }
    if (overwriteExisting) {
      try {
        // 已确认存在的 URI 不带 CREATE，避免文件提供方再次报重名。
        file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        targetExisted = true;
      } catch (_e) {
        // 拆分导出时有些分卷尚不存在：覆盖模式只对已有分卷生效，
        // 新分卷需要回退到 CREATE。
        file = fileIo.openSync(path,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      }
    } else {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    }
    // 新建目标在写入中途失败时是无效半成品，应立即删除；覆盖既有文件时
    // 无法在这里恢复原内容，保留目标比误删用户原文件更安全。
    return new ZipWriter(file.fd, path, !targetExisted);
  }

  /**
   * 注入后台 CRC32 实现。ArkTS 的 @Concurrent 函数只能从 .ets 调用方传入，
   * 因此 ZipWriter 保持可被 .ts 使用，同时由导出服务启用 TaskPool 加速。
   */
  static setCrc32Provider(provider: ZipCrc32Provider | null): void {
    ZipWriter.crc32Provider_ = provider;
  }

  /** 添加文本条目（UTF-8 编码，STORED） */
  async addText(name: string, text: string): Promise<void> {
    await this.addStored(name, this.encoder_.encodeInto(text));
  }

  /** 添加二进制条目（STORED） */
  async addStored(name: string, data: Uint8Array): Promise<void> {
    if (this.closed_) throw new Error('ZipWriter already closed');
    const nameBytes = this.encoder_.encodeInto(name);
    // 图片条目可能很大；CRC32 逐字节计算必须放到 TaskPool，否则会长时间阻塞
    // ArkUI 主线程并触发 THREAD_BLOCK_6S。任务使用副本并转移副本所有权，保留
    // 原始 data 给后续文件写入。
    const crc = await ZipWriter.crc32Async_(data);
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
    if (this.removeOnAbort_) {
      try {
        fileIo.unlinkSync(this.path_);
        console.warn('[ZipWriter] removed incomplete output:', this.path_);
      } catch (_e) { /* 文件提供方可能不允许删除，忽略并保留原错误 */ }
    }
  }

  private writeBytes_(data: Uint8Array): void {
    // readCachedImage / TaskPool 返回的图片通常已经是完整 ArrayBuffer。
    // 仅在带 offset 或共享更大 buffer 的视图上做 slice，避免每张图片写入
    // ZIP 前再复制一次完整 payload。
    const isFullBuffer: boolean = data.byteOffset === 0 && data.byteLength === data.buffer.byteLength;
    const buf: ArrayBuffer = isFullBuffer
      ? data.buffer as ArrayBuffer
      : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    fileIo.writeSync(this.fd_, buf);
  }

  // ============================================================
  // CRC32（ZIP 标准多项式 0xEDB88320）
  // ============================================================

  private static async crc32Async_(data: Uint8Array): Promise<number> {
    const provider = ZipWriter.crc32Provider_;
    if (provider) {
      const input: ArrayBuffer = data.buffer.slice(
        data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
      try {
        // 只把副本交给 provider，原始 data 仍需在主线程写入 ZIP。
        return await provider(input);
      } catch (e) {
        console.warn('[ZipWriter] CRC provider unavailable, using yielding fallback:',
          (e as Error).message || String(e));
      }
    }
    // 没有 provider（例如直接使用 EpubBuilder）或 TaskPool 失败时，分块计算并主动
    // 让出事件循环，确保大图片不会再次触发主线程看门狗。
    return await ZipWriter.crc32Yielding_(data);
  }

  private static async crc32Yielding_(data: Uint8Array): Promise<number> {
    const table: Uint32Array = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c: number = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c >>> 0;
    }
    let crc: number = 0xFFFFFFFF;
    const chunkSize: number = 16 * 1024;
    for (let start = 0; start < data.length; start += chunkSize) {
      const end: number = Math.min(data.length, start + chunkSize);
      for (let i = start; i < end; i++) {
        crc = (crc >>> 8) ^ table[(crc ^ data[i]) & 0xFF];
      }
      if (end < data.length) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}
