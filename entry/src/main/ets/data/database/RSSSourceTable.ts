/**
 * RSS 数据表操作
 * 对应 Android RssSourceDao / RssArticleDao / RssStarDao
 */
import relationalStore from '@ohos.data.relationalStore';
import { RSSSource, RSSArticle, RssStar, RssReadRecord } from '../../model/RSSSource';
import { RSSImportPreview } from '../../model/RSSImport';
import { RdbUtil } from './RdbUtil';

// ====== 建表 SQL ======

export const RSSSourceTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_sources (
    source_url TEXT PRIMARY KEY,
    source_name TEXT DEFAULT '',
    source_icon TEXT DEFAULT '',
    source_group TEXT DEFAULT '',
    source_comment TEXT DEFAULT '',
    enabled INTEGER DEFAULT 1,
    variable_comment TEXT DEFAULT '',
    js_lib TEXT DEFAULT '',
    enabled_cookie_jar INTEGER DEFAULT 0,
    concurrent_rate TEXT DEFAULT '',
    header TEXT DEFAULT '',
    login_url TEXT DEFAULT '',
    login_ui TEXT DEFAULT '',
    login_check_js TEXT DEFAULT '',
    cover_decode_js TEXT DEFAULT '',
    sort_url TEXT DEFAULT '',
    single_url INTEGER DEFAULT 0,
    article_style INTEGER DEFAULT 0,
    rule_articles TEXT DEFAULT '',
    rule_next_page TEXT DEFAULT '',
    rule_title TEXT DEFAULT '',
    rule_pub_date TEXT DEFAULT '',
    rule_description TEXT DEFAULT '',
    rule_image TEXT DEFAULT '',
    rule_link TEXT DEFAULT '',
    rule_content TEXT DEFAULT '',
    content_whitelist TEXT DEFAULT '',
    content_blacklist TEXT DEFAULT '',
    should_override_url_loading TEXT DEFAULT '',
    style TEXT DEFAULT '',
    enable_js INTEGER DEFAULT 1,
    load_with_base_url INTEGER DEFAULT 1,
    inject_js TEXT DEFAULT '',
    preload_js TEXT DEFAULT '',
    start_html TEXT DEFAULT '',
    start_style TEXT DEFAULT '',
    start_js TEXT DEFAULT '',
    show_web_log INTEGER DEFAULT 0,
    last_update_time INTEGER DEFAULT 0,
    custom_order INTEGER DEFAULT 0,
    type INTEGER DEFAULT 0,
    preload INTEGER DEFAULT 0,
    cache_first INTEGER DEFAULT 0,
    search_url TEXT DEFAULT '',
    redirect_policy TEXT DEFAULT 'ASK_CROSS_ORIGIN'
  );
`;

export const RSSArticleTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_articles (
    origin TEXT NOT NULL,
    sort TEXT NOT NULL,
    title TEXT DEFAULT '',
    order_num INTEGER DEFAULT 0,
    link TEXT NOT NULL,
    pub_date TEXT DEFAULT '',
    description TEXT DEFAULT '',
    content TEXT DEFAULT '',
    image TEXT DEFAULT '',
    group_name TEXT DEFAULT '默认分组',
    is_read INTEGER DEFAULT 0,
    variable TEXT DEFAULT '',
    type INTEGER DEFAULT 0,
    dur_pos INTEGER DEFAULT 0,
    PRIMARY KEY (origin, link, sort)
  );
`;

export const RssStarTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_stars (
    origin TEXT NOT NULL,
    sort TEXT DEFAULT '',
    title TEXT DEFAULT '',
    star_time INTEGER DEFAULT 0,
    link TEXT NOT NULL,
    pub_date TEXT DEFAULT '',
    description TEXT DEFAULT '',
    content TEXT DEFAULT '',
    image TEXT DEFAULT '',
    group_name TEXT DEFAULT '默认分组',
    variable TEXT DEFAULT '',
    type INTEGER DEFAULT 0,
    dur_pos INTEGER DEFAULT 0,
    PRIMARY KEY (origin, link)
  );
