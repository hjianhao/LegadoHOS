/**
 * 纯 ArkTS ZIP 文件读取器
 *
 * 使用 @ohos.zlib 进行 DEFLATE 解压，支持 STORED 和 DEFLATED 条目。
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
import zlib from '@ohos.zlib';

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
  private fileBytes_: Uint8Array | null = null;  // 缓存整个文件，避免重复读取

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
    this.fileBytes_ = new Uint8Array(buffer);
    this.entries_ = this.parseCentralDirectory(this.fileBytes_);
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

    if (!this.fileBytes_) throw new Error('ZIP not opened');

    const bytes = this.fileBytes_;

      // 读取 Local File Header（仅用于获取数据偏移量）
      let offset = entry.localHeaderOffset;
      const sig = this.readU32(bytes, offset);
      if (sig !== 0x04034b50) {
        console.error('[ZipReader] Invalid local header signature at offset', offset);
        return null;
      }

      const flags = this.readU16(bytes, offset + 6);
      const compressionMethod = this.readU16(bytes, offset + 8);
      const fileNameLen = this.readU16(bytes, offset + 26);
      const extraLen = this.readU16(bytes, offset + 28);

      // 始终使用 central directory 的尺寸值（local header 因 Data Descriptor 可能为 0）
      let compressedSize = entry.compressedSize;
      let uncompressedSize = entry.uncompressedSize;

      if ((flags & 0x08) !== 0) {
        console.info('[ZipReader] Data descriptor for:', entry.fileName);
      }

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
        // DEFLATED — 使用系统 @ohos.zlib 原生解压（比纯 JS 快 50~100 倍）
        try {
          const decompressed = await inflateRawDataNative(compressedData, uncompressedSize);
          result = decompressed.buffer as ArrayBuffer;
        } catch (_e) {
          // 降级到纯 JS 实现
          console.warn('[ZipReader] native inflate failed, fallback to JS');
          result = inflateRawData(compressedData, uncompressedSize).buffer as ArrayBuffer;
        }
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
    // 容错：若 EOCD 中的 centralDirOffset 损坏，从 EOCD 位置反推
    let centralDirOffset = this.readU32(bytes, eocdOffset + 16);
    const calculatedOffset = eocdOffset - centralDirSize;
    if (centralDirOffset < 0 || centralDirOffset > fileLen || centralDirOffset + centralDirSize !== eocdOffset) {
      centralDirOffset = calculatedOffset;
    }
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
   * 将所有条目解压到目标目录
   * 每 10 条 yield 一次让 UI 线程处理事件，避免 ANR
   */
  async extractAll(targetDir: string): Promise<void> {
    if (!this.entries_) throw new Error('ZIP not opened');
    if (!fileFs.accessSync(targetDir)) {
      fileFs.mkdirSync(targetDir, true);
    }
    for (let i = 0; i < this.entries_.length; i++) {
      const entry = this.entries_[i];
      // 跳过目录条目（文件名以 / 结尾或尺寸为 0 的空条目）
      if (entry.fileName.endsWith('/') || entry.uncompressedSize === 0) {
        continue;
      }
      // 每 10 条让出 UI 线程，避免主线程长时间阻塞导致 ANR
      if (i > 0 && i % 10 === 0) {
        await new Promise<void>(r => setTimeout(r, 0));
      }
      const filePath = targetDir + '/' + entry.fileName;
      const dir = filePath.substring(0, filePath.lastIndexOf('/'));
      if (!fileFs.accessSync(dir)) {
        fileFs.mkdirSync(dir, true);
      }
      const data = await this.extractData(entry);
      // 空缓冲区会导致 fileFs.writeSync 报 "Illegal write buffer" 错误
      if (data && data.byteLength > 0) {
        const fd = fileFs.openSync(filePath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
        try {
          fileFs.writeSync(fd.fd, data);
        } finally {
          fileFs.closeSync(fd);
        }
      }
    }
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

// ==================== DEFLATE 解压 — 纯 ArkTS 实现 ====================
//
// 支持所有 DEFLATE block 类型:
// - BTYPE=00: 无压缩存储
// - BTYPE=01: 静态 Huffman
// - BTYPE=10: 动态 Huffman
// - LZ77 长度/距离回引
class BitReader {
  private data: Uint8Array;
  private pos: number = 0;
  private bits: number = 0;
  private bitsCount: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  /** 读取 1 位 */
  readBit(): number {
    if (this.bitsCount === 0) {
      this.bits = this.pos < this.data.length ? this.data[this.pos++] : 0;
      this.bitsCount = 8;
    }
    this.bitsCount--;
    return (this.bits >> (7 - this.bitsCount)) & 1;
  }

  /** 读取 n 位（LSB 优先） */
  readBits(n: number): number {
    let val = 0;
    for (let i = 0; i < n; i++) {
      val |= this.readBit() << i;
    }
    return val;
  }

  /** 读取 n 位（MSB 优先，用于 Huffman 解码） */
  peekBits(n: number): number {
    // 确保有 n 位可用
    while (this.bitsCount < n) {
      this.bits = (this.bits << 8) | (this.pos < this.data.length ? this.data[this.pos++] : 0);
      this.bitsCount += 8;
    }
    return (this.bits >>> (this.bitsCount - n)) & ((1 << n) - 1);
  }

  /** 消费 n 位 */
  skipBits(n: number): void {
    this.bitsCount -= n;
    if (this.bitsCount < 0) this.bitsCount = 0;
  }

  /** 对齐到字节边界 */
  toByteAligned(): void {
    this.bitsCount = 0;
  }

  /** 读取一个 Huffman 编码符号 */
  readHuffmanSymbol(tree: HuffmanTree): number {
    let code = 0;
    let len = 0;
    const maxLen = Math.min(tree.maxBits, 24);
    while (len < maxLen) {
      const bit = this.readBit();
      code = (code << 1) | bit;
      len++;
      const sym = tree.lookup(code, len);
      if (sym >= 0) return sym;
    }
    throw new Error('Bad Huffman code');
  }

  get position(): number { return this.pos; }
  get remaining(): number { return this.data.length - this.pos; }
}

/**
 * Huffman 树 — 用查找表加速解码
 */
class HuffmanTree {
  private table: Map<number, number> = new Map();  // (code << 5) | len → symbol
  maxBits: number = 0;

  /**
   * 从码长数组构建 Huffman 树
   * @param codeLengths 长度为 symbols 的数组，codeLengths[sym] = 码长（0 表示未使用）
   */
  constructor(codeLengths: number[]) {
    // 统计每个码长的数量
    const maxLen = Math.max(...codeLengths);
    this.maxBits = maxLen;

    // 计算每个码长的起始编码值 (RFC 1951)
    const blCount: number[] = new Array(maxLen + 1).fill(0);
    for (const len of codeLengths) {
      if (len > 0) blCount[len]++;
    }

    let code = 0;
    const nextCode: number[] = new Array(maxLen + 1).fill(0);
    for (let bits = 1; bits <= maxLen; bits++) {
      code = (code + (blCount[bits - 1] || 0)) << 1;
      nextCode[bits] = code;
    }

    // 构建查找表
    for (let sym = 0; sym < codeLengths.length; sym++) {
      const len = codeLengths[sym];
      if (len === 0) continue;
      if (len > 24) continue; // safety limit
      const c = nextCode[len]++;
      // 存储编码: key 用 (code << 5) | len
      this.table.set((c << 5) | len, sym);
    }
  }

  /** 查找给定编码对应的符号，未找到返回 -1 */
  lookup(code: number, len: number): number {
    const val = this.table.get((code << 5) | len);
    return val !== undefined ? val : -1;
  }
}

/** 长度表： [base, extraBits] */
const LENGTH_TABLE: Array<[number, number]> = [
  [3, 0], [4, 0], [5, 0], [6, 0], [7, 0], [8, 0], [9, 0], [10, 0],
  [11, 1], [13, 1], [15, 1], [17, 1],
  [19, 2], [23, 2], [27, 2], [31, 2],
  [35, 3], [43, 3], [51, 3], [59, 3],
  [67, 4], [83, 4], [99, 4], [115, 4],
  [131, 5], [163, 5], [195, 5], [227, 5],
  [258, 0], [258, 0], [258, 0], [258, 0],
];

/** 距离表： [base, extraBits] */
const DIST_TABLE: Array<[number, number]> = [
  [1, 0], [2, 0], [3, 0], [4, 0],
  [5, 1], [7, 1],
  [9, 2], [13, 2],
  [17, 3], [25, 3],
  [33, 4], [49, 4],
  [65, 5], [97, 5],
  [129, 6], [193, 6],
  [257, 7], [385, 7],
  [513, 8], [769, 8],
  [1025, 9], [1537, 9],
  [2049, 10], [3073, 10],
  [4097, 11], [6145, 11],
  [8193, 12], [12289, 12],
  [16385, 13], [24577, 13],
];

/**
 * 使用系统 @ohos.zlib 解压 raw DEFLATE 数据（比纯 JS 实现快 50~100 倍）
 */
async function inflateRawDataNative(compressed: Uint8Array, uncompressedSize: number): Promise<Uint8Array> {
  const zip = await zlib.createZip();
  const input = compressed.buffer.slice(compressed.byteOffset, compressed.byteOffset + compressed.byteLength);
  // 初始输出缓冲区：取 uncompressedSize（已知）或 4 倍压缩大小
  let outputSize = Math.max(uncompressedSize || compressed.length * 4, 64 * 1024);
  const maxAttempts = 5;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const output = new ArrayBuffer(outputSize);
    const strm: zlib.ZStream = {
      nextIn: input,
      availableIn: compressed.byteLength,
      nextOut: output,
      availableOut: outputSize,
    };
    const initStatus = await zip.inflateInit2(strm, -15); // -15 = raw DEFLATE (无 zlib 头)
    if (initStatus !== zlib.ReturnStatus.OK) {
      throw new Error('inflateInit2 failed: ' + initStatus);
    }
    const status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
    await zip.inflateEnd(strm);
    if (status === zlib.ReturnStatus.STREAM_END || status === zlib.ReturnStatus.OK) {
      const totalOut = strm.totalOut || 0;
      return new Uint8Array(output.slice(0, totalOut));
    }
    if (status === zlib.ReturnStatus.BUF_ERROR) {
      outputSize *= 2;
      continue;
    }
    throw new Error('inflate status: ' + status + ' totalOut=' + (strm.totalOut || 0));
  }
  throw new Error('inflate: BUF_ERROR after ' + maxAttempts + ' attempts');
}

/**
 * 解压一条 raw DEFLATE 数据流（纯 JS 实现，兜底用）
 */
function inflateRawData(compressed: Uint8Array, uncompressedSize: number): Uint8Array {
  const reader = new BitReader(compressed);
  const output: number[] = [];

  // 静态 Huffman 树的码长
  const staticLitLen: number[] = new Array(288);
  for (let i = 0; i <= 143; i++) staticLitLen[i] = 8;
  for (let i = 144; i <= 255; i++) staticLitLen[i] = 9;
  for (let i = 256; i <= 279; i++) staticLitLen[i] = 7;
  for (let i = 280; i <= 287; i++) staticLitLen[i] = 8;

  const staticDist: number[] = new Array(32).fill(5);

  let isFinal = false;
  while (!isFinal) {
    // 块头
    isFinal = reader.readBit() === 1;
    const blockType = reader.readBits(2);

    if (blockType === 0) {
      // BTYPE=00: 无压缩存储
      reader.toByteAligned();
      const len = reader.readBits(16);
      /* const nlen = */ reader.readBits(16); // one's complement, skip
      for (let i = 0; i < len && reader.remaining > 0; i++) {
        output.push(reader.readBits(8));
      }
    } else if (blockType === 1 || blockType === 2) {
      // BTYPE=01: 静态 Huffman, BTYPE=10: 动态 Huffman
      let litLenTree: HuffmanTree;
      let distTree: HuffmanTree;

      if (blockType === 1) {
        litLenTree = new HuffmanTree(staticLitLen);
        distTree = new HuffmanTree(staticDist);
      } else {
        // 动态 Huffman: 读取码长编码
        const hlit = reader.readBits(5) + 257;   // 字面/长度码数量
        const hdist = reader.readBits(5) + 1;    // 距离码数量
        const hclen = reader.readBits(4) + 4;    // 码长编码表长度

        // 码长编码的符号顺序
        const clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
        const clLengths: number[] = new Array(19).fill(0);
        for (let i = 0; i < hclen; i++) {
          clLengths[clOrder[i]] = reader.readBits(3);
        }

        const clTree = new HuffmanTree(clLengths);

        // 用码长树解码实际的 litLen + dist 码长
        const allLengths: number[] = [];
        while (allLengths.length < hlit + hdist) {
          const sym = reader.readHuffmanSymbol(clTree);
          if (sym < 16) {
            allLengths.push(sym);
          } else if (sym === 16) {
            // 重复上一个码长 3-6 次
            const repeat = reader.readBits(2) + 3;
            const last = allLengths.length > 0 ? allLengths[allLengths.length - 1] : 0;
            for (let j = 0; j < repeat && allLengths.length < hlit + hdist; j++) {
              allLengths.push(last);
            }
          } else if (sym === 17) {
            // 重复 0 长度 3-10 次
            const repeat = reader.readBits(3) + 3;
            for (let j = 0; j < repeat && allLengths.length < hlit + hdist; j++) {
              allLengths.push(0);
            }
          } else if (sym === 18) {
            // 重复 0 长度 11-138 次
            const repeat = reader.readBits(7) + 11;
            for (let j = 0; j < repeat && allLengths.length < hlit + hdist; j++) {
              allLengths.push(0);
            }
          }
        }

        litLenTree = new HuffmanTree(allLengths.slice(0, hlit));
        distTree = new HuffmanTree(allLengths.slice(hlit, hlit + hdist));
      }

      // 解压块内容
      while (true) {
        const sym = reader.readHuffmanSymbol(litLenTree);
        if (sym < 256) {
          output.push(sym);
        } else if (sym === 256) {
          break; // 块结束
        } else {
          // 长度/距离回引
          const lenIdx = sym - 257;
          const [baseLen, extraLenBits] = LENGTH_TABLE[lenIdx] || [0, 0];
          let length = baseLen + (extraLenBits > 0 ? reader.readBits(extraLenBits) : 0);

          const distSym = reader.readHuffmanSymbol(distTree);
          const [baseDist, extraDistBits] = DIST_TABLE[distSym] || [0, 0];
          let distance = baseDist + (extraDistBits > 0 ? reader.readBits(extraDistBits) : 0);

          if (distance === 0) {
            throw new Error('Invalid zero distance');
          }

          // LZ77 复制
          const start = output.length - distance;
          for (let i = 0; i < length; i++) {
            output.push(output[start + i]);
          }
        }
      }
    } else {
      throw new Error('Invalid block type: 3 (reserved)');
    }
  }

  return new Uint8Array(output);
}
