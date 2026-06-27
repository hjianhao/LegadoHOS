/**
 * 书源数据模型（核心模型）
 * 兼容 Legado 书源 JSON 格式
 *
 * 每个书源包含搜索、详情、目录、正文的抓取规则，
 * 规则支持 JSONPath/CSS/XPath/正则表达式。
 */
export interface BookSource {
  id: number;
  sourceName: string;
  sourceUrl: string;        // 书源网站 URL
  sourceType: number;       // 0=出版, 1=网络
  group: string;            // 分组标签
  enabled: boolean;
  weight: number;           // 优先级权重
  customOrder: number;

  // --- 搜索规则 ---
  ruleSearchUrl: string;           // 搜索 URL 模板
  ruleSearchList: string;          // 搜索结果列表选择器
  ruleSearchName: string;          // 书名选择器
  ruleSearchAuthor: string;        // 作者选择器
  ruleSearchCover: string;         // 封面选择器
  ruleSearchNoteUrl: string;       // 书籍详情页 URL 选择器
  ruleSearchKind: string;          // 分类选择器
  ruleSearchWordCount: string;     // 字数选择器
  ruleSearchLastUpdateTime: string;// 最后更新时间选择器
  ruleSearchIntroduce: string;     // 简介选择器

  // --- 书籍详情规则 ---
  ruleBookInfoInit: string;        // 初始化 JS
  ruleBookInfoName: string;
  ruleBookInfoAuthor: string;
  ruleBookInfoCover: string;
  ruleBookInfoIntroduce: string;
  ruleBookInfoKind: string;
  ruleBookInfoWordCount: string;
  ruleBookInfoLastUpdateTime: string;
  ruleBookInfoFrom: string;

  // --- 目录规则 ---
  ruleTocUrl: string;              // 目录页 URL 模板
  ruleToc: string;                 // 目录列表选择器
  ruleTocTitle: string;            // 章节标题选择器
  ruleTocUrlItem: string;          // 章节链接选择器

  // --- 正文规则 ---
  ruleBookContentUrl: string;      // 正文页 URL 模板
  ruleBookContent: string;         // 正文内容选择器
  ruleBookContentNext: string;     // 下一页选择器

  // --- 发现规则 ---
  ruleExplores: string;            // 发现页规则 JSON

  // --- 评论规则 ---
  ruleReview: string;

  // 书源 JS 脚本（覆盖规则式配置）
  script: string;                  // 完整的 JS 书源脚本

  // 自定义请求头（JSON 字符串，如 {"device":"xxx"}）
  header: string;

  // --- 编辑页需要的扩展字段 ---
  ruleSearchCheckKeyWord: string;
  ruleSearchLastChapter: string;
  ruleBookInfoLastChapter: string;
  ruleBookInfoTocUrl: string;
  ruleBookInfoCanReName: string;
  ruleBookInfoDownloadUrls: string;
  ruleBookInfoRelatedBooks: string;
  ruleTocPreUpdateJs: string;
  ruleTocFormatJs: string;
  ruleTocIsVolume: string;
  ruleTocIsVip: string;
  ruleTocIsPay: string;
  ruleTocUpdateTime: string;
  ruleTocNextTocUrl: string;
  ruleBookContentSubContent: string;
  ruleBookContentTitle: string;
  ruleBookContentWebJs: string;
  ruleBookContentSourceRegex: string;
  ruleBookContentReplaceRegex: string;
  ruleBookContentImageStyle: string;
  ruleBookContentImageDecode: string;
  ruleBookContentPayAction: string;
  ruleBookContentCallBackJs: string;
  respondTime: number;
  concurrentRate: string;
  bookSourceComment: string;
  variableComment: string;
  coverDecodeJs: string;
  loginUrl: string;
  loginCheckJs: string;
  jsLib: string;
  bookUrlPattern: string;
  respond: number;
  ruleExploreScreen: string;
  ruleExploreList: string;
  ruleExploreName: string;
  ruleExploreAuthor: string;
  ruleExploreCover: string;
  ruleExploreKind: string;
  ruleExploreWordCount: string;
  ruleExploreLastChapter: string;
  ruleExploreLastUpdateTime: string;
  ruleExploreNoteUrl: string;
  ruleExploreIntroduce: string;
  exploreUrl: string;
  loginUi: string;
  eventListener: boolean;
  customButton: boolean;
  homepageModules: string;
  enabledCookieJar: boolean;
  enabledExplore: boolean;
  exploreScreen: string;
  review: string;
  ruleReviewUrl: string;
  ruleReviewAvatar: string;
  ruleReviewContent: string;
  ruleReviewPostTime: string;
  ruleReviewQuoteUrl: string;
  reviewUrl: string;
  reviewAvatar: string;
  reviewContent: string;
  reviewPostTime: string;
  reviewQuoteUrl: string;
  rawJson: string;

