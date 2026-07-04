/**
 * 排版引擎
 *
 * 负责将文本内容排版为可显示的页面。
 * 使用 measureTextSize 精确二分查找页面边界，保证页间文字衔接。
 */
import { MeasureUtils } from '@kit.ArkUI';

export interface LayoutConfig {
  fontFamily: string;
  fontSize: number;
  fontBold: boolean;
  fontWeight: number;
  lineHeightMultiplier: number;
  paragraphSpacing: number;
  letterSpacing: number;
  textAlign: 'left' | 'justify';
  firstLineIndent: boolean;
  indentSize: number;
  pagePadding: number;
  pagePaddingTop: number;
  pagePaddingBottom: number;
  pagePaddingLeft: number;
  pagePaddingRight: number;
  zhFormat: boolean;
  chineseMode: string;
  measuredCharWidth: number;
  measuredLineHeight: number;
  pxToVp?: (px: number) => number;
}

export interface LayoutPage {
  lines: LayoutLine[];
  startOffset: number;         // 在全文中的起始字符偏移
  endOffset: number;           // 在全文中的结束字符偏移
}

export interface LayoutLine {
  text: string;
  offset: number;              // 在段落中的字符偏移
  height: number;              // 行高 (px)
  isParagraphStart: boolean;
  isParagraphEnd: boolean;
}

export const DEFAULT_LAYOUT_CONFIG: LayoutConfig = {
  fontFamily: '默认', fontSize: 18, fontBold: false, fontWeight: 1,
  lineHeightMultiplier: 1.6, paragraphSpacing: 10, letterSpacing: 0.5,
  textAlign: 'justify', firstLineIndent: true, indentSize: 2,
  pagePadding: 20,
  pagePaddingTop: 24, pagePaddingBottom: 24, pagePaddingLeft: 20, pagePaddingRight: 20,
  zhFormat: true, chineseMode: 'original',
  measuredCharWidth: 0, measuredLineHeight: 0,
};

export class TextLayout {
  /**
   * 将文本精确分割为页面（基于 measureTextSize 二分查找边界）
   */
  static splitIntoPages(
    text: string,
    config: LayoutConfig,
    pageWidth: number,
    pageHeight: number,
    measure?: MeasureUtils
  ): LayoutPage[] {
    if (!text) return [];

    // pageWidth/pageHeight 来自 onAreaChange（单位 vp），padding 也单位 vp
    const innerW = pageWidth - config.pagePaddingLeft - config.pagePaddingRight;
    const innerH = pageHeight - config.pagePaddingTop - config.pagePaddingBottom;
    if (innerW <= 0 || innerH <= 0) return [];

    if (measure) {
      return this.splitIntoPagesPrecise_(text, config, innerW, innerH, measure);
    }
    return this.splitIntoPagesEstimated_(text, config, pageWidth, pageHeight);
  }

  /** 使用 measureTextSize 二分查找每页边界 */
  private static splitIntoPagesPrecise_(
    text: string,
    config: LayoutConfig,
    innerW: number,
    innerH: number,
    measure: MeasureUtils
  ): LayoutPage[] {
    const pages: LayoutPage[] = [];
    let offset = 0;
    const len = text.length;

    while (offset < len) {
      // 二分查找：最长前缀使其高度 <= innerH
      const end = this.findPageEnd_(text, offset, len, innerW, innerH, config, measure);
      if (end <= offset) {
        // 连一个字符都放不下，至少放一个字符避免死循环
        pages.push({ lines: [{ text: text[offset], offset: offset, height: config.fontSize * config.lineHeightMultiplier, isParagraphStart: true, isParagraphEnd: false }], startOffset: offset, endOffset: offset + 1 });
        offset++;
        continue;
      }
      const pageText = text.substring(offset, end);
      // 拆成显示用行（用于 PageView 渲染）
      const lines = this.splitToLines_(pageText, config.fontSize * config.lineHeightMultiplier, config);
      pages.push({ lines: lines, startOffset: offset, endOffset: end });
      offset = end;
    }
    return pages;
  }

