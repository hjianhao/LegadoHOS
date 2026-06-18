/**
 * 书签模型
 */
export interface Bookmark {
  id: number;
  bookId: number;
  bookName: string;
  bookAuthor: string;
  chapterIndex: number;
  chapterName: string;
  chapterPos: number;    // 字符位置
  text: string;          // 书签处文本（上下文）
  note: string;          // 笔记
  createTime: number;
  updateTime: number;
}
