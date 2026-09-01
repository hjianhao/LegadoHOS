/** 从详情页 HTML 提取封面地址，优先使用 Open Graph 元数据。 */

function readAttribute(tag: string, name: string): string {
  const match = tag.match(new RegExp('\\b' + name + '\\s*=\\s*["\\\']([^"\\\']*)["\\\']', 'i'));
  return match ? match[1].trim() : '';
}

function isIgnoredCover(value: string): boolean {
  return /(?:favicon|logo|zanwu|default[-_ ]?cover|avatar|banner)/i.test(value);
}

function absoluteUrl(pageUrl: string, value: string): string {
  const raw = (value || '').trim().replace(/&amp;/gi, '&');
  if (!raw || /^javascript:/i.test(raw)) return '';
  if (/^(?:https?:|data:)/i.test(raw)) return raw;
  if (raw.startsWith('//')) {
    const protocol = pageUrl.match(/^([a-z]+:)/i)?.[1] || 'https:';
    return protocol + raw;
  }
  const cleanPageUrl = (pageUrl || '').replace(/[?#].*$/, '').replace(/\/+$/, '');
  const origin = cleanPageUrl.match(/^(https?:\/\/[^/]+)/i)?.[1] || cleanPageUrl;
  if (raw.startsWith('/')) return origin + raw;
  const slash = cleanPageUrl.lastIndexOf('/');
  return (slash >= 0 ? cleanPageUrl.substring(0, slash + 1) : cleanPageUrl + '/') + raw;
}

function coverFromMeta(html: string, pageUrl: string): string {
  const tags = html.match(/<meta\b[^>]*>/gi) || [];
  for (const tag of tags) {
    const property = readAttribute(tag, 'property') || readAttribute(tag, 'name');
    if (property.toLowerCase() !== 'og:image') continue;
    const value = readAttribute(tag, 'content');
    if (!isIgnoredCover(value)) {
      const url = absoluteUrl(pageUrl, value);
      if (url) return url;
    }
  }
  return '';
}

function coverFromImage(html: string, pageUrl: string): string {
  const tags = html.match(/<img\b[^>]*>/gi) || [];
  for (const tag of tags) {
    const value = readAttribute(tag, 'src') || readAttribute(tag, 'data-src') ||
      readAttribute(tag, 'data-original') || readAttribute(tag, 'data-lazy-src');
    if (!value || isIgnoredCover(value)) continue;
    if (!/\.(?:jpe?g|png|webp|gif|bmp)(?:[?#]|$)/i.test(value)) continue;
    const url = absoluteUrl(pageUrl, value);
    if (url) return url;
  }
  return '';
}

export function extractCoverUrl(html: string, pageUrl: string): string {
  if (!html) return '';
  return coverFromMeta(html, pageUrl) || coverFromImage(html, pageUrl);
}
