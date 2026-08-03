/** 在线搜书与 AI 搜书发现共用的搜索引擎配置。 */

export interface OnlineSearchEngine {
  id: string;
  name: string;
}

export const ONLINE_SEARCH_ENGINES: OnlineSearchEngine[] = [
  { id: 'bing', name: '必应' },
  { id: 'baidu', name: '百度' },
  { id: 'sogou', name: '搜狗' },
  { id: 'shenma', name: '神马' },
  { id: 'google', name: 'Google' },
];

export function normalizeOnlineSearchEngine(value: string): string {
  return ONLINE_SEARCH_ENGINES.some((item: OnlineSearchEngine): boolean => item.id === value)
    ? value : 'bing';
}

export function getOnlineSearchEngineName(value: string): string {
  const id = normalizeOnlineSearchEngine(value);
  const item = ONLINE_SEARCH_ENGINES.find((candidate: OnlineSearchEngine): boolean => candidate.id === id);
  return item ? item.name : '必应';
}

export function buildOnlineSearchUrl(engineId: string, keyword: string): string {
  const encoded = encodeURIComponent(keyword);
  switch (normalizeOnlineSearchEngine(engineId)) {
    case 'baidu': return 'https://www.baidu.com/s?wd=' + encoded;
    case 'sogou': return 'https://www.sogou.com/web?query=' + encoded;
    case 'shenma': return 'https://m.sm.cn/s?q=' + encoded;
    case 'google': return 'https://www.google.com/search?q=' + encoded;
    case 'bing':
    default: return 'https://cn.bing.com/search?q=' + encoded;
  }
}

function hostAndPath_(url: string): { host: string; path: string } {
  const match = (url || '').trim().match(/^https?:\/\/([^/?#]+)([^?#]*)/i);
  if (!match || match.length < 3) return { host: '', path: '' };
  return { host: match[1].toLowerCase(), path: match[2].toLowerCase() || '/' };
}

export function isOnlineSearchEngineHost(url: string): boolean {
  const parsed = hostAndPath_(url);
  const host = parsed.host.replace(/^www\./, '');
  // 搜索结果中的跳转、招聘、帮助和推广链接可能使用搜索引擎自己的
  // 子域名（例如 talent.baidu.com），不能只匹配搜索首页的主机名。
  return host === 'bing.com' || host.endsWith('.bing.com') ||
    host === 'baidu.com' || host.endsWith('.baidu.com') ||
    host === 'sogou.com' || host.endsWith('.sogou.com') ||
    host === 'sm.cn' || host.endsWith('.sm.cn') ||
    host === 'google.com' || host.endsWith('.google.com') ||
    host.endsWith('.google.co.uk') || host.endsWith('.google.co.jp');
}

export function isOnlineSearchResultPage(url: string): boolean {
  const parsed = hostAndPath_(url);
  if (!parsed.host) return false;
  const host = parsed.host.replace(/^www\./, '');
  if ((host === 'bing.com' || host === 'cn.bing.com') && parsed.path === '/search') return true;
  if ((host === 'baidu.com' || host === 'm.baidu.com') && parsed.path === '/s') return true;
  if ((host === 'sogou.com' || host === 'm.sogou.com') && parsed.path === '/web') return true;
  if ((host === 'sm.cn' || host === 'm.sm.cn') && parsed.path === '/s') return true;
  return (host === 'google.com' || host.endsWith('.google.com') ||
    host.endsWith('.google.co.uk') || host.endsWith('.google.co.jp')) &&
    parsed.path === '/search';
}
