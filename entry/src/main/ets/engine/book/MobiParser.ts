/**
 * MOBI 格式解析器 — 纯 ArkTS 实现
 *
 * MOBI 格式基于 PDB (Palm Database) 容器:
 * ┌──────────────────────┐
 * │ PDB Header (78 bytes)│ ← 数据库名、创建时间、记录数
 * ├──────────────────────┤
 * │ Record Info[0] (8B)  │ ← 每条记录的偏移
 * │ Record Info[1] (8B)  │
 * │ ...                  │
 * ├──────────────────────┤
 * │ Record 0: MOBI Header│ ← MOBI 文件头 + EXTH
 * │ Record 1: PalmDoc    │ ← 压缩的文本数据
 * │ Record 2: ...        │ ← 更多文本记录
 * │ ...                  │
 * │ Record N: INDX       │ ← 索引（可选）
 * └──────────────────────┘
 *
 * PalmDoc 压缩算法：
 * - 0x01-0x08: 回退拷贝 (1-8 字节)
 * - 0x09-0x7F: 字面字符
 * - 0x80-0xFF: 空格 + (byte & 0x7F) 个空格
 */
import { BookChapter } from '../../model/BookChapter';
import fileFs from '@ohos.file.fs';

const PDB_HEADER_SIZE = 78;
const RECORD_INFO_SIZE = 8;

export interface MobiMeta {
  title: string;
  author: string;
  isbn: string;
  publisher: string;
  description: string;
  coverOffset: number;
  coverSize: number;
}

export class MobiParser {
  private filePath: string;
  private meta_: MobiMeta = { title: '', author: '', isbn: '', publisher: '', description: '', coverOffset: 0, coverSize: 0 };
  private chapters_: BookChapter[] = [];

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  async parse(): Promise<{ meta: MobiMeta; chapters: BookChapter[] }> {
    const buffer = fileFs.readSync(fileFs.openSync(this.filePath, fileFs.OpenMode.READ_ONLY).fd);
    const bytes = new Uint8Array(buffer);

    if (bytes.length < PDB_HEADER_SIZE) throw new Error('Invalid MOBI: file too small');

    // 1. 解析 PDB Header
    const pdbName = new TextDecoder('ascii').decode(bytes.slice(0, 32)).replace(/\0/g, '').trim();
    const numRecords = this.readU16(bytes, 76);

    if (numRecords < 1) throw new Error('Invalid MOBI: no records');

    // 2. 解析 Record Info
    const recordOffsets: number[] = [];
    const recordLengths: number[] = [];
    for (let i = 0; i < numRecords; i++) {
      const offset = PDB_HEADER_SIZE + i * RECORD_INFO_SIZE;
      recordOffsets.push(this.readU32(bytes, offset));
      const uniqueID = this.readU32(bytes, offset + 4);
      // 下一条记录的偏移减去当前就是长度
    }

    // 计算记录长度
    for (let i = 0; i < numRecords; i++) {
      if (i + 1 < numRecords) {
        recordLengths.push(recordOffsets[i + 1] - recordOffsets[i]);
      } else {
        recordLengths.push(bytes.length - recordOffsets[i]);
      }
    }

    // 3. 解析 MOBI Header (Record 0)
    const mobiOffset = recordOffsets[0];
    const mobiSig = this.readAscii(bytes, mobiOffset, 4);
    if (mobiSig !== 'MOBI') throw new Error('Invalid MOBI header');

    const mobiHeaderLen = this.readU32(bytes, mobiOffset + 20);
    const mobiType = this.readU32(bytes, mobiOffset + 4);
    const encoding = this.readU32(bytes, mobiOffset + 12); // 1252=CP1252, 65001=UTF-8
    const titleOffset = this.readU32(bytes, mobiOffset + 84);
    const titleLen = this.readU32(bytes, mobiOffset + 88);

    // 标题
    if (titleOffset > 0 && titleLen > 0) {
      const titleStart = mobiOffset + titleOffset;
      this.meta_.title = this.decodeText(bytes.slice(titleStart, titleStart + titleLen), encoding);
    } else {
      this.meta_.title = pdbName;
    }

    // 4. 解析 EXTH Header (扩展头)
    const exthOffset = mobiOffset + mobiHeaderLen;
    if (this.readAscii(bytes, exthOffset, 4) === 'EXTH') {
      const exthLen = this.readU32(bytes, exthOffset + 4);
      const exthRecordCount = this.readU32(bytes, exthOffset + 8);

      let exthPos = exthOffset + 12;
      for (let i = 0; i < exthRecordCount && exthPos < bytes.length; i++) {
        const exthType = this.readU32(bytes, exthPos);
        const exthRecLen = this.readU32(bytes, exthPos + 4);
        const exthData = bytes.slice(exthPos + 8, exthPos + exthRecLen);

        switch (exthType) {
          case 100: this.meta_.author = this.decodeText(exthData, encoding); break;
          case 104: this.meta_.publisher = this.decodeText(exthData, encoding); break;
          case 105: this.meta_.description = this.decodeText(exthData, encoding); break;
          case 106: this.meta_.isbn = this.decodeText(exthData, encoding); break;
          case 201: this.meta_.coverOffset = this.readU32(exthData, 0); break;
          case 202: this.meta_.coverSize = this.readU32(exthData, 0); break;
        }

        exthPos += exthRecLen;
      }
    }

    // 5. 解压 PalmDoc 文本记录
    const textStartRecord = 1; // Record 1 开始是文本
    let fullText = '';
    let firstChapter = true;

    for (let i = textStartRecord; i < numRecords; i++) {
      const recData = bytes.slice(recordOffsets[i], recordOffsets[i] + recordLengths[i]);
      const decompressed = this.decompressPalmDoc(recData);
      const text = this.decodeText(decompressed, encoding);

      if (firstChapter) {
        // 第一个记录通常有完整的文本
        fullText = text;
        firstChapter = false;
      } else {
        fullText += '\n' + text;
      }
    }

    // 6. 分章（根据 MOBI 索引或文本中的章节标记）
    this.chapters_ = this.splitChapters(fullText);

    console.info(`[MOBI] Parsed: ${this.meta_.title}, ${this.chapters_.length} chapters`);

    return { meta: this.meta_, chapters: this.chapters_ };
  }

