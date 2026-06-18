/**
 * EPUB 解析器 — 纯 ArkTS 实现
 *
 * 格式解析链路:
 *   EPUB (.epub = .zip)
 *    → META-INF/container.xml
 *    → package.opf (元数据 + manifest + spine)
 *    → toc.ncx 或 nav.xhtml (目录)
 *    → 按 spine 顺序提取 xhtml 内容 → 纯文本
 *
 * 关键技术:
 *   - ZipReader.ts: 纯 ArkTS ZIP 解析 (无 libzip 依赖)
 *   - 正则 XML 解析 (无 DOM 库依赖)
 *   - HtmlUtil.stripHtml: HTML 标签剥离
 */
import { BookChapter } from '../../model/BookChapter';
import { ZipReader, ZipEntry } from '../../util/ZipReader';
import { HtmlUtil } from '../../util/HtmlUtil';

export interface EpubMeta {
  title: string;
  author: string;
  coverPath: string;
  description: string;
  language: string;
  publisher: string;
  isbn: string;
  date: string;
}

export class EpubParser {
  private filePath: string;
  private zipReader: ZipReader | null = null;
  private meta_: EpubMeta | null = null;
  private chapters_: BookChapter[] = [];

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  async parse(): Promise<{ meta: EpubMeta; chapters: BookChapter[] }> {
    this.zipReader = new ZipReader(this.filePath);
    await this.zipReader.open();

    // 1. 解析 container.xml → 获取 OPF 路径
    const containerEntry = this.zipReader.findEntry('META-INF/container.xml');
    if (!containerEntry) throw new Error('Invalid EPUB: missing container.xml');
    const containerXml = await this.zipReader.extractText(containerEntry);
    const opfPath = this.parseContainerXml(containerXml);

    // 2. 解析 OPF → 获取元数据 + manifest + spine
    const opfEntry = this.zipReader.findEntry(opfPath);
    if (!opfEntry) throw new Error(`Invalid EPUB: missing ${opfPath}`);
    const opfXml = await this.zipReader.extractText(opfEntry);
    const opfDir = opfPath.substring(0, opfPath.lastIndexOf('/') + 1);
    this.meta_ = this.parseOpfMeta(opfXml);

    const manifest = this.parseManifest(opfXml);
    const spineIds = this.parseSpine(opfXml);

    // 3. 解析目录 (NCX 或 nav)
    const tocId = this.getTocId(opfXml);
    let navMap: Array<{ id: string; title: string; href: string }> = [];

    if (tocId && manifest[tocId]) {
      const tocHref = this.resolvePath(opfDir, manifest[tocId]);
      const tocEntry = this.zipReader.findEntry(tocHref);
      if (tocEntry) {
        const tocXml = await this.zipReader.extractText(tocEntry);
        navMap = this.parseNcx(tocXml);
      }
    }

    // 如果 NCX 没有目录，从 spine 生成
    if (navMap.length === 0) {
      navMap = spineIds.map((id, idx) => ({
        id, title: `第 ${idx + 1} 章`, href: manifest[id] || '',
      }));
    }

    // 4. 按 spine 顺序提取正文
    const now = Date.now();
    for (let i = 0; i < spineIds.length; i++) {
      const id = spineIds[i];
      const href = manifest[id];
      if (!href) continue;

      const fullPath = this.resolvePath(opfDir, href);
      const entry = this.zipReader.findEntry(fullPath);
      if (!entry) continue;

      const html = await this.zipReader.extractText(entry);
      const text = HtmlUtil.stripHtml(html);

      // 从 navMap 找标题
      const nav = navMap.find(n => n.href === href || n.id === id);
      const title = nav?.title || `第 ${i + 1} 章`;

      this.chapters_.push({
        id: 0, bookId: 0, index: i, volumeIndex: 0,
        title, url: fullPath,
        content: text,
        contentLength: text.length,
        isRead: false, isDownloaded: false, isCached: true,
        duration: 0, audioUrl: '',
        createTime: now, updateTime: now,
      });
    }

    this.zipReader.close();
    console.info(`[EPUB] Parsed: ${this.meta_?.title}, ${this.chapters_.length} chapters`);

    return { meta: this.meta_, chapters: this.chapters_ };
  }

  /**
   * 解析 container.xml 获取 OPF 路径
   */
  private parseContainerXml(xml: string): string {
    const match = xml.match(/href\s*=\s*["']([^"']+\.opf)["']/i);
    return match ? match[1] : 'content.opf';
  }

