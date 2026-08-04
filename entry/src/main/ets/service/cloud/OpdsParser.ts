/**
 * OPDS 目录解析器。
 *
 * 支持：
 * - OPDS 1.x（Atom XML navigation/acquisition feed）
 * - OPDS 2.0（JSON navigation/publications）
 *
 * 解析层不做网络请求，也不依赖 ArkUI，便于单元测试。
 */

export interface OpdsNavigationEntry {
  title: string;
  url: string;
  isNextPage: boolean;
}

export interface OpdsAcquisitionEntry {
  title: string;
  author: string;
  formatTitle: string;
  url: string;
  contentType: string;
  size: number;
  updatedAt: number;
  remoteId: string;
}

export interface OpdsCatalogPage {
  title: string;
  navigation: OpdsNavigationEntry[];
  acquisitions: OpdsAcquisitionEntry[];
  /** rel=search 指向的搜索模板或 OpenSearch Description 地址。 */
  searchUrl: string;
  searchType: string;
}

interface OpdsLinkValue {
  href: string;
  rel: string;
  type: string;
  title: string;
  length: number;
}

export class OpdsParser {
  static parse(payload: string, requestUrl: string): OpdsCatalogPage {
    const text = (payload || '').trim();
    if (!text) {
      throw new Error('OPDS 返回为空');
    }
    if (text.startsWith('{')) {
      return OpdsParser.parseJson_(text, requestUrl);
    }
    if (text.startsWith('<')) {
      return OpdsParser.parseXml_(text, requestUrl);
    }
    throw new Error('服务返回的不是 OPDS XML/JSON');
  }

  static resolveUrl(baseUrl: string, href: string): string {
    let value = OpdsParser.decodeEntities_(href || '').trim();
    if (!value) {
      return '';
    }
    if (new RegExp('^https?://', 'i').test(value)) {
      return value;
    }
    const base = (baseUrl || '').trim();
    const originMatch = base.match(new RegExp('^(https?://[^/?#]+)', 'i'));
    if (!originMatch) {
      return '';
    }
    const origin = originMatch[1];
    if (value.startsWith('//')) {
      const schemeMatch = origin.match(new RegExp('^(https?):', 'i'));
      return (schemeMatch ? schemeMatch[1] : 'https') + ':' + value;
    }
    if (value.startsWith('?')) {
      return base.split('#')[0].split('?')[0] + value;
    }
    if (value.startsWith('#')) {
      return base.split('#')[0] + value;
    }
    if (value.startsWith('/')) {
      return origin + OpdsParser.normalizeUrlPath_(value);
    }
    let basePath = base.substring(origin.length);
    const queryIndex = basePath.indexOf('?');
    if (queryIndex >= 0) {
      basePath = basePath.substring(0, queryIndex);
    }
    const hashIndex = basePath.indexOf('#');
    if (hashIndex >= 0) {
      basePath = basePath.substring(0, hashIndex);
    }
    const slash = basePath.lastIndexOf('/');
    const parent = slash >= 0 ? basePath.substring(0, slash + 1) : '/';
    return origin + OpdsParser.normalizeUrlPath_(parent + value);
  }

  static extensionFor(contentType: string, url: string): string {
    const type = (contentType || '').toLowerCase();
    const lowerUrl = (url || '').toLowerCase();
    if (type.indexOf('epub') >= 0 || lowerUrl.indexOf('.epub') >= 0) {
      return 'epub';
    }
    if (type.indexOf('pdf') >= 0 || lowerUrl.indexOf('.pdf') >= 0) {
      return 'pdf';
    }
    if (type.indexOf('mobipocket') >= 0 || lowerUrl.indexOf('.mobi') >= 0) {
      return 'mobi';
    }
    if (type.indexOf('amazon') >= 0 || lowerUrl.indexOf('.azw3') >= 0 ||
      lowerUrl.indexOf('.kf8') >= 0) {
      return 'azw3';
    }
    if (type.indexOf('text/plain') >= 0 || lowerUrl.indexOf('.txt') >= 0) {
      return 'txt';
    }
    return '';
  }