  // 时间
  createTime: number;
  updateTime: number;
}

/**
 * 书源脚本的标准函数接口
 * 兼容 Legado 书源脚本规范
 */
export interface BookSourceScript {
  /** 搜索函数 */
  search(key: string, page: number): BookSourceSearchResult[];

  /** 获取书籍详情 */
  getBookInfo(url: string): BookSourceBookInfo;

  /** 获取目录 */
  getToc(url: string): BookSourceChapter[];

  /** 获取正文内容 */
  getContent(url: string): string;

  /** 发现页 */
  getExplore(url: string): BookSourceSearchResult[];
}

export interface BookSourceSearchResult {
  bookUrl: string;
  bookName: string;
  author: string;
  coverUrl: string;
  kind: string;
  wordCount: string;
  lastUpdateTime: string;
  introduce: string;
  sourceName: string;
}

export interface BookSourceBookInfo {
  name: string;
  author: string;
  coverUrl: string;
  introduce: string;
  kind: string;
  wordCount: string;
  lastUpdateTime: string;
  chapters: BookSourceChapter[];
}

export interface BookSourceChapter {
  title: string;
  url: string;
  index: number;
}

/**
 * 将规则值转换为适用于数据库 TEXT 列的字符串
 *
 * Legado 书源中规则字段可以是：
 *   - 字符串: "ul.list > li"
 *   - JSON 对象: { "selector": "ul.list" }
 *   - JSON 数组: ["sel1", "sel2"]
 * 数据库 TEXT 列只能存字符串，这里统一做 JSON.stringify
 */
function toRuleString(val: unknown): string {
  if (typeof val === 'string') {
    return val;
  }
  if (val === null || val === undefined) {
    return '';
  }
  // 对象/数组 → JSON 字符串
  return JSON.stringify(val);
}

/**
 * 从 JSON 对象解析为 BookSource
 *
 * 兼容 Legado 书源 JSON 格式的多种字段名
 */
