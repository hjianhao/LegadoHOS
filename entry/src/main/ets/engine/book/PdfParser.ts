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
    let content: string = '';
    try {
      file = fileFs.openSync(this.filePath, fileFs.OpenMode.READ_ONLY);
      const stat = fileFs.statSync(this.filePath);
      const buf = new ArrayBuffer(stat.size);
      fileFs.readSync(file.fd, buf);
      const bytes = new Uint8Array(buf);
      // latin-1 解码：逐字节映射到 char code
      const chars: string[] = [];
      for (let i = 0; i < bytes.length; i++) {
        chars.push(String.fromCharCode(bytes[i]));
      }
      content = chars.join('');
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

    // 1. 解析文件头
    if (!content.startsWith('%PDF')) {
      console.warn('[PDF] Not a PDF file');
      return { meta: this.meta_, chapters: this.chapters_ };
    }

    const versionMatch = content.match(/%PDF-(\d+\.\d+)/);
    console.info(`[PDF] Version: ${versionMatch ? versionMatch[1] : 'unknown'}`);

    // 2. 提取元数据
    this.meta_.title = this.extractPdfField(content, '/Title') || this.guessTitle();
    this.meta_.author = this.extractPdfField(content, '/Author');
    this.meta_.subject = this.extractPdfField(content, '/Subject');
    this.meta_.keywords = this.extractPdfField(content, '/Keywords');
    this.meta_.creator = this.extractPdfField(content, '/Creator');
    this.meta_.producer = this.extractPdfField(content, '/Producer');

    // 3. 提取文本
    const rawText = this.extractRawText(content);
    const lines = rawText.split('\n')
      .map(l => l.trim())
      .filter(l => l.length > 2); // 过滤过短的碎片

    const fullText = lines.join('\n\n');

    // 4. 按 PDF 页面或章节标记分章
    this.chapters_ = this.splitIntoChapters(fullText);

    // 5. 估算页数（通过 /Pages 对象或文本长度估算）
    const pagesMatch = content.match(/\/Type\s*\/Pages[^>]*\/Count\s+(\d+)/);
    this.meta_.pageCount = pagesMatch ? parseInt(pagesMatch[1]) : Math.ceil(fullText.length / 2000);

    console.info(`[PDF] Parsed: ${this.meta_.title}, ${this.meta_.pageCount} pages, ${fullText.length} chars`);

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
    const parts = this.filePath.split('/');
    return parts[parts.length - 1].replace(/\.pdf$/i, '');
  }

  getMeta(): PdfMeta { return this.meta_; }
  getChapters(): BookChapter[] { return this.chapters_; }
}
