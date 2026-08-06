/**
 * 书源类型常量（兼容 Legado bookSourceType）
 * 0=文本, 1=音频, 2=图片/漫画, 3=文件
 */
export enum BookSourceType {
  TEXT = 0,
  AUDIO = 1,
  IMAGE = 2,
  FILE = 3,
}

/**
 * 判断书源是否为漫画（图片）类型
 */
export function isImageSource(source: BookSource): boolean {
  return source.sourceType === BookSourceType.IMAGE;
}

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
  sourceType: number;       // 书源类型: 0=文本, 1=音频, 2=图片/漫画, 3=文件（兼容 Legado bookSourceType）
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
  isExploreRequest?: boolean;      // 发现分类合成请求标记（不持久化）
  checkRequestGroup?: string;      // 校验专用网络取消组（不持久化）

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

  // AI 生成标记
  isAiGenerated: boolean;     // 是否为 AI 自动分析生成的临时书源

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
  latestChapterTitle?: string;
  canReName?: boolean;
  downloadUrls?: string[];
  relatedBooks?: Object[];
  tocUrl?: string;
  chapters: BookSourceChapter[];
}

export interface BookSourceChapter {
  title: string;
  url: string;
  index: number;
  isVolume?: boolean;  // 是否是卷标题
  isVip?: boolean;
  isPay?: boolean;
  updateTime?: string;
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
 * Android Legado 的嵌套规则既可能是 JSON 对象，也可能是“JSON 对象字符串”。
 * Gson 的自定义反序列化器同时支持这两种形式，HOS 端也必须先还原对象，
 * 否则 ruleSearch/BookInfo 等字段会在导入时整体变成空规则。
 */
function parseNestedRuleObject(val: unknown): Record<string, unknown> {
  if (val && typeof val === 'object' && !Array.isArray(val)) {
    return val as Record<string, unknown>;
  }
  if (typeof val === 'string') {
    try {
      const parsed: unknown = JSON.parse(val);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch (_e) {
      // 普通字符串规则（例如 ruleToc 的 CSS 选择器）不是嵌套对象。
    }
  }
  return {};
}

function isNestedRuleObjectString(val: unknown): boolean {
  if (typeof val !== 'string') return false;
  try {
    const parsed: unknown = JSON.parse(val);
    return !!parsed && typeof parsed === 'object' && !Array.isArray(parsed);
  } catch (_e) {
    return false;
  }
}

/** 从 rawJson 取出嵌套对象，供导出时保留未建模字段。 */
function rawNestedRuleObject(rawJson: string, key: string): Record<string, Object> {
  if (!rawJson) return {};
  try {
    const raw = JSON.parse(rawJson) as Record<string, unknown>;
    const nested = parseNestedRuleObject(raw[key]);
    return nested as Record<string, Object>;
  } catch (_e) {
    return {};
  }
}

function mergeNestedRuleObject(
  rawJson: string, key: string, standard: Record<string, Object>
): Record<string, Object> {
  const result: Record<string, Object> = rawNestedRuleObject(rawJson, key);
  Object.keys(standard).forEach((field: string): void => {
    result[field] = standard[field];
  });
  return result;
}

/**
 * 创建空的 BookSource 对象（所有字段为默认值）
 */
export function createEmptyBookSource(): BookSource {
  return parseBookSource({});
}

/**
 * 从 JSON 对象解析为 BookSource
 *
 * 兼容 Legado 书源 JSON 格式的多种字段名
 */
export function parseBookSource(json: any): BookSource {
  // 兼容嵌套格式: ruleSearch.bookList 或 ruleSearchList
  const rs = parseNestedRuleObject(json.ruleSearch);
  const re = parseNestedRuleObject(json.ruleExplore);
  const bi = parseNestedRuleObject(json.ruleBookInfo);
  const rt = parseNestedRuleObject(json.ruleToc);
  const rc = parseNestedRuleObject(json.ruleContent);
  const rr = parseNestedRuleObject(json.ruleReview);
  return {
    id: json.id || 0,
    sourceName: json.sourceName || json.bookSourceName || '',
    sourceUrl: json.sourceUrl || json.bookSourceUrl || '',
    sourceType: json.bookSourceType ?? json.sourceType ?? 0,
    group: json.bookSourceGroup || json.group || '',
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
    // Android 标准字段名是 updateTime，lastUpdateTime 是旧版 HOS 兼容名。
    ruleSearchLastUpdateTime: toRuleString(json.ruleSearchLastUpdateTime ||
      rs.updateTime || rs.lastUpdateTime || ''),
    ruleSearchIntroduce: toRuleString(json.ruleSearchIntroduce || rs.intro || rs.introduce || ''),
    ruleBookInfoInit: toRuleString(json.ruleBookInfoInit || bi.init || ''),
    ruleBookInfoName: toRuleString(json.ruleBookInfoName || bi.name || ''),
    ruleBookInfoAuthor: toRuleString(json.ruleBookInfoAuthor || bi.author || ''),
    ruleBookInfoCover: toRuleString(json.ruleBookInfoCover || bi.coverUrl || ''),
    ruleBookInfoIntroduce: toRuleString(json.ruleBookInfoIntroduce || bi.intro || bi.introduce || ''),
    ruleBookInfoKind: toRuleString(json.ruleBookInfoKind || bi.kind || ''),
    ruleBookInfoWordCount: toRuleString(json.ruleBookInfoWordCount || bi.wordCount || ''),
    ruleBookInfoLastUpdateTime: toRuleString(json.ruleBookInfoLastUpdateTime ||
      bi.updateTime || bi.lastUpdateTime || ''),
    ruleBookInfoFrom: toRuleString(json.ruleBookInfoFrom || bi.from || ''),
    ruleTocUrl: toRuleString(json.ruleTocUrl || rt.tocUrl || ''),
    ruleToc: toRuleString(typeof json.ruleToc === 'string' && !isNestedRuleObjectString(json.ruleToc)
      ? json.ruleToc : rt.chapterList || ''),
    ruleTocTitle: toRuleString(json.ruleTocTitle || rt.chapterName || ''),
    ruleTocUrlItem: toRuleString(json.ruleTocUrlItem || rt.chapterUrl || ''),
    ruleBookContentUrl: toRuleString(json.ruleBookContentUrl || rc.contentUrl || ''),
    ruleBookContent: toRuleString(json.ruleBookContent || rc.content || ''),
    ruleBookContentNext: toRuleString(json.ruleBookContentNext || rc.nextContentUrl || ''),
    ruleExplores: toRuleString(json.ruleExplores),
    // ReviewRule 同样支持对象和 JSON 字符串两种 Android 导入格式。
    ruleReview: toRuleString(json.ruleReview),
    script: toRuleString(json.script),
    header: toRuleString(json.header || ''),
    ruleSearchCheckKeyWord: json.ruleSearchCheckKeyWord || rs.checkKeyWord || json.checkKeyWord || '',
    ruleSearchLastChapter: json.ruleSearchLastChapter || rs.lastChapter || '',
    ruleBookInfoLastChapter: json.ruleBookInfoLastChapter || bi.lastChapter || '',
    ruleBookInfoTocUrl: json.ruleBookInfoTocUrl || bi.tocUrl || '',
    ruleBookInfoCanReName: json.ruleBookInfoCanReName || bi.canReName || '',
    ruleBookInfoDownloadUrls: json.ruleBookInfoDownloadUrls || bi.downloadUrls || '',
    ruleBookInfoRelatedBooks: json.ruleBookInfoRelatedBooks || bi.relatedBooks || '',
    ruleTocPreUpdateJs: json.ruleTocPreUpdateJs || rt.preUpdateJs || '',
    ruleTocFormatJs: json.ruleTocFormatJs || rt.formatJs || '',
    ruleTocIsVolume: json.ruleTocIsVolume || rt.isVolume || '',
    ruleTocIsVip: json.ruleTocIsVip || rt.isVip || '',
    ruleTocIsPay: json.ruleTocIsPay || rt.isPay || '',
    ruleTocUpdateTime: json.ruleTocUpdateTime || rt.updateTime || '',
    ruleTocNextTocUrl: json.ruleTocNextTocUrl || rt.nextTocUrl || '',
    ruleBookContentSubContent: json.ruleBookContentSubContent || rc.subContent || '',
    ruleBookContentTitle: json.ruleBookContentTitle || rc.title || '',
    ruleBookContentWebJs: json.ruleBookContentWebJs || rc.webJs || '',
    ruleBookContentSourceRegex: json.ruleBookContentSourceRegex || rc.sourceRegex || '',
    ruleBookContentReplaceRegex: toRuleString(json.ruleBookContentReplaceRegex || rc.replaceRegex || ''),
    ruleBookContentImageStyle: json.ruleBookContentImageStyle || rc.imageStyle || '',
    ruleBookContentImageDecode: json.ruleBookContentImageDecode || rc.imageDecode || '',
    ruleBookContentPayAction: json.ruleBookContentPayAction || rc.payAction || '',
    ruleBookContentCallBackJs: json.ruleBookContentCallBackJs || rc.callBackJs || '',
    respondTime: json.respondTime ?? 180000,
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
    ruleExploreList: json.ruleExploreList || re.bookList || '',
    ruleExploreName: json.ruleExploreName || re.name || '',
    ruleExploreAuthor: json.ruleExploreAuthor || re.author || '',
    ruleExploreCover: json.ruleExploreCover || re.coverUrl || '',
    ruleExploreKind: json.ruleExploreKind || re.kind || '',
    ruleExploreWordCount: json.ruleExploreWordCount || re.wordCount || '',
    ruleExploreLastChapter: json.ruleExploreLastChapter || re.lastChapter || '',
    ruleExploreLastUpdateTime: json.ruleExploreLastUpdateTime || re.updateTime || re.lastUpdateTime || '',
    ruleExploreNoteUrl: json.ruleExploreNoteUrl || re.bookUrl || '',
    ruleExploreIntroduce: json.ruleExploreIntroduce || re.intro || '',
    exploreUrl: json.exploreUrl || '',
    loginUi: json.loginUi || '',
    eventListener: json.eventListener || false,
    customButton: json.customButton || false,
    homepageModules: json.homepageModules || '',
    enabledCookieJar: json.enabledCookieJar !== false,
    enabledExplore: json.enabledExplore !== false,
    exploreScreen: json.exploreScreen || '',
    review: json.review || '',
    reviewUrl: json.reviewUrl || rr.reviewUrl || '',
    ruleReviewUrl: json.ruleReviewUrl || rr.reviewUrl || '',
    ruleReviewAvatar: json.ruleReviewAvatar || rr.avatarRule || '',
    ruleReviewContent: json.ruleReviewContent || rr.contentRule || '',
    ruleReviewPostTime: json.ruleReviewPostTime || rr.postTimeRule || '',
    ruleReviewQuoteUrl: json.ruleReviewQuoteUrl || rr.reviewQuoteUrl || '',
    reviewAvatar: json.reviewAvatar || rr.avatarRule || '',
    reviewContent: json.reviewContent || rr.contentRule || '',
    reviewPostTime: json.reviewPostTime || rr.postTimeRule || '',
    reviewQuoteUrl: json.reviewQuoteUrl || rr.reviewQuoteUrl || '',
    rawJson: json.rawJson || '',
    createTime: json.createTime || 0,
    // Android Legado 以 lastUpdateTime 判断导入源是否需要更新。
    updateTime: json.lastUpdateTime ?? json.updateTime ?? 0,
    isAiGenerated: json.isAiGenerated || false,
  };
}

/**
 * 转换为 Android Legado 可直接导入的标准 JSON 对象。
 *
 * 先保留 rawJson 中未知的扩展字段，再用当前模型覆盖标准字段。这样编辑一个
 * 已导入书源时，不会丢掉尚未拆列、或由新版 Legado 新增的配置。
 */
export function bookSourceToJsonObject(source: BookSource): Record<string, Object> {
  let result: Record<string, Object> = {};
  if (source.rawJson) {
    try {
      const raw = JSON.parse(source.rawJson) as Record<string, Object>;
      if (raw && !Array.isArray(raw)) result = raw;
    } catch (_e) { /* 无效原始 JSON 不影响按模型重新生成 */ }
  }

  result['bookSourceName'] = source.sourceName;
  result['bookSourceUrl'] = source.sourceUrl;
  result['bookSourceType'] = source.sourceType;
  result['bookSourceGroup'] = source.group;
  result['enabled'] = source.enabled;
  result['enabledExplore'] = source.enabledExplore;
  result['enabledCookieJar'] = source.enabledCookieJar;
  result['weight'] = source.weight;
  result['customOrder'] = source.customOrder;
  result['lastUpdateTime'] = source.updateTime;
  result['respondTime'] = source.respondTime;
  result['concurrentRate'] = source.concurrentRate;
  result['header'] = source.header;
  result['loginUrl'] = source.loginUrl;
  result['loginUi'] = source.loginUi;
  result['loginCheckJs'] = source.loginCheckJs;
  result['coverDecodeJs'] = source.coverDecodeJs;
  result['jsLib'] = source.jsLib;
  result['bookUrlPattern'] = source.bookUrlPattern;
  result['bookSourceComment'] = source.bookSourceComment;
  result['isAiGenerated'] = source.isAiGenerated;
  result['variableComment'] = source.variableComment;
  // 兼容旧版 HOS/Legado 书源字段：这些字段不能只依赖 rawJson 保留，
  // 新建或 AI 生成的 BookSource 也必须能够完整导出。
  result['ruleExplores'] = source.ruleExplores;
  result['ruleReview'] = mergeNestedRuleObject(source.rawJson, 'ruleReview', {
    'reviewUrl': source.ruleReviewUrl || source.reviewUrl,
    'avatarRule': source.ruleReviewAvatar || source.reviewAvatar,
    'contentRule': source.ruleReviewContent || source.reviewContent,
    'postTimeRule': source.ruleReviewPostTime || source.reviewPostTime,
    'reviewQuoteUrl': source.ruleReviewQuoteUrl || source.reviewQuoteUrl,
    'voteUpUrl': rawNestedRuleObject(source.rawJson, 'ruleReview')['voteUpUrl'] || '',
    'voteDownUrl': rawNestedRuleObject(source.rawJson, 'ruleReview')['voteDownUrl'] || '',
    'postReviewUrl': rawNestedRuleObject(source.rawJson, 'ruleReview')['postReviewUrl'] || '',
    'postQuoteUrl': rawNestedRuleObject(source.rawJson, 'ruleReview')['postQuoteUrl'] || '',
    'deleteUrl': rawNestedRuleObject(source.rawJson, 'ruleReview')['deleteUrl'] || ''
  });
  result['script'] = source.script;
  result['respond'] = source.respond;
  result['ruleExploreScreen'] = source.ruleExploreScreen;
  result['review'] = source.review;
  result['ruleReviewUrl'] = source.ruleReviewUrl;
  result['ruleReviewAvatar'] = source.ruleReviewAvatar;
  result['ruleReviewContent'] = source.ruleReviewContent;
  result['ruleReviewPostTime'] = source.ruleReviewPostTime;
  result['ruleReviewQuoteUrl'] = source.ruleReviewQuoteUrl;
  result['reviewUrl'] = source.reviewUrl;
  result['reviewAvatar'] = source.reviewAvatar;
  result['reviewContent'] = source.reviewContent;
  result['reviewPostTime'] = source.reviewPostTime;
  result['reviewQuoteUrl'] = source.reviewQuoteUrl;
  result['exploreUrl'] = source.exploreUrl;
  result['exploreScreen'] = source.exploreScreen;
  result['homepageModules'] = source.homepageModules;
  result['eventListener'] = source.eventListener;
  result['customButton'] = source.customButton;

  result['searchUrl'] = source.ruleSearchUrl;
  result['ruleSearch'] = mergeNestedRuleObject(source.rawJson, 'ruleSearch', {
    'checkKeyWord': source.ruleSearchCheckKeyWord,
    'bookList': source.ruleSearchList,
    'name': source.ruleSearchName,
    'author': source.ruleSearchAuthor,
    'kind': source.ruleSearchKind,
    'wordCount': source.ruleSearchWordCount,
    'lastChapter': source.ruleSearchLastChapter,
    // Android Legado 的标准字段名；lastUpdateTime 仅保留给旧版 HOS。
    'updateTime': source.ruleSearchLastUpdateTime,
    'lastUpdateTime': source.ruleSearchLastUpdateTime,
    'intro': source.ruleSearchIntroduce,
    'coverUrl': source.ruleSearchCover,
    'bookUrl': source.ruleSearchNoteUrl
  });
  result['ruleExplore'] = mergeNestedRuleObject(source.rawJson, 'ruleExplore', {
    'bookList': source.ruleExploreList,
    'name': source.ruleExploreName,
    'author': source.ruleExploreAuthor,
    'kind': source.ruleExploreKind,
    'wordCount': source.ruleExploreWordCount,
    'lastChapter': source.ruleExploreLastChapter,
    'updateTime': source.ruleExploreLastUpdateTime,
    'lastUpdateTime': source.ruleExploreLastUpdateTime,
    'intro': source.ruleExploreIntroduce,
    'coverUrl': source.ruleExploreCover,
    'bookUrl': source.ruleExploreNoteUrl
  });
  result['ruleBookInfo'] = mergeNestedRuleObject(source.rawJson, 'ruleBookInfo', {
    'init': source.ruleBookInfoInit,
    'name': source.ruleBookInfoName,
    'author': source.ruleBookInfoAuthor,
    'kind': source.ruleBookInfoKind,
    'wordCount': source.ruleBookInfoWordCount,
    'lastChapter': source.ruleBookInfoLastChapter,
    'updateTime': source.ruleBookInfoLastUpdateTime,
    'lastUpdateTime': source.ruleBookInfoLastUpdateTime,
    'intro': source.ruleBookInfoIntroduce,
    'coverUrl': source.ruleBookInfoCover,
    'tocUrl': source.ruleBookInfoTocUrl,
    'canReName': source.ruleBookInfoCanReName,
    'downloadUrls': source.ruleBookInfoDownloadUrls,
    'relatedBooks': source.ruleBookInfoRelatedBooks,
    'from': source.ruleBookInfoFrom
  });
  result['ruleToc'] = mergeNestedRuleObject(source.rawJson, 'ruleToc', {
    'tocUrl': source.ruleTocUrl,
    'chapterList': source.ruleToc,
    'chapterName': source.ruleTocTitle,
    'chapterUrl': source.ruleTocUrlItem,
    'preUpdateJs': source.ruleTocPreUpdateJs,
    'formatJs': source.ruleTocFormatJs,
    'isVolume': source.ruleTocIsVolume,
    'isVip': source.ruleTocIsVip,
    'isPay': source.ruleTocIsPay,
    'updateTime': source.ruleTocUpdateTime,
    'nextTocUrl': source.ruleTocNextTocUrl
  });
  result['ruleContent'] = mergeNestedRuleObject(source.rawJson, 'ruleContent', {
    'contentUrl': source.ruleBookContentUrl,
    'content': source.ruleBookContent,
    'subContent': source.ruleBookContentSubContent,
    'title': source.ruleBookContentTitle,
    'nextContentUrl': source.ruleBookContentNext,
    'webJs': source.ruleBookContentWebJs,
    'sourceRegex': source.ruleBookContentSourceRegex,
    'replaceRegex': source.ruleBookContentReplaceRegex,
    'imageStyle': source.ruleBookContentImageStyle,
    'imageDecode': source.ruleBookContentImageDecode,
    'payAction': source.ruleBookContentPayAction,
    'callBackJs': source.ruleBookContentCallBackJs
  });
  return result;
}

export function serializeBookSource(source: BookSource, pretty: boolean = false): string {
  return JSON.stringify(bookSourceToJsonObject(source), null, pretty ? 2 : 0);
}
