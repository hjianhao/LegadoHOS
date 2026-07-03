/**
 * 书籍阅读进度 — WebDAV 同步数据格式
 * 对应 Android Legado 的 BookProgress 实体
 */
export interface BookProgress {
  name: string;
  author: string;
  durChapterIndex: number;
  durChapterPos: number;       // 章节内位置 (字符偏移)
  durChapterTime: number;      // 保存时间戳 (毫秒)
  durChapterTitle: string;
}

/**
 * 从 Book 构造 BookProgress
 */
export function bookToProgress(book: {
  name: string;
  author: string;
  durChapterIndex: number;
  durChapterPos: number;
  durChapterTitle: string;
}): BookProgress {
  return {
    name: book.name,
    author: book.author,
    durChapterIndex: book.durChapterIndex,
    durChapterPos: book.durChapterPos,
    durChapterTime: Date.now(),
    durChapterTitle: book.durChapterTitle,
  };
}
