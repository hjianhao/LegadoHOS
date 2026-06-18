/**
 * 规则解析器
 *
 * 支持 Legado 书源规则语法：
 * - JSONPath: $.list[*]
 * - CSS 选择器: div.book-list > .item
 * - XPath: //div[@class="book-list"]
 * - 正则: regex(pattern, flags)
 * - 混合规则: CSS+JSONPath
 */
export class RuleParser {
  /**
   * 判断规则类型并执行对应解析
   */
  static parse(html: string, rule: string): any {
    if (!rule || rule.trim() === '') return null;

    const trimmed = rule.trim();

    // 正则规则: regex(pattern, flags)
    if (trimmed.startsWith('regex(')) {
      return this.parseRegex(html, trimmed);
    }

    // JSONPath: $.xxx[*].yyy
    if (trimmed.startsWith('$.')) {
      try {
        const json = JSON.parse(html);
        return this.parseJsonPath(json, trimmed);
      } catch (e) {
        return null;
      }
    }

    // CSS / XPath（通过 HTML 解析）
    // 简化的实现——实际需要集成 HTML 解析器
    if (trimmed.startsWith('//') || trimmed.startsWith('.') ||
        trimmed.startsWith('#') || trimmed.includes(' > ') ||
        trimmed.startsWith('div') || trimmed.startsWith('ul')) {
      return this.parseCssOrXPath(html, trimmed);
    }

    // 纯文本/属性名
    return trimmed;
  }

  /**
   * 批量解析多个规则
   */
  static parseAll(html: string, rules: Record<string, string>): Record<string, any> {
    const result: Record<string, any> = {};
    for (const [key, rule] of Object.entries(rules)) {
      if (rule) {
        result[key] = this.parse(html, rule);
      }
    }
    return result;
  }

  /**
   * 解析 CSS 选择器规则
   * 使用简化的选择器匹配（实际项目应集成 jsoup 或类似 HTML 解析器）
   */
  static parseCssOrXPath(html: string, selector: string): string[] {
    const results: string[] = [];

    // XPath: //div[@class="book-list"]
    if (selector.startsWith('//')) {
      const tagMatch = selector.match(/^\/\/(\w+)/);
      const attrMatch = selector.match(/@(\w+)/);
      const classMatch = selector.match(/@class="([^"]+)"/);

      if (tagMatch) {
        const tag = tagMatch[1];
        const className = classMatch ? classMatch[1] : '';
        const attr = attrMatch ? attrMatch[1] : '';

        // 简化的 HTML 标签匹配
        const pattern = className
          ? new RegExp(`<${tag}[^>]*class="[^"]*${className}[^"]*"[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi')
          : new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi');

        let match;
        while ((match = pattern.exec(html)) !== null) {
          if (attr === 'href') {
            const hrefMatch = match[0].match(/href="([^"]+)"/);
            results.push(hrefMatch ? hrefMatch[1] : match[1].trim());
          } else {
            results.push(match[1].trim());
          }
        }
      }
      return results;
    }

    // CSS 选择器简化版
    const parts = selector.split(/\s*>\s*/);
    let currentHtml = html;

    for (const part of parts) {
      const cleanPart = part.replace(/[:.]/g, ' ').trim();
      const segments = cleanPart.split(/\s+/);

      for (const seg of segments) {
        if (seg.startsWith('#')) {
          // ID 选择器
          const id = seg.slice(1);
          const idMatch = currentHtml.match(new RegExp(`<[^>]*id=["']${id}["'][^>]*>([\\s\\S]*?)<\\/[^>]+>`, 'i'));
          if (idMatch) currentHtml = idMatch[1];
        } else if (seg.startsWith('.')) {
          // Class 选择器
          const cls = seg.slice(1);
          const clsMatch = currentHtml.match(new RegExp(`<[^>]*class=["'][^"']*${cls}[^"']*["'][^>]*>([\\s\\S]*?)<\\/[^>]+>`, 'i'));
          if (clsMatch) currentHtml = clsMatch[1];
        }
        // 标签名选择器
      }
    }

    // 提取文本内容
    const textMatch = currentHtml.match(/>([^<]+)</);
    if (textMatch) results.push(textMatch[1].trim());

    return results;
  }

  /**
   * 解析 JSONPath
   * 支持: $.key, $.arr[*].key, $.arr[0].key
   */
  static parseJsonPath(json: any, path: string): any {
    const parts = path.replace(/^\$\.?/, '').split(/\./);
    let current = json;

    for (const part of parts) {
      if (current === null || current === undefined) return null;

      // 数组索引: key[0] 或 [*]
      const arrayMatch = part.match(/^(\w+)?\[(\d+|\*)\]$/);
      if (arrayMatch) {
        const arrayName = arrayMatch[1];
        const index = arrayMatch[2];

        if (arrayName) current = current[arrayName];
        if (!Array.isArray(current)) return null;

        if (index === '*') {
          return current;
        }
        current = current[parseInt(index)];
        continue;
      }

      if (typeof current === 'object' && part in current) {
        current = current[part];
      } else {
        return null;
      }
    }

    return current;
  }

  /**
   * 解析正则规则
   * regex(pattern, flags)
   */
  static parseRegex(html: string, rule: string): string[] {
    const match = rule.match(/^regex\((.+?)(?:,\s*([gimsuy]+))?\)$/);
    if (!match) return [];

    try {
      const pattern = match[1];
      const flags = match[2] || 'g';
      const regex = new RegExp(pattern, flags);
      const results: string[] = [];
      let execMatch;
      while ((execMatch = regex.exec(html)) !== null) {
        results.push(execMatch[1] || execMatch[0]);
      }
      return results;
    } catch (e) {
      console.error('[RuleParser] Regex error:', e);
      return [];
    }
  }
}
