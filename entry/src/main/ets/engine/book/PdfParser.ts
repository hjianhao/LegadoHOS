/**
 * PDF 解析器 — 纯文本提取
 *
 * 不依赖 @ohos.multimedia.pdf 渲染 API，
 * 直接解析 PDF 文件结构提取文本内容:
 *
 * PDF 结构:
 * ┌──────────────┐
 * │ Header       │  %PDF-1.x
 * ├──────────────┤
 * │ Object 1     │  obj ... endobj
 * │ Object 2     │  流式文本内容/图片
 * │ ...          │
 * ├──────────────┤
 * │ Cross-ref    │  对象位置索引表
 * ├──────────────┤
 * │ Trailer      │  /Root /Info 引用
 * └──────────────┘
 *
 * 文本提取方式:
 * - 查找 BT...ET (Begin Text / End Text) 标记
 * - 提取 Tj/TJ 操作符中的文字
 * - 拼接成段落
 */
import { BookChapter } from '../../model/BookChapter';
import fileFs from '@ohos.file.fs';
import { localBookTitleFromPath } from './LocalBookFileUtil';

export interface PdfMeta {
  title: string;
  author: string;
  subject: string;
  keywords: string;
  creator: string;
  producer: string;
  pageCount: number;
}

export class PdfParser {
  private filePath: string;
  private meta_: PdfMeta = { title: '', author: '', subject: '', keywords: '', creator: '', producer: '', pageCount: 0 };
  private chapters_: BookChapter[] = [];

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  async parse(): Promise<{ meta: PdfMeta; chapters: BookChapter[] }> {
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(this.filePath, fileFs.OpenMode.READ_ONLY);
      const stat = fileFs.statSync(this.filePath);
      if (stat.size < 8) {
        throw new Error('PDF 文件内容为空');
      }
      // 导入阶段只做轻量探测。完整解析、元数据与页面渲染交给 PDF.js，
      // 避免将大型 PDF 整体读入 ArkTS 内存，也允许没有文字层的扫描版导入。
      const headerBuffer = new ArrayBuffer(Math.min(1024, stat.size));
      const readLength = fileFs.readSync(file.fd, headerBuffer,
        { offset: 0, length: headerBuffer.byteLength });
      const bytes = new Uint8Array(headerBuffer, 0, readLength);
      let header = '';
      for (let i = 0; i < bytes.length; i++) header += String.fromCharCode(bytes[i]);
      const versionMatch = header.match(/%PDF-(\d+\.\d+)/);
      if (!versionMatch) {
        throw new Error('不是有效的 PDF 文件');
      }
      console.info(`[PDF] Probe version=${versionMatch[1]} size=${stat.size}`);
    } catch (err) {
      throw new Error(`Read PDF failed: ${this.filePath}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[PDF] close failed:', (err as Error).message);
        }
      }
    }

    this.meta_.title = this.guessTitle();
    const now = Date.now();
    this.chapters_ = [{
      id: 0, bookId: 0, index: 0, volumeIndex: 0,
      title: 'PDF', url: '', content: '', contentLength: 0,
      isRead: false, isDownloaded: true, isCached: false,
      duration: 0, audioUrl: '', createTime: now, updateTime: now,
    }];
    return { meta: this.meta_, chapters: this.chapters_ };
  }

  /**
   * 提取 PDF 元数据字段（处理转义和编码）
   */
  private extractPdfField(content: string, field: string): string {
    const patterns = [
      // /Title(SomeText)
      new RegExp(`${field}\\s*\\(([^)]*?)\\)`, 'i'),
      // /Title <FEFF...>
      new RegExp(`${field}\\s*<([^>]+)>`, 'i'),
      // 字符串中的十六进制
      new RegExp(`${field}\\s*\\(([^)]*)\\)`, 'i'),
    ];

    for (const regex of patterns) {
      const match = content.match(regex);
      if (match) {
        let val = match[1];
        // 处理括号嵌套
        if (val.includes('\\(')) val = val.replace(/\\([()\\])/g, '$1');
        // 处理十六进制编码
        if (/^FEFF[0-9A-Fa-f]+$/.test(val)) {
          const hex = val.slice(4);
          const chars: string[] = [];
          for (let i = 0; i < hex.length; i += 4) {
            const code = parseInt(hex.slice(i, i + 4), 16);
            if (!isNaN(code)) chars.push(String.fromCharCode(code));
          }
          return chars.join('');
        }
        return val;
      }
    }
    return '';
  }

  /**
   * 提取 PDF 正文文本
   * 搜索 BT...ET 标记中的 Tj/TJ 操作符
   */
  private extractRawText(content: string): string {
    const texts: string[] = [];
    let pos = 0;

    while (pos < content.length) {
      // 找 BT
      const btStart = content.indexOf('BT', pos);
      if (btStart < 0) break;

      const btEnd = content.indexOf('ET', btStart);
      if (btEnd < 0) break;

      const btBlock = content.slice(btStart + 2, btEnd);

      // 提取 Tj: (text) Tj
      const tjRegex = /\(([^)]*?)\)\s*Tj/g;
      let tjMatch: RegExpExecArray | null;
      while ((tjMatch = tjRegex.exec(btBlock)) !== null) {
        let text = tjMatch[1];
        // 处理 PDF 转义
        text = text.replace(/\\([nrtfb()\\])/g, (m, ch) => {
          const map: Record<string, string> = { 'n': '\n', 'r': '\r', 't': '\t', 'f': '\f', 'b': '\b', '(': '(', ')': ')', '\\': '\\' };
          return map[ch] || ch;
        });
        // 处理八进制转义
        text = text.replace(/\\(\d{3})/g, (m, oct) => String.fromCharCode(parseInt(oct, 8)));
        if (text.trim()) texts.push(text.trim());
      }

      // 提取 TJ: [(text) num (text) ...] TJ
      const tjArrayRegex = /\[([^\]]*)\]\s*TJ/g;
      let tjArrayMatch: RegExpExecArray | null;
      while ((tjArrayMatch = tjArrayRegex.exec(btBlock)) !== null) {
        const items = tjArrayMatch[1];
        const parts = items.match(/\(([^)]*?)\)/g);
        if (parts) {
          const line = parts.map((p: string) => p.slice(1, -1)).join('');
          if (line.trim()) texts.push(line.trim());
        }
      }

      pos = btEnd + 2;
    }

    return texts.join('\n');
  }

  /**
   * 分章
   */
  private splitIntoChapters(text: string): BookChapter[] {
    const chapters: BookChapter[] = [];
    const now = Date.now();

    const chapterRegex = /^(?:第\s*[一二三四五六七八九十百千万亿两0-9]+\s*[章节卷回篇部]|Chapter\s+\d+|Part\s+\d+)/im;
    const lines = text.split('\n');
    let currentLines: string[] = [];
    let chapIndex = 0;
    let chapTitle = '前言';

    for (const line of lines) {
      if (chapterRegex.test(line)) {
        if (currentLines.length > 0) {
          chapters.push({
            id: 0, bookId: 0, index: chapIndex++, volumeIndex: 0,
            title: chapTitle, url: '',
            content: currentLines.join('\n').trim(),
            contentLength: currentLines.join('').length,
            isRead: false, isDownloaded: false, isCached: true,
            duration: 0, audioUrl: '',
            createTime: now, updateTime: now,
          });
          currentLines = [];
        }
        chapTitle = line;
      } else if (line.trim()) {
        currentLines.push(line);
      }
    }

    if (currentLines.length > 0) {
      chapters.push({
        id: 0, bookId: 0, index: chapIndex, volumeIndex: 0,
        title: chapTitle, url: '',
        content: currentLines.join('\n').trim(),
        contentLength: currentLines.join('').length,
        isRead: false, isDownloaded: false, isCached: true,
        duration: 0, audioUrl: '',
        createTime: now, updateTime: now,
      });
    }

    return chapters;
  }

  private guessTitle(): string {
    return localBookTitleFromPath(this.filePath);
  }

  getMeta(): PdfMeta { return this.meta_; }
  getChapters(): BookChapter[] { return this.chapters_; }
}