  /**
   * 解析 OPF metadata
   */
  private parseOpfMeta(opfXml: string): EpubMeta {
    const getTag = (tag: string) => {
      const m = opfXml.match(new RegExp(`<${tag}[^>]*>([^<]*)<\\/${tag}>`, 'i'));
      return m ? m[1].trim() : '';
    };
    const getAttr = (tag: string, attr: string) => {
      const m = opfXml.match(new RegExp(`<${tag}[^>]*${attr}\\s*=\\s*["']([^"']+)["']`, 'i'));
      return m ? m[1].trim() : '';
    };

    // dc:title, dc:creator, dc:language, dc:description, dc:publisher, dc:identifier, dc:date
    const title = getTag('dc:title') || getTag('title');
    const author = getTag('dc:creator') || getTag('creator');
    const desc = getTag('dc:description') || getTag('description');
    const lang = getTag('dc:language') || getTag('language');
    const pub = getTag('dc:publisher') || getTag('publisher');
    const date = getTag('dc:date') || getTag('date');

    // 从 manifest 找封面
    const coverMatch = opfXml.match(/<item[^>]*id\s*=\s*["'](?:(?:cover)|(?:cover-image)|(?:img))["'][^>]*href\s*=\s*["']([^"']+)["']/i);
    const coverPath = coverMatch ? coverMatch[1] : '';

    // ISBN
    const isbnMatch = opfXml.match(/<dc:identifier[^>]*>[\s]*(?:urn:isbn:)?(\d{10,13})/i);
    const isbn = isbnMatch ? isbnMatch[1] : '';

    return { title, author, coverPath, description: desc, language: lang, publisher: pub, isbn, date };
  }

  /**
   * 解析 manifest
   * id → href 映射
   */
  private parseManifest(opfXml: string): Record<string, string> {
    const map: Record<string, string> = {};
    const regex = /<item\s+([^>]*)\/?>/gi;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(opfXml)) !== null) {
      const attrs = match[1];
      const idM = attrs.match(/id\s*=\s*["']([^"']+)["']/i);
      const hrefM = attrs.match(/href\s*=\s*["']([^"']+)["']/i);
      const mediaM = attrs.match(/media-type\s*=\s*["']([^"']+)["']/i);
      if (idM && hrefM && mediaM) {
        const mt = mediaM[1];
        // 只保留文本类型的条目
        if (mt.includes('xml') || mt.includes('html') || mt.includes('xhtml') || mt.includes('css') || mt.includes('ncx')) {
          map[idM[1]] = hrefM[1];
        }
      }
    }
    return map;
  }

  /**
   * 解析 spine（阅读顺序）
   */
  private parseSpine(opfXml: string): string[] {
    const order: string[] = [];
    const regex = /<itemref\s+([^>]*)\/?>/gi;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(opfXml)) !== null) {
      const idM = match[1].match(/idref\s*=\s*["']([^"']+)["']/i);
      if (idM) order.push(idM[1]);
    }
    return order;
  }

  /**
   * 获取目录文件 ID
   */
  private getTocId(opfXml: string): string {
    const m = opfXml.match(/<spine[^>]*toc\s*=\s*["']([^"']+)["']/i);
    return m ? m[1] : '';
  }

  /**
   * 解析 NCX 目录
   */
  private parseNcx(ncxXml: string): Array<{ id: string; title: string; href: string }> {
    const navMap: Array<{ id: string; title: string; href: string }> = [];

    const navPointRegex = /<navPoint[^>]*>([\s\S]*?)<\/navPoint>/gi;
    let npMatch: RegExpExecArray | null;
    while ((npMatch = navPointRegex.exec(ncxXml)) !== null) {
      const content = npMatch[1];

      const titleM = content.match(/<text>([^<]*)<\/text>/i);
      const srcM = content.match(/<content\s+src\s*=\s*["']([^"']+)["']/i);
      const idM = npMatch[0].match(/id\s*=\s*["']([^"']+)["']/i);

      if (srcM) {
        const href = srcM[1].split('#')[0]; // 去掉锚点
        navMap.push({
          id: idM ? idM[1] : '',
          title: titleM ? titleM[1].trim() : '无标题',
          href,
        });

        // 递归解析子 navPoint
        // content 中还可能有嵌套，简化版只处理一级
      }
    }

    return navMap;
  }

  /**
   * 解析 nav.xhtml 中的目录（HTML5 EPUB 3 方式）
   */
  /* istanbul ignore next */
  private parseNav(navHtml: string): Array<{ title: string; href: string }> {
    const nav: Array<{ title: string; href: string }> = [];
    const linkRegex = /<a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
    let match: RegExpExecArray | null;
    while ((match = linkRegex.exec(navHtml)) !== null) {
      nav.push({
        href: match[1].split('#')[0],
        title: HtmlUtil.stripHtml(match[2]).trim(),
      });
    }
    return nav;
  }

  /**
   * 解析路径（相对路径转绝对）
   */
  private resolvePath(base: string, relative: string): string {
    if (relative.startsWith('/')) return relative.slice(1);
    if (relative.startsWith('http')) return relative;
    const parts = base.split('/');
    const relParts = relative.split('/');
    for (const part of relParts) {
      if (part === '.') continue;
      if (part === '..') parts.pop();
      else parts.push(part);
    }
    return parts.join('/');
  }

  getMeta(): EpubMeta | null { return this.meta_; }
  getChapters(): BookChapter[] { return this.chapters_; }
}