export function parseBookSource(json: any): BookSource {
  // 兼容嵌套格式: ruleSearch.bookList 或 ruleSearchList
  const rs = json.ruleSearch || {};
  return {
    id: json.id || 0,
    sourceName: json.sourceName || json.bookSourceName || '',
    sourceUrl: json.sourceUrl || json.bookSourceUrl || '',
    sourceType: json.sourceType || 0,
    group: json.group || '',
    enabled: json.enabled !== false,
    weight: json.weight || 0,
    customOrder: json.customOrder || 0,
    // 兼容多种搜索URL字段名
    ruleSearchUrl: toRuleString(json.ruleSearchUrl || rs.searchUrl || json.searchUrl || json.search_url || ''),
    ruleSearchList: toRuleString(json.ruleSearchList || rs.bookList || json.searchList || json.search_list || ''),
    ruleSearchName: toRuleString(json.ruleSearchName || rs.name || ''),
    ruleSearchAuthor: toRuleString(json.ruleSearchAuthor || rs.author || ''),
    ruleSearchCover: toRuleString(json.ruleSearchCover || rs.coverUrl || ''),
    ruleSearchNoteUrl: toRuleString(json.ruleSearchNoteUrl || rs.bookUrl || ''),
    ruleSearchKind: toRuleString(json.ruleSearchKind || rs.kind || ''),
    ruleSearchWordCount: toRuleString(json.ruleSearchWordCount || rs.wordCount || ''),
    ruleSearchLastUpdateTime: toRuleString(json.ruleSearchLastUpdateTime || rs.lastUpdateTime || ''),
    ruleSearchIntroduce: toRuleString(json.ruleSearchIntroduce || rs.intro || rs.introduce || ''),
    ruleBookInfoInit: toRuleString(json.ruleBookInfoInit),
    ruleBookInfoName: toRuleString(json.ruleBookInfoName),
    ruleBookInfoAuthor: toRuleString(json.ruleBookInfoAuthor),
    ruleBookInfoCover: toRuleString(json.ruleBookInfoCover),
    ruleBookInfoIntroduce: toRuleString(json.ruleBookInfoIntroduce),
    ruleBookInfoKind: toRuleString(json.ruleBookInfoKind),
    ruleBookInfoWordCount: toRuleString(json.ruleBookInfoWordCount),
    ruleBookInfoLastUpdateTime: toRuleString(json.ruleBookInfoLastUpdateTime),
    ruleBookInfoFrom: toRuleString(json.ruleBookInfoFrom),
    ruleTocUrl: toRuleString(json.ruleTocUrl),
    ruleToc: toRuleString(json.ruleToc),
    ruleTocTitle: toRuleString(json.ruleTocTitle),
    ruleTocUrlItem: toRuleString(json.ruleTocUrlItem),
    ruleBookContentUrl: toRuleString(json.ruleBookContentUrl),
    ruleBookContent: toRuleString(json.ruleBookContent),
    ruleBookContentNext: toRuleString(json.ruleBookContentNext),
    ruleExplores: toRuleString(json.ruleExplores),
    ruleReview: toRuleString(json.ruleReview),
    script: toRuleString(json.script),
    header: toRuleString(json.header || ''),
    ruleSearchCheckKeyWord: json.ruleSearchCheckKeyWord || json.checkKeyWord || '',
    ruleSearchLastChapter: json.ruleSearchLastChapter || '',
    ruleBookInfoLastChapter: json.ruleBookInfoLastChapter || '',
    ruleBookInfoTocUrl: json.ruleBookInfoTocUrl || json.tocUrl || '',
    ruleBookInfoCanReName: json.ruleBookInfoCanReName || '',
    ruleBookInfoDownloadUrls: json.ruleBookInfoDownloadUrls || '',
    ruleBookInfoRelatedBooks: json.ruleBookInfoRelatedBooks || '',
    ruleTocPreUpdateJs: json.ruleTocPreUpdateJs || '',
    ruleTocFormatJs: json.ruleTocFormatJs || '',
    ruleTocIsVolume: json.ruleTocIsVolume || '',
    ruleTocIsVip: json.ruleTocIsVip || '',
    ruleTocIsPay: json.ruleTocIsPay || '',
    ruleTocUpdateTime: json.ruleTocUpdateTime || '',
    ruleTocNextTocUrl: json.ruleTocNextTocUrl || '',
    ruleBookContentSubContent: json.ruleBookContentSubContent || '',
    ruleBookContentTitle: json.ruleBookContentTitle || '',
    ruleBookContentWebJs: json.ruleBookContentWebJs || '',
    ruleBookContentSourceRegex: json.ruleBookContentSourceRegex || '',
    ruleBookContentReplaceRegex: json.ruleBookContentReplaceRegex || '',
    ruleBookContentImageStyle: json.ruleBookContentImageStyle || '',
    ruleBookContentImageDecode: json.ruleBookContentImageDecode || '',
    ruleBookContentPayAction: json.ruleBookContentPayAction || '',
    ruleBookContentCallBackJs: json.ruleBookContentCallBackJs || '',
    respondTime: json.respondTime || 0,
    concurrentRate: json.concurrentRate || '',
    bookSourceComment: json.bookSourceComment || '',
    variableComment: json.variableComment || '',
    coverDecodeJs: json.coverDecodeJs || '',
    loginUrl: json.loginUrl || '',
    loginCheckJs: json.loginCheckJs || '',
    jsLib: json.jsLib || '',
    bookUrlPattern: json.bookUrlPattern || '',
    respond: json.respond || 0,
    ruleExploreScreen: json.ruleExploreScreen || '',
    ruleExploreList: json.ruleExploreList || '',
    ruleExploreName: json.ruleExploreName || '',
    ruleExploreAuthor: json.ruleExploreAuthor || '',
    ruleExploreCover: json.ruleExploreCover || '',
    ruleExploreKind: json.ruleExploreKind || '',
    ruleExploreWordCount: json.ruleExploreWordCount || '',
    ruleExploreLastChapter: json.ruleExploreLastChapter || '',
    ruleExploreLastUpdateTime: json.ruleExploreLastUpdateTime || '',
    ruleExploreNoteUrl: json.ruleExploreNoteUrl || '',
    ruleExploreIntroduce: json.ruleExploreIntroduce || '',
    exploreUrl: json.exploreUrl || '',
    loginUi: json.loginUi || '',
    eventListener: json.eventListener || false,
    customButton: json.customButton || false,
    homepageModules: json.homepageModules || '',
    enabledCookieJar: json.enabledCookieJar !== false,
    enabledExplore: json.enabledExplore !== false,
    exploreScreen: json.exploreScreen || '',
    review: json.review || '',
    reviewUrl: json.reviewUrl || '',
    ruleReviewUrl: json.ruleReviewUrl || '',
    ruleReviewAvatar: json.ruleReviewAvatar || '',
    ruleReviewContent: json.ruleReviewContent || '',
    ruleReviewPostTime: json.ruleReviewPostTime || '',
    ruleReviewQuoteUrl: json.ruleReviewQuoteUrl || '',
    reviewAvatar: json.reviewAvatar || '',
    reviewContent: json.reviewContent || '',
    reviewPostTime: json.reviewPostTime || '',
    reviewQuoteUrl: json.reviewQuoteUrl || '',
    rawJson: json.rawJson || '',
    createTime: json.createTime || 0,
    updateTime: json.updateTime || 0,
  };
}
