/**
 * 轻量 HTML 解析器 + CSS 选择器引擎
 *
 * 专为 Legado 书源规则设计，支持：
 * - HTML → DOM 树解析（处理嵌套、自闭合、属性）
 * - CSS 选择器：tag, .class, #id, tag.class, ancestor descendant, parent>child
 * - 属性后缀：@text, @href, @src, @html, @ownText
 * - Legado 扩展：tag@@className 表示 <tag class="className">
 *
 * 非完整 HTML/CSS 规范实现，仅覆盖书源规则常见的模式。
 */
import { toJsRegexReplacement } from '../engine/source/RuleAnalyzer';

// ============= 模型 =============

export interface HtmlElement {
  tagName: string;
  attributes: Record<string, string>;
  children: HtmlElement[];
  parent: HtmlElement | null;
  /** 直接文本节点（不包括子元素中的文本） */
  ownText: string;
  /** 所有后代文本 */
  text: string;
  /** 内部 HTML（不包括当前标签本身） */
  innerHtml: string;
  /** 外部 HTML（包括当前标签） */
  outerHtml: string;
}

// ============= 解析器 =============

const VOID_ELEMENTS = new Set([
  'br', 'hr', 'img', 'input', 'meta', 'link', 'area', 'base',
  'col', 'embed', 'source', 'track', 'wbr'
]);

export class HtmlParser {
  /**
   * 将 HTML 字符串解析为 DOM 树
   */
  parse(html: string): HtmlElement {
    const root: HtmlElement = this.createElement('#root');
    const stack: HtmlElement[] = [root];
    let pos = 0;

    while (pos < html.length) {
      // 文本节点
      if (html[pos] !== '<') {
        const textEnd = html.indexOf('<', pos);
        const text = textEnd === -1 ? html.substring(pos) : html.substring(pos, textEnd);
        if (text.trim()) {
          const current = stack[stack.length - 1];
          if (current) {
            current.ownText += text;
          }
        }
        pos = textEnd === -1 ? html.length : textEnd;
        continue;
      }

      // 注释 <!-- ... -->
      if (html.substring(pos, pos + 4) === '<!--') {
        const end = html.indexOf('-->', pos + 4);
        pos = end === -1 ? html.length : end + 3;
        continue;
      }

      // DOCTYPE
      if (html.substring(pos, pos + 2).toUpperCase() === '<!' ||
          html.substring(pos, pos + 9).toUpperCase() === '<!DOCTYPE') {
        const end = html.indexOf('>', pos);
        pos = end === -1 ? html.length : end + 1;
        continue;
      }

      // </ 结束标签
      if (html[pos + 1] === '/') {
        const tagEnd = html.indexOf('>', pos);
        if (tagEnd === -1) break;
        const tagName = html.substring(pos + 2, tagEnd).trim().split(/\s+/)[0].toLowerCase();

        // 从栈中找到匹配的开启标签，只弹出到匹配位置
        // 避免不匹配的结束标签（如不规范的 </a>）弹出整个栈，破坏后续解析
        let found = false;
        for (let j = stack.length - 1; j > 0; j--) {
          if (stack[j].tagName === tagName) {
            while (stack.length > j) {
              stack.pop();
            }
            found = true;
            break;
          }
        }
        // 没找到匹配的开启标签 → 忽略该结束标签（浏览器行为）
        pos = tagEnd + 1;
        continue;
      }

      // < 开始标签
      const tagEnd = html.indexOf('>', pos);
      if (tagEnd === -1) break;

      // 判断自闭合
      const isSelfClose = html[tagEnd - 1] === '/' || html[tagEnd - 1] === '?';

      // 提取标签内容: <tag attr1="v1" attr2='v2' attr3>
      const tagContent = html.substring(pos + 1, isSelfClose ? tagEnd - 1 : tagEnd).trim();

      // 提取标签名
      const nameMatch = tagContent.match(/^([a-zA-Z0-9_-]+)/);
      if (!nameMatch) {
        // 不是有效标签（如 <! 或其他处理异常）
        pos = tagEnd + 1;
        continue;
      }

      const tagName = nameMatch[1].toLowerCase();
      const isVoid = VOID_ELEMENTS.has(tagName);

      // 提取属性
      const attrs = this.parseAttributes(tagContent.substring(nameMatch[0].length));

      const element = this.createElement(tagName, attrs);
      const parent = stack[stack.length - 1];
      if (parent) {
        element.parent = parent;
        parent.children.push(element);
      }

      // 自闭合或 void 元素不推入栈
      if (!isSelfClose && !isVoid) {
        stack.push(element);
      }

      pos = tagEnd + 1;
    }

    // 重建文本内容
    this.buildText(root);
    this.buildHtml(root);
    return root;
  }