  /** 二分查找一页的结束位置 */
  private static findPageEnd_(
    text: string, start: number, totalLen: number,
    innerW: number, innerH: number,
    config: LayoutConfig, measure: MeasureUtils
  ): number {
    let lo = start;
    let hi = totalLen;

    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      const sub = text.substring(start, mid);
      const size = measure.measureTextSize({
        textContent: sub,
        constraintWidth: innerW,
        fontSize: config.fontSize,
        fontWeight: config.fontWeight,
        fontFamily: config.fontFamily,
        letterSpacing: config.letterSpacing,
        lineHeight: config.fontSize * config.lineHeightMultiplier,
      });
      const sizeObj = size as Record<string, Object>;
      const measuredH = config.pxToVp ? config.pxToVp(Number(sizeObj['height'] || 0)) : Number(sizeObj['height'] || 0);
      if (measuredH <= innerH) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /** 将页面文本按换行符拆成 LayoutLine 数组（供 PageView 渲染） */
  private static splitToLines_(text: string, lh: number, config?: LayoutConfig): LayoutLine[] {
    const lines: LayoutLine[] = [];
    const parts = text.split('\n');
    let off = 0;
    let isFirstParagraph = true;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) {
        let lineText = parts[i];
        // 首行缩进
        if (config && config.firstLineIndent && config.indentSize > 0) {
          const indentChars = config.indentSize * 2;
          let indent = '';
          for (let j = 0; j < indentChars; j++) indent += ' ';
          lineText = indent + lineText;
        }
        lines.push({
          text: lineText,
          offset: off,
          height: lh,
          isParagraphStart: true,
          isParagraphEnd: false,
        });
      }
      off += parts[i].length + 1; // +1 for newline
    }
    if (lines.length > 0) {
      lines[lines.length - 1].isParagraphEnd = true;
    }
    return lines;
  }

  /** 回退：基于字符计数的估算分段 */
  private static splitIntoPagesEstimated_(
    text: string,
    config: LayoutConfig,
    pageWidth: number,
    pageHeight: number
  ): LayoutPage[] {
    const pages: LayoutPage[] = [];
    const paragraphs = text.split('\n');
    const lineHeight = config.measuredLineHeight > 0
      ? config.measuredLineHeight
      : config.fontSize * config.lineHeightMultiplier;
    const usableHeight = pageHeight - config.pagePaddingTop - config.pagePaddingBottom;
    const maxLinesPerPage = Math.floor(usableHeight / lineHeight);

    let currentLines: LayoutLine[] = [];
    let globalOffset = 0;

    for (let pi = 0; pi < paragraphs.length; pi++) {
      const para = paragraphs[pi];
      const paraLines = this.wrapParagraph(para, config, pageWidth);

      for (const line of paraLines) {
        if (currentLines.length >= maxLinesPerPage) {
          const pageStartOffset = currentLines.length > 0 ? currentLines[0].offset : globalOffset;
          const pageEndOffset = currentLines.length > 0
            ? currentLines[currentLines.length - 1].offset + currentLines[currentLines.length - 1].text.length
            : globalOffset;
          pages.push({ lines: [...currentLines], startOffset: pageStartOffset, endOffset: pageEndOffset });
          currentLines = [];
        }
        currentLines.push({ ...line, offset: globalOffset });
        globalOffset += line.text.length;
      }
      if (pi < paragraphs.length - 1) { globalOffset += 1; }
    }
    if (currentLines.length > 0) {
      pages.push({ lines: currentLines, startOffset: currentLines[0]?.offset || 0, endOffset: globalOffset });
    }
    return pages;
  }

  /**
   * 将段落按行宽换行
   */
  private static wrapParagraph(
    text: string,
    config: LayoutConfig,
    pageWidth: number
  ): LayoutLine[] {
    if (!text.trim()) {
      const lh = config.measuredLineHeight > 0
        ? config.measuredLineHeight
        : config.fontSize * config.lineHeightMultiplier;
      return [{
        text: '', offset: 0, height: lh,
        isParagraphStart: true, isParagraphEnd: true,
      }];
    }

    const lh = config.measuredLineHeight > 0
      ? config.measuredLineHeight
      : config.fontSize * config.lineHeightMultiplier;

    // 估算每行最大字符数
    const charWidth = config.measuredCharWidth > 0
      ? config.measuredCharWidth
      : config.fontSize * 0.6;
    const usableWidth = pageWidth - config.pagePaddingLeft - config.pagePaddingRight;
    const maxCharsPerLine = Math.max(1, Math.floor(usableWidth / charWidth));

    const lines: LayoutLine[] = [];
    let remaining = text;

    // 首行缩进
    let firstLine = true;

    while (remaining.length > 0) {
      let lineLength: number;
      if (firstLine && config.firstLineIndent && config.indentSize > 0) {
        // 按 indentSize 缩进（每个缩进 = 2空格）
        const indentChars = config.indentSize * 2;
        lineLength = Math.min(maxCharsPerLine - indentChars, remaining.length);
        if (lineLength > 0) {
          let indent = '';
          for (let i = 0; i < indentChars; i++) indent += ' ';
          const lineText = indent + remaining.slice(0, lineLength);
          lines.push({
            text: lineText,
            offset: text.length - remaining.length,
            height: lh,
            isParagraphStart: true,
            isParagraphEnd: lineLength >= remaining.length,
          });
          remaining = remaining.slice(lineLength);
        }
        firstLine = false;
      } else {
        lineLength = Math.min(maxCharsPerLine, remaining.length);
        lines.push({
          text: remaining.slice(0, lineLength),
          offset: text.length - remaining.length,
          height: lh,
          isParagraphStart: false,
          isParagraphEnd: lineLength >= remaining.length,
        });
        remaining = remaining.slice(lineLength);
      }
    }

    return lines;
  }

  /**
   * 应用内容替换规则
   */
  static applyReplaceRules(
    text: string,
    rules: Array<{ pattern: string; replacement: string; isRegex: boolean }>
  ): string {
    let result = text;
    for (const rule of rules) {
      try {
        if (rule.isRegex) {
          const regex = new RegExp(rule.pattern, 'gi');
          result = result.replace(regex, rule.replacement);
        } else {
          result = result.split(rule.pattern).join(rule.replacement);
        }
      } catch (e) {
        console.warn('[TextLayout] Replace rule error:', rule.pattern, e);
      }
    }
    return result;
  }
}
