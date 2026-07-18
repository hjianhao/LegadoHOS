/** 优书网书单列表、详情与登录服务。 */
import util from '@ohos.util';
import { NetUtil } from '../util/NetUtil';
import { CookieStore } from '../util/CookieStore';
import { LoginInfoStore } from '../util/LoginInfoStore';
import { getHtmlParser, HtmlElement, HtmlParser } from '../util/HtmlParser';
import { HtmlUtil } from '../util/HtmlUtil';
import { YoushuFilterGroup, YoushuFilterOption } from './YoushuBookService';

export const YOUSHU_BASE_URL = 'https://www.youshu.me';
export const YOUSHU_BOOKLISTS_URL = YOUSHU_BASE_URL + '/booklists';
const YOUSHU_LOGIN_URL = YOUSHU_BASE_URL + '/login.php';

export interface YoushuBooklistItem {
  id: string;
  title: string;
  coverUrl: string;
  creator: string;
  bookCount: string;
  recentBook: string;
  recentUpdate: string;
  wordCount: string;
  followerCount: string;
  rating: string;
  ratingCount: string;
  description: string;
  detailUrl: string;
}

export interface YoushuBooklistPage {
  filters: YoushuFilterGroup[];
  booklists: YoushuBooklistItem[];
  nextPageUrl: string;
  pageStats: string;
  currentUrl: string;
  loggedIn: boolean;
}

export interface YoushuBooklistBook {
  id: string;
  position: string;
  name: string;
  author: string;
  category: string;
  wordCount: string;
  updateTime: string;
  rating: string;
  ratingCount: string;
  coverUrl: string;
  review: string;
  addedTime: string;
}

export interface YoushuBooklistDetail {
  id: string;
  title: string;
  coverUrl: string;
  creator: string;
  metadata: string;
  description: string;
  rating: string;
  ratingCount: string;
  stats: string[];
  books: YoushuBooklistBook[];
  nextPageUrl: string;
  currentUrl: string;
  loginRequired: boolean;
}

export interface YoushuLoginResult {
  success: boolean;
  message: string;
}

export class YoushuBooklistService {
  static async loadPage(url: string = YOUSHU_BOOKLISTS_URL): Promise<YoushuBooklistPage> {
    const requestUrl = this.absoluteUrl(url);
    const html = await this.getHtml(requestUrl, YOUSHU_BOOKLISTS_URL);
    return this.parsePage(html, requestUrl);
  }

  static parsePage(html: string, currentUrl: string = YOUSHU_BOOKLISTS_URL): YoushuBooklistPage {
    const parser = getHtmlParser();
    const root = parser.parse(html);
    return {
      filters: this.parseFilters(parser, root),
      booklists: this.parseBooklists(parser, root),
      nextPageUrl: this.absoluteUrl(parser.extractAttr(root, '#pagelink a.next@href')),
      pageStats: this.clean(parser.extractAttr(root, '#pagestats@text')),
      currentUrl: this.absoluteUrl(currentUrl),
      loggedIn: !this.isLoginPage(parser, root),
    };
  }

  static async loadDetail(url: string): Promise<YoushuBooklistDetail> {
    const requestUrl = this.absoluteUrl(url);
    const html = await this.getHtml(requestUrl, YOUSHU_BOOKLISTS_URL);
    return this.parseDetail(html, requestUrl);
  }