  // ============= CSS 选择器 =============

  /**
   * 根据 CSS 选择器查找所有匹配元素
   *
   * 支持的选择器：
   *   tag           — 标签名
   *   .class        — 类名
   *   #id           — ID
   *   tag.class     — 标签+类
   *   tag#id        — 标签+ID
   *   ancestor descendant — 后代
   *   parent>child     — 子元素
   *   [attr]        — 有属性
   *   [attr=value]  — 属性等于
   *
   * 属性后缀（自动识别）：
   *   expr@text     — 文本内容
   *   expr@href     — href 属性
   *   expr@src      — src 属性
   *   expr@html     — 内部 HTML
   *   expr@ownText  — 直接文本
   *   expr@@className — 等同 tag.className
   */
  querySelectorAll(root: HtmlElement, selector: string): HtmlElement[] {
    if (!selector || !root) return [];

    const s = selector.trim();

    // 分离属性后缀: expr@text | expr@href | expr@src | expr@html | expr@ownText | expr@textNodes
    let attrSuffix = 'text';
    let cssSel = s;
    const attrMatch = s.match(/^(.*?)@(text|href|src|html|ownText|textNodes|value)$/i);
    if (attrMatch) {
      cssSel = attrMatch[1].trim();
      attrSuffix = attrMatch[2].toLowerCase();
    }

    // 处理 Legado 扩展 @@ (等同 tag.class)
    if (cssSel.includes('@@')) {
      const parts = cssSel.split('@@');
      if (parts.length === 2) {
        cssSel = parts[0] + '.' + parts[1];
      }
    }

    const elements = this.findElements(root, cssSel);

    // 根据需要提取不同内容
    if (attrSuffix !== 'text') {
      return elements.filter(el => {
        if (attrSuffix === 'href' || attrSuffix === 'src') {
          return el.attributes[attrSuffix] !== undefined;
        }
        return true;
      });
    }

    return elements;
  }

  /**
   * 查找第一个匹配元素
   */
  querySelector(root: HtmlElement, selector: string): HtmlElement | null {
    const results = this.querySelectorAll(root, selector);
    return results.length > 0 ? results[0] : null;
  }

