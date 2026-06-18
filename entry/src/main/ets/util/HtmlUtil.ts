/**
 * HTML 工具
 * 提供文本净化、HTML 标签剥离等能力
 *
 * 参照 Legado-with-MD3 的正文格式化逻辑：
 * - 先尝试从常见容器 ID/class 定位正文区域
 * - 保留段落结构（<p>、<br>、<div> → 换行）
 * - 标题特殊处理
 * - HTML 实体解码
 * - 中文字间距优化
 */
export class HtmlUtil {

  /**
   * 将 HTML 正文格式化为易读的纯文本
   * 先定位正文区域，再清洗为纯文本
   */
  static stripHtml(html: string): string {
    if (!html) return '';
    const contentHtml = HtmlUtil.extractContentArea(html);
    return HtmlUtil.cleanHtmlToText(contentHtml);
  }

  /**
   * 从 HTML 中识别并提取正文区域
   * 按优先级尝试多种常见容器模式
   */
  private static extractContentArea(html: string): string {
    const contentPatterns = [
      // id 精确匹配
      /<[^>]*id=["'](?:content|chaptercontent|booktxt|articlecontent|textcontent|nr|content1|bookcontent|chapter|text|article|readcontent|novelcontent|readc|txt|chapterContent|article_content|text_area|booktxt|novelcontent|read_area|reading|bookcontent|maincontent|contentbox|textcontent|articlecontent|chapter_content)["'][^>]*>([\s\S]*?)<\/[^>]+>/i,
      // class 匹配
      /<[^>]*class=["'][^"']*(?:content|chapter|article|text|novel|booktxt|read|nr|txt|chapter_content|article_content|text_area|read_area|reading|maincontent|contentbox|chaptercontent|novelcontent|bookcontent|readcontent|chapterbody)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i,
      // <article> 或 <main>
      /<article[^>]*>([\s\S]*?)<\/article>/i,
      /<main[^>]*>([\s\S]*?)<\/main>/i,
    ];

    for (const pattern of contentPatterns) {
      const match = html.match(pattern);
      if (match && match[1] && match[1].length > 200) {
        return match[1];
      }
    }

    // 兜底：找文本最长的 <div> 作为正文
    const divRegex = /<div[^>]*>([\s\S]*?)<\/div>/gi;
    let bestDiv = '';
    let bestLen = 0;
    let dMatch: RegExpExecArray | null;
    while ((dMatch = divRegex.exec(html)) !== null) {
      const textLen = dMatch[1].replace(/<[^>]+>/g, '').trim().length;
      if (textLen > bestLen && textLen > 500) {
        bestLen = textLen;
        bestDiv = dMatch[1];
      }
    }
    if (bestDiv) {
      return bestDiv;
    }

    return html;
  }

  /**
   * 将 HTML 清洗为易读纯文本（不包含正文区域识别）
   */
  private static cleanHtmlToText(html: string): string {
    if (!html) return '';
    let t = html;

    // 移除 <style> 和 <script>
    t = t.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');
    t = t.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
    // 移除注释
    t = t.replace(/<!--[\s\S]*?-->/g, '');

    // nav/footer/header 只移除标签，保留内部文本
    t = t.replace(/<nav[^>]*>/gi, '\n');
    t = t.replace(/<\/nav>/gi, '\n');
    t = t.replace(/<footer[^>]*>[\s\S]*?<\/footer>/gi, '');
    t = t.replace(/<header[^>]*>([\s\S]*?)<\/header>/gi, '\n$1\n');
    t = t.replace(/<aside[^>]*>[\s\S]*?<\/aside>/gi, '');
    t = t.replace(/<iframe[^>]*>[\s\S]*?<\/iframe>/gi, '');

    // 块级标签 → 换行
    t = t.replace(/<h[1-6][^>]*>/gi, '\n');
    t = t.replace(/<\/h[1-6]>/gi, '\n');
    t = t.replace(/<p[^>]*>/gi, '\n');
    t = t.replace(/<\/p>/gi, '\n');
    t = t.replace(/<div[^>]*>/gi, '\n');
    t = t.replace(/<\/div>/gi, '\n');
    t = t.replace(/<section[^>]*>/gi, '\n');
    t = t.replace(/<\/section>/gi, '\n');
    t = t.replace(/<article[^>]*>/gi, '\n');
    t = t.replace(/<\/article>/gi, '\n');
    t = t.replace(/<blockquote[^>]*>/gi, '\n');
    t = t.replace(/<\/blockquote>/gi, '\n');
    t = t.replace(/<br\s*\/?>/gi, '\n');

    // 链接保留文本
    t = t.replace(/<a[^>]*>([\s\S]*?)<\/a>/gi, '$1');

    // 移除常见冗余行（行首导航文本）
    const redundantLines = [
      /^首页\s*$/gmi, /^排行榜\s*$/gmi, /^分类\s*$/gmi, /^搜索\s*$/gmi,
      /^我的书架\s*$/gmi, /^书架\s*$/gmi, /^个人中心\s*$/gmi,
      /^登录\s*$/gmi, /^注册\s*$/gmi, /^全部\s*$/gmi,
      /^上一章\s*$/gmi, /^下一章\s*$/gmi, /^回目录\s*$/gmi,
      /^手机阅读\s*$/gmi, /^精彩推荐\s*$/gmi, /^相关推荐\s*$/gmi,
    ];
    for (const rx of redundantLines) {
      t = t.replace(rx, '');
    }

    // 移除剩余所有标签
    t = t.replace(/<[^>]+>/g, '');

    // HTML 实体解码
    t = t
      .replace(/&nbsp;/g, ' ')
      .replace(/&ensp;/g, ' ')
      .replace(/&emsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&#x27;/g, "'")
      .replace(/&#x2F;/g, '/')
      .replace(/&#\d+;/g, (m: string): string =>
        String.fromCharCode(parseInt(m.substring(2, m.length - 1)))
      );

    // 空白优化
    t = t.trim();
    t = t.split('\n').map(l => l.trim()).join('\n');
    t = t.replace(/\n{4,}/g, '\n\n\n');
    t = t.replace(/\n{3,}/g, '\n\n');

    return t.substring(0, 20000);
  }

  /**
   * 获取 HTML 属性值
   */
  static getAttr(html: string, tag: string, attr: string): string[] {
    const results: string[] = [];
    const regex = new RegExp(`<${tag}[^>]*${attr}\\s*=\\s*["']([^"']+)["'][^>]*>`, 'gi');
    let match: RegExpExecArray | null;
    while ((match = regex.exec(html)) !== null) {
      results.push(match[1]);
    }
    return results;
  }

  /**
   * 提取 HTML 文本内容
   */
  static getText(html: string, selector?: string): string[] {
    if (!selector) return [this.stripHtml(html)];
    const parts = selector.split(/\s*>\s*/);
    let currentHtml = html;
    for (const part of parts) {
      if (part.startsWith('.')) {
        const cls = part.slice(1);
        const match = currentHtml.match(
          new RegExp(`<[^>]*class=["'][^"']*${cls}[^"']*["'][^>]*>([\\s\\S]*?)<\\/[^>]+>`, 'i')
        );
        if (match) currentHtml = match[1];
        else return [];
      } else if (part.startsWith('#')) {
        const id = part.slice(1);
        const match = currentHtml.match(
          new RegExp(`<[^>]*id=["']${id}["'][^>]*>([\\s\\S]*?)<\\/[^>]+>`, 'i')
        );
        if (match) currentHtml = match[1];
        else return [];
      }
    }
    return [this.stripHtml(currentHtml)];
  }
}