`;

export const RssReadRecordTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_read_records (
    origin TEXT NOT NULL,
    sort TEXT DEFAULT '',
    title TEXT DEFAULT '',
    read_time INTEGER DEFAULT 0,
    record TEXT DEFAULT '',
    image TEXT DEFAULT '',
    type INTEGER DEFAULT 0,
    dur_pos INTEGER DEFAULT 0,
    pub_date TEXT DEFAULT '',
    PRIMARY KEY (origin, record)
  );
`;

// ====== RSSSourceTable ======

export class RSSSourceTable {
  static readonly TABLE_NAME = 'rss_sources';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  /** 获取所有启用的 RSS 源 */
  async getEnabledSources(): Promise<RSSSource[]> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('enabled', 1);
    p.orderByDesc('custom_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readSources(rs);
  }

  /** 获取所有 RSS 源 */
  async getAll(): Promise<RSSSource[]> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.orderByDesc('custom_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readSources(rs);
  }

  /** 根据 sourceUrl 获取单个源 */
  async getByKey(sourceUrl: string): Promise<RSSSource | null> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('source_url', sourceUrl);
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list = this.readSources(rs);
    return list.length > 0 ? list[0] : null;
  }

  /** 插入或替换 */
  async insert(source: RSSSource): Promise<void> {
    const row = this.sourceToBucket(source);
    try { await RdbUtil.insert(this.rdbStore, RSSSourceTable.TABLE_NAME, row); } catch (_e_) { const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME); p.equalTo('source_url', row.sourceUrl); await RdbUtil.update(this.rdbStore, row, p); }
  }

  /** 更新 */
  async update(source: RSSSource): Promise<void> {
    const row = this.sourceToBucket(source);
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('source_url', source.sourceUrl);
    await RdbUtil.update(this.rdbStore, row, p);
  }

  /** 删除 */

  async getMaxOrder(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore, 'SELECT MAX(custom_order) FROM rss_sources');
    let maxOrder = 0;
    if (RdbUtil.first(rs)) maxOrder = RdbUtil.longAt(rs, 0) || 0;
    RdbUtil.close(rs);
    return maxOrder;
  }

  async getMinOrder(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore, 'SELECT MIN(custom_order) FROM rss_sources');
    let minOrder = 0;
    if (RdbUtil.first(rs)) minOrder = RdbUtil.longAt(rs, 0) || 0;
    RdbUtil.close(rs);
    return minOrder;
  }

  async delete(sourceUrl: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('source_url', sourceUrl);
    await RdbUtil.delete(this.rdbStore, p);
  }

  /** 批量导入 — 解析 JSON 为预览列表 */
  async importSourcesPreview(jsonText: string): Promise<RSSImportPreview[]> {
    const result: RSSImportPreview[] = [];
    let sources: RSSSource[] = [];
    try {
      const data: Object = JSON.parse(jsonText) as Object;
      if (Array.isArray(data)) {
        sources = data as RSSSource[];
      } else {
        sources = [data as RSSSource];
      }
    } catch (_e) {
      return result;
    }

    for (const s of sources) {
      if (!s.sourceUrl || !s.sourceName) continue;
      // 检查是否已存在
      const existing = await this.getByKey(s.sourceUrl);
      const status = existing ? 'existing' : 'new';
      const item: RSSImportPreview = { source: s, status: status, checked: status === 'new' };
      result.push(item);
    }
    return result;
  }

  /** 批量导入选中的源 */
  async importSelected(items: RSSImportPreview[], keepName: boolean, keepGroup: boolean, customGroup: string): Promise<number> {
    let count = 0;
    for (const item of items) {
      if (!item.checked) continue;
      const s = item.source;
      if (!keepName && item.status === 'update') {
        // 更新时不覆盖名称
      }
      if (customGroup) {
        s.sourceGroup = customGroup;
      } else if (!keepGroup) {
        s.sourceGroup = '';
      }
      await this.insert(s);
      count++;
    }
    return count;
  }

  /** 启用/禁用 */
  async setEnabled(sourceUrl: string, enabled: boolean): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('source_url', sourceUrl);
    await RdbUtil.update(this.rdbStore, { 'enabled': enabled ? 1 : 0 }, p);
  }

  /** 获取所有分组 */
  async getAllGroups(): Promise<string[]> {
    const sql = 'SELECT DISTINCT source_group FROM rss_sources WHERE source_group IS NOT NULL AND source_group != \'\'';
    const rs = await RdbUtil.querySql(this.rdbStore, sql);
    const groups = new Set<string>();
    while (RdbUtil.next(rs)) {
      const g = RdbUtil.stringAt(rs, 0);
      if (g) {
        g.split(/[,，]/).forEach((item: string) => {
          const t = item.trim();
          if (t) groups.add(t);
        });
      }
    }
    RdbUtil.close(rs);
    return Array.from(groups).sort();
  }

  /** 通过分组获取源 */
  async getByGroup(group: string): Promise<RSSSource[]> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.like('source_group', `%${group}%`);
    p.orderByDesc('custom_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readSources(rs);
  }

  /** 搜索源 */
  async search(keyword: string): Promise<RSSSource[]> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.beginWrap();
    p.like('source_name', `%${keyword}%`);
    p.or().like('source_url', `%${keyword}%`);
    p.or().like('source_group', `%${keyword}%`);
    p.endWrap();
    p.orderByDesc('custom_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readSources(rs);
  }

  /** 批量导入 */
  async batchInsert(sources: RSSSource[]): Promise<void> {
    for (const s of sources) {
      await this.insert(s);
    }
  }

  /** 批量启用/禁用 */
  async batchSetEnabled(urls: string[], enabled: boolean): Promise<void> {
    for (const url of urls) {
      await this.setEnabled(url, enabled);
    }
  }

  /** 批量删除 */
  async batchDelete(urls: string[]): Promise<void> {
    for (const url of urls) {
      await this.delete(url);
    }
  }

  /** 更新自定义排序 */
  async updateOrder(sourceUrl: string, order: number): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    p.equalTo('source_url', sourceUrl);
    await RdbUtil.update(this.rdbStore, { 'custom_order': order, 'last_update_time': Date.now() }, p);
  }

  /** 计数 */
  async count(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore, 'SELECT COUNT(*) FROM rss_sources');
    let c = 0;
    if (RdbUtil.first(rs)) c = RdbUtil.longAt(rs, 0);
    RdbUtil.close(rs);
    return c;
  }

  // ====== 辅助方法 ======

  private readSources(rs: relationalStore.ResultSet): RSSSource[] {
    const list: RSSSource[] = [];
    if (!rs) return list;
    while (RdbUtil.next(rs)) {
      list.push({
        sourceUrl: RdbUtil.string(rs, 'source_url') || '',
        sourceName: RdbUtil.string(rs, 'source_name') || '',
        sourceIcon: RdbUtil.string(rs, 'source_icon') || '',
        sourceGroup: RdbUtil.string(rs, 'source_group') || '',
        sourceComment: RdbUtil.string(rs, 'source_comment') || '',
        enabled: RdbUtil.long(rs, 'enabled') === 1,
        variableComment: RdbUtil.string(rs, 'variable_comment') || '',
        jsLib: RdbUtil.string(rs, 'js_lib') || '',
        enabledCookieJar: RdbUtil.long(rs, 'enabled_cookie_jar') === 1,
        concurrentRate: RdbUtil.string(rs, 'concurrent_rate') || '',
        header: RdbUtil.string(rs, 'header') || '',
        loginUrl: RdbUtil.string(rs, 'login_url') || '',
        loginUi: RdbUtil.string(rs, 'login_ui') || '',
        loginCheckJs: RdbUtil.string(rs, 'login_check_js') || '',
        coverDecodeJs: RdbUtil.string(rs, 'cover_decode_js') || '',
        sortUrl: RdbUtil.string(rs, 'sort_url') || '',
        singleUrl: RdbUtil.long(rs, 'single_url') === 1,
        articleStyle: RdbUtil.long(rs, 'article_style'),
        ruleArticles: RdbUtil.string(rs, 'rule_articles') || '',
        ruleNextPage: RdbUtil.string(rs, 'rule_next_page') || '',
        ruleTitle: RdbUtil.string(rs, 'rule_title') || '',
        rulePubDate: RdbUtil.string(rs, 'rule_pub_date') || '',
        ruleDescription: RdbUtil.string(rs, 'rule_description') || '',
        ruleImage: RdbUtil.string(rs, 'rule_image') || '',
        ruleLink: RdbUtil.string(rs, 'rule_link') || '',
        ruleContent: RdbUtil.string(rs, 'rule_content') || '',
        contentWhitelist: RdbUtil.string(rs, 'content_whitelist') || '',
        contentBlacklist: RdbUtil.string(rs, 'content_blacklist') || '',
        shouldOverrideUrlLoading: RdbUtil.string(rs, 'should_override_url_loading') || '',
        style: RdbUtil.string(rs, 'style') || '',
        enableJs: RdbUtil.long(rs, 'enable_js') === 1,
        loadWithBaseUrl: RdbUtil.long(rs, 'load_with_base_url') === 1,
        injectJs: RdbUtil.string(rs, 'inject_js') || '',
        preloadJs: RdbUtil.string(rs, 'preload_js') || '',
        startHtml: RdbUtil.string(rs, 'start_html') || '',
        startStyle: RdbUtil.string(rs, 'start_style') || '',
        startJs: RdbUtil.string(rs, 'start_js') || '',
        showWebLog: RdbUtil.long(rs, 'show_web_log') === 1,
        lastUpdateTime: RdbUtil.long(rs, 'last_update_time'),
        customOrder: RdbUtil.long(rs, 'custom_order'),
        type: RdbUtil.long(rs, 'type'),
        preload: RdbUtil.long(rs, 'preload') === 1,
        cacheFirst: RdbUtil.long(rs, 'cache_first') === 1,
        searchUrl: RdbUtil.string(rs, 'search_url') || '',
        redirectPolicy: RdbUtil.string(rs, 'redirect_policy') || 'ASK_CROSS_ORIGIN',
      });
    }
    try { RdbUtil.close(rs); } catch (_e) { /* ignore */ }
    return list;
  }

  private sourceToBucket(source: RSSSource): relationalStore.ValuesBucket {
    return {
      'source_url': source.sourceUrl,
      'source_name': source.sourceName,
      'source_icon': source.sourceIcon,
      'source_group': source.sourceGroup,
      'source_comment': source.sourceComment,
      'enabled': source.enabled ? 1 : 0,
      'variable_comment': source.variableComment,
      'js_lib': source.jsLib,
      'enabled_cookie_jar': source.enabledCookieJar ? 1 : 0,
      'concurrent_rate': source.concurrentRate,
      'header': source.header,
      'login_url': source.loginUrl,
      'login_ui': source.loginUi,
      'login_check_js': source.loginCheckJs,
      'cover_decode_js': source.coverDecodeJs,
      'sort_url': source.sortUrl,
      'single_url': source.singleUrl ? 1 : 0,
      'article_style': source.articleStyle,
      'rule_articles': source.ruleArticles,
      'rule_next_page': source.ruleNextPage,
      'rule_title': source.ruleTitle,
      'rule_pub_date': source.rulePubDate,
      'rule_description': source.ruleDescription,
      'rule_image': source.ruleImage,
      'rule_link': source.ruleLink,
      'rule_content': source.ruleContent,
      'content_whitelist': source.contentWhitelist,
      'content_blacklist': source.contentBlacklist,
      'should_override_url_loading': source.shouldOverrideUrlLoading,
      'style': source.style,
      'enable_js': source.enableJs ? 1 : 0,
      'load_with_base_url': source.loadWithBaseUrl ? 1 : 0,
      'inject_js': source.injectJs,
      'preload_js': source.preloadJs,
      'start_html': source.startHtml,
      'start_style': source.startStyle,
      'start_js': source.startJs,
      'show_web_log': source.showWebLog ? 1 : 0,
      'last_update_time': source.lastUpdateTime,
      'custom_order': source.customOrder,
      'type': source.type,
      'preload': source.preload ? 1 : 0,
      'cache_first': source.cacheFirst ? 1 : 0,
      'search_url': source.searchUrl,
      'redirect_policy': source.redirectPolicy,
    };
  }
}