  static fileName(entry: OpdsAcquisitionEntry): string {
    let base = (entry.title || '未命名书籍').replace(new RegExp('[\\\\/:*?"<>|]', 'g'), '_').trim();
    const format = (entry.formatTitle || '').replace(new RegExp('[\\\\/:*?"<>|]', 'g'), '_').trim();
    if (format && base.toLowerCase().indexOf(format.toLowerCase()) < 0) {
      base += ' · ' + format;
    }
    const ext = OpdsParser.extensionFor(entry.contentType, entry.url);
    if (ext && !base.toLowerCase().endsWith('.' + ext)) {
      base += '.' + ext;
    }
    return base;
  }

  /** 从 OpenSearch Description 中提取 Atom/OPDS 搜索模板。 */
  static parseOpenSearchTemplate(payload: string, requestUrl: string): string {
    const xml = (payload || '').trim();
    if (!new RegExp('<(?:[a-zA-Z0-9_-]+:)?OpenSearchDescription\\b', 'i').test(xml)) {
      throw new Error('未识别到 OpenSearch 描述');
    }
    const regex = new RegExp('<(?:[a-zA-Z0-9_-]+:)?Url\\b([^>]*)\\/?>', 'gi');
    let fallback = '';
    let match: RegExpExecArray | null = regex.exec(xml);
    while (match !== null) {
      const attrs = OpdsParser.attributes_(match[1]);
      const template = attrs['template'] || '';
      if (template.indexOf('{searchTerms}') < 0) {
        match = regex.exec(xml);
        continue;
      }
      const resolved = OpdsParser.resolveUrl(requestUrl, template);
      const type = (attrs['type'] || '').toLowerCase();
      if (type.indexOf('atom+xml') >= 0 || type.indexOf('opds+json') >= 0) {
        return resolved;
      }
      if (!fallback) {
        fallback = resolved;
      }
      match = regex.exec(xml);
    }
    if (fallback) {
      return fallback;
    }
    throw new Error('OpenSearch 未声明可用的 {searchTerms} 模板');
  }

  private static parseXml_(xml: string, requestUrl: string): OpdsCatalogPage {
    if (!new RegExp('<(?:[a-zA-Z0-9_-]+:)?feed\\b', 'i').test(xml)) {
      throw new Error('未识别到 OPDS Atom feed');
    }
    const entryRegex = new RegExp(
      '<(?:[a-zA-Z0-9_-]+:)?entry\\b[^>]*>[\\s\\S]*?<\\/(?:[a-zA-Z0-9_-]+:)?entry>',
      'gi'
    );
    const entryBlocks: string[] = [];
    let entryMatch: RegExpExecArray | null = entryRegex.exec(xml);
    while (entryMatch !== null) {
      entryBlocks.push(entryMatch[0]);
      entryMatch = entryRegex.exec(xml);
    }
    const feedOnly = xml.replace(entryRegex, '');
    const page: OpdsCatalogPage = {
      title: OpdsParser.tagText_(feedOnly, 'title') || 'OPDS 书库',
      navigation: [],
      acquisitions: [],
      searchUrl: '',
      searchType: '',
    };

    for (let i = 0; i < entryBlocks.length; i++) {
      const block = entryBlocks[i];
      const title = OpdsParser.tagText_(block, 'title') || '未命名';
      const authorBlock = OpdsParser.tagBlock_(block, 'author');
      let author = OpdsParser.tagText_(authorBlock, 'name');
      const content = OpdsParser.tagText_(block, 'content');
      if (!author && content && content.length < 200) {
        author = content;
      }
      const updatedRaw = OpdsParser.tagText_(block, 'updated') ||
        OpdsParser.tagText_(block, 'published');
      const updatedAt = updatedRaw ? (Date.parse(updatedRaw) || 0) : 0;
      const remoteId = OpdsParser.tagText_(block, 'id');
      const links = OpdsParser.xmlLinks_(block, requestUrl);
      let acquisitionCount = 0;
      for (let j = 0; j < links.length; j++) {
        const link = links[j];
        if (OpdsParser.isAcquisition_(link)) {
          page.acquisitions.push({
            title: title,
            author: author,
            formatTitle: link.title,
            url: link.href,
            contentType: link.type,
            size: link.length,
            updatedAt: updatedAt,
            remoteId: remoteId || link.href,
          });
          acquisitionCount++;
        }
      }
      if (acquisitionCount === 0) {
        for (let j = 0; j < links.length; j++) {
          const link = links[j];
          if (OpdsParser.isNavigation_(link)) {
            page.navigation.push({
              title: author ? (title + ' — ' + author) : title,
              url: link.href,
              isNextPage: false,
            });
            break;
          }
        }
      }
    }

    const feedLinks = OpdsParser.xmlLinks_(feedOnly, requestUrl);
    // 先单独收集 rel=search：next 的 break 不能让排在它后面的 search link
    // 被跳过（部分站点 next 声明在 search 之前，会漏掉搜索模板）。
    for (let i = 0; i < feedLinks.length; i++) {
      const link = feedLinks[i];
      if (OpdsParser.hasRel_(link.rel, 'search') && link.href && !page.searchUrl) {
        page.searchUrl = link.href;
        page.searchType = link.type;
      }
    }
    for (let i = 0; i < feedLinks.length; i++) {
      const link = feedLinks[i];
      if (OpdsParser.hasRel_(link.rel, 'next') && link.href) {
        page.navigation.push({
          title: link.title || '下一页',
          url: link.href,
          isNextPage: true,
        });
        break;
      }
    }
    return page;
  }

