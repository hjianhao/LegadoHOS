/**
 * CookieStore — 按域名持久化 Cookie（参照 Android Legado CookieStore）
 *
 * - 内存缓存 + preferences 持久化（store: legado_cookies）
 * - 网络层请求前注入 Cookie 头，响应后解析 Set-Cookie 合并保存
 * - JS 引擎（Worker / 主线程）通过 __cookieOp 同步桥访问同一份数据
 * - WebView 登录后把 WebCookieManager 的 cookie 拉回这里
 *
 * key 设计：以 url 的 host 为键（Android 用二级域名，host 更精确且够用）
 */
import preferences from '@ohos.data.preferences';

const COOKIE_STORE_NAME = 'legado_cookies';
const KEY_PREFIX = 'host_';

/** 提取 URL 的 host（小写，不含端口以外的部分） */
export function hostOf(url: string): string {
  try {
    const m = url.match(/^https?:\/\/([^/?#]+)/i);
    if (!m) return '';
    return m[1].toLowerCase();
  } catch (_e) {
    return '';
  }
}

/**
 * 拆分逗号拼接的 Set-Cookie 头。
 * 只在 ",<token>=" 处切分（Expires 日期中的逗号后不是 token=，不会误切）。
 */
export function splitSetCookieHeader(raw: string): string[] {
  return raw.split(/,(?=\s*[^\s;,=]+=[^;,]*)/).map(s => s.trim()).filter(s => !!s);
}

/** 归一化响应头中的 set-cookie（可能是 string 或 string[]）为独立 cookie 行数组 */
export function normalizeSetCookies(raw: string | string[] | undefined): string[] {
  if (!raw) return [];
  if (Array.isArray(raw)) {
    const out: string[] = [];
    for (const item of raw) {
      out.push(...splitSetCookieHeader(String(item)));
    }
    return out;
  }
  return splitSetCookieHeader(raw);
}

interface CookiePair {
  name: string;
  value: string;
  /** true 表示服务器要求删除该 cookie（Max-Age=0 或 Expires 已过期） */
  expired: boolean;
}

/** 解析单行 Set-Cookie，提取 name=value 及过期标记 */
export function parseSetCookieLine(line: string): CookiePair | null {
  const firstSemi = line.indexOf(';');
  const pair = (firstSemi < 0 ? line : line.substring(0, firstSemi)).trim();
  const eq = pair.indexOf('=');
  if (eq <= 0) return null;
  const name = pair.substring(0, eq).trim();
  const value = pair.substring(eq + 1).trim();
  if (!name) return null;

  let expired = false;
  const attrs = firstSemi < 0 ? '' : line.substring(firstSemi + 1);
  const maxAge = attrs.match(/max-age\s*=\s*(-?\d+)/i);
  if (maxAge && parseInt(maxAge[1], 10) <= 0) {
    expired = true;
  }
  const expires = attrs.match(/expires\s*=\s*([^;]+)/i);
  if (expires) {
    const ts = Date.parse(expires[1].trim());
    if (!isNaN(ts) && ts <= Date.now()) {
      expired = true;
    }
  }
  if (!value && !expired) {
    // name= 空值视为删除（常见登出写法）
    expired = true;
  }
  return { name, value, expired };
}

/** 把 "a=1; b=2" 形式的 cookie 头解析为键值对 */
export function parseCookieHeader(header: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const seg of header.split(';')) {
    const eq = seg.indexOf('=');
    if (eq > 0) {
      const name = seg.substring(0, eq).trim();
      if (name) map.set(name, seg.substring(eq + 1).trim());
    }
  }
  return map;
}

export function cookieMapToHeader(map: Map<string, string>): string {
  const parts: string[] = [];
  map.forEach((v, k) => { parts.push(k + '=' + v); });
  return parts.join('; ');
}

export class CookieStore {
  private static instance: CookieStore;
  private prefStore_: preferences.Preferences | null = null;
  /** host → "a=1; b=2" 形式的 cookie 头 */
  private memoryCache_: Map<string, string> = new Map();

  private constructor() {}

  static getInstance(): CookieStore {
    if (!CookieStore.instance) {
      CookieStore.instance = new CookieStore();
    }
    return CookieStore.instance;
  }

  async init(context: Context): Promise<void> {
    if (this.prefStore_) return;
    try {
      this.prefStore_ = await preferences.getPreferences(context, COOKIE_STORE_NAME);
      const all = this.prefStore_.getAllSync() as Record<string, Object>;
      for (const key of Object.keys(all)) {
        if (key.startsWith(KEY_PREFIX) && typeof all[key] === 'string') {
          this.memoryCache_.set(key.substring(KEY_PREFIX.length), all[key] as string);
        }
      }
      console.info('[CookieStore] init OK,', this.memoryCache_.size, 'hosts loaded');
    } catch (err) {
      console.error('[CookieStore] init failed:', (err as Error).message);
    }
  }

  /** 同步获取某个 URL 应携带的 Cookie 头（读内存缓存） */
  getCookie(url: string): string {
    const host = hostOf(url);
    if (!host) return '';
    return this.memoryCache_.get(host) || '';
  }

  getCookieByHost(host: string): string {
    return this.memoryCache_.get(host.toLowerCase()) || '';
  }

  /** 合并写入一个 "a=1; b=2" 形式的 cookie 头（对应 Android replaceCookie） */
  async setCookie(url: string, cookieHeader: string): Promise<void> {
    const host = hostOf(url);
    if (!host || !cookieHeader) return;
    await this.setByHost(host, cookieHeader);
  }

  /** 按 host 合并写入（WebView 拉回 / Worker 同步用） */
  async setByHost(host: string, cookieHeader: string): Promise<void> {
    host = host.toLowerCase();
    const existing = parseCookieHeader(this.memoryCache_.get(host) || '');
    const incoming = parseCookieHeader(cookieHeader);
    incoming.forEach((v, k) => { existing.set(k, v); });
    await this.persistHost_(host, existing);
  }

  /** 从响应头保存 Set-Cookie（合并 + 处理过期删除） */
  async setCookiesFromResponse(url: string, setCookieRaw: string | string[] | undefined): Promise<void> {
    const host = hostOf(url);
    if (!host) return;
    const lines = normalizeSetCookies(setCookieRaw);
    if (lines.length === 0) return;
    const existing = parseCookieHeader(this.memoryCache_.get(host) || '');
    let changed = false;
    for (const line of lines) {
      const pair = parseSetCookieLine(line);
      if (!pair) continue;
      if (pair.expired) {
        if (existing.delete(pair.name)) changed = true;
      } else {
        existing.set(pair.name, pair.value);
        changed = true;
      }
    }
    if (changed) {
      await this.persistHost_(host, existing);
      console.info('[CookieStore]', host, 'cookies updated,', existing.size, 'pairs');
    }
  }

  async removeCookie(url: string): Promise<void> {
    const host = hostOf(url);
    if (!host) return;
    await this.removeByHost(host);
  }

  async removeByHost(host: string): Promise<void> {
    host = host.toLowerCase();
    this.memoryCache_.delete(host);
    if (this.prefStore_) {
      try {
        this.prefStore_.deleteSync(KEY_PREFIX + host);
        this.prefStore_.flush();
      } catch (_e) { /* ignore */ }
    }
  }

  /** 全量快照（同步给 JS Worker） */
  getSnapshot(): Record<string, string> {
    const out: Record<string, string> = {};
    this.memoryCache_.forEach((v, k) => { out[k] = v; });
    return out;
  }

  private async persistHost_(host: string, map: Map<string, string>): Promise<void> {
    const header = cookieMapToHeader(map);
    if (header) {
      this.memoryCache_.set(host, header);
    } else {
      this.memoryCache_.delete(host);
    }
    if (this.prefStore_) {
      try {
        if (header) {
          this.prefStore_.putSync(KEY_PREFIX + host, header);
        } else {
          this.prefStore_.deleteSync(KEY_PREFIX + host);
        }
        this.prefStore_.flush();
      } catch (err) {
        console.warn('[CookieStore] persist failed:', (err as Error).message);
      }
    }
  }
}
