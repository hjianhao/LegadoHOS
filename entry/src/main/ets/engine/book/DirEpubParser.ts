/**
 * 目录 EPUB 解析器 — 从解压后的目录读取元数据和章节
 *
 * 目录结构：
 *   outputDir/
 *   ├── META-INF/container.xml
 *   └── OEBPS/ (或任意内容目录)
 *       ├── package.opf
 *       ├── chapter1.xhtml
 *       └── images/...
 */
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import { HtmlUtil } from '../../util/HtmlUtil';
import { BookChapter } from '../../model/BookChapter';

/** 解析结果 */
export interface DirEpubMeta {
  title: string;
  author: string;
  description: string;
  coverPath: string;   // 解压目录中的封面相对路径
}

export interface DirEpubResult {
  meta: DirEpubMeta;
  chapters: BookChapter[];
  opfDir: string;      // OPF 所在目录（用于计算相对路径）
}

export class DirEpubParser {
  private rootDir: string;
  private skipContent_: boolean;

  constructor(rootDir: string, skipContent?: boolean) {
    this.rootDir = rootDir.endsWith('/') ? rootDir : rootDir + '/';
    this.skipContent_ = skipContent ?? false;
  }
  async parse(): Promise<DirEpubResult> {
    // 1. 读 container.xml → OPF 路径
    const containerPath = this.rootDir + 'META-INF/container.xml';
    if (!this.exists_(containerPath)) {
      throw new Error('Invalid EPUB: missing META-INF/container.xml');
    }
    const containerXml = this.readTextFile_(containerPath);
    const opfRelPath = this.parseContainerXml_(containerXml);
    const opfPath = this.rootDir + opfRelPath;
    if (!this.exists_(opfPath)) {
      throw new Error('Invalid EPUB: missing OPF: ' + opfRelPath);
    }
    const opfXml = this.readTextFile_(opfPath);
    const opfDir = opfRelPath.substring(0, opfRelPath.lastIndexOf('/') + 1);

    // 2. 解析 OPF → 元数据 + manifest + spine
    const meta = this.parseOpfMeta_(opfXml);
    const manifest = this.parseManifest_(opfXml);
    const spineIds = this.parseSpine_(opfXml);

    // 3. 提取封面
    let coverData: ArrayBuffer | null = null;
    if (meta.coverPath) {
      const coverFullPath = this.resolvePath_(opfDir, meta.coverPath);
      const absPath = this.rootDir + coverFullPath;
      coverData = this.exists_(absPath) ? this.readBinaryFile_(absPath) : null;
    }

    // 建立 spine 索引（用于过滤 navMap + 后续合并）
    const hrefToSpineIdx: Record<string, number> = {};
    for (let si = 0; si < spineIds.length; si++) {
      const shref = manifest[spineIds[si]];
      if (shref) hrefToSpineIdx[shref] = si;
    }

    // 4. 解析目录 (NCX) — 优先使用 NCX（更精确的章节分组）
    let navMap: Array<{ id: string; title: string; href: string }> = [];
    let tocId = this.getTocId_(opfXml);
    console.info('[DirEpub] tocId from spine attr:', tocId || '(none)', 'opfDir:', opfDir);
    if (!tocId) {
      const ncxMatch = opfXml.match(/<item[^>]*?media-type\s*=\s*["']application\/x-dtbncx\+xml["'][^>]*?\sid\s*=\s*["']([^"']+)["']/i);
      tocId = ncxMatch ? ncxMatch[1] : '';
      console.info('[DirEpub] tocId from media-type:', tocId || '(none)');
    }
    if (tocId && manifest[tocId]) {
      const manifestHref = manifest[tocId];
      const tocPath = this.resolvePath_(opfDir, manifestHref);
      const absPath = this.rootDir + tocPath;
      console.info('[DirEpub] NCX resolved:', absPath, 'exists:', this.exists_(absPath));
      if (this.exists_(absPath)) {
        const tocXml = this.readTextFile_(absPath);
        navMap = this.parseNcxFlat_(tocXml);
	      console.info('[DirEpub] NCX parsed:', navMap.length, 'entries');
	      // 过滤：只保留在 spine 中的条目（去掉卷级分组如"第一部"）
	      navMap = navMap.filter(n => hrefToSpineIdx[n.href] !== undefined);
	    console.info('[DirEpub] NCX after spine filter:', navMap.length, 'entries');
	    for (let di = 0; di < Math.min(50, navMap.length); di++) {
	      console.info('[DirEpub] navMap[' + di + ']:', navMap[di].title, '→ href:', navMap[di].href);
	    }
      }
    } else {
      console.info('[DirEpub] tocId not found in manifest');
    }

    // 方式 B: EPUB 3 nav 文档（manifest 中 properties="nav"）
    if (navMap.length === 0) {
      const navIdMatch = opfXml.match(/<item\s[^>]*?properties\s*=\s*["']nav["'][^>]*?\sid\s*=\s*["']([^"']+)["']/i);
      const navId = navIdMatch ? navIdMatch[1] : '';
      console.info('[DirEpub] navId:', navId || '(none)');
      if (navId && manifest[navId]) {
        const navHref = this.resolvePath_(opfDir, manifest[navId]);
        const absPath = this.rootDir + navHref;
        console.info('[DirEpub] nav path:', absPath, 'exists:', this.exists_(absPath));
        if (this.exists_(absPath)) {
          const navHtml = this.readTextFile_(absPath);
          const parsed = this.parseNav_(navHtml);
          navMap = parsed.map(n => ({ id: '', title: n.title, href: n.href }));
		          console.info('[DirEpub] nav parsed:', navMap.length, 'entries');
		          navMap = navMap.filter(n => hrefToSpineIdx[n.href] !== undefined);
		          console.info('[DirEpub] nav after spine filter:', navMap.length, 'entries');
        }
      }
    }

    // 兜底：从 spine 生成
    if (navMap.length === 0) {
      navMap = spineIds.map((id, idx) => ({
        id, title: `第 ${idx + 1} 章`, href: manifest[id] || '',
      }));
    }

    // =========================================================
    // 5. 按 navMap + spine 合并提取正文
    const now = Date.now();
    const chapters: BookChapter[] = [];

	    if (navMap.length > 0) {
		      for (let i = 0; i < navMap.length; i++) {
		        const nav = navMap[i];
		        let spineStart = hrefToSpineIdx[nav.href];
        let spineEnd = spineIds.length;
        for (let j = i + 1; j < navMap.length; j++) {
          const nextIdx = hrefToSpineIdx[navMap[j].href];
          if (nextIdx !== undefined) { spineEnd = nextIdx; break; }
        }

	        let combinedText = '';
	        let lastFullPath = '';
	        const startIdx = spineStart !== undefined ? spineStart : 0;
	        for (let si = startIdx; si < spineEnd; si++) {
	          const shref = manifest[spineIds[si]];
	          if (!shref) continue;
	          const fullPath = this.resolvePath_(opfDir, shref);
	          const absPath = this.rootDir + fullPath;
	          if (!this.exists_(absPath)) continue;
	          lastFullPath = fullPath;
	          if (!this.skipContent_) {
	            const html = this.readTextFile_(absPath);
	            let text = HtmlUtil.toPlainText(html);
	            if (combinedText && nav.title) {
	              const lines = text.split('\n');
	              while (lines.length > 0 && lines[0].trim() === nav.title) {
	                lines.shift();
	              }
	              text = lines.join('\n').trim();
	            }
	            if (html) combinedText += text + '\n';
	          }
	        }

	        if (!combinedText && !this.skipContent_) {
	          const fullPath = this.resolvePath_(opfDir, nav.href);
	          const absPath = this.rootDir + fullPath;
	          if (this.exists_(absPath)) {
	            const html = this.readTextFile_(absPath);
	            combinedText = HtmlUtil.toPlainText(html);
	            lastFullPath = fullPath;
	          }
	        }

	        const text = combinedText.trim();
        if (i < 3) {
          console.info('[EPUB] chapter "' + nav.title.substring(0, 20) + '" content=' + text.length + ' chars (spine ' + startIdx + '-' + spineEnd + ')');
        }

        chapters.push({
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
	      for (let i = 0; i < spineIds.length; i++) {
	        const id = spineIds[i];
	        const href = manifest[id];
	        if (!href) continue;
	        const fullPath = this.resolvePath_(opfDir, href);
	        const absPath = this.rootDir + fullPath;
	        if (!this.exists_(absPath)) continue;
	        let text = '';
	        if (!this.skipContent_) {
	          const html = this.readTextFile_(absPath);
	          text = HtmlUtil.toPlainText(html);
	        }
	        chapters.push({
	          id: 0, bookId: 0, index: i, volumeIndex: 0,
	          title: `第 ${i + 1} 章`, url: fullPath,
	          content: text,
	          contentLength: text.length,
          isRead: false, isDownloaded: false, isCached: true,
          duration: 0, audioUrl: '',
          createTime: now, updateTime: now,
        });
      }
    }

    return { meta, chapters, opfDir };
  }

  // ==================== 内部方法 ====================

  private exists_(path: string): boolean {
    try {
      return fileFs.accessSync(path);
    } catch (_e) {
      return false;
    }
  }

  private readBinaryFile_(path: string): ArrayBuffer {
    let fd: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fd = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(fd.fd, buf);
      return buf;
    } catch (err) {
      throw new Error(`Read EPUB file failed: ${path}: ${(err as Error).message}`);
    } finally {
      if (fd) {
        try {
          fileFs.closeSync(fd);
        } catch (err) {
          console.warn('[DirEpub] close file failed:', (err as Error).message);
        }
      }
    }
  }

  private readTextFile_(path: string): string {
    const buf = this.readBinaryFile_(path);
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    return decoder.decodeToString(new Uint8Array(buf));
  }

  private parseContainerXml_(xml: string): string {
    const m = xml.match(/(?:full-path|href)\s*=\s*["']([^"']+\.opf)["']/i);
    return m ? m[1] : 'content.opf';
  }

  private parseOpfMeta_(opfXml: string): DirEpubMeta {
    const getTag = (tag: string): string => {
      const m = opfXml.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'i'));
      return m ? m[1].trim() : '';
    };
    const title = getTag('dc:title') || getTag('title');
    const author = getTag('dc:creator') || getTag('creator');
    const desc = getTag('dc:description') || getTag('description');

    let coverPath = '';
    const coverMeta = opfXml.match(/<meta\s+name\s*=\s*["']cover["'][^>]*?\scontent\s*=\s*["']([^"']+)["']/i);
    if (coverMeta) {
      const id = coverMeta[1];
      const item = opfXml.match(new RegExp(`<item[^>]*?\\sid\\s*=\\s*["']${this.escapeRegex_(id)}["'][^>]*?\\shref\\s*=\\s*["']([^"']+)["']`, 'i'));
      if (item) coverPath = item[1];
    }
    if (!coverPath) {
      const img = opfXml.match(/<item[^>]*?\smedia-type\s*=\s*["']image\/[^"']+["'][^>]*?\shref\s*=\s*["']([^"']+)["']/i);
      if (img) coverPath = img[1];
    }

    return { title, author, description: desc, coverPath };
  }

  private parseManifest_(opfXml: string): Record<string, string> {
    const map: Record<string, string> = {};
    const regex = /<item\s+([^>]*)\/?>/gi;
    let m: RegExpExecArray | null;
    while ((m = regex.exec(opfXml)) !== null) {
      const idM = m[1].match(/id\s*=\s*["']([^"']+)["']/i);
      const hrefM = m[1].match(/href\s*=\s*["']([^"']+)["']/i);
      if (idM && hrefM) map[idM[1]] = hrefM[1];
    }
    return map;
  }

  private parseSpine_(opfXml: string): string[] {
    const ids: string[] = [];
    const regex = /<itemref\s+([^>]*)\/?>/gi;
    let m: RegExpExecArray | null;
    while ((m = regex.exec(opfXml)) !== null) {
      const idM = m[1].match(/idref\s*=\s*["']([^"']+)["']/i);
      if (idM) ids.push(idM[1]);
    }
    return ids;
  }

  private getTocId_(opfXml: string): string {
    const m = opfXml.match(/<spine[^>]*toc\s*=\s*["']([^"']+)["']/i);
    return m ? m[1] : '';
  }

  private parseNcxFlat_(ncxXml: string): Array<{ id: string; title: string; href: string }> {
    const result: Array<{ id: string; title: string; href: string }> = [];
    this.parseNcxLevel_(ncxXml, result);
    // 按 href 去重（保留第一个 = 父级标题），卷级分组会在 spine 过滤中去除
    const seen = new Set<string>();
    return result.filter(n => {
      if (seen.has(n.href)) return false;
      seen.add(n.href);
      return true;
    });
  }

  private parseNcxLevel_(xml: string, result: Array<{ id: string; title: string; href: string }>): void {
    // 基于深度计数解析 navPoint，正确处理嵌套（非贪婪 regex 会吞内层子节点）
    let i = 0;
    while (i < xml.length) {
      // 查找下一个 <navPoint
      const startTagBegin = xml.indexOf('<navPoint', i);
      if (startTagBegin < 0) break;
      const startTagEnd = xml.indexOf('>', startTagBegin);
      if (startTagEnd < 0) break;

      // 从 > 后开始，计数 <navPoint 和 </navPoint> 找到匹配的结束位置
      let depth = 1;
      let pos = startTagEnd + 1;
      while (depth > 0 && pos < xml.length) {
        const nextOpen = xml.indexOf('<navPoint', pos);
        const nextClose = xml.indexOf('</navPoint>', pos);
        if (nextClose < 0) break;
        if (nextOpen >= 0 && nextOpen < nextClose) {
          depth++;
          pos = nextOpen + 9; // len('<navPoint')
        } else {
          depth--;
          pos = nextClose + 11; // len('</navPoint>')
        }
      }
      const fullTag = xml.substring(startTagBegin, pos);
      i = pos;

      const srcM = fullTag.match(/<content\s+src\s*=\s*["']([^"']+)["']/i);
      if (!srcM) continue;
      const titleM = fullTag.match(/<text>([^<]*)<\/text>/i);
      const idM = fullTag.match(/id\s*=\s*["']([^"']+)["']/i);
      result.push({
        id: idM ? idM[1] : '',
        title: titleM ? titleM[1].trim() : '',
        href: srcM[1].split('#')[0],
      });
      // 递归处理子 navPoint
      const innerNav = fullTag.match(/<navPoint[^>]*>([\s\S]*)<\/navPoint>\s*$/i);
      if (innerNav) {
        this.parseNcxLevel_(innerNav[1], result);
      }
    }
  }

  private parseNav_(navHtml: string): Array<{ title: string; href: string }> {
    const result: Array<{ title: string; href: string }> = [];
    const navM = navHtml.match(/<nav[^>]*>([\s\S]*?)<\/nav>/i);
    if (!navM) return result;
    const olM = navM[1].match(/<ol[^>]*>([\s\S]*)<\/ol>/i);
    if (!olM) return result;
    let top = olM[1].replace(/<ol[^>]*>[\s\S]*?<\/ol>/gi, '');
    const aRx = /<a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
    let m: RegExpExecArray | null;
    while ((m = aRx.exec(top)) !== null) {
      result.push({
        href: m[1].split('#')[0],
        title: HtmlUtil.stripHtml(m[2]).trim(),
      });
    }
    return result;
  }

  private resolvePath_(base: string, relative: string): string {
    if (relative.startsWith('/')) return relative.substring(1);
    const parts = base.split('/').filter(p => p);
    for (const p of relative.split('/')) {
      if (p === '.' || p === '') continue;
      if (p === '..') parts.pop();
      else parts.push(p);
    }
    return parts.join('/');
  }

  private escapeRegex_(s: string): string {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
}