  private static parseJson_(json: string, requestUrl: string): OpdsCatalogPage {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(json) as Record<string, Object>;
    } catch (_e) {
      throw new Error('OPDS 2.0 JSON 解析失败');
    }
    // Project Gutenberg 官方 OPDS 可能按出口 IP 自动返回 403。
    // Gutendex 是其公开元数据的 JSON API，作为内置书库的只读目录降级来源。
    if (Array.isArray(root['results']) && typeof root['count'] === 'number') {
      return OpdsParser.parseGutendex_(root);
    }
    const metadata = OpdsParser.record_(root['metadata']);
    const page: OpdsCatalogPage = {
      title: OpdsParser.string_(metadata['title']) || 'OPDS 书库',
      navigation: [],
      acquisitions: [],
      searchUrl: '',
      searchType: '',
    };

    const navigation = OpdsParser.recordArray_(root['navigation']);
    for (let i = 0; i < navigation.length; i++) {
      const row = navigation[i];
      const href = OpdsParser.resolveUrl(requestUrl, OpdsParser.string_(row['href']));
      if (!href) {
        continue;
      }
      page.navigation.push({
        title: OpdsParser.string_(row['title']) || '目录',
        url: href,
        isNextPage: false,
      });
    }

    const publications = OpdsParser.recordArray_(root['publications']);
    for (let i = 0; i < publications.length; i++) {
      const publication = publications[i];
      const meta = OpdsParser.record_(publication['metadata']);
      const title = OpdsParser.string_(meta['title']) || '未命名';
      const author = OpdsParser.authorFromJson_(meta['author']);
      const modified = OpdsParser.string_(meta['modified']) || OpdsParser.string_(meta['published']);
      const updatedAt = modified ? (Date.parse(modified) || 0) : 0;
      const remoteId = OpdsParser.string_(meta['identifier']);
      const links = OpdsParser.jsonLinks_(publication['links'], requestUrl);
      for (let j = 0; j < links.length; j++) {
        const link = links[j];
        if (!OpdsParser.isAcquisition_(link)) {
          continue;
        }
        page.acquisitions.push({
          title: title,
          author: author,
          formatTitle: link.title,
          url: link.href,
          contentType: link.type,
          size: link.length,
          updatedAt: updatedAt,
          remoteId: remoteId || link.href,
        });
      }
    }