// ====== RSSArticleTable ======

export class RSSArticleTable {
  static readonly TABLE_NAME = 'rss_articles';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getByOrigin(origin: string): Promise<RSSArticle[]> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.orderByDesc('order_num');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readArticles(rs);
  }

  async getByOriginSort(origin: string, sort: string): Promise<RSSArticle[]> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    if (sort) p.and().equalTo('sort', sort);
    p.orderByDesc('order_num');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readArticles(rs);
  }

  async getByOriginAndLink(origin: string, link: string): Promise<RSSArticle | null> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('link', link);
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list = this.readArticles(rs);
    return list.length > 0 ? list[0] : null;
  }

  async insert(article: RSSArticle): Promise<void> {
    const row = this.articleToBucket(article);
    await RdbUtil.insert(this.rdbStore, RSSArticleTable.TABLE_NAME, row);
  }

  /** 插入或替换（主键冲突时更新） */
  async replace(article: RSSArticle): Promise<void> {
    const row = this.articleToBucket(article);
    try { await RdbUtil.insert(this.rdbStore, RSSArticleTable.TABLE_NAME, row); } catch (_e_) { const p2 = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME); p2.equalTo('origin', row.origin); p2.and().equalTo('link', row.link); p2.and().equalTo('sort', row.sort); await RdbUtil.update(this.rdbStore, row, p2); }
  }

  async batchInsert(articles: RSSArticle[]): Promise<void> {
    for (const a of articles) {
      await this.replace(a);
    }
  }

  async update(article: RSSArticle): Promise<void> {
    const row = this.articleToBucket(article);
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', article.origin);
    p.and().equalTo('link', article.link);
    p.and().equalTo('sort', article.sort);
    await RdbUtil.update(this.rdbStore, row, p);
  }

  async markRead(origin: string, link: string, sort: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('link', link);
    p.and().equalTo('sort', sort);
    await RdbUtil.update(this.rdbStore, { 'is_read': 1 }, p);
  }

  async markAllRead(origin: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('is_read', 0);
    await RdbUtil.update(this.rdbStore, { 'is_read': 1 }, p);
  }

  async delete(origin: string, link: string, sort: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('link', link);
    p.and().equalTo('sort', sort);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async deleteByOrigin(origin: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async getUnreadCount(origin: string): Promise<number> {
    const p = new relationalStore.RdbPredicates(RSSArticleTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('is_read', 0);
    const rs = await RdbUtil.query(this.rdbStore, p, ['COUNT(*) AS cnt']);
    let c = 0;
    if (RdbUtil.first(rs)) c = RdbUtil.longAt(rs, 0);
    RdbUtil.close(rs);
    return c;
  }

  async getRecent(limit: number): Promise<RSSArticle[]> {
    const sql = `SELECT * FROM rss_articles ORDER BY order_num DESC LIMIT ${limit}`;
    const rs = await RdbUtil.querySql(this.rdbStore, sql);
    return this.readArticles(rs);
  }

  private readArticles(rs: relationalStore.ResultSet): RSSArticle[] {
    const list: RSSArticle[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        origin: RdbUtil.string(rs, 'origin') || '',
        sort: RdbUtil.string(rs, 'sort') || '',
        title: RdbUtil.string(rs, 'title') || '',
        order: RdbUtil.long(rs, 'order_num'),
        link: RdbUtil.string(rs, 'link') || '',
        pubDate: RdbUtil.string(rs, 'pub_date') || null,
        description: RdbUtil.string(rs, 'description') || null,
        content: RdbUtil.string(rs, 'content') || null,
        image: RdbUtil.string(rs, 'image') || null,
        group: RdbUtil.string(rs, 'group_name') || '默认分组',
        read: RdbUtil.long(rs, 'is_read') === 1,
        variable: RdbUtil.string(rs, 'variable') || null,
        type: RdbUtil.long(rs, 'type'),
        durPos: RdbUtil.long(rs, 'dur_pos'),
      });
    }
    try { RdbUtil.close(rs); } catch (_e) { /* ignore */ }
    return list;
  }

  private articleToBucket(article: RSSArticle): relationalStore.ValuesBucket {
    return {
      'origin': article.origin,
      'sort': article.sort || '',
      'title': article.title || '',
      'order_num': article.order || 0,
      'link': article.link || '',
      'pub_date': article.pubDate || '',
      'description': article.description || '',
      'content': article.content || '',
      'image': article.image || '',
      'group_name': article.group || '默认分组',
      'is_read': article.read ? 1 : 0,
      'variable': article.variable || '',
      'type': article.type || 0,
      'dur_pos': article.durPos || 0,
    };
  }
}