  /**
   * 提取 CSS 选择器的属性值
   * @returns 直接返回属性值字符串（用于 @text/@href/@src/@html/@ownText/@textNodes）
   */
  extractAttr(root: HtmlElement, selector: string): string {
    const s = selector.trim();

    // 先剥离 ## 后缀（post-processing），例如 span.0@text##作者：(.*)
    let postProcessors: string[] = [];
    let cleanSelector = s;
    if (s.includes('##')) {
      const parts = s.split('##');
      cleanSelector = parts[0];
      postProcessors = parts.slice(1);
    }

   let attrSuffix = 'text';
   let cssSel = cleanSelector;
   const attrMatch = cleanSelector.match(/^(.*?)@(text|href|src|html|ownText|textNodes|value)$/i);
   if (attrMatch) {
     cssSel = attrMatch[1].trim();
     attrSuffix = attrMatch[2].toLowerCase();
   } else {
     // 通用 @attrName 兜底：匹配任意 HTML 属性名（title, data-src, data-original, onclick 等）
     const genericMatch = cleanSelector.match(/^(.*?)@([\w-]+)$/i);
     if (genericMatch) {
       cssSel = genericMatch[1].trim();
       attrSuffix = genericMatch[2].toLowerCase();
     }
   }

    // 处理 Legado 扩展 @@
    if (cssSel.includes('@@')) {
      const parts = cssSel.split('@@');
      if (parts.length === 2) {
        cssSel = parts[0] + '.' + parts[1];
      }
    }

	    let elements: HtmlElement[];
	    if (!cssSel) {
	      // Legado @attrName 独立使用（如 @href、@data-title）—— 以 root 自身为目标元素
	      elements = root ? [root] : [];
	    } else {
	      elements = this.findElements(root, cssSel);
	    }
	    if (elements.length === 0) return '';

    const el = elements[0];

    let result = '';
    switch (attrSuffix) {
      case 'text':
        result = this.cleanText(el.text);
        break;
      case 'ownText':
        result = this.cleanText(el.ownText);
        break;
      case 'textNodes':
        result = this.collectTextNodes(el);
        break;
      case 'href':
      case 'src':
        result = el.attributes[attrSuffix] || '';
        break;
      case 'html':
        result = el.innerHtml;
        break;
      case 'value':
        result = el.attributes['value'] || '';
        break;
      default:
        result = el.attributes[attrSuffix] || this.cleanText(el.text);
        break;
    }

    // 应用 ## 后缀 post-processing
    // Legado 约定两种格式 (doc/source.md §7.2/§7.3):
    //   净化: ##regex##replacement (循环替换，保留未匹配部分)
    //   OnlyOne: ##regex##replacement### (只取第一个匹配，返回替换结果，丢弃未匹配部分)
    // split('##') 后末尾 '#' 表示 OnlyOne (即原规则以 ### 结尾)
    const isOnlyOne = postProcessors.length > 0 && postProcessors[postProcessors.length - 1] === '#';
    const pairs = isOnlyOne ? postProcessors.slice(0, -1) : postProcessors;
    if (isOnlyOne) {
      // OnlyOne: 取第一个匹配，用替换模板构造结果，丢弃未匹配部分
      for (let i = 0; i < pairs.length; i += 2) {
        const pattern = pairs[i];
        // Android Legado 允许省略 replacement，此时按空字符串替换。
        const replacement = i + 1 < pairs.length ? pairs[i + 1] : '';
        if (!pattern) continue;
        try {
          const regex = new RegExp(pattern);
          const match = regex.exec(result);
          if (match) {
            result = replacement.replace(/\$(\d+)/g, (_m: string, idx: string) => match[parseInt(idx, 10)] || '');
          } else {
            result = '';
          }
        } catch (e) {
          console.warn('[HtmlParser] Invalid ## regex pair:', pattern, replacement);
        }
        break; // OnlyOne 只处理第一对
      }
    } else {
      // 净化: 循环替换，保留未匹配部分
      for (let i = 0; i < pairs.length; i += 2) {
        const pattern = pairs[i];
        const replacement = i + 1 < pairs.length ? pairs[i + 1] : '';
        if (!pattern) continue;
        try {
          result = result.replace(new RegExp(pattern, 'g'), toJsRegexReplacement(replacement));
        } catch (e) {
          console.warn('[HtmlParser] Invalid ## regex pair:', pattern, replacement);
        }
      }
    }

    return result;
  }

