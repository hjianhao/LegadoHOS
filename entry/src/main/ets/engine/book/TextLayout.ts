/**
 * 排版引擎
 *
 * 负责将文本内容排版为可显示的页面。
 * 处理：字体选择、字号、行距、段距、对齐、缩进。
 */

export interface LayoutConfig {
  fontFamily: string;
  fontSize: number;            // sp
  fontBold: boolean;
  lineHeightMultiplier: number; // 1.0 ~ 2.0
  paragraphSpacing: number;    // sp
  letterSpacing: number;       // sp
  textAlign: 'left' | 'justify';
  firstLineIndent: boolean;    // 首行缩进2字符
  pagePadding: number;         // px
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
  fontFamily: '默认',
  fontSize: 18,
  fontBold: false,
  lineHeightMultiplier: 1.6,
  paragraphSpacing: 10,
  letterSpacing: 0.5,
  textAlign: 'justify',
  firstLineIndent: true,
  pagePadding: 24,
};

export class TextLayout {
  /**
   * 将文本分割为页面
   */
  static splitIntoPages(
    text: string,
    config: LayoutConfig,
    pageWidth: number,
    pageHeight: number
  ): LayoutPage[] {
    if (!text) return [];

    const pages: LayoutPage[] = [];
    const paragraphs = text.split('\n');
    const lineHeight = config.fontSize * config.lineHeightMultiplier;
    const usableHeight = pageHeight - config.pagePadding * 2;
    const maxLinesPerPage = Math.floor(usableHeight / lineHeight);

    let currentLines: LayoutLine[] = [];
    let globalOffset = 0;

    for (let pi = 0; pi < paragraphs.length; pi++) {
      const para = paragraphs[pi];
      const paraLines = this.wrapParagraph(para, config, pageWidth);

      for (const line of paraLines) {
        if (currentLines.length >= maxLinesPerPage) {
          // 保存当前页
          const pageStartOffset = currentLines.length > 0
            ? currentLines[0].offset
            : globalOffset;
          const pageEndOffset = currentLines.length > 0
            ? currentLines[currentLines.length - 1].offset
              + currentLines[currentLines.length - 1].text.length
            : globalOffset;

          pages.push({
            lines: [...currentLines],
            startOffset: pageStartOffset,
            endOffset: pageEndOffset,
          });
          currentLines = [];
        }
        currentLines.push({
          ...line,
          offset: globalOffset,
        });
        globalOffset += line.text.length;
      }

      // 段落后加空行（除了最后一章）
      if (pi < paragraphs.length - 1) {
        globalOffset += 1; // 换行符
      }
    }

    // 最后一页
    if (currentLines.length > 0) {
      pages.push({
        lines: currentLines,
        startOffset: currentLines[0]?.offset || 0,
        endOffset: globalOffset,
      });
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
      return [{
        text: '', offset: 0, height: config.fontSize * config.lineHeightMultiplier,
        isParagraphStart: true, isParagraphEnd: true,
      }];
    }

    // 估算每行最大字符数（基于字体大小和页面宽度）
    const charWidth = config.fontSize * 0.6; // 估算中文字符宽度
    const usableWidth = pageWidth - config.pagePadding * 2;
    const maxCharsPerLine = Math.max(1, Math.floor(usableWidth / charWidth));

    const lines: LayoutLine[] = [];
    let remaining = text;

    // 首行缩进
    let firstLine = true;

    while (remaining.length > 0) {
      let lineLength: number;
      if (firstLine && config.firstLineIndent) {
        // 缩进2字符
        lineLength = Math.min(maxCharsPerLine - 2, remaining.length);
        if (lineLength > 0) {
          const lineText = '  ' + remaining.slice(0, lineLength);
          lines.push({
            text: lineText,
            offset: text.length - remaining.length,
            height: config.fontSize * config.lineHeightMultiplier,
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
          height: config.fontSize * config.lineHeightMultiplier,
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
