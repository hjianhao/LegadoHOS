/**
 * HTML 实体解码工具。
 *
 * 正文书源通常返回 HTML 片段，而不是已经解码的纯文本。这里集中处理
 * 常见 HTML4 命名实体和十进制/十六进制数字实体，避免不同清洗路径各自
 * 维护一份不完整的替换表。
 */
export class HtmlEntityUtil {
  private static readonly NAMED_ENTITIES: Record<string, string> = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
    nbsp: ' ', ensp: ' ', emsp: ' ', thinsp: '', zwnj: '', zwj: '',
    ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', sbquo: '‚', bdquo: '„',
    laquo: '«', raquo: '»', lsaquo: '‹', rsaquo: '›',
    hellip: '…', mdash: '—', ndash: '–', minus: '−', middot: '·', bull: '•',
    prime: '′', Prime: '″',
    copy: '©', reg: '®', trade: '™', deg: '°', plusmn: '±', times: '×', divide: '÷',
    frac12: '½', frac14: '¼', frac34: '¾', sup1: '¹', sup2: '²', sup3: '³',
    micro: 'µ', para: '¶', sect: '§', cent: '¢', pound: '£', yen: '¥', euro: '€',
    shy: '\u00ad', NewLine: '\n'
  };

  static decode(value: string): string {
    if (!value || value.indexOf('&') < 0) return value || '';
    return value.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]+);/gi,
      (entity: string, token: string): string => {
        const numeric = token.match(/^#x([0-9a-f]+)$/i);
        const decimal = token.match(/^#([0-9]+)$/);
        if (numeric || decimal) {
          const codePoint = parseInt(numeric ? numeric[1] : (decimal ? decimal[1] : ''), numeric ? 16 : 10);
          if (!isFinite(codePoint) || codePoint < 0 || codePoint > 0x10FFFF) return entity;
          if (codePoint <= 0xFFFF) return String.fromCharCode(codePoint);
          const adjusted = codePoint - 0x10000;
          return String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
        }
        const exact = HtmlEntityUtil.NAMED_ENTITIES[token];
        if (exact !== undefined) return exact;
        const name = token.toLowerCase();
        return HtmlEntityUtil.NAMED_ENTITIES[name] ?? entity;
      });
  }
}
