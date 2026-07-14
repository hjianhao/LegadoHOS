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
  coverData: ArrayBuffer | null;   // 封面图片数据（解压后）
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
	    const opfDir = opfPath.substring(0, opfPath.lastIndexOf('/'));
    this.meta_ = this.parseOpfMeta(opfXml);

		    const manifest = this.parseManifest(opfXml);
		    const spineItems = this.parseSpine(opfXml);
		    // 过滤掉 linear="no" 的非正文条目
		    const spineIds: string[] = spineItems
		      .filter(item => !item.linearNo)
		      .map(item => item.id);

		    // 提取封面图片数据
	    let coverData: ArrayBuffer | null = null;
		    if (this.meta_.coverPath) {
		      const coverFullPath = this.resolvePath(opfDir, this.meta_.coverPath);
		      const coverEntry = this.zipReader.findEntry(coverFullPath);
		      if (coverEntry) {
		        coverData = await this.zipReader.extractData(coverEntry);
		        console.info('[EPUB] cover extracted: ' + (coverData ? coverData.byteLength + ' bytes' : 'null'));
		      } else {
		        console.warn('[EPUB] cover entry not found: ' + coverFullPath);
		      }
		    } else {
		      console.warn('[EPUB] no coverPath in OPF metadata');
		    }
	    this.meta_.coverData = coverData;

	    // 3. 解析目录 (NCX 或 nav)
	    let navMap: Array<{ id: string; title: string; href: string }> = [];

	    // 方式 A: NCX 目录 (EPUB 2)
	    const tocId = this.getTocId(opfXml);
	    if (tocId && manifest[tocId]) {
	      const tocHref = this.resolvePath(opfDir, manifest[tocId]);
	      const tocEntry = this.zipReader.findEntry(tocHref);
	      if (tocEntry) {
	        const tocXml = await this.zipReader.extractText(tocEntry);
	        navMap = this.parseNcxRecursive(tocXml);
	      }
	    }

	    // 方式 B: EPUB 3 nav 文档（按 manifest 中 properties="nav" 查找）
	    if (navMap.length === 0) {
	      const navIdMatch = opfXml.match(/<item\s[^>]*?properties\s*=\s*["']nav["'][^>]*?\sid\s*=\s*["']([^"']+)["']/i);
	      const navId = navIdMatch ? navIdMatch[1] : '';
	      if (navId && manifest[navId]) {
	        const navHref = this.resolvePath(opfDir, manifest[navId]);
	        const navEntry = this.zipReader.findEntry(navHref);
		  if (navEntry) {
		            const navHtml = await this.zipReader.extractText(navEntry);
		            const parsed = this.parseNav(navHtml);
		            navMap = parsed.map(n => ({ id: '', title: n.title, href: n.href }));
		          }
	      }
	    }

	    // 兜底：从 spine 生成
	    if (navMap.length === 0) {
	      navMap = spineIds.map((id, idx) => ({
	        id, title: `第 ${idx + 1} 章`, href: manifest[id] || '',
	      }));
	    }

	    // 4. 按 NCX 目录 + spine 合并提取正文
	    //    EPUB 中，一个章节可能分布在多个 spine 文件中，
	    //    NCX navPoint 只指向该章节的第一个 spine 文件。
	    //    需要合并从 navPoint href 到下一个 navPoint href 之间的所有 spine 内容。
	    const now = Date.now();
	    if (navMap.length > 0) {
	      // 建立 manifest href → spine 索引的映射
	      const hrefToSpineIdx: Record<string, number> = {};
	      for (let si = 0; si < spineIds.length; si++) {
	        const shref = manifest[spineIds[si]];
	        if (shref) {
	          hrefToSpineIdx[shref] = si;
	        }
	      }

	      for (let i = 0; i < navMap.length; i++) {
	        const nav = navMap[i];
	        const navHref = nav.href;

	        // 找到该 navPoint 对应的 spine 起始位置
	        let spineStart = hrefToSpineIdx[navHref];
	        // 找到下一个 navPoint 对应的 spine 起始位置
	        let spineEnd = spineIds.length;
	        for (let j = i + 1; j < navMap.length; j++) {
	          const nextIdx = hrefToSpineIdx[navMap[j].href];
	          if (nextIdx !== undefined) {
	            spineEnd = nextIdx;
	            break;
	          }
	        }

	        // 合并 spine[spineStart..spineEnd) 的所有内容
	        let combinedText = '';
	        let lastFullPath = '';
	        const startIdx = spineStart !== undefined ? spineStart : 0;
	        const endIdx = spineEnd;
	        for (let si = startIdx; si < endIdx; si++) {
	          const shref = manifest[spineIds[si]];
	          if (!shref) continue;
	          const fullPath = this.resolvePath(opfDir, shref);
	          const entry = this.zipReader.findEntry(fullPath);
	          if (!entry) continue;
	          lastFullPath = fullPath;
	          const html = await this.zipReader.extractText(entry);
	          if (html) {
	            combinedText += HtmlUtil.toPlainText(html) + '\n';
	          }
	        }

	        // 如果 navPoint 不在 spine 中（如封面图片），直接提取该文件
	        if (!combinedText) {
	          const fullPath = this.resolvePath(opfDir, navHref);
	          const entry = this.zipReader.findEntry(fullPath);
	          if (entry) {
	            const html = await this.zipReader.extractText(entry);
	            combinedText = HtmlUtil.toPlainText(html);
	            lastFullPath = fullPath;
	          }
	        }

	        const text = combinedText.trim();
	        if (i < 3) {
	          console.info('[EPUB] chapter "' + nav.title.substring(0, 20) + '" content=' + text.length + ' chars (spine ' + startIdx + '-' + endIdx + ')');
	        }

	        this.chapters_.push({
	          id: 0, bookId: 0, index: i, volumeIndex: 0,
	          title: nav.title, url: lastFullPath,
	          content: text,
	          contentLength: text.length,
	          isRead: false, isDownloaded: false, isCached: true,
	          duration: 0, audioUrl: '',
	          createTime: now, updateTime: now,
	        });
	      }
	    } else {
	      // 兜底：无 NCX 时按 spine 顺序提取
	      for (let i = 0; i < spineIds.length; i++) {
	        const id = spineIds[i];
	        const href = manifest[id];
	        if (!href) continue;

	        const fullPath = this.resolvePath(opfDir, href);
	        const entry = this.zipReader.findEntry(fullPath);
	        if (!entry) continue;

	        const html = await this.zipReader.extractText(entry);
	        const text = HtmlUtil.toPlainText(html);

	        const title = `第 ${i + 1} 章`;

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
	    }

	    this.zipReader.close();
	    console.info(`[EPUB] Parsed: ${this.meta_?.title}, ${this.chapters_.length} chapters`);

    return { meta: this.meta_, chapters: this.chapters_ };
  }

  /**
   * 解析 container.xml 获取 OPF 路径
   */
  private parseContainerXml(xml: string): string {
    const match = xml.match(/(?:full-path|href)\s*=\s*["']([^"']+\.opf)["']/i);
    return match ? match[1] : 'content.opf';
  }

  /**
   * 解析 OPF metadata
   */
  private parseOpfMeta(opfXml: string): EpubMeta {
    const getTag = (tag: string) => {
      const m = opfXml.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'i'));
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

	    // 从 manifest 找封面 — 优先用 EPUB 标准 <meta name="cover"> 方式
	    let coverPath = '';
	    const coverMetaMatch = opfXml.match(/<meta\s+name\s*=\s*["']cover["'][^>]*?\scontent\s*=\s*["']([^"']+)["']/i);
	    if (coverMetaMatch) {
	      const coverId = coverMetaMatch[1];
	      const coverHrefMatch = opfXml.match(new RegExp(
	        `<item[^>]*?\\sid\\s*=\\s*["']${coverId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}["'][^>]*?\\shref\\s*=\\s*["']([^"']+)["']`,
	        'i'
	      ));
	      if (coverHrefMatch) {
	        coverPath = coverHrefMatch[1];
	      }
	    }
	    // 备用：按 ID 命名惯例查找
	    if (!coverPath) {
	      const coverIdPatterns = ['cover', 'cover-image', 'coverimg', 'coverpage', 'cover_jpg', 'cover\\.', 'img'];
	      for (const pat of coverIdPatterns) {
	        const coverRegex = new RegExp(
	          `<item[^>]*?\\s(id\\s*=\\s*["'](?:${pat})["'])[^>]*?\\s(href\\s*=\\s*["']([^"']+)["'])[^>]*?\\/?\\s*>`,
	          'i'
	        );
	        const m = coverRegex.exec(opfXml);
	        if (m && m[3]) {
	          coverPath = m[3];
	          break;
	        }
	        const coverRegex2 = new RegExp(
	          `<item[^>]*?\\s(href\\s*=\\s*["']([^"']+)["'])[^>]*?\\s(id\\s*=\\s*["'](?:${pat})["'])[^>]*?\\/?\\s*>`,
	          'i'
	        );
	        const m2 = coverRegex2.exec(opfXml);
	        if (m2 && m2[2]) {
	          coverPath = m2[2];
	          break;
	        }
	      }
	    }
	    // 兜底：取第一个图片条目
	    if (!coverPath) {
	      const imgItem = opfXml.match(/<item[^>]*?\smedia-type\s*=\s*["']image\/[^"']+["'][^>]*?\shref\s*=\s*["']([^"']+)["']/i);
	      if (imgItem) {
	        coverPath = imgItem[1];
	      }
	      if (!coverPath) {
	        const imgItem2 = opfXml.match(/<item[^>]*?\shref\s*=\s*["']([^"']+)["'][^>]*?\smedia-type\s*=\s*["']image\/[^"']+["']/i);
	        if (imgItem2) {
	          coverPath = imgItem2[1];
	        }
	      }
	    }
	    console.info('[EPUB] coverPath="' + coverPath + '"');

	    // ISBN
    const isbnMatch = opfXml.match(/<dc:identifier[^>]*>[\s]*(?:urn:isbn:)?(\d{10,13})/i);
    const isbn = isbnMatch ? isbnMatch[1] : '';

	    return { title, author, coverPath, coverData: null, description: desc, language: lang, publisher: pub, isbn, date };
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
      if (idM && hrefM) {
        map[idM[1]] = hrefM[1];
      }
    }
    return map;
  }

  /**
   * 解析 spine（阅读顺序）
   */
  private parseSpine(opfXml: string): Array<{ id: string; linearNo: boolean }> {
    const order: Array<{ id: string; linearNo: boolean }> = [];
    const regex = /<itemref\s+([^>]*)\/?>/gi;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(opfXml)) !== null) {
      const idM = match[1].match(/idref\s*=\s*["']([^"']+)["']/i);
      if (idM) {
        const linearNo = /linear\s*=\s*["']no["']/i.test(match[1]);
        order.push({ id: idM[1], linearNo });
      }
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
   * 递归解析 NCX 目录（支持嵌套 navPoint，如 卷→回→章）
   */
  private parseNcxRecursive(ncxXml: string): Array<{ id: string; title: string; href: string }> {
    const navMap: Array<{ id: string; title: string; href: string }> = [];
    this.parseNcxLevel_(ncxXml, navMap);
    return navMap;
  }

  /** 递归处理一层 navPoint，将叶子节点展平到 navMap */
  private parseNcxLevel_(xml: string, result: Array<{ id: string; title: string; href: string }>): void {
    const navPointRegex = /<navPoint[^>]*>([\s\S]*?)<\/navPoint>/gi;
    let npMatch: RegExpExecArray | null;
    while ((npMatch = navPointRegex.exec(xml)) !== null) {
      const content = npMatch[1];

      // 检查是否有子 navPoint
      const hasChildren = /<navPoint[^>]*>[\s\S]*?<\/navPoint>/i.test(content);

      const titleM = content.match(/<text>([^<]*)<\/text>/i);
      const srcM = content.match(/<content\s+src\s*=\s*["']([^"']+)["']/i);
      const idM = npMatch[0].match(/id\s*=\s*["']([^"']+)["']/i);

      if (hasChildren) {
        // 有子节点：先递归处理子 navPoint
        this.parseNcxLevel_(content, result);
      } else if (srcM) {
        // 叶子节点：添加到目录
        const href = srcM[1].split('#')[0];
        result.push({
          id: idM ? idM[1] : '',
          title: titleM ? titleM[1].trim() : '无标题',
          href,
        });
      }
    }
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