    const rootLinks = OpdsParser.jsonLinks_(root['links'], requestUrl);
    // 与 XML 分支一致：search 收集独立于 next 的 break，避免顺序依赖漏掉搜索模板。
    for (let i = 0; i < rootLinks.length; i++) {
      const link = rootLinks[i];
      if (OpdsParser.hasRel_(link.rel, 'search') && link.href && !page.searchUrl) {
        page.searchUrl = link.href;
        page.searchType = link.type;
      }
    }
    for (let i = 0; i < rootLinks.length; i++) {
      const link = rootLinks[i];
      if (OpdsParser.hasRel_(link.rel, 'next') && link.href) {
        page.navigation.push({
          title: link.title || '下一页',
          url: link.href,
          isNextPage: true,
        });
        break;
      }
    }
    return page;
  }

  private static parseGutendex_(root: Record<string, Object>): OpdsCatalogPage {
    const page: OpdsCatalogPage = {
      title: 'Project Gutenberg（备用目录）',
      navigation: [],
      acquisitions: [],
      searchUrl: '',
      searchType: '',
    };
    const books = OpdsParser.recordArray_(root['results']);
    for (let i = 0; i < books.length; i++) {
      const book = books[i];
      const rawId = book['id'];
      const id = typeof rawId === 'number' ? rawId as number : parseInt(String(rawId || '0'), 10);
      if (id <= 0) {
        continue;
      }
      const formats = OpdsParser.record_(book['formats']);
      let epubUrl = OpdsParser.string_(formats['application/epub+zip']);
      if (!epubUrl) {
        const keys = Object.keys(formats);
        for (let j = 0; j < keys.length; j++) {
          if (keys[j].toLowerCase().indexOf('application/epub') === 0) {
            epubUrl = OpdsParser.string_(formats[keys[j]]);
            break;
          }
        }
      }
      if (!epubUrl) {
        continue;
      }
      // 使用 Project Gutenberg 官方镜像列表中的高速镜像，避免主站 IP 封禁影响下载。
      const withImages = epubUrl.toLowerCase().indexOf('images') >= 0;
      const mirrorUrl = 'https://gutenberg.pglaf.org/cache/epub/' + id.toString() +
        '/pg' + id.toString() + (withImages ? '-images' : '') + '.epub';
      page.acquisitions.push({
        title: OpdsParser.string_(book['title']) || ('Gutenberg #' + id.toString()),
        author: OpdsParser.authorFromJson_(book['authors']),
        formatTitle: 'EPUB',
        url: mirrorUrl,
        contentType: 'application/epub+zip',
        size: 0,
        updatedAt: 0,
        remoteId: 'gutenberg:' + id.toString(),
      });
    }
    const next = OpdsParser.string_(root['next']);
    if (next) {
      page.navigation.push({
        title: '下一页',
        url: next,
        isNextPage: true,
      });
    }
    return page;
  }

  private static xmlLinks_(block: string, requestUrl: string): OpdsLinkValue[] {
    const out: OpdsLinkValue[] = [];
    const regex = new RegExp('<(?:[a-zA-Z0-9_-]+:)?link\\b([^>]*)\\/?>', 'gi');
    let match: RegExpExecArray | null = regex.exec(block);
    while (match !== null) {
      const attrs = OpdsParser.attributes_(match[1]);
      const href = OpdsParser.resolveUrl(requestUrl, attrs['href'] || '');
      if (href) {
        out.push({
          href: href,
          rel: attrs['rel'] || '',
          type: attrs['type'] || '',
          title: attrs['title'] || '',
          length: parseInt(attrs['length'] || '0', 10) || 0,
        });
      }
      match = regex.exec(block);
    }
    return out;
  }

  private static jsonLinks_(value: Object | undefined, requestUrl: string): OpdsLinkValue[] {
    const rows = OpdsParser.recordArray_(value);
    const out: OpdsLinkValue[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      const href = OpdsParser.resolveUrl(requestUrl, OpdsParser.string_(row['href']));
      if (!href) {
        continue;
      }
      let rel = '';
      if (Array.isArray(row['rel'])) {
        const rels = row['rel'] as Object[];
        const values: string[] = [];
        for (let j = 0; j < rels.length; j++) {
          values.push(String(rels[j]));
        }
        rel = values.join(' ');
      } else {
        rel = OpdsParser.string_(row['rel']);
      }
      const lengthValue = row['length'];
      out.push({
        href: href,
        rel: rel,
        type: OpdsParser.string_(row['type']),
        title: OpdsParser.string_(row['title']),
        length: typeof lengthValue === 'number' ? lengthValue as number : 0,
      });
    }
    return out;
  }

  private static isAcquisition_(link: OpdsLinkValue): boolean {
    if (link.rel.toLowerCase().indexOf('acquisition') >= 0) {
      return true;
    }
    return OpdsParser.extensionFor(link.type, link.href).length > 0 &&
      link.rel.toLowerCase().indexOf('image') < 0;
  }

  private static isNavigation_(link: OpdsLinkValue): boolean {
    const rel = link.rel.toLowerCase();
    if (rel.indexOf('subsection') >= 0 || rel.indexOf('collection') >= 0) {
      return true;
    }
    return link.type.toLowerCase().indexOf('opds-catalog') >= 0 &&
      rel.indexOf('related') < 0 && rel.indexOf('self') < 0 &&
      rel.indexOf('start') < 0;
  }

  private static hasRel_(raw: string, expected: string): boolean {
    const parts = (raw || '').toLowerCase().split(new RegExp('\\s+'));
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === expected.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  private static attributes_(raw: string): Record<string, string> {
    const attrs: Record<string, string> = {};
    const regex = new RegExp('([a-zA-Z_:][a-zA-Z0-9_.:-]*)\\s*=\\s*(["\\\'])([\\s\\S]*?)\\2', 'g');
    let match: RegExpExecArray | null = regex.exec(raw || '');
    while (match !== null) {
      attrs[match[1].toLowerCase()] = OpdsParser.decodeEntities_(match[3]);
      match = regex.exec(raw || '');
    }
    return attrs;
  }

  private static tagBlock_(xml: string, tag: string): string {
    if (!xml) {
      return '';
    }
    const regex = new RegExp(
      '<(?:[a-zA-Z0-9_-]+:)?' + tag + '\\b[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z0-9_-]+:)?' + tag + '>',
      'i'
    );
    const match = xml.match(regex);
    return match ? match[1] : '';
  }

  private static tagText_(xml: string, tag: string): string {
    const block = OpdsParser.tagBlock_(xml, tag);
    if (!block) {
      return '';
    }
    return OpdsParser.decodeEntities_(
      block.replace(new RegExp('<br\\s*\\/?>', 'gi'), '\n')
        .replace(new RegExp('<[^>]+>', 'g'), ' ')
    ).replace(new RegExp('\\s+', 'g'), ' ').trim();
  }

  private static decodeEntities_(raw: string): string {
    return (raw || '')
      .replace(new RegExp('&amp;', 'gi'), '&')
      .replace(new RegExp('&lt;', 'gi'), '<')
      .replace(new RegExp('&gt;', 'gi'), '>')
      .replace(new RegExp('&quot;', 'gi'), '"')
      .replace(new RegExp('&apos;|&#39;', 'gi'), "'")
      .replace(new RegExp('&#(\\d+);', 'g'), (_all: string, value: string): string => {
        return String.fromCharCode(parseInt(value, 10) || 0);
      })
      .replace(new RegExp('&#x([0-9a-f]+);', 'gi'), (_all: string, value: string): string => {
        return String.fromCharCode(parseInt(value, 16) || 0);
      });
  }

  private static normalizeUrlPath_(raw: string): string {
    const queryIndex = raw.search(/[?#]/);
    const suffix = queryIndex >= 0 ? raw.substring(queryIndex) : '';
    const path = queryIndex >= 0 ? raw.substring(0, queryIndex) : raw;
    const parts = path.split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (!part || part === '.') {
        continue;
      }
      if (part === '..') {
        if (out.length > 0) {
          out.pop();
        }
      } else {
        out.push(part);
      }
    }
    return '/' + out.join('/') + suffix;
  }

  private static record_(value: Object | undefined): Record<string, Object> {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return {};
  }

  private static recordArray_(value: Object | undefined): Array<Record<string, Object>> {
    if (!Array.isArray(value)) {
      return [];
    }
    return value as Array<Record<string, Object>>;
  }

  private static string_(value: Object | undefined): string {
    return typeof value === 'string' ? value as string : '';
  }

  private static authorFromJson_(value: Object | undefined): string {
    const rows: Array<Record<string, Object>> = [];
    if (Array.isArray(value)) {
      const arr = value as Array<Record<string, Object>>;
      for (let i = 0; i < arr.length; i++) {
        rows.push(arr[i]);
      }
    } else {
      const one = OpdsParser.record_(value);
      if (Object.keys(one).length > 0) {
        rows.push(one);
      }
    }
    const names: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      const name = OpdsParser.string_(rows[i]['name']);
      if (name) {
        names.push(name);
      }
    }
    return names.join('、');
  }
}