  /**
   * 提取所有匹配元素的属性值（用于 {{@CSS@attr}} 多元素提取）
   * 与 extractAttr 逻辑一致，但返回所有匹配元素的值列表
   * @returns 属性值数组
   */
  extractAttrAll(root: HtmlElement, selector: string): string[] {
    const s = selector.trim();

    let cleanSelector = s;
    if (s.includes('##')) {
      cleanSelector = s.split('##')[0];
    }

    let attrSuffix = 'text';
    let cssSel = cleanSelector;
    const attrMatch = cleanSelector.match(/^(.*?)@(text|href|src|html|ownText|textNodes|value)$/i);
    if (attrMatch) {
      cssSel = attrMatch[1].trim();
      attrSuffix = attrMatch[2].toLowerCase();
    } else {
      const genericMatch = cleanSelector.match(/^(.*?)@([\w-]+)$/i);
      if (genericMatch) {
        cssSel = genericMatch[1].trim();
        attrSuffix = genericMatch[2].toLowerCase();
      }
    }

    if (cssSel.includes('@@')) {
      const parts = cssSel.split('@@');
      if (parts.length === 2) {
        cssSel = parts[0] + '.' + parts[1];
      }
    }

    let elements: HtmlElement[];
    if (!cssSel) {
      elements = root ? [root] : [];
    } else {
      elements = this.findElements(root, cssSel);
    }
    if (elements.length === 0) return [];

    return elements.map((el: HtmlElement): string => {
      switch (attrSuffix) {
        case 'text':
          return this.cleanText(el.text);
        case 'ownText':
          return this.cleanText(el.ownText);
        case 'textNodes':
          return this.collectTextNodes(el);
        case 'href':
        case 'src':
          return el.attributes[attrSuffix] || '';
        case 'html':
          return el.innerHtml;
        case 'value':
          return el.attributes['value'] || '';
        default:
          return el.attributes[attrSuffix] || this.cleanText(el.text);
      }
    }).filter((v: string): boolean => !!v);
  }

  /**
   * 获取属性值（用于非标准属性名）
   */
  getAttr(el: HtmlElement, name: string): string {
    return el.attributes[name] || '';
  }

  // ============= 私有方法 =============

  private createElement(tagName: string, attributes: Record<string, string> = {}): HtmlElement {
    return {
      tagName,
      attributes,
      children: [],
      parent: null,
      ownText: '',
      text: '',
      innerHtml: '',
      outerHtml: '',
    };
  }

