/**
 * 阅读记录模型
 */
export interface ReadRecord {
  id: number;
  bookId: number;
  date: string;          // YYYY-MM-DD
  duration: number;      // 阅读时长（秒）
  chapterCount: number;  // 阅读章节数
  startTime: number;     // 开始阅读时间戳
}

export interface ReadRecordDetail {
  id: number;
  recordId: number;
  bookId: number;
  chapterIndex: number;
  startTime: number;
  duration: number;
}
