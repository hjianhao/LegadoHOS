/**
 * 书架分组数据模型
 *
 * 分组体系：
 * - 系统内置组（id 0-6）：由内存常量提供，不存储在 DB 中
 * - 自定义组（id >= BookGroup.CUSTOM）：存储在 book_groups 表
 *
 * 分组与书籍关系：一个书只能属于一个分组（groupId 外键）
 */
import { Book } from './Book';

/** 内置分组枚举 */
export enum BookGroup {
  ALL = 0,
  LOCAL = 1,
  AUDIO_BOOK = 2,
  MANGA = 3,
  READING = 4,
  UNREAD = 5,
  FINISHED = 6,
  CUSTOM = 10, // 自定义分组从此开始
}

/** 分组显示样式 */
export enum BookGroupStyle {
  TAB = 0,       // Tab 标签栏
  HIDDEN = 1,    // 隐藏 Tab（仅通过文件夹或下拉菜单切换）
  FOLDER = 2,    // 文件夹模式
}

/** BookGroup DB 实体（仅用于自定义分组） */
export interface BookGroupItem {
  id: number;              // 主键（>= CUSTOM 的为自定义分组，< CUSTOM 的为系统组）
  name: string;            // 分组名称
  order: number;           // 排序权重
  cover: string;           // 分组封面图 URL（可选）
  isSystem: boolean;       // 是否为系统内置组
  enableRefresh: boolean;  // 是否允许下拉刷新
  show: boolean;           // 是否在标签栏显示
  isPrivate: boolean;      // 是否私密
  bookSort: number;        // 分组级排序覆盖（-1=使用全局默认）
}

/** 系统内置分组名称映射 */
export const SYSTEM_GROUP_NAMES: Record<number, string> = {
  [BookGroup.ALL]: '全部',
  [BookGroup.LOCAL]: '本地',
  [BookGroup.AUDIO_BOOK]: '听书',
  [BookGroup.MANGA]: '漫画',
  [BookGroup.READING]: '在读',
  [BookGroup.UNREAD]: '未读',
  [BookGroup.FINISHED]: '已完本',
};

/** 系统内置分组默认配置 */
export function getSystemGroupDefaults(): BookGroupItem[] {
  return [
    { id: BookGroup.ALL, name: '全部', order: 0, cover: '', isSystem: true, enableRefresh: true, show: true, isPrivate: false, bookSort: -1 },
    { id: BookGroup.READING, name: '在读', order: 1, cover: '', isSystem: true, enableRefresh: true, show: true, isPrivate: false, bookSort: -1 },
    { id: BookGroup.UNREAD, name: '未读', order: 2, cover: '', isSystem: true, enableRefresh: true, show: true, isPrivate: false, bookSort: -1 },
    { id: BookGroup.FINISHED, name: '已完本', order: 3, cover: '', isSystem: true, enableRefresh: true, show: true, isPrivate: false, bookSort: -1 },
    { id: BookGroup.LOCAL, name: '本地', order: 4, cover: '', isSystem: true, enableRefresh: false, show: true, isPrivate: false, bookSort: -1 },
    { id: BookGroup.AUDIO_BOOK, name: '听书', order: 5, cover: '', isSystem: true, enableRefresh: false, show: false, isPrivate: false, bookSort: -1 },
    { id: BookGroup.MANGA, name: '漫画', order: 6, cover: '', isSystem: true, enableRefresh: false, show: false, isPrivate: false, bookSort: -1 },
  ];
}

/** 判断书籍是否属于某个系统分组 */
export function bookMatchesSystemGroup(book: Book, groupId: number): boolean {
  switch (groupId) {
    case BookGroup.ALL:
      return true;
    case BookGroup.READING:
      return book.durChapterIndex > 0 &&
        (book.totalChapterNum <= 0 || book.durChapterIndex < book.totalChapterNum);
    case BookGroup.UNREAD:
      return book.isShelf && (book.totalChapterNum <= 0 || book.durChapterIndex === 0);
    case BookGroup.FINISHED:
      return book.totalChapterNum > 0 && book.durChapterIndex >= book.totalChapterNum;
    case BookGroup.LOCAL:
      return book.origin === '本地';
    case BookGroup.AUDIO_BOOK:
      return book.isAudio;
    case BookGroup.MANGA:
      return book.isManga;
    default:
      return false;
  }
}

/** 新书自动分配到哪个系统分组 */
export function getDefaultGroupForBook(book: Book): number {
  if (book.isAudio) return BookGroup.AUDIO_BOOK;
  if (book.isManga) return BookGroup.MANGA;
  return BookGroup.ALL;
}

/** 自定义分组表名 */
export const BOOK_GROUP_TABLE_NAME = 'book_groups';
