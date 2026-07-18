/**
 * EPUB 生成器（EPUB 2.0 + NCX）
 *
 * 结构对齐安卓 Legado（me.ag2s.epublib 产物）：
 *   mimetype（第一个条目，STORED 不压缩）
 *   META-INF/container.xml
 *   OEBPS/content.opf / toc.ncx / Styles/main.css
 *   OEBPS/Text/cover.xhtml / intro.xhtml / chapter_N.xhtml
 *   OEBPS/Images/cover.jpg
 *
 * 模板在 resources/rawfile/epub_export/ 下，读取失败时用内置兜底模板。
 * 正文的 <img> 标签保留原始网络地址，不内嵌图片（一期范围）。
 */
import { ZipWriter } from '../../util/ZipWriter';
import http from '@ohos.net.http';
import util from '@ohos.util';
import { common } from '@kit.AbilityKit';

export interface EpubChapter {
  title: string;
  /** 已净化/替换后的正文纯文本（可能含 <img> 标签） */
  content: string;
}

export interface EpubData {
  name: string;
  author: string;
  /** 纯文本简介 */
  introduce: string;
  coverUrl: string;
  chapters: EpubChapter[];
}

interface CoverImage {
  bytes: Uint8Array;
  ext: string;
  mediaType: string;
}

interface EpubTemplates {
  chapter: string;
  cover: string;
  intro: string;
  css: string;
}

const FALLBACK_CHAPTER = `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <link rel="stylesheet" type="text/css" href="../Styles/main.css" />
  <title>{title}</title>
</head>
<body>
  <h2 class="head">{title}</h2>
{content}
</body>
</html>
`;

const FALLBACK_COVER = `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <link rel="stylesheet" type="text/css" href="../Styles/main.css" />
  <title>封面</title>
</head>
<body class="cover">
  <div class="cover-image"><img src="../Images/cover.jpg" alt="封面" /></div>
  <h1 class="cover-title">{name}</h1>
  <h3 class="cover-author">{author}</h3>
</body>
</html>
`;

const FALLBACK_INTRO = `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <link rel="stylesheet" type="text/css" href="../Styles/main.css" />
  <title>内容简介</title>
</head>
<body>
  <h1>内容简介</h1>
{intro}
</body>
</html>
`;

const FALLBACK_CSS = `body { margin: 1em 0.5em; line-height: 1.6; }
h2.head { font-size: 1.2em; border-bottom: 1px solid #999; padding-bottom: 0.5em; margin-bottom: 1em; }
p { text-indent: 2em; margin: 0.4em 0; }
img { max-width: 100%; }
.duokan-image-single { text-align: center; margin: 0.5em 0; }
body.cover { text-align: center; }
.cover-image img { max-width: 80%; margin: 2em auto 1em; }
.cover-title { font-size: 1.4em; margin: 0.5em 0; }
.cover-author { font-weight: normal; color: #666; }
`;

export class EpubBuilder {
  /**
   * 生成 EPUB 写入 targetPath（picker 返回的 uri 或目录拼接路径）。
   * 异常会向上抛出（文件不可写、模板渲染失败等）。
   */
  static async build(data: EpubData, targetPath: string, context: common.Context | undefined,
    onProgress?: (done: number, total: number) => void): Promise<void> {
    const templates = EpubBuilder.loadTemplates(context);
    const cover = await EpubBuilder.fetchCover(data.coverUrl);
    const uuid = EpubBuilder.randomUuid();

    const zip = ZipWriter.open(targetPath);
    try {
      // 规范：mimetype 必须是第一个条目且不压缩
      await zip.addText('mimetype', 'application/epub+zip');
      await zip.addText('META-INF/container.xml', EpubBuilder.buildContainerXml());
      await zip.addText('OEBPS/Styles/main.css', templates.css);

      const hasCover = cover !== null;
      if (hasCover) {
        await zip.addStored('OEBPS/Images/cover.' + cover!.ext, cover!.bytes);
        const coverHtml = templates.cover
          .split('{name}').join(EpubBuilder.escapeXml(data.name))
          .split('{author}').join(EpubBuilder.escapeXml(data.author));
        await zip.addText('OEBPS/Text/cover.xhtml', coverHtml);
      }

      const intro = (data.introduce || '').trim();
      const hasIntro = intro.length > 0;
      if (hasIntro) {
        const introHtml = templates.intro
          .split('{intro}').join(EpubBuilder.contentToXhtml(intro));
        await zip.addText('OEBPS/Text/intro.xhtml', introHtml);
      }

      const total = data.chapters.length;
      for (let i = 0; i < total; i++) {
        const ch = data.chapters[i];
        const html = templates.chapter
          .split('{title}').join(EpubBuilder.escapeXml(ch.title))
          .split('{content}').join(EpubBuilder.contentToXhtml(ch.content));
        await zip.addText('OEBPS/Text/chapter_' + (i + 1) + '.xhtml', html);
        if (onProgress) onProgress(i + 1, total);
      }

      await zip.addText('OEBPS/content.opf',
        EpubBuilder.buildOpf(data, uuid, hasCover, hasIntro, cover));
      await zip.addText('OEBPS/toc.ncx',
        EpubBuilder.buildNcx(data, uuid, hasCover, hasIntro));
      await zip.finish();
    } catch (e) {
      zip.abort();
      throw e;
    }
  }

