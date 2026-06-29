/**
 * RSS 数据模型
 * 参考 Android RssSource / RssArticle / RssStar / RssReadRecord
 */

export interface RSSSource {
  sourceUrl: string;
  sourceName: string;
  sourceIcon: string;
  sourceGroup: string;
  sourceComment: string;
  enabled: boolean;
  variableComment: string;
  jsLib: string;
  enabledCookieJar: boolean;
  concurrentRate: string;
  header: string;
  loginUrl: string;
  loginUi: string;
  loginCheckJs: string;
  coverDecodeJs: string;
  sortUrl: string;
  singleUrl: boolean;
  articleStyle: number;
  ruleArticles: string;
  ruleNextPage: string;
  ruleTitle: string;
  rulePubDate: string;
  ruleDescription: string;
  ruleImage: string;
  ruleLink: string;
  ruleContent: string;
  contentWhitelist: string;
  contentBlacklist: string;
  shouldOverrideUrlLoading: string;
  style: string;
  enableJs: boolean;
  loadWithBaseUrl: boolean;
  injectJs: string;
  preloadJs: string;
  startHtml: string;
  startStyle: string;
  startJs: string;
  showWebLog: boolean;
  lastUpdateTime: number;
  customOrder: number;
  type: number;
  preload: boolean;
  cacheFirst: boolean;
  searchUrl: string;
  redirectPolicy: string;
}

export interface RSSArticle {
  origin: string;
  sort: string;
  title: string;
  order: number;
  link: string;
  pubDate: string | null;
  description: string | null;
  content: string | null;
  image: string | null;
  group: string;
  read: boolean;
  variable: string | null;
  type: number;
  durPos: number;
}

export interface RssStar {
  origin: string;
  sort: string;
  title: string;
  starTime: number;
  link: string;
  pubDate: string | null;
  description: string | null;
  content: string | null;
  image: string | null;
  group: string;
  variable: string | null;
  type: number;
  durPos: number;
}

export interface RssReadRecord {
  origin: string;
  sort: string;
  title: string;
  readTime: number;
  record: string;
  image: string | null;
  type: number;
  durPos: number;
  pubDate: string | null;
}

/** 创建 RSS 源默认值 */
export function createDefaultRSSSource(): RSSSource {
  return {
    sourceUrl: '',
    sourceName: '',
    sourceIcon: '',
    sourceGroup: '',
    sourceComment: '',
    enabled: true,
    variableComment: '',
    jsLib: '',
    enabledCookieJar: false,
    concurrentRate: '',
    header: '',
    loginUrl: '',
    loginUi: '',
    loginCheckJs: '',
    coverDecodeJs: '',
    sortUrl: '',
    singleUrl: false,
    articleStyle: 0,
    ruleArticles: '',
    ruleNextPage: '',
    ruleTitle: '',
    rulePubDate: '',
    ruleDescription: '',
    ruleImage: '',
    ruleLink: '',
    ruleContent: '',
    contentWhitelist: '',
    contentBlacklist: '',
    shouldOverrideUrlLoading: '',
    style: '',
    enableJs: true,
    loadWithBaseUrl: true,
    injectJs: '',
    preloadJs: '',
    startHtml: '',
    startStyle: '',
    startJs: '',
    showWebLog: false,
    lastUpdateTime: 0,
    customOrder: 0,
    type: 0,
    preload: false,
    cacheFirst: false,
    searchUrl: '',
    redirectPolicy: 'ASK_CROSS_ORIGIN',
  };
}