  /**
   * PalmDoc 解压缩
   *
   * 算法:
   * - 0x00: 字面量 0x00
   * - 0x01-0x08: 回退 N 字节 (1-8)
   * - 0x09-0x7F: 字面量
   * - 0x80-0xBF: 字面量 (80-BF)
   * - 0xC0-0xFF: (byte & 0x3F) 个空格
   */
  private decompressPalmDoc(data: Uint8Array): Uint8Array {
    const result: number[] = [];
    let i = 0;

    while (i < data.length) {
      const b = data[i++];

      if (b === 0) {
        result.push(0);
      } else if (b >= 1 && b <= 8) {
        // 回退拷贝: 拷贝前 b 字节
        const count = b;
        const start = result.length - count;
        for (let j = 0; j < count; j++) {
          if (start + j >= 0) result.push(result[start + j]);
          else result.push(0x20);
        }
      } else if (b >= 0x09 && b <= 0x7F) {
        result.push(b);
      } else if (b >= 0x80 && b <= 0xBF) {
        result.push(b);
      } else {
        // 0xC0-0xFF: 空格压缩
        const spaceCount = b & 0x3F;
        for (let j = 0; j < spaceCount; j++) result.push(0x20);
      }
    }

    return new Uint8Array(result);
  }

  /**
   * 按分章标记分割文本
   */
  private splitChapters(text: string): BookChapter[] {
    const chapters: BookChapter[] = [];
    const now = Date.now();

    // 尝试检测章节标记
    const chapterRegex = /^(?:第\s*[零一二三四五六七八九十百千万亿两0-9]+\s*[章节卷回篇部集]|Chapter\s+\d+|Part\s+\d+)/im;
    const lines = text.split('\n');
    let currentLines: string[] = [];
    let chapIndex = 0;
    let chapTitle = '前言';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) { currentLines.push(line); continue; }

      if (chapterRegex.test(trimmed)) {
        if (currentLines.length > 0) {
          chapters.push(this.makeChapter(chapIndex++, chapTitle, currentLines, now));
          currentLines = [];
        }
        chapTitle = trimmed;
        continue;
      }

      // 也检测 <h1>-<h6> HTML 标记
      const htmlHeader = line.match(/<[hH]([1-6])[^>]*>([^<]+)<\/[hH]\1>/);
      if (htmlHeader) {
        if (currentLines.length > 0) {
          chapters.push(this.makeChapter(chapIndex++, chapTitle, currentLines, now));
          currentLines = [];
        }
        chapTitle = htmlHeader[2].trim();
        continue;
      }

      currentLines.push(line);
    }

    // 最后一章
    if (currentLines.length > 0) {
      chapters.push(this.makeChapter(chapIndex++, chapTitle, currentLines, now));
    }

    return chapters;
  }

  private makeChapter(index: number, title: string, lines: string[], now: number): BookChapter {
    const content = lines.join('\n').trim();
    return {
      id: 0, bookId: 0, index, volumeIndex: 0,
      title, url: '', content,
      contentLength: content.length,
      isRead: false, isDownloaded: false, isCached: true,
      duration: 0, audioUrl: '',
      createTime: now, updateTime: now,
    };
  }

  private decodeText(data: Uint8Array, encoding: number): string {
    if (encoding === 65001) {
      return new TextDecoder('utf-8', { fatal: false }).decode(data);
    }
    // CP1252 / Latin-1
    return new TextDecoder('windows-1252', { fatal: false }).decode(data);
  }

  private readU16(bytes: Uint8Array, offset: number): number {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  private readU32(bytes: Uint8Array | Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8)
      | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
  }

  private readAscii(bytes: Uint8Array, offset: number, len: number): string {
    return new TextDecoder('ascii').decode(bytes.slice(offset, offset + len));
  }

  getMeta(): MobiMeta { return this.meta_; }
  getChapters(): BookChapter[] { return this.chapters_; }
}
