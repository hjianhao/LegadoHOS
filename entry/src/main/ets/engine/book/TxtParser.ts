/**
 * TXT 文件解析器
 *
 * 功能：
 * - 编码自动检测（BOM / UTF-8 / GBK / GB18030 / Big5 / UTF-16）
 * - 综合目录规则匹配（兼容 Legado TxtTocRule）
 * - 流式扫描全文，只记录章节标题与字节偏移，不加载全文到内存
 * - 提供按偏移读取章节内容的能力
 */
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import { BookChapter } from '../../model/BookChapter';
import { TxtTocRule } from '../../model/CacheEntry';

export interface TxtParseResult {
  encoding: string;
  chapters: BookChapter[];
}

const DEFAULT_TOC_RULES: TxtTocRule[] = [
  {
    id: -1,
    name: '目录(去空白)',
    rule: '(?<=[　\\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$',
    isEnabled: true, sortOrder: 0, createTime: 0,
  },
  {
    id: -2,
    name: '目录',
    rule: '^[ 　\\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$',
    isEnabled: true, sortOrder: 1, createTime: 0,
  },
  {
    id: -4,
    name: '目录(古典、轻小说备用)',
    rule: '^[ 　\\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|回(?![合来事去])|场(?![和合比电是])|话|篇(?!张))).{0,30}$',
    isEnabled: false, sortOrder: 3, createTime: 0,
  },
  {
    id: -8,
    name: '数字 分隔符 标题名称',
    rule: '^[ 　\\t]{0,4}\\d{1,5}[:：,.， 、_—\\-].{1,30}$',
    isEnabled: true, sortOrder: 7, createTime: 0,
  },
  {
    id: -9,
    name: '大写数字 分隔符 标题名称',
    rule: '^[ 　\\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?)[ 、_—\\-].{1,30}$',
    isEnabled: true, sortOrder: 8, createTime: 0,
  },
  {
    id: -10,
    name: '数字混合 分隔符 标题名称',
    rule: '^[ 　\\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?[ 、_—\\-]|\\d{1,5}章?[:：,.， 、_—\\-]).{0,30}$',
    isEnabled: false, sortOrder: 9, createTime: 0,
  },
  {
    id: -11,
    name: '正文 标题/序号',
    rule: '^[ 　\\t]{0,4}正文[ 　]{1,4}.{0,20}$',
    isEnabled: true, sortOrder: 10, createTime: 0,
  },
  {
    id: -12,
    name: 'Chapter/Section/Part/Episode 序号 标题',
    rule: '^[ 　\\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO][.、]|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\\s{0,4}\\d{1,4}.{0,30}$',
    isEnabled: true, sortOrder: 11, createTime: 0,
  },
  {
    id: -14,
    name: '特殊符号 序号 标题',
    rule: '(?<=[\\s　])[【〔〖「『〈［\\[](?:第|[Cc]hapter)[\\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$',
    isEnabled: true, sortOrder: 13, createTime: 0,
  },
  {
    id: -16,
    name: '特殊符号 标题(单个)',
    rule: '(?<=[\\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$',
    isEnabled: true, sortOrder: 15, createTime: 0,
  },
  {
    id: -17,
    name: '章/卷 序号 标题',
    rule: '^[ \\t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$',
    isEnabled: true, sortOrder: 16, createTime: 0,
  },
  {
    id: -21,
    name: '书名 括号 序号',
    rule: '^[一-龥]{1,20}[ 　\\t]{0,4}[(（][\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\\t]{0,4}$',
    isEnabled: true, sortOrder: 20, createTime: 0,
  },
  {
    id: -22,
    name: '书名 序号',
    rule: '^[一-龥]{1,20}[ 　\\t]{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 　\\t]{0,4}$',
    isEnabled: true, sortOrder: 21, createTime: 0,
  },
  {
    id: -24,
    name: '字数分割 分节阅读',
    rule: '(?<=[ 　\\t]{0,4})(?:.{0,15}分[页节章段]阅读[-_ ]|第\\s{0,4}[\\d零一二两三四五六七八九十百千万]{1,6}\\s{0,4}[页节]).{0,30}$',
    isEnabled: true, sortOrder: 23, createTime: 0,
  },
  {
    id: -25,
    name: '通用规则',
    rule: '(?im)^.{0,6}(?:[引楔]子|正文(?!完|结)|[引序前]言|[序终]章|扉页|[上中下][部篇卷]|卷首语|后记|尾声|番外|={2,4}|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|页[、 　]|集(?![合和])|部(?![分是门落])|篇(?!张))).{0,40}$|^.{0,6}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟a-z]{1,8}[、. 　].{0,20}$',
    isEnabled: false, sortOrder: 24, createTime: 0,
  },
];