  static parseDetail(html: string, currentUrl: string): YoushuBooklistDetail {
    const parser = getHtmlParser();
    const root = parser.parse(html);
    const info = parser.querySelector(root, '#doulist-info');
    const title = this.clean(parser.extractAttr(root, '#contenti h1 span@text'));
    const detailId = currentUrl.match(/\/booklist\/(\d+)/)?.[1] || title;
    const stats: string[] = [];
    const cells = parser.querySelectorAll(root, 'table.hide td');
    for (const cell of cells) {
      const value = this.clean(parser.extractAttr(cell, '@text'));
      if (value) stats.push(value);
    }
    const books = this.parseDetailBooks(parser, root);
    const reviewRegex = /<span[^>]*class=["'][^"']*\bsummary-text\b[^"']*["'][^>]*>([\s\S]*?)<\/span>/gi;
    let reviewMatch: RegExpExecArray | null;
    let reviewIndex = 0;
    while ((reviewMatch = reviewRegex.exec(html)) !== null && reviewIndex < books.length) {
      books[reviewIndex].review = HtmlUtil.toPlainText(reviewMatch[1]).trim();
      reviewIndex++;
    }
    return {
      id: detailId,
      title: title,
      coverUrl: this.absoluteUrl(parser.extractAttr(root, '#doulist-info .doulist-cover img@src')),
      creator: this.clean(parser.extractAttr(root, '#doulist-info .meta a@text')),
      metadata: this.clean(parser.extractAttr(root, '#doulist-info .meta@text')),
      description: info ? HtmlUtil.toPlainText(parser.extractAttr(info, '.doulist-about@html')).trim() : '',
      rating: this.clean(parser.extractAttr(root, '.ratenum@text')) || '-',
      ratingCount: this.clean(parser.extractAttr(root, '.ratediv .gray@text')).replace(/[()（）]/g, '') || '暂无评分',
      stats: stats,
      books: books,
      nextPageUrl: this.absoluteUrl(parser.extractAttr(root, '#pagelink a.next@href')),
      currentUrl: this.absoluteUrl(currentUrl),
      loginRequired: !title && this.isLoginPage(parser, root),
    };
  }

  static async loadCaptcha(): Promise<string> {
    // 验证码必须与登录请求共享 CookieStore 中的会话。
    const url = YOUSHU_BASE_URL + '/checkcode.php?rand=' + Date.now().toString();
    const bytes = new Uint8Array(await NetUtil.httpGetBinary(url, {
      'Referer': YOUSHU_BOOKLISTS_URL,
      'Accept': 'image/avif,image/webp,image/png,image/*,*/*;q=0.8',
    }));
    const base64 = new util.Base64Helper().encodeToStringSync(bytes);
    return 'data:image/png;base64,' + base64;
  }

  static async login(
    username: string,
    password: string,
    checkcode: string
  ): Promise<YoushuLoginResult> {
    const body = 'username=' + encodeURIComponent(username) +
      '&password=' + encodeURIComponent(password) +
      '&checkcode=' + encodeURIComponent(checkcode) +
      '&usecookie=1&act=login&jumpreferer=1';
    const loginHeaders: Record<string, string> = {
      'Referer': YOUSHU_BOOKLISTS_URL,
      'Origin': YOUSHU_BASE_URL,
      'X-Requested-With': 'XMLHttpRequest',
      'Content-Type': 'application/x-www-form-urlencoded',
      // 优书网的登录端点拒绝 RCP 默认的无长度 POST（HTTP 411）。
      // 表单值已经 encodeURIComponent，body 此时全部为 ASCII，字符数即 UTF-8 字节数。
      'Content-Length': body.length.toString(),
    };
    try {
      await NetUtil.httpPost(YOUSHU_LOGIN_URL, body, loginHeaders);
    } catch (e) {
      const message = (e as Error).message || String(e);
      if (!message.includes('HTTP 411')) throw e;
      console.warn('[YoushuLogin] RCP POST rejected with 411, retrying through system HTTP');
      await NetUtil.httpPostSystem(YOUSHU_LOGIN_URL, body, loginHeaders);
    }
    const verifyHtml = await this.getHtml(YOUSHU_BOOKLISTS_URL, YOUSHU_BOOKLISTS_URL);
    const parser = getHtmlParser();
    const loggedIn = !this.isLoginPage(parser, parser.parse(verifyHtml));
    if (!loggedIn) {
      return { success: false, message: '登录失败，请检查账号、密码和验证码' };
    }
    // 登录态仅由 CookieStore 持久化，不在 Preferences 中保存明文密码。
    await LoginInfoStore.getInstance().remove(YOUSHU_BASE_URL);
    return { success: true, message: '登录成功，会话已保存' };
  }

  static async logout(): Promise<void> {
    await CookieStore.getInstance().removeCookie(YOUSHU_BASE_URL);
  }

  static async forgetSavedLogin(): Promise<void> {
    await LoginInfoStore.getInstance().remove(YOUSHU_BASE_URL);
  }

  private static async getHtml(url: string, referer: string): Promise<string> {
    return await NetUtil.httpGet(url, {
      'Referer': referer,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    });
  }

  private static parseFilters(parser: HtmlParser, root: HtmlElement): YoushuFilterGroup[] {
    const tables = parser.querySelectorAll(root, 'table.grid');
    let filterTable: HtmlElement | null = null;
    for (const table of tables) {
      if (table.text.includes('书单筛选条件')) {
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
      const options: YoushuFilterOption[] = [];
      const anchors = parser.querySelectorAll(cells[1], 'a');
      for (const anchor of anchors) {
        const name = this.clean(parser.extractAttr(anchor, '@text'));
        const href = parser.getAttr(anchor, 'href');
        if (!name || !href) continue;
        options.push({
          name: name,
          url: this.absoluteUrl(href),
          selected: parser.getAttr(anchor, 'class').split(/\s+/).includes('hot'),
        });
      }
      const groupName = this.clean(parser.extractAttr(cells[0], '@text')).replace(/[：:]$/, '');
      if (groupName && options.length > 0) groups.push({ name: groupName, options: options });
    }
    return groups;
  }

  private static parseBooklists(parser: HtmlParser, root: HtmlElement): YoushuBooklistItem[] {
    const body = parser.querySelector(root, '#jieqi_page_contents');
    if (!body) return [];
    const rows = parser.querySelectorAll(body, '.c_row');
    const result: YoushuBooklistItem[] = [];
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      let detailAnchor: HtmlElement | null = null;
      const titleAnchors = parser.querySelectorAll(row, '.c_subject a');
      for (const anchor of titleAnchors) {
        if (/^\/booklist\/\d+\/?$/.test(parser.getAttr(anchor, 'href'))) {
          detailAnchor = anchor;
          break;
        }
      }
      if (!detailAnchor) continue;
      const detailUrl = this.absoluteUrl(parser.getAttr(detailAnchor, 'href'));
      const title = this.clean(parser.extractAttr(detailAnchor, '@text'));
      if (!title) continue;
      const values = parser.querySelectorAll(row, '.c_tag .c_value');
      const valueAt = (valueIndex: number): string => valueIndex < values.length ?
        this.clean(parser.extractAttr(values[valueIndex], '@text')) : '';
      const recentValue = valueAt(2);
      const dateMatch = recentValue.match(/(\d{4}-\d{2}-\d{2})$/);
      result.push({
        id: detailUrl.match(/\/booklist\/(\d+)/)?.[1] || (title + index.toString()),
        title: title,
        coverUrl: this.absoluteUrl(parser.extractAttr(row, '.sortimg img@src')),
        creator: valueAt(0),
        bookCount: valueAt(1),
        recentBook: dateMatch ? recentValue.substring(0, recentValue.length - dateMatch[1].length).replace(/\/$/, '').trim() : recentValue,
        recentUpdate: dateMatch?.[1] || '',
        wordCount: valueAt(3),
        followerCount: this.clean(parser.extractAttr(row, '.collectsd-num@text')),
        rating: this.clean(parser.extractAttr(row, '.c_rr@text')) || '-',
        ratingCount: this.clean(parser.extractAttr(row, '.stard@text')).replace(/[()（）]/g, '') || '暂无评分',
        description: HtmlUtil.toPlainText(parser.extractAttr(row, '.c_description@html')).trim(),
        detailUrl: detailUrl,
      });
    }
    return result;
  }

  private static parseDetailBooks(parser: HtmlParser, root: HtmlElement): YoushuBooklistBook[] {
    const rows = parser.querySelectorAll(root, '.doulist-item');
    const result: YoushuBooklistBook[] = [];
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      const titleAnchor = parser.querySelector(row, '.title a');
      if (!titleAnchor) continue;
      const name = this.clean(parser.extractAttr(titleAnchor, '@text'));
      if (!name) continue;
      const detailUrl = parser.getAttr(titleAnchor, 'href');
      const abstractText = this.clean(parser.extractAttr(row, '.abstract@text'));
      result.push({
        id: detailUrl.match(/\/book\/(\d+)/)?.[1] || (name + index.toString()),
        position: this.clean(parser.extractAttr(row, '.pos@text')) || (index + 1).toString(),
        name: name,
        author: this.captureField(abstractText, '作者', '分类'),
        category: this.captureField(abstractText, '分类', '字数'),
        wordCount: this.captureField(abstractText, '字数', '更新'),
        updateTime: this.captureField(abstractText, '更新', ''),
        rating: this.clean(parser.extractAttr(row, '.rating_nums@text')) || '-',
        ratingCount: this.clean(parser.extractAttr(row, '.rating@text')).replace(/^.*?\d+(?:\.\d+)?/, '').replace(/[()（）]/g, ''),
        coverUrl: this.absoluteUrl(parser.extractAttr(row, '.post img@src')),
        review: HtmlUtil.toPlainText(parser.extractAttr(row, '.summary-text@html')).trim(),
        addedTime: this.clean(parser.extractAttr(row, 'time.time@text')),
      });
    }
    return result;
  }

  private static captureField(text: string, label: string, nextLabel: string): string {
    const end = nextLabel ? '(?=' + nextLabel + '\\s*[:：])' : '$';
    const match = text.match(new RegExp(label + '\\s*[:：]\\s*(.*?)\\s*' + end));
    return match?.[1]?.trim() || '';
  }

  private static isLoginPage(parser: HtmlParser, root: HtmlElement): boolean {
    return parser.querySelector(root, '#t_frmlogin') !== null;
  }

  private static clean(value: string): string {
    return (value || '').replace(/\s+/g, ' ').trim();
  }

  private static absoluteUrl(url: string): string {
    if (!url) return '';
    if (/^https?:\/\//i.test(url)) return url;
    return YOUSHU_BASE_URL + (url.startsWith('/') ? url : '/' + url);
  }
}
