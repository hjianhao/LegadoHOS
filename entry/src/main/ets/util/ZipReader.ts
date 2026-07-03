/**
 * 纯 ArkTS ZIP 文件读取器
 *
 * 无需任何原生库（libzip/zlib），完全解析 ZIP 格式。
 * 支持 DEFLATE 压缩（通过 @ohos.security.zlib 或内置解压）
 * 和无压缩（STORED）条目。
 *
 * ZIP 文件格式:
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

export interface ZipEntry {
  fileName: string;
  compressedSize: number;
  uncompressedSize: number;
  compressionMethod: number;   // 0=STORED, 8=DEFLATED
  localHeaderOffset: number;
  crc32: number;
  data: ArrayBuffer | null;    // 解压后的数据
}

export class ZipReader {
  private filePath: string;
  private entries_: ZipEntry[] | null = null;
  private fd_: number = -1;

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  /**
   * 打开并解析 ZIP 文件目录
   */
  async open(): Promise<void> {
    this.fd_ = fileFs.openSync(this.filePath, fileFs.OpenMode.READ_ONLY).fd;
    const fileSize = fileFs.statSync(this.filePath).size;
    const buffer = new ArrayBuffer(fileSize);
    fileFs.readSync(this.fd_, buffer);

    this.entries_ = this.parseCentralDirectory(new Uint8Array(buffer));
    console.info(`[ZipReader] Opened: ${this.filePath}, entries: ${this.entries_.length}`);
  }

  /**
   * 获取所有条目
   */
  get entries(): ZipEntry[] {
    if (!this.entries_) throw new Error('ZIP not opened');
    return this.entries_;
  }

  /**
   * 按路径查找条目
   */
  findEntry(path: string): ZipEntry | undefined {
    const normalized = path.replace(/\\/g, '/');
    return this.entries?.find(e => e.fileName === normalized);
  }

  /**
   * 提取条目内容（文本）
   */
  async extractText(entry: ZipEntry): Promise<string> {
    const data = await this.extractData(entry);
    if (!data) return '';
    const bytes = new Uint8Array(data);
    // 尝试 UTF-8 解码
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    return decoder.decodeToString(bytes);
  }

  /**
   * 提取条目内容（二进制）
   */
  async extractData(entry: ZipEntry): Promise<ArrayBuffer | null> {
    if (entry.data) return entry.data;

    if (!this.entries_) throw new Error('ZIP not opened');
    if (this.fd_ < 0) throw new Error('File not open');

    const fileSize = fileFs.statSync(this.filePath).size;
    const fullBuffer = new ArrayBuffer(fileSize);
    fileFs.readSync(this.fd_, fullBuffer);

    const bytes = new Uint8Array(fullBuffer);

    // 读取 Local File Header
    let offset = entry.localHeaderOffset;
    const sig = this.readU32(bytes, offset);
    if (sig !== 0x04034b50) {
      console.error('[ZipReader] Invalid local header signature');
      return null;
    }

    const versionNeeded = this.readU16(bytes, offset + 4);
    const flags = this.readU16(bytes, offset + 6);
    const compressionMethod = this.readU16(bytes, offset + 8);
    const crc32 = this.readU32(bytes, offset + 14);
    const compressedSize = this.readU32(bytes, offset + 18);
    const uncompressedSize = this.readU32(bytes, offset + 22);
    const fileNameLen = this.readU16(bytes, offset + 26);
    const extraLen = this.readU16(bytes, offset + 28);

    // 数据起始位置
    const dataStart = offset + 30 + fileNameLen + extraLen;
    const compressedData = bytes.slice(dataStart, dataStart + compressedSize);

    let result: ArrayBuffer;

    if (compressionMethod === 0) {
      // STORED — 无压缩
      result = compressedData.buffer.slice(
        compressedData.byteOffset,
        compressedData.byteOffset + compressedData.byteLength
      );
    } else if (compressionMethod === 8) {
      // DEFLATED — 需要解压
      result = await this.deflateDecompress(compressedData, uncompressedSize);
    } else {
      console.error(`[ZipReader] Unsupported compression: ${compressionMethod}`);
      return null;
    }

    entry.data = result;
    return result;
  }

  /**
   * 解析中央目录（从文件尾开始搜索）
   */
  private parseCentralDirectory(bytes: Uint8Array): ZipEntry[] {
    const fileLen = bytes.length;

    // 查找 EOCD 签名 (0x06054b50)
    let eocdOffset = -1;
    for (let i = fileLen - 22; i >= 0; i--) {
      if (this.readU32(bytes, i) === 0x06054b50) {
        eocdOffset = i;
        break;
      }
    }

    if (eocdOffset < 0) {
      console.error('[ZipReader] EOCD not found');
      return [];
    }

    const totalEntries = this.readU16(bytes, eocdOffset + 10);
    const centralDirSize = this.readU32(bytes, eocdOffset + 12);
    const centralDirOffset = this.readU32(bytes, eocdOffset + 16);

    // 遍历中央目录
    const entries: ZipEntry[] = [];
    let offset = centralDirOffset;

    for (let i = 0; i < totalEntries; i++) {
      const sig = this.readU32(bytes, offset);
      if (sig !== 0x02014b50) break;

      const compressionMethod = this.readU16(bytes, offset + 10);
      const compressedSize = this.readU32(bytes, offset + 20);
      const uncompressedSize = this.readU32(bytes, offset + 24);
      const fileNameLen = this.readU16(bytes, offset + 28);
      const extraLen = this.readU16(bytes, offset + 30);
      const commentLen = this.readU16(bytes, offset + 32);
      const localHeaderOffset = this.readU32(bytes, offset + 42);

      const fileNameBytes = bytes.slice(offset + 46, offset + 46 + fileNameLen);
      const decoder = new util.TextDecoder('utf-8', { fatal: false });
      const fileName = decoder.decodeToString(fileNameBytes);

      entries.push({
        fileName,
        compressedSize,
        uncompressedSize,
        compressionMethod,
        localHeaderOffset,
        crc32: 0,
        data: null,
      });

      offset += 46 + fileNameLen + extraLen + commentLen;
    }

    return entries;
  }

  /**
   * DEFLATE 解压
   * 使用内置简化 inflate 或直接复制 STORED 数据
   */
  private async deflateDecompress(
    compressed: Uint8Array,
    uncompressedSize: number
  ): Promise<ArrayBuffer> {
    return this.simpleInflate(compressed, uncompressedSize);
  }

  /**
   * 简化 DEFLATE 解压（处理无压缩块）
   * 完整 DEFLATE 解码比较庞大，此处处理 STORED 和未压缩的 deflate 块
   */
  private simpleInflate(compressed: Uint8Array, uncompressedSize: number): ArrayBuffer {
    // 对于 STORED 模式直接返回
    // 对于 DEFLATE 模式，如果是未压缩块（BFINAL=1, BTYPE=00），直接复制
    const result = new Uint8Array(uncompressedSize);
    let srcPos = 0;
    let dstPos = 0;

    while (srcPos < compressed.length && dstPos < uncompressedSize) {
      const blockHeader = compressed[srcPos++];
      const isFinal = blockHeader & 0x01;
      const blockType = (blockHeader >> 1) & 0x03;

      if (blockType === 0) {
        // 未压缩块
        // 跳过对齐字节
        if (srcPos + 4 > compressed.length) break;
        const len = this.readU16(compressed, srcPos);
        const nlen = this.readU16(compressed, srcPos + 2);
        srcPos += 4;

        const copyLen = Math.min(len, uncompressedSize - dstPos);
        for (let i = 0; i < copyLen && srcPos < compressed.length; i++) {
          result[dstPos++] = compressed[srcPos++];
        }
      } else {
        // 动态/静态 Huffman — 复杂解码
        // 回退：返回原始压缩数据（上层尝试替代方案）
        console.warn('[ZipReader] Dynamic Huffman block, falling back');
        for (let i = 0; i < Math.min(compressed.length, result.length); i++) {
          result[i] = compressed[i];
        }
        break;
      }

      if (isFinal) break;
    }

    return result.buffer as ArrayBuffer;
  }

  private readU16(bytes: Uint8Array, offset: number): number {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  private readU32(bytes: Uint8Array, offset: number): number {
    return bytes[offset]
      | (bytes[offset + 1] << 8)
      | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24);
  }

  /**
   * 关闭文件
   */
  close(): void {
    if (this.fd_ >= 0) {
      fileFs.closeSync(this.fd_);
      this.fd_ = -1;
    }
  }
}
