/**
 * 优书网书库抓取与解析。
 *
 * 书库筛选链接由服务端生成，客户端直接解析并复用这些链接，避免绑定站点的
 * URL 参数细节，也能自动跟随分类、年份和首发站点的调整。
 */
import { NetUtil } from '../util/NetUtil';
import { getHtmlParser, HtmlElement, HtmlParser } from '../util/HtmlParser';

const YOUSHU_BASE_URL = 'https://www.youshu.me';
export const YOUSHU_BOOKS_URL = YOUSHU_BASE_URL + '/books';

export interface YoushuFilterOption {
  name: string;
  url: string;
  selected: boolean;
}

export interface YoushuFilterGroup {
  name: string;
  options: YoushuFilterOption[];
}

export interface YoushuBookItem {
  id: string;
  name: string;
  rating: string;
  ratingCount: string;
  author: string;
  totalVisits: string;
  lastUpdate: string;
  status: string;
  detailUrl: string;
}

export interface YoushuBookPage {
  filters: YoushuFilterGroup[];
  books: YoushuBookItem[];
  nextPageUrl: string;
  pageStats: string;
  currentUrl: string;
}

export class YoushuBookService {
  static async loadPage(url: string = YOUSHU_BOOKS_URL): Promise<YoushuBookPage> {
    const requestUrl = this.absoluteUrl(url);
    const html = await NetUtil.httpGet(requestUrl, {
      'Referer': YOUSHU_BOOKS_URL,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    });
    return this.parsePage(html, requestUrl);
  }

  static parsePage(html: string, currentUrl: string = YOUSHU_BOOKS_URL): YoushuBookPage {
    const parser = getHtmlParser();
    const root = parser.parse(html);
    return {
      filters: this.parseFilters(parser, root),
      books: this.parseBooks(parser, root),
      nextPageUrl: this.absoluteUrl(parser.extractAttr(root, '#pagelink a.next@href')),
      pageStats: parser.extractAttr(root, '#pagestats@text'),
      currentUrl: this.absoluteUrl(currentUrl),
    };
  }

  private static parseFilters(parser: HtmlParser, root: HtmlElement): YoushuFilterGroup[] {
    const tables = parser.querySelectorAll(root, 'table.grid');
    let filterTable: HtmlElement | null = null;
    for (const table of tables) {
      if (table.text.includes('筛选条件')) {
        filterTable = table;
        break;
      }
    }
    if (!filterTable) return [];

    const groups: YoushuFilterGroup[] = [];
    const rows = parser.querySelectorAll(filterTable, 'tr');
    for (const row of rows) {
      const cells = parser.querySelectorAll(row, 'td');
      if (cells.length < 2) continue;
      const groupName = parser.extractAttr(cells[0], '@text').replace(/[：:]$/, '').trim();
      const anchors = parser.querySelectorAll(cells[1], 'a');
      const options: YoushuFilterOption[] = [];
      for (const anchor of anchors) {
        const name = parser.extractAttr(anchor, '@text').trim();
        const href = parser.getAttr(anchor, 'href');
        if (!name || !href) continue;
        const className = parser.getAttr(anchor, 'class');
        options.push({
          name: name,
          url: this.absoluteUrl(href),
          selected: className.split(/\s+/).includes('hot'),
        });
      }
      if (groupName && options.length > 0) groups.push({ name: groupName, options: options });
    }
    return groups;
  }

  private static parseBooks(parser: HtmlParser, root: HtmlElement): YoushuBookItem[] {
    const body = parser.querySelector(root, '#jieqi_page_contents');
    if (!body) return [];
    const rows = parser.querySelectorAll(body, 'tr');
    const books: YoushuBookItem[] = [];
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      const cells = parser.querySelectorAll(row, 'td');
      if (cells.length < 6) continue;
      const nameAnchor = parser.querySelector(cells[0], 'a.pop');
      if (!nameAnchor) continue;
      const name = parser.extractAttr(nameAnchor, '@text').trim();
      const detailUrl = this.absoluteUrl(parser.getAttr(nameAnchor, 'href'));
      if (!name) continue;
      const rating = parser.extractAttr(cells[1], '.c_rr@text').trim();
      const ratingCount = parser.extractAttr(cells[1], '.stard@text')
        .replace(/[()（）]/g, '').trim();
      const bookId = detailUrl.match(/\/book\/(\d+)/)?.[1] || (name + '_' + index.toString());
      books.push({
        id: bookId,
        name: name,
        rating: rating || '-',
        ratingCount: ratingCount || '暂无评分',
        author: parser.extractAttr(cells[2], '@text').trim(),
        totalVisits: parser.extractAttr(cells[3], '@text').trim(),
        lastUpdate: parser.extractAttr(cells[4], '@text').trim(),
        status: parser.extractAttr(cells[5], '@text').trim(),
        detailUrl: detailUrl,
      });
    }
    return books;
  }

  private static absoluteUrl(url: string): string {
    if (!url) return '';
    if (/^https?:\/\//i.test(url)) return url;
    return YOUSHU_BASE_URL + (url.startsWith('/') ? url : '/' + url);
  }
}