  private parseAttributes(attrStr: string): Record<string, string> {
    const attrs: Record<string, string> = {};
    const regex = /([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let match;
    while ((match = regex.exec(attrStr)) !== null) {
      const name = match[1].toLowerCase();
      const value = match[2] ?? match[3] ?? match[4] ?? '';
      attrs[name] = value;
    }
    return attrs;
  }

  private buildText(el: HtmlElement): void {
    // 先递归子元素，再按文档顺序拼接：自身直接文本在前，子元素文本在后
    // 注意：ownText 是该元素所有直接文本节点的拼接（不区分在子元素前还是后），
    // 但绝大多数实际场景中 ownText 在子元素之前，所以 ownText 先加更接近原文顺序。
    if (el.ownText) {
      el.text = el.ownText;
    }
    for (const child of el.children) {
      this.buildText(child);
      if (child.text) {
        el.text += child.text;
      } else if (child.ownText) {
        el.text += child.ownText;
      }
    }
  }

  private buildHtml(el: HtmlElement): void {
    let inner: string = el.ownText;
    for (const child of el.children) {
      this.buildHtml(child);
      inner += child.outerHtml;
    }
    el.innerHtml = inner;

    if (el.tagName === '#root') {
      el.outerHtml = inner;
      return;
    }

    const attrParts: string[] = [];
    for (const [k, v] of Object.entries(el.attributes)) {
      if (v) {
        attrParts.push(`${k}="${v}"`);
      } else {
        attrParts.push(k);
      }
    }
    const attrStr = attrParts.length > 0 ? ' ' + attrParts.join(' ') : '';

    if (VOID_ELEMENTS.has(el.tagName)) {
      el.outerHtml = `<${el.tagName}${attrStr}>`;
    } else {
      el.outerHtml = `<${el.tagName}${attrStr}>${inner}</${el.tagName}>`;
    }
  }

  /**
   * 递归查找匹配 CSS 选择器的元素
   */
  private findElements(root: HtmlElement, selector: string): HtmlElement[] {
    if (!root || !selector) return [];

    // CSS 逗号分组: .s1,.s7 — 取第一个有结果的分组
    if (selector.includes(',')) {
      const groups = this.splitByCommaOutsideBrackets(selector);
      if (groups.length > 1) {
        for (const group of groups) {
          const g = group.trim();
          if (g) {
            const result = this.findElementsInner(root, g);
            if (result.length > 0) return result;
          }
        }
        return [];
      }
    }

    return this.findElementsInner(root, selector);
  }

  /**
   * CSS 逗号分组，避开 [] 和 () 内的逗号
   */
  private splitByCommaOutsideBrackets(selector: string): string[] {
    const parts: string[] = [];
    let current = '';
    let depthBracket = 0;
    let depthParen = 0;
    for (const ch of selector) {
      if (ch === '[') depthBracket++;
      else if (ch === ']') depthBracket--;
      else if (ch === '(') depthParen++;
      else if (ch === ')') depthParen--;
      else if (ch === ',' && depthBracket === 0 && depthParen === 0) {
        parts.push(current);
        current = '';
        continue;
      }
      current += ch;
    }
    if (current.trim()) parts.push(current.trim());
    return parts;
  }

  private findElementsInner(root: HtmlElement, selector: string): HtmlElement[] {
    if (!root || !selector) return [];

    // 分割组合器: ' ' (descendant) or '>' (child)
    const parts = this.splitSelector(selector);
    if (parts.length === 1) {
      const sel = parts[0];
      if (sel === '*') return this.allElements(root);
      return this.matchSimple(root, sel);
    }

    // 检查最后一段是否有排除索引 !N 或 !N:M，或者位置索引 .N
    const lastIdx = parts.length - 1;
    const lastPart = parts[lastIdx];
    let exclStart = -1;
    let exclEnd = -1;
    let posIndex = 0;
    let hasPosIndex = false;
    // 排除先处理（可与位置索引共存）
    let workPart = lastPart;
    const exclMatch = lastPart.match(/^(.*?)!(-?\d+)(?::(-?\d+))?$/);
    if (exclMatch) {
      workPart = exclMatch[1];
      exclStart = parseInt(exclMatch[2]);
      exclEnd = exclMatch[3] !== undefined ? parseInt(exclMatch[3]) : exclStart;
    }
    // 位置索引: selector.N 或 selector.-N（如 a.0, td.2, .odd.1, p.-1）
    const posMatch = workPart.match(/^(.+)\.(-?\d+)$/);
    if (posMatch) {
      parts[lastIdx] = posMatch[1]; // 去掉 .N
      posIndex = parseInt(posMatch[2]);
      hasPosIndex = true;
    } else if (exclStart >= 0) {
      parts[lastIdx] = workPart; // 只去掉 ! 部分
    }

    // 组合选择器
    const results: HtmlElement[] = [];

    if (parts.length === 2 && parts[1] === '>') {
      const parents = this.findElements(root, parts[0]);
      for (const p of parents) {
        for (const child of p.children) {
          if (this.matchesSelector(child, parts[2])) {
            results.push(child);
          }
        }
      }
    } else if (parts[1] === '>') {
      const ancestors = this.findElements(root, parts[0]);
      for (const a of ancestors) {
        const children = this.findElementsInChildren(a, parts.slice(2));
        results.push(...children);
      }
    } else {
      const ancestors = this.findElements(root, parts[0]);
      const remainingSelector = parts.slice(1).join(' ');
      for (const a of ancestors) {
        const descendants = this.findElements(a, remainingSelector);
        results.push(...descendants);
      }
    }

    // 应用排除索引
    if (exclStart >= 0 && results.length > 0) {
      const filtered: HtmlElement[] = [];
      for (let i = 0; i < results.length; i++) {
        if (i < exclStart || i > exclEnd) {
          filtered.push(results[i]);
        }
      }
      // 再应用位置索引
      if (hasPosIndex && posIndex >= 0 && posIndex < filtered.length) return [filtered[posIndex]];
      if (hasPosIndex && posIndex < 0 && filtered.length + posIndex >= 0) return [filtered[filtered.length + posIndex]];
      return filtered;
    }

    // 应用位置索引
    if (hasPosIndex && results.length > 0) {
      if (posIndex >= 0 && posIndex < results.length) return [results[posIndex]];
      if (posIndex < 0 && results.length + posIndex >= 0) return [results[results.length + posIndex]];
      return [];
    }

    return results;
  }

  /**
   * 在元素的子元素中查找匹配后续选择器的元素
   */
  private findElementsInChildren(parent: HtmlElement, selectorParts: string[]): HtmlElement[] {
    if (selectorParts.length === 0) return [parent];

    const results: HtmlElement[] = [];
    if (selectorParts[1] === '>') {
      for (const child of parent.children) {
        if (this.matchesSelector(child, selectorParts[0])) {
          const deeper = this.findElementsInChildren(child, selectorParts.slice(2));
          results.push(...deeper);
        }
      }
    } else {
      for (const child of parent.children) {
        if (this.matchesSelector(child, selectorParts[0])) {
          if (selectorParts.length === 1) {
            results.push(child);
          } else {
            const deeper = this.findElementsInChildren(child, selectorParts.slice(1));
            results.push(...deeper);
          }
        }
      }
    }
    return results;
  }

  /**
   * 在元素的所有后代中查找匹配选择器的元素
   */
  private findAllDescendants(root: HtmlElement, selector: string): HtmlElement[] {
    const results: HtmlElement[] = [];
    const queue = [...root.children];
    while (queue.length > 0) {
      const el = queue.shift()!;
      if (this.matchesSelector(el, selector)) {
        results.push(el);
      }
      queue.push(...el.children);
    }
    return results;
  }

  /**
   * 匹配单个简单选择器
   * 在 root 及其所有后代中查找
   */
  private matchSimple(root: HtmlElement, selector: string): HtmlElement[] {
    // 排除索引: selector!N 或 selector!N:M (如 tr!0, li!0:2, a!-1)
    let exclSelector = selector;
    let exclStart = -1;
    let exclEnd = -1;
    const exclMatch = selector.match(/^(.*?)!(-?\d+)(?::(-?\d+))?$/);
    if (exclMatch) {
      exclSelector = exclMatch[1];
      exclStart = parseInt(exclMatch[2]);
      exclEnd = exclMatch[3] !== undefined ? parseInt(exclMatch[3]) : exclStart;
    }

    // 位置索引: selector.N 或 selector.-N (如 a.0, td.2, .odd.1, p.-1)
    const posMatch = exclSelector.match(/^(.+)\.(-?\d+)$/);
    if (posMatch) {
      const baseSel = posMatch[1];
      const position = parseInt(posMatch[2]);
      const allMatches: HtmlElement[] = [];
      const queue = [root];
      while (queue.length > 0) {
        const el = queue.shift()!;
        if (el.tagName !== '#root' && this.matchesSelector(el, baseSel)) {
          allMatches.push(el);
        }
        queue.push(...el.children);
      }
      // 正数索引
      if (position >= 0 && position < allMatches.length) {
        return [allMatches[position]];
      }
      // 负数索引（倒数）
      if (position < 0 && allMatches.length + position >= 0) {
        return [allMatches[allMatches.length + position]];
      }
      return [];
    }

    const results: HtmlElement[] = [];
    const queue = [root];
    while (queue.length > 0) {
      const el = queue.shift()!;
      if (el.tagName !== '#root' && this.matchesSelector(el, exclSelector)) {
        results.push(el);
      }
      queue.push(...el.children);
    }

    // 应用排除索引
    if (exclStart >= 0) {
      const filtered: HtmlElement[] = [];
      for (let i = 0; i < results.length; i++) {
        const normalized = exclStart >= 0 ? i : results.length + i;
        if (normalized < exclStart || normalized > exclEnd) {
          filtered.push(results[i]);
        }
      }
      return filtered;
    }

    return results;
  }

  /**
   * 检查单个元素是否匹配选择器
   * 支持: tag, .class, #id, tag.class, tag#id, [attr], [attr=value]
   */
  private matchesSelector(el: HtmlElement, selector: string): boolean {
    if (!selector) return false;
    // 去掉位置索引 .N 和排除索引 !N（单独的位置/排除由 findElements/matchSimple 处理）
    let s = selector.trim();
    s = s.replace(/!(-?\d+)(?::(-?\d+))?$/, '');  // 去掉 !N
    s = s.replace(/\.(-?\d+)$/, '');               // 去掉 .N 位置

    // CSS 伪类: :nth-of-type(n), :eq(n), :first, :last
    // 先提取伪类，再从选择器中去掉
    let pseudoType = '';
    let pseudoArg = '';
    const nthMatch = s.match(/:nth-of-type\((\d+)\)/i);
    if (nthMatch) {
      pseudoType = 'nth-of-type';
      pseudoArg = nthMatch[1];
      s = s.replace(/:nth-of-type\(\d+\)/i, '');
    }
    const eqMatch = s.match(/:eq\((\d+)\)/i);
    if (eqMatch) {
      pseudoType = 'eq';
      pseudoArg = eqMatch[1];
      s = s.replace(/:eq\(\d+\)/i, '');
    }
    const firstMatch = s.match(/:first/i);
    if (firstMatch) {
      pseudoType = 'first';
      pseudoArg = '';
      s = s.replace(/:first/i, '');
    }
    const lastMatch = s.match(/:last/i);
    if (lastMatch) {
      pseudoType = 'last';
      pseudoArg = '';
      s = s.replace(/:last/i, '');
    }

    // 属性选择器 [attr] 或 [attr=value]
    if (s.startsWith('[')) {
      return this.matchAttrSelector(el, s);
    }

    // 解析 tag, .class, #id, 组合
    const tagMatch = s.match(/^([a-zA-Z0-9_*-]+)/);
    const classMatch = s.match(/\.([\w-]+)/);
    const idMatch = s.match(/#([\w-]+)/);

    // 如果指定了标签名但不匹配
    if (tagMatch && tagMatch[1] !== '*' && el.tagName !== tagMatch[1]) {
      return false;
    }

    // 如果指定了 ID 但不匹配
    if (idMatch) {
      if (el.attributes['id'] !== idMatch[1]) return false;
    }

    // 如果指定了类名但不匹配（支持多 class: .row.thumb-overlay-albums）
    const allClassMatches = s.match(/\.([\w-]+)/g);
    if (allClassMatches && allClassMatches.length > 0) {
      const classes = (el.attributes['class'] || '').split(/\s+/);
      for (const cm of allClassMatches) {
        const className = cm.substring(1); // 去掉前导 .
        if (!classes.includes(className)) return false;
      }
    }

	    // 基础选择器匹配后，检查伪类
	    if (pseudoType) {
	      const parent = el.parent;
	      if (!parent) return pseudoType === 'first' || pseudoType === 'last'; // root always matches :first/:last
	
	      // 收集符合条件的兄弟元素
	      let siblings: HtmlElement[];
	      if (pseudoType === 'nth-of-type') {
	        siblings = parent.children.filter(child => child.tagName === el.tagName);
	      } else {
	        siblings = parent.children;
	      }
	
	      const idx = siblings.indexOf(el);
	      if (idx < 0) return false;
	
	      const n = pseudoArg ? parseInt(pseudoArg) : 0;
	      switch (pseudoType) {
	        case 'nth-of-type':
	        case 'eq':
	          return idx === n - 1; // CSS :nth-of-type is 1-indexed, :eq(0) is 0-indexed
	        case 'first':
	          return idx === 0;
	        case 'last':
	          return idx === siblings.length - 1;
	      }
	    }
	
	    // 处理 tag[attr] 组合属性选择器（如 a[href*=...]、div[data-x=y]）
	    // 注意: 纯 [attr] 已在前面 startsWith('[') 分支处理，这里只处理 tag[attr] 组合
	    const attrSelStart = s.indexOf('[');
	    if (attrSelStart >= 0) {
	      const attrPart = s.substring(attrSelStart);
	      // 检查该属性选择器是否在 [] 外部（排除已处理的伪类参数中的 [）
	      // 对于合法 CSS 选择器，[ 必然在 tag 名之后，不会是第一个字符
	      if (!this.matchAttrSelector(el, attrPart)) {
	        return false;
	      }
	    }
	
	    // 如果选择器只有 .class 或 #id（没有标签名），检查通过
	    if (!tagMatch || !tagMatch[1]) return true;
	
	    // 标签名匹配（包括通配符）
	    if (tagMatch[1] === '*') return true;
	    return el.tagName === tagMatch[1];
  }

  private matchAttrSelector(el: HtmlElement, selector: string): boolean {
    // 支持三种属性值格式：[attr="val"]、[attr='val']、[attr=val]（无引号）
    const match = selector.match(/^\[([\w-]+)(?:([~|^$*]?=)(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`\]]+)))?\]$/);
    if (!match) return false;
    const attrName = match[1].toLowerCase();
    const operator = match[2] || '';
    const value = match[3] ?? match[4] ?? match[5] ?? '';

    const attrVal = el.attributes[attrName];

    if (!operator) {
      // [attr] — 只要有属性即匹配
      return attrVal !== undefined;
    }

    if (attrVal === undefined) return false;

    switch (operator) {
      case '=': return attrVal === value;
      case '~=': return attrVal.split(/\s+/).includes(value);
      case '|=': return attrVal === value || attrVal.startsWith(value + '-');
      case '^=': return attrVal.startsWith(value);
      case '$=': return attrVal.endsWith(value);
      case '*=': return attrVal.includes(value);
      default: return false;
    }
  }

  /**
   * 分割组合器选择器
   * "div.book > a" → ["div.book", ">", "a"]
   * ".list li a" → [".list", "li", "a"]
   */
  private splitSelector(selector: string): string[] {
    const parts: string[] = [];
    let current = '';
    let i = 0;

    while (i < selector.length) {
      if (selector[i] === '>') {
        if (current.trim()) parts.push(current.trim());
        parts.push('>');
        current = '';
        i++;
        while (i < selector.length && selector[i] === ' ') i++;
      } else if (selector[i] === ' ') {
        if (current.trim()) {
          parts.push(current.trim());
          current = '';
        }
        i++;
        while (i < selector.length && selector[i] === ' ') i++;
      } else {
        current += selector[i];
        i++;
      }
    }

    if (current.trim()) parts.push(current.trim());
    return parts;
  }

  private allElements(root: HtmlElement): HtmlElement[] {
    const result: HtmlElement[] = [];
    const queue = [root];
    while (queue.length > 0) {
      const el = queue.shift()!;
      if (el.tagName !== '#root') result.push(el);
      queue.push(...el.children);
    }
    return result;
  }

  private cleanText(text: string): string {
    return text.replace(/\s+/g, ' ').trim();
  }

  /** 收集元素的所有文本节点（递归），用换行分隔块级元素和 <br> */
  private collectTextNodes(el: HtmlElement): string {
    const parts: string[] = [];
    this.collectTextNodesRecursive(el, parts);
    return parts.join('\n');
  }

  private collectTextNodesRecursive(el: HtmlElement, parts: string[]): void {
    // <br> 标签产生换行
    if (el.tagName === 'br' || el.tagName === 'BR') {
      parts.push('\n');
      return;
    }
    // 直接文本节点
    if (el.ownText) {
      const t = el.ownText.replace(/\s+/g, ' ').trim();
      if (t) parts.push(t);
    }
    // 递归处理子元素
    for (const child of el.children) {
      this.collectTextNodesRecursive(child, parts);
    }
  }
}

// ============= 全局单例 =============

let _instance: HtmlParser | null = null;

export function getHtmlParser(): HtmlParser {
  if (!_instance) {
    _instance = new HtmlParser();
  }
  return _instance;
}
