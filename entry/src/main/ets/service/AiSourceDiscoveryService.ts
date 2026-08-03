import { BookSource } from '../model/BookSource';
import {
  AiSearchPageLink, AiSourceCandidate, AiSourceCandidateDuplicate,
  AiSourceCandidateSample
} from '../model/AiSourceDiscovery';
import { isSafeAiImportUrl } from '../engine/ai/AiBookImporter';
import { isOnlineSearchEngineHost } from './OnlineSearchEngineService';

interface ParsedHttpUrl {
  scheme: string;
  authority: string;
  host: string;
  port: string;
  path: string;
}

interface CandidateAccumulator {
  landingUrl: string;
  homepageUrl: string;
  normalizedSiteKey: string;
  host: string;
  displayName: string;
  hitCount: number;
  samples: AiSourceCandidateSample[];
  confidence: number;
  directCount: number;
  pendingCount: number;
}

function parseHttpUrl_(value: string): ParsedHttpUrl | null {
  const match = (value || '').trim().match(/^(https?):\/\/([^/?#]+)([^?#]*)/i);
  if (!match || match.length < 4) return null;
  const authority = match[2];
  if (authority.includes('@')) return null;
  let host = authority;
  let port = '';
  if (host.startsWith('[')) {
    const end = host.indexOf(']');
    if (end >= 0) {
      const rest = host.substring(end + 1);
      host = host.substring(1, end);
      port = rest.startsWith(':') ? rest.substring(1) : '';
    }
  } else {
    const separator = host.lastIndexOf(':');
    if (separator > 0 && host.indexOf(':') === separator) {
      port = host.substring(separator + 1);
      host = host.substring(0, separator);
    }
  }
  return {
    scheme: match[1].toLowerCase(),
    authority: authority,
    host: host.toLowerCase(),
    port: port,
    path: match[3] || '/',
  };
}

function decodePart_(value: string): string {
  const normalized = (value || '').replace(/&amp;/gi, '&').replace(/\+/g, ' ');
  try {
    return decodeURIComponent(normalized);
  } catch (_e) {
    return normalized;
  }
}

function queryParam_(url: string, names: string[]): string {
  const question = (url || '').indexOf('?');
  if (question < 0) return '';
  const hash = url.indexOf('#', question);
  const query = url.substring(question + 1, hash >= 0 ? hash : url.length);
  for (const item of query.split('&')) {
    const separator = item.indexOf('=');
    const rawKey = separator >= 0 ? item.substring(0, separator) : item;
    const key = decodePart_(rawKey).toLowerCase();
    if (!names.includes(key)) continue;
    return decodePart_(separator >= 0 ? item.substring(separator + 1) : '');
  }
  return '';
}

function withoutQueryFragment_(url: string): string {
  return (url || '').split('#')[0];
}

function normalizedHost_(host: string): string {
  return host.toLowerCase().replace(/^www\./, '');
}

function authority_(parsed: ParsedHttpUrl): string {
  const defaultPort = (parsed.scheme === 'http' && parsed.port === '80') ||
    (parsed.scheme === 'https' && parsed.port === '443');
  const host = parsed.host.includes(':') ? '[' + parsed.host + ']' : parsed.host;
  return host + (parsed.port && !defaultPort ? ':' + parsed.port : '');
}

function isHttpsPreferred_(left: string, right: string): boolean {
  return /^https:\/\//i.test(right) && !/^https:\/\//i.test(left);
}

function shortText_(value: string): string {
  return (value || '').replace(/\s+/g, ' ').trim().substring(0, 500);
}

/** 用于相关性判断的轻量文本归一化，不改变界面上展示的原文。 */
function normalizedSearchText_(value: string): string {
  return (value || '').toLowerCase()
    .replace(/[\s《》「」『』【】\[\]（）(){}<>“”‘’'"`~～!！?？,，。；;：:、·・…—–_\-|｜/\\]+/g, '');
}

function isGenericNavigationText_(value: string): boolean {
  const text = normalizedSearchText_(value);
  if (!text) return true;
  return /^(?:首页|主页|登录|注册|退出|设置|帮助|反馈|招聘|校园招聘|广告|推广|更多|详情|下一页|上一页|翻页|图片|视频|新闻|地图|收藏|分享|下载|快照|翻译)$/.test(text);
}

function hasBookMetadataText_(value: string): boolean {
  return /作者|小说|章节|目录|连载|完结|阅读|字数|简介|书名|更新时间|最新章节/.test(value || '');
}

/** 仅保留带有明确站内跳转形态的 opaque 搜索链接。 */
function isOpaqueSearchRedirect_(url: string): boolean {
  const parsed = parseHttpUrl_(url);
  if (!parsed) return /^(?:\/|\?|#)?(?:link|url|redirect|jump|goto|ck|aclick)(?:[/?#]|$)/i.test(url || '');
  if (!isOnlineSearchEngineHost(url)) return false;
  if (/(?:^|\/)(?:search|s|web)(?:\/|$)/i.test(parsed.path)) return false;
  return /(?:^|\/)(?:link|url|redirect|jump|goto|ck|aclick)(?:\/|$)/i.test(parsed.path) ||
    /[?&](?:url|target|u|dest|destination)=/i.test(url);
}

function isRelevantSearchLink_(link: AiSearchPageLink, keyword: string,
  landingUrl: string, direct: boolean): boolean {
  const expected = normalizedSearchText_(keyword);
  if (!expected) return true;
  const text = normalizedSearchText_((link.text || '') + ' ' + (link.title || ''));
  if (text.includes(expected)) return true;

  // 结果卡片的辅助链接（“阅读”“详情”等）可能没有重复书名；只在同一
  // 卡片确实包含书名、且链接是外站直达的小说路径时保留，避免把页脚导航
  // 或广告卡片归并成候选网站。
  const context = shortText_(link.context || '');
  if (!normalizedSearchText_(context).includes(expected) || !direct) return false;
  if (isGenericNavigationText_(link.text || link.title || '')) return false;
  return isLikelyBookPath_(landingUrl) || hasBookMetadataText_(context);
}

function isLikelyBookPath_(url: string): boolean {
  const parsed = parseHttpUrl_(url);
  if (!parsed) return false;
  return /(?:^|\/)(?:book|books|novel|fiction|story|read|chapter|info)(?:\/|\b)/i.test(parsed.path);
}

function displayName_(link: AiSearchPageLink, host: string, keyword: string): string {
  const values = [link.title, link.text]
    .map((value: string): string => shortText_(value))
    .filter((value: string): boolean => !!value && !/^https?:\/\//i.test(value));
  const exact = values.find((value: string): boolean => value.includes(keyword));
  return (exact || values.sort((a: string, b: string): number => a.length - b.length)[0] || host).substring(0, 120);
}

function candidateKey_(key: string, index: number, landingUrl: string): string {
  if (key) return key;
  return landingUrl ? 'pending-' + landingUrl : 'pending-' + index.toString();
}

export class AiSourceDiscoveryService {
  static normalizeHomepageUrl(url: string): string {
    const parsed = parseHttpUrl_(url);
    if (!parsed || !isSafeAiImportUrl(url)) return '';
    return parsed.scheme + '://' + authority_({
      scheme: parsed.scheme,
      authority: parsed.authority,
      host: normalizedHost_(parsed.host),
      port: parsed.port,
      path: '/',
    });
  }

  static normalizedSiteKey(url: string): string {
    const parsed = parseHttpUrl_(url);
    if (!parsed || !isSafeAiImportUrl(url)) return '';
    const host = normalizedHost_(parsed.host);
    const defaultPort = (parsed.scheme === 'http' && parsed.port === '80') ||
      (parsed.scheme === 'https' && parsed.port === '443');
    return host + (parsed.port && !defaultPort ? ':' + parsed.port : '');
  }

  static isCandidateUrl(url: string): boolean {
    const value = withoutQueryFragment_(url).trim();
    return isSafeAiImportUrl(value) && !isOnlineSearchEngineHost(value);
  }

  static decodeKnownSearchRedirect(engineId: string, link: AiSearchPageLink): string {
    const data = decodePart_(link.dataUrl || '');
    if (this.isCandidateUrl(data)) return withoutQueryFragment_(data);

    const redirectParams = ['url', 'target', 'u', 'dest', 'destination', 'q'];
    const decoded = queryParam_(link.href, redirectParams);
    if (this.isCandidateUrl(decoded)) return withoutQueryFragment_(decoded);

    const href = decodePart_(link.href || '');
    if (this.isCandidateUrl(href)) return withoutQueryFragment_(href);
    // engineId is intentionally part of the signature: future engines can add
    // provider-specific redirect decoding without changing callers.
    void engineId;
    return '';
  }

  private static landingUrl_(engineId: string, link: AiSearchPageLink): { url: string; direct: boolean } {
    const decoded = this.decodeKnownSearchRedirect(engineId, link);
    if (decoded) return { url: decoded, direct: true };
    const href = (link.href || '').trim();
    return { url: href, direct: false };
  }

  private static homepageFromLanding_(url: string): string {
    const parsed = parseHttpUrl_(url);
    if (!parsed || !isSafeAiImportUrl(url)) return '';
    const origin = parsed.scheme + '://' + authority_(parsed);
    return this.normalizeHomepageUrl(origin);
  }

  private static confidence_(link: AiSearchPageLink, keyword: string,
    hitCount: number, direct: boolean, landingUrl: string): number {
    const text = (link.text + ' ' + link.title).toLowerCase();
    const context = (link.context || '').toLowerCase();
    const expected = keyword.toLowerCase();
    let score = 0;
    if (expected && text.includes(expected)) score += 35;
    if (expected && context.includes(expected)) score += 20;
    if (hitCount >= 2) score += 15;
    if (isLikelyBookPath_(landingUrl)) score += 10;
    if (direct) score += 10;
    else score -= 30;
    if (!shortText_(link.text)) score -= 10;
    return Math.max(0, Math.min(100, score));
  }

  private static mergeSample_(samples: AiSourceCandidateSample[], sample: AiSourceCandidateSample): AiSourceCandidateSample[] {
    if (!sample.url || samples.some((item: AiSourceCandidateSample): boolean => item.url === sample.url)) return samples;
    return [...samples, sample].slice(0, 3);
  }

  static buildCandidates(engineId: string, keyword: string, resultPageUrl: string,
    links: AiSearchPageLink[], existingSources: BookSource[]): AiSourceCandidate[] {
    const normalizedKeyword = keyword.trim();
    const merged = new Map<string, CandidateAccumulator>();
    let pendingIndex = 0;
    for (const link of links.slice(0, 300)) {
      const landing = this.landingUrl_(engineId, link);
      const homepage = this.homepageFromLanding_(landing.url);
      const siteKey = this.normalizedSiteKey(homepage);
      const safe = !!homepage && this.isCandidateUrl(landing.url);
      if (!landing.url || !isRelevantSearchLink_(link, normalizedKeyword, landing.url, landing.direct)) continue;
      // 已知的非安全直达地址不能降级为“待确认”；只有符合常见跳转形态
      // 的 opaque 链接才保留，且它们默认不会被选中。
      if (landing.direct && !safe) continue;
      if (!safe && !landing.direct && !isOpaqueSearchRedirect_(landing.url)) continue;
      // Opaque search redirects are retained as address-pending rows, but are
      // never selected automatically and cannot be sent to the Agent directly.
      const key = candidateKey_(siteKey, pendingIndex++, landing.url);
      if (merged.has(key)) {
        const current = merged.get(key)!;
        current.hitCount++;
        if (landing.direct) current.directCount++;
        else current.pendingCount++;
        current.confidence = Math.max(current.confidence,
          this.confidence_(link, normalizedKeyword, current.hitCount, landing.direct, landing.url));
        current.samples = this.mergeSample_(current.samples, {
          title: shortText_(link.title || link.text), url: landing.url, context: shortText_(link.context),
        });
        if (landing.direct && isHttpsPreferred_(current.homepageUrl, homepage)) {
          current.homepageUrl = homepage;
          current.landingUrl = landing.url;
        }
        continue;
      }
      const parsed = parseHttpUrl_(landing.url);
      const host = safe && parsed ? parsed.host : '地址待确认';
      const initialHit = 1;
      merged.set(key, {
        landingUrl: landing.url,
        homepageUrl: homepage,
        normalizedSiteKey: siteKey,
        host: host || '地址待确认',
        displayName: displayName_(link, host || '地址待确认', normalizedKeyword),
        hitCount: initialHit,
        samples: [{ title: shortText_(link.title || link.text), url: landing.url, context: shortText_(link.context) }],
        confidence: this.confidence_(link, normalizedKeyword, initialHit, landing.direct, landing.url),
        directCount: landing.direct ? 1 : 0,
        pendingCount: landing.direct ? 0 : 1,
      });
    }

    const candidates: AiSourceCandidate[] = [];
    for (const item of merged.values()) {
      let duplicate: AiSourceCandidateDuplicate = 'none';
      let existingSourceId = 0;
      let existingSourceName = '';
      for (const source of existingSources) {
        const sourceHomepage = this.normalizeHomepageUrl(source.sourceUrl);
        const sourceKey = this.normalizedSiteKey(source.sourceUrl);
        if (item.homepageUrl && sourceHomepage === item.homepageUrl) {
          duplicate = 'exact';
          existingSourceId = source.id;
          existingSourceName = source.sourceName;
          break;
        }
        if (duplicate === 'none' && item.normalizedSiteKey && sourceKey === item.normalizedSiteKey) {
          duplicate = 'same_host';
          existingSourceId = source.id;
          existingSourceName = source.sourceName;
        }
      }
      const safe = !!item.homepageUrl && this.isCandidateUrl(item.landingUrl);
      candidates.push({
        id: engineId + ':' + (item.normalizedSiteKey || item.landingUrl || item.displayName),
        engineId: engineId,
        keyword: normalizedKeyword,
        resultPageUrl: resultPageUrl,
        displayName: item.displayName,
        landingUrl: item.landingUrl,
        homepageUrl: item.homepageUrl,
        normalizedSiteKey: item.normalizedSiteKey,
        host: item.host,
        hitCount: item.hitCount,
        samples: item.samples,
        confidence: item.confidence,
        selected: safe && duplicate === 'none',
        safe: safe,
        duplicate: duplicate,
        existingSourceId: existingSourceId,
        existingSourceName: existingSourceName,
        status: 'candidate',
        currentStep: -1,
        stepSummary: '',
        logs: [],
        savedSourceId: 0,
        error: '',
      });
    }
    candidates.sort((left: AiSourceCandidate, right: AiSourceCandidate): number => {
      if (right.confidence !== left.confidence) return right.confidence - left.confidence;
      if (right.hitCount !== left.hitCount) return right.hitCount - left.hitCount;
      return left.host.localeCompare(right.host);
    });
    const usedIds = new Map<string, number>();
    for (const candidate of candidates) {
      const base = candidate.id;
      const count = usedIds.get(base) || 0;
      usedIds.set(base, count + 1);
      candidate.id = count === 0 ? base : base + '#' + count.toString();
    }
    return candidates.slice(0, 50);
  }
}