// ====== RssStarTable ======

export class RssStarTable {
  static readonly TABLE_NAME = 'rss_stars';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getAll(): Promise<RssStar[]> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.orderByDesc('star_time');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readStars(rs);
  }

  async get(origin: string, link: string): Promise<RssStar | null> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('link', link);
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list = this.readStars(rs);
    return list.length > 0 ? list[0] : null;
  }

  async insert(star: RssStar): Promise<void> {
    const row = this.starToBucket(star);
    try { await RdbUtil.insert(this.rdbStore, RssStarTable.TABLE_NAME, row); } catch (_e_) { const p2 = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME); p2.equalTo('origin', row.origin); p2.and().equalTo('link', row.link); await RdbUtil.update(this.rdbStore, row, p2); }
  }

  async update(star: RssStar): Promise<void> {
    const row = this.starToBucket(star);
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('origin', star.origin);
    p.and().equalTo('link', star.link);
    await RdbUtil.update(this.rdbStore, row, p);
  }

  async delete(origin: string, link: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.and().equalTo('link', link);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async deleteByOrigin(origin: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('origin', origin);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async deleteAll(): Promise<void> {
    await RdbUtil.executeSql(this.rdbStore, 'DELETE FROM rss_stars');
  }

  async deleteByGroup(group: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('group_name', group);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async getGroups(): Promise<string[]> {
    const sql = 'SELECT DISTINCT group_name FROM rss_stars WHERE group_name IS NOT NULL AND group_name != \'\'';
    const rs = await RdbUtil.querySql(this.rdbStore, sql);
    const groups: string[] = [];
    while (RdbUtil.next(rs)) groups.push(RdbUtil.stringAt(rs, 0) || '');
    RdbUtil.close(rs);
    return groups;
  }

  async getByGroup(group: string): Promise<RssStar[]> {
    const p = new relationalStore.RdbPredicates(RssStarTable.TABLE_NAME);
    p.equalTo('group_name', group);
    p.orderByDesc('star_time');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readStars(rs);
  }

  async count(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore, 'SELECT COUNT(*) FROM rss_stars');
    let c = 0;
    if (RdbUtil.first(rs)) c = RdbUtil.longAt(rs, 0);
    RdbUtil.close(rs);
    return c;
  }

  private readStars(rs: relationalStore.ResultSet): RssStar[] {
    const list: RssStar[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        origin: RdbUtil.string(rs, 'origin') || '',
        sort: RdbUtil.string(rs, 'sort') || '',
        title: RdbUtil.string(rs, 'title') || '',
        starTime: RdbUtil.long(rs, 'star_time'),
        link: RdbUtil.string(rs, 'link') || '',
        pubDate: RdbUtil.string(rs, 'pub_date') || null,
        description: RdbUtil.string(rs, 'description') || null,
        content: RdbUtil.string(rs, 'content') || null,
        image: RdbUtil.string(rs, 'image') || null,
        group: RdbUtil.string(rs, 'group_name') || '默认分组',
        variable: RdbUtil.string(rs, 'variable') || null,
        type: RdbUtil.long(rs, 'type'),
        durPos: RdbUtil.long(rs, 'dur_pos'),
      });
    }
    try { RdbUtil.close(rs); } catch (_e) { /* ignore */ }
    return list;
  }

  private starToBucket(star: RssStar): relationalStore.ValuesBucket {
    return {
      'origin': star.origin,
      'sort': star.sort || '',
      'title': star.title || '',
      'star_time': star.starTime || 0,
      'link': star.link || '',
      'pub_date': star.pubDate || '',
      'description': star.description || '',
      'content': star.content || '',
      'image': star.image || '',
      'group_name': star.group || '默认分组',
      'variable': star.variable || '',
      'type': star.type || 0,
      'dur_pos': star.durPos || 0,
    };
  }
}

