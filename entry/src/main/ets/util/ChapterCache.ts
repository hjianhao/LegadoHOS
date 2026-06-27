/**
 * 全局章节缓存
 * 用于在 BookInfoPage / ReadPage 与 ChapterListPage 之间传递章节数据，
 * 避免通过 router params 序列化大数组的性能问题。
 */
import { BookSourceChapter } from '../model/BookSource';

export class ChapterCache {
  /** 章节列表 */
  static chapters: BookSourceChapter[] = [];
  /** 当前缓存的书籍 URL，用于校验缓存是否有效 */
  static bookUrl: string = '';
  /** 缓存的书源 header（用于 ReadPage 内容获取，避免 source 匹配失败） */
  static sourceHeader: Record<string, string> = {};
}