/** 无目录时按字节大小兜底分章的阈值 */
const FALLBACK_CHUNK_SIZE = 10000;

interface RuleMatchCount {
  rule: TxtTocRule;
  count: number;
}

export class TxtParser {
  /**
   * 解析 TXT 文件：流式扫描，返回章节目录（含字节偏移，不含全文）
   */
  static async parse(
    filePath: string,
    tocRules?: TxtTocRule[],
    forcedCharset?: string
  ): Promise<TxtParseResult> {
    const encoding = forcedCharset || await this.detectEncoding_(filePath);
    const rules = this.buildRules_(tocRules);

    const bestRule = await this.selectBestRule_(filePath, encoding, rules);
    let chapters: BookChapter[];
    if (bestRule) {
      chapters = await this.splitByRule_(filePath, encoding, bestRule);
    } else {
      chapters = await this.splitBySize_(filePath, encoding, FALLBACK_CHUNK_SIZE);
    }

    return { encoding, chapters };
  }

  /**
   * 按字节偏移读取章节内容并解码
   */
  static async readChapterContent(
    filePath: string,
    start: number,
    end: number,
    encoding: string
  ): Promise<string> {
    if (end <= start) return '';
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      const length = end - start;
      const buf = new ArrayBuffer(length);
      fileFs.readSync(file.fd, buf, { offset: start, length });
      return this.decodeBytes_(new Uint8Array(buf), encoding);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[TxtParser] close file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 检测文件编码（读取前 8KB）
   */
  private static async detectEncoding_(filePath: string): Promise<string> {
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      const stat = fileFs.statSync(filePath);
      const size = Math.min(stat.size, 8192);
      const buf = new ArrayBuffer(size);
      fileFs.readSync(file.fd, buf, { offset: 0, length: size });
      const bytes = new Uint8Array(buf);

      // BOM
      if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) return 'utf-8';
      if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) return 'utf-16le';
      if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) return 'utf-16be';

      // UTF-8 严格校验
      try {
        new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
        return 'utf-8';
      } catch (_e) { /* not utf-8 */ }

      // GB18030 / GBK
      try {
        new util.TextDecoder('gb18030', { fatal: true }).decodeToString(bytes);
        return 'gb18030';
      } catch (_e) {
        try {
          new util.TextDecoder('gbk', { fatal: true }).decodeToString(bytes);
          return 'gbk';
        } catch (_e2) { /* not gbk */ }
      }

      // Big5
      try {
        new util.TextDecoder('big5', { fatal: true }).decodeToString(bytes);
        return 'big5';
      } catch (_e) { /* not big5 */ }

      return 'utf-8';
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[TxtParser] close file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 构建生效的规则列表
   */
  private static buildRules_(tocRules?: TxtTocRule[]): TxtTocRule[] {
    const userRules = (tocRules || []).filter(r => r.isEnabled);
    if (userRules.length > 0) {
      return [...userRules, ...DEFAULT_TOC_RULES];
    }
    return DEFAULT_TOC_RULES.filter(r => r.isEnabled);
  }

  /**
   * 流式遍历文件每一行
   */
  private static async forEachLine_(
    filePath: string,
    encoding: string,
    callback: (line: string, byteOffset: number, byteLength: number) => void
  ): Promise<void> {
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      const stat = fileFs.statSync(filePath);
      const fileSize = stat.size;
      const chunkSize = 256 * 1024;
      let fileOffset = 0;
      let carry: Uint8Array = new Uint8Array(0);

      while (fileOffset < fileSize) {
        const readLen = Math.min(chunkSize, fileSize - fileOffset);
        const buf = new ArrayBuffer(readLen);
        fileFs.readSync(file.fd, buf, { offset: fileOffset, length: readLen });
        const chunk = new Uint8Array(buf);

        const all = new Uint8Array(carry.length + chunk.length);
        all.set(carry, 0);
        all.set(chunk, carry.length);

        let lastNl = -1;
        for (let i = all.length - 1; i >= 0; i--) {
          if (all[i] === 0x0A) {
            lastNl = i;
            break;
          }
        }

        let processBytes: Uint8Array;
        let newCarry: Uint8Array;
        if (lastNl < 0) {
          processBytes = new Uint8Array(0);
          newCarry = all;
        } else {
          processBytes = all.subarray(0, lastNl + 1);
          newCarry = all.subarray(lastNl + 1);
        }

        const baseOffset = fileOffset - carry.length;
        if (processBytes.length > 0) {
          const text = this.decodeBytes_(processBytes, encoding);
          const lines = text.split('\n');
          let bytePos = baseOffset;
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const lineWithNl = i < lines.length - 1 ? line + '\n' : line;
            const byteLen = this.byteLength_(lineWithNl, encoding);
            callback(line, bytePos, byteLen);
            bytePos += byteLen;
          }
        }

        carry = newCarry;
        fileOffset += readLen;
      }

      if (carry.length > 0) {
        const baseOffset = fileSize - carry.length;
        const text = this.decodeBytes_(carry, encoding);
        callback(text, baseOffset, carry.length);
      }
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[TxtParser] close file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 选择最佳目录规则
   * 统计各规则匹配数，匹配间隔需 >1000 字节，避免短行误匹配
   */
  private static async selectBestRule_(
    filePath: string,
    encoding: string,
    rules: TxtTocRule[]
  ): Promise<TxtTocRule | null> {
    const counts: RuleMatchCount[] = rules.map(rule => ({ rule, count: 0 }));
    const lastMatchEnd: number[] = new Array(rules.length).fill(-1);

    await this.forEachLine_(filePath, encoding, (line, byteOffset, byteLength) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      for (let i = 0; i < rules.length; i++) {
        const rule = rules[i];
        if (!rule.rule) continue;
        try {
          const regex = new RegExp(`^(?:${rule.rule})$`, 'i');
          if (regex.test(trimmed)) {
            if (lastMatchEnd[i] < 0 || byteOffset - lastMatchEnd[i] > 1000) {
              counts[i].count++;
              lastMatchEnd[i] = byteOffset + byteLength;
            }
          }
        } catch (e) {
          console.warn('[TxtParser] Invalid toc rule:', rule.name, e);
        }
      }
    });

    let best: RuleMatchCount | null = null;
    let maxCount = 1;
    for (const item of counts) {
      if (item.count >= maxCount) {
        maxCount = item.count;
        best = item;
      }
    }
    return best ? best.rule : null;
  }

  /**
   * 按规则流式拆分章节
   */
  private static async splitByRule_(
    filePath: string,
    encoding: string,
    rule: TxtTocRule
  ): Promise<BookChapter[]> {
    const chapters: BookChapter[] = [];
    let lastTitle = '前言';
    let lastStart = 0;
    let chapterIndex = 0;
    const fileSize = fileFs.statSync(filePath).size;

    await this.forEachLine_(filePath, encoding, (line, byteOffset, byteLength) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      try {
        const regex = new RegExp(`^(?:${rule.rule})$`, 'i');
        if (regex.test(trimmed)) {
          if (byteOffset > lastStart) {
            chapters.push(this.createChapterMeta_(chapterIndex++, lastTitle, lastStart, byteOffset));
          }
          lastTitle = trimmed;
          lastStart = byteOffset;
        }
      } catch (e) {
        console.warn('[TxtParser] Invalid toc rule:', rule.name, e);
      }
    });

    // 最后一章
    if (fileSize > lastStart) {
      chapters.push(this.createChapterMeta_(chapterIndex, lastTitle, lastStart, fileSize));
    }

    // 移除空的前言
    if (chapters.length > 1 && chapters[0].title === '前言' && chapters[0].start === chapters[0].end) {
      chapters.shift();
      chapters.forEach((ch, idx) => ch.index = idx);
    }

    // 合并误识别的短章节（如“第三部电影”这类正文句子）
    return this.mergeShortChapters_(chapters);
  }

  /**
   * 合并内容过短的章节到相邻章节
   * 误识别的“章节”通常只是一句话，长度远小于正常章节
   */
  private static mergeShortChapters_(chapters: BookChapter[]): BookChapter[] {
    if (chapters.length <= 1) return chapters;
    const MIN_CHAPTER_BYTES = 200; // 约 100 字以内视为误识别
    const merged: BookChapter[] = [];

    for (const ch of chapters) {
      const start = ch.start ?? 0;
      const end = ch.end ?? 0;
      const len = end - start;
      if (len < MIN_CHAPTER_BYTES && merged.length > 0) {
        // 合并到上一章：扩展上一章范围，标题保持上一章的
        const prev = merged[merged.length - 1];
        prev.end = end;
        prev.contentLength = (prev.end ?? 0) - (prev.start ?? 0);
        continue;
      }
      merged.push(ch);
    }

    // 如果最后几章都是短章节，可能被连续合并，这是预期行为
    merged.forEach((ch, idx) => ch.index = idx);
    return merged;
  }

  /**
   * 按字节大小兜底分章（尽量在换行处切开）
   */
  private static async splitBySize_(
    filePath: string,
    encoding: string,
    chunkSize: number
  ): Promise<BookChapter[]> {
    const chapters: BookChapter[] = [];
    const fileSize = fileFs.statSync(filePath).size;
    let chapterIndex = 0;
    let pos = 0;

    while (pos < fileSize) {
      let end = Math.min(pos + chunkSize, fileSize);
      if (end < fileSize) {
        // 读取一小块向后找换行
        const searchStart = Math.max(pos + chunkSize * 0.5, end - 512);
        const searchLen = Math.min(1024, fileSize - searchStart);
        let file: fileFs.File | null = null;
        try {
          file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
          const buf = new ArrayBuffer(searchLen);
          fileFs.readSync(file.fd, buf, { offset: searchStart, length: searchLen });
          const bytes = new Uint8Array(buf);
          for (let i = bytes.length - 1; i >= 0; i--) {
            if (bytes[i] === 0x0A) {
              end = searchStart + i + 1;
              break;
            }
          }
        } finally {
          if (file) fileFs.closeSync(file);
        }
      }
      const idx = chapterIndex++;
      chapters.push(this.createChapterMeta_(idx, `第${idx + 1}节`, pos, end));
      pos = end;
    }

    return chapters;
  }

  /**
   * 创建章节元数据（不含内容）
   */
  private static createChapterMeta_(index: number, title: string, start: number, end: number): BookChapter {
    return {
      id: 0,
      bookId: 0,
      index,
      volumeIndex: 0,
      title: title.trim() || `第${index + 1}节`,
      url: '',
      content: '',
      contentLength: end - start,
      isRead: false,
      isDownloaded: true,
      isCached: false,
      duration: 0,
      audioUrl: '',
      createTime: Date.now(),
      updateTime: Date.now(),
      start,
      end,
    };
  }

  /**
   * 解码字节数组
   */
  private static decodeBytes_(bytes: Uint8Array, encoding: string): string {
    try {
      const decoder = new util.TextDecoder(encoding, { fatal: false });
      return decoder.decodeToString(bytes);
    } catch (e) {
      console.warn('[TxtParser] decode failed, fallback to utf-8:', encoding, e);
      return new util.TextDecoder('utf-8', { fatal: false }).decodeToString(bytes);
    }
  }

  /**
   * 计算字符串在指定编码下的字节长度
   */
  private static byteLength_(text: string, encoding: string): number {
    try {
      // 目前 ArkTS 没有直接的 TextEncoder 编码为任意 charset，先按常见编码估算
      if (encoding === 'utf-8') {
        let len = 0;
        for (let i = 0; i < text.length; i++) {
          const code = text.charCodeAt(i);
          if (code < 0x80) len += 1;
          else if (code < 0x800) len += 2;
          else if (code >= 0xD800 && code <= 0xDBFF) { len += 4; i++; }
          else len += 3;
        }
        return len;
      }
      // GBK / GB18030 / Big5：ASCII 1 字节，其他 2 字节
      let len = 0;
      for (let i = 0; i < text.length; i++) {
        const code = text.charCodeAt(i);
        len += code < 0x80 ? 1 : 2;
      }
      return len;
    } catch (_e) {
      return text.length;
    }
  }
}