  // ============================================================
  // 模板加载（rawfile 优先，内置兜底）
  // ============================================================
  private static loadTemplates(context: common.Context | undefined): EpubTemplates {
    const templates: EpubTemplates = {
      chapter: FALLBACK_CHAPTER,
      cover: FALLBACK_COVER,
      intro: FALLBACK_INTRO,
      css: FALLBACK_CSS,
    };
    if (!context) return templates;
    try {
      const rm = context.resourceManager;
      const decoder = new util.TextDecoder('utf-8');
      templates.chapter = decoder.decodeToString(rm.getRawFileContentSync('epub_export/chapter.xhtml'));
      templates.cover = decoder.decodeToString(rm.getRawFileContentSync('epub_export/cover.xhtml'));
      templates.intro = decoder.decodeToString(rm.getRawFileContentSync('epub_export/intro.xhtml'));
      templates.css = decoder.decodeToString(rm.getRawFileContentSync('epub_export/main.css'));
    } catch (e) {
      console.warn('[EpubBuilder] rawfile templates unavailable, use fallback:', (e as Error).message);
    }
    return templates;
  }

  // ============================================================
  // 封面抓取（魔数识别图片类型，识别不了就不嵌封面）
  // ============================================================
  private static async fetchCover(coverUrl: string): Promise<CoverImage | null> {
    if (!coverUrl || (!coverUrl.startsWith('http://') && !coverUrl.startsWith('https://'))) {
      return null;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(coverUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 10000,
      });
      if (resp.responseCode < 200 || resp.responseCode >= 400) return null;
      if (!(resp.result instanceof ArrayBuffer)) return null;
      const bytes = new Uint8Array(resp.result as ArrayBuffer);
      return EpubBuilder.detectImage(bytes);
    } catch (e) {
      console.warn('[EpubBuilder] fetch cover fail:', (e as Error).message);
      return null;
    } finally {
      req.destroy();
    }
  }

  private static detectImage(bytes: Uint8Array): CoverImage | null {
    if (bytes.length < 12) return null;
    // JPEG: FF D8 FF
    if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
      return { bytes: bytes, ext: 'jpg', mediaType: 'image/jpeg' };
    }
    // PNG: 89 50 4E 47
    if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
      return { bytes: bytes, ext: 'png', mediaType: 'image/png' };
    }
    // GIF: 47 49 46
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
      return { bytes: bytes, ext: 'gif', mediaType: 'image/gif' };
    }
    // WEBP: RIFF....WEBP
    if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
      && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
      return { bytes: bytes, ext: 'webp', mediaType: 'image/webp' };
    }
    return null;
  }

  // ============================================================
  // OPF / NCX / container.xml
  // ============================================================
  private static buildContainerXml(): string {
    return '<?xml version="1.0" encoding="utf-8"?>\n'
      + '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
      + '  <rootfiles>\n'
      + '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
      + '  </rootfiles>\n'
      + '</container>\n';
  }

  private static buildOpf(data: EpubData, uuid: string, hasCover: boolean, hasIntro: boolean,
    cover: CoverImage | null): string {
    const date = new Date().toISOString().substring(0, 10);
    let manifest = '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
      + '    <item id="css" href="Styles/main.css" media-type="text/css"/>\n';
    let spine = '';
    if (hasCover) {
      manifest += '    <item id="cover-image" href="Images/cover.' + cover!.ext + '" media-type="' + cover!.mediaType + '"/>\n'
        + '    <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>\n';
      spine += '    <itemref idref="cover"/>\n';
    }
    if (hasIntro) {
      manifest += '    <item id="intro" href="Text/intro.xhtml" media-type="application/xhtml+xml"/>\n';
      spine += '    <itemref idref="intro"/>\n';
    }
    for (let i = 0; i < data.chapters.length; i++) {
      manifest += '    <item id="chapter_' + (i + 1) + '" href="Text/chapter_' + (i + 1)
        + '.xhtml" media-type="application/xhtml+xml"/>\n';
      spine += '    <itemref idref="chapter_' + (i + 1) + '"/>\n';
    }

    return '<?xml version="1.0" encoding="utf-8"?>\n'
      + '<package version="2.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">\n'
      + '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n'
      + '    <dc:title>' + EpubBuilder.escapeXml(data.name) + '</dc:title>\n'
      + '    <dc:creator opf:role="aut" opf:file-as="' + EpubBuilder.escapeXml(data.author) + '">'
      + EpubBuilder.escapeXml(data.author) + '</dc:creator>\n'
      + '    <dc:language>zh</dc:language>\n'
      + '    <dc:identifier id="bookid">urn:uuid:' + uuid + '</dc:identifier>\n'
      + '    <dc:publisher>Legado</dc:publisher>\n'
      + '    <dc:description>' + EpubBuilder.escapeXml(data.introduce || '') + '</dc:description>\n'
      + '    <dc:date>' + date + '</dc:date>\n'
      + (hasCover ? '    <meta name="cover" content="cover-image"/>\n' : '')
      + '  </metadata>\n'
      + '  <manifest>\n' + manifest + '  </manifest>\n'
      + '  <spine toc="ncx">\n' + spine + '  </spine>\n'
      + (hasCover
        ? '  <guide>\n    <reference type="cover" title="封面" href="Text/cover.xhtml"/>\n  </guide>\n'
        : '')
      + '</package>\n';
  }

  private static buildNcx(data: EpubData, uuid: string, hasCover: boolean, hasIntro: boolean): string {
    let navPoints = '';
    let order = 1;
    if (hasCover) {
      navPoints += EpubBuilder.navPoint(order, order, '封面', 'Text/cover.xhtml');
      order++;
    }
    if (hasIntro) {
      navPoints += EpubBuilder.navPoint(order, order, '内容简介', 'Text/intro.xhtml');
      order++;
    }
    for (let i = 0; i < data.chapters.length; i++) {
      navPoints += EpubBuilder.navPoint(order, order, data.chapters[i].title,
        'Text/chapter_' + (i + 1) + '.xhtml');
      order++;
    }
    return '<?xml version="1.0" encoding="utf-8"?>\n'
      + '<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">\n'
      + '  <head>\n'
      + '    <meta name="dtb:uid" content="urn:uuid:' + uuid + '"/>\n'
      + '    <meta name="dtb:depth" content="1"/>\n'
      + '    <meta name="dtb:totalPageCount" content="0"/>\n'
      + '    <meta name="dtb:maxPageNumber" content="0"/>\n'
      + '  </head>\n'
      + '  <docTitle><text>' + EpubBuilder.escapeXml(data.name) + '</text></docTitle>\n'
      + '  <navMap>\n' + navPoints + '  </navMap>\n'
      + '</ncx>\n';
  }

  private static navPoint(id: number, playOrder: number, label: string, src: string): string {
    return '    <navPoint id="np-' + id + '" playOrder="' + playOrder + '">'
      + '<navLabel><text>' + EpubBuilder.escapeXml(label) + '</text></navLabel>'
      + '<content src="' + src + '"/></navPoint>\n';
  }

  // ============================================================
  // 正文 → xhtml 片段：按行包 <p>，整行是 <img> 时包图床 div，标签保留
  // ============================================================
  private static contentToXhtml(content: string): string {
    const out: string[] = [];
    const lines = content.split('\n');
    for (const raw of lines) {
      const line = raw.trim();
      if (!line) continue;
      if (/^<img[^>]+>$/i.test(line)) {
        out.push('<div class="duokan-image-single">' + line + '</div>');
      } else {
        out.push('<p>' + EpubBuilder.escapeHtmlKeepImg(line) + '</p>');
      }
    }
    return out.join('\n');
  }

  /** 转义 HTML，但保留 <img> 标签原样（对齐安卓 StringUtil.formatHtml 的行为） */
  private static escapeHtmlKeepImg(text: string): string {
    const parts = text.split(/(<img[^>]*>)/i);
    let out = '';
    for (const part of parts) {
      if (!part) continue;
      if (/^<img[^>]*>$/i.test(part)) {
        out += part;
      } else {
        out += EpubBuilder.escapeXml(part);
      }
    }
    return out;
  }

  private static escapeXml(text: string): string {
    return (text || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  private static randomUuid(): string {
    let uuid = '';
    for (let i = 0; i < 32; i++) {
      const c = Math.floor(Math.random() * 16);
      uuid += c.toString(16);
      if (i === 7 || i === 11 || i === 15 || i === 19) uuid += '-';
    }
    return uuid;
  }
}
