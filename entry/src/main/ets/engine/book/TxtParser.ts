/**
 * TXT 文件解析器
 *
 * 功能：编码检测 → 按章节规则拆分 → 生成 BookChapter 列表
 * 兼容 Legado 的 TxtTocRule 规则体系
 */
import { BookChapter } from '../../model/BookChapter';
import { TxtTocRule } from '../../model/CacheEntry';

export interface TxtParseResult {
  encoding: string;
  chapters: BookChapter[];
  content: string;      // 全文（未分割）
}

export class TxtParser {
  /**
   * 解析 TXT 文件
   */
  static async parse(
    filePath: string,
    tocRules?: TxtTocRule[]
  ): Promise<TxtParseResult> {
    const fileUtil = await import('../../util/FileUtil');
    const content = await fileUtil.FileUtil.readTextFile(filePath);
    const encoding = this.detectEncodingFromContent(content);

    // 使用规则拆分章节
    const chapters = this.splitChapters(content, tocRules);

    return {
      encoding,
      chapters,
      content,
    };
  }

  /**
   * 从文本内容检测编码（BOM / 特征）
   */
  private static detectEncodingFromContent(content: string): string {
    if (content.charCodeAt(0) === 0xFEFF) return 'utf-8-bom';
    // UTF-16 BE BOM
    if (content.charCodeAt(0) === 0xFFFE) return 'utf-16';
    return 'utf-8';
  }

  /**
   * 按规则拆分章节
   */
  private static splitChapters(
    content: string,
    tocRules?: TxtTocRule[]
  ): BookChapter[] {
    const chapters: BookChapter[] = [];
    const activeRules = (tocRules || []).filter(r => r.isEnabled);

    if (activeRules.length === 0) {
      // 使用默认分章规则
      const defaultRegex = /^(?:第\s*[零一二三四五六七八九十百千万亿两0-9]+\s*[章节卷回篇部集]|Chapter\s+\d+)/im;
      return this.splitByRegex(content, defaultRegex);
    }

    // 使用用户定义的规则
    for (const rule of activeRules) {
      try {
        const regex = new RegExp(rule.rule, 'im');
        chapters.push(...this.splitByRegex(content, regex));
      } catch (e) {
        console.warn('[TxtParser] Invalid rule:', rule.name, e);
      }
    }

    return chapters.length > 0 ? chapters : this.splitByLineCount(content, 3000);
  }

  /**
   * 按正则分章
   */
  private static splitByRegex(content: string, regex: RegExp): BookChapter[] {
    const chapters: BookChapter[] = [];
    const lines = content.split('\n');
    let currentChapter: string[] = [];
    let chapterIndex = 0;
    let lastTitle = '前言';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) {
        currentChapter.push(line);
        continue;
      }

      if (regex.test(trimmed)) {
        // 保存上一章
        if (currentChapter.length > 0) {
          chapters.push({
            id: 0, bookId: 0, index: chapterIndex++, volumeIndex: 0,
            title: lastTitle, url: '',
            content: currentChapter.join('\n'),
            contentLength: currentChapter.join('\n').length,
            isRead: false, isDownloaded: false, isCached: false,
            duration: 0, audioUrl: '',
            createTime: Date.now(), updateTime: Date.now(),
          });
          currentChapter = [];
        }
        lastTitle = trimmed;
        continue;
      }

      currentChapter.push(line);
    }

    // 最后一章
    if (currentChapter.length > 0) {
      chapters.push({
        id: 0, bookId: 0, index: chapterIndex, volumeIndex: 0,
        title: lastTitle, url: '',
        content: currentChapter.join('\n'),
        contentLength: currentChapter.join('\n').length,
        isRead: false, isDownloaded: false, isCached: false,
        duration: 0, audioUrl: '',
        createTime: Date.now(), updateTime: Date.now(),
      });
    }

    return chapters;
  }

  /**
   * 按行数分章（兜底方案）
   */
  private static splitByLineCount(content: string, linesPerChapter: number): BookChapter[] {
    const lines = content.split('\n');
    const chapters: BookChapter[] = [];
    let chapterIndex = 0;

    for (let i = 0; i < lines.length; i += linesPerChapter) {
      const chunk = lines.slice(i, i + linesPerChapter);
      chapters.push({
        id: 0, bookId: 0, index: chapterIndex++, volumeIndex: 0,
        title: `第${chapterIndex}章`, url: '',
        content: chunk.join('\n'),
        contentLength: chunk.join('\n').length,
        isRead: false, isDownloaded: false, isCached: false,
        duration: 0, audioUrl: '',
        createTime: Date.now(), updateTime: Date.now(),
      });
    }

    return chapters;
  }
}