// ====== RssReadRecordTable ======

export class RssReadRecordTable {
  static readonly TABLE_NAME = 'rss_read_records';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getRecent(limit: number): Promise<RssReadRecord[]> {
    const sql = `SELECT * FROM rss_read_records ORDER BY read_time DESC LIMIT ${limit}`;
    const rs = await RdbUtil.querySql(this.rdbStore, sql);
    return this.readRecords(rs);
  }

  async getByOrigin(origin: string, limit: number): Promise<RssReadRecord[]> {
    const p = new relationalStore.RdbPredicates(RssReadRecordTable.TABLE_NAME);
    p.equalTo('origin', origin);
    p.orderByDesc('read_time');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    return this.readRecords(rs);
  }

  async insert(record: RssReadRecord): Promise<void> {
    const row = this.recordToBucket(record);
    try { await RdbUtil.insert(this.rdbStore, RssReadRecordTable.TABLE_NAME, row); } catch (_e_) { const p2 = new relationalStore.RdbPredicates(RssReadRecordTable.TABLE_NAME); p2.equalTo('origin', row.origin); p2.and().equalTo('record', row.record); await RdbUtil.update(this.rdbStore, row, p2); }
  }

  async deleteByOrigin(origin: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(RssReadRecordTable.TABLE_NAME);
    p.equalTo('origin', origin);
    await RdbUtil.delete(this.rdbStore, p);
  }

  private readRecords(rs: relationalStore.ResultSet): RssReadRecord[] {
    const list: RssReadRecord[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        origin: RdbUtil.string(rs, 'origin') || '',
        sort: RdbUtil.string(rs, 'sort') || '',
        title: RdbUtil.string(rs, 'title') || '',
        readTime: RdbUtil.long(rs, 'read_time'),
        record: RdbUtil.string(rs, 'record') || '',
        image: RdbUtil.string(rs, 'image') || null,
        type: RdbUtil.long(rs, 'type'),
        durPos: RdbUtil.long(rs, 'dur_pos'),
        pubDate: RdbUtil.string(rs, 'pub_date') || null,
      });
    }
    try { RdbUtil.close(rs); } catch (_e) { /* ignore */ }
    return list;
  }

  private recordToBucket(record: RssReadRecord): relationalStore.ValuesBucket {
    return {
      'origin': record.origin,
      'sort': record.sort || '',
      'title': record.title || '',
      'read_time': record.readTime || 0,
      'record': record.record || '',
      'image': record.image || '',
      'type': record.type || 0,
      'dur_pos': record.durPos || 0,
      'pub_date': record.pubDate || '',
    };
  }
}
