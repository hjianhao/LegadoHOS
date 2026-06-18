/**
 * 章节数据模型
 */
export interface BookChapter {
  id: number;
  bookId: number;       // 外键 → Book
  index: number;        // 章节序号
  volumeIndex: number;  // 卷序号
  title: string;
  url: string;          // 内容来源 URL
  content: string;      // 缓存的内容（纯文本）
  contentLength: number;

  // 状态
  isRead: boolean;
  isDownloaded: boolean;
  isCached: boolean;

  // 有声书
  duration: number;     // 音频时长（秒）
  audioUrl: string;     // 音频 URL

  // 时间
  createTime: number;
  updateTime: number;
}

export function createDefaultChapter(): BookChapter {
  return {
    id: 0,
    bookId: 0,
    index: 0,
    volumeIndex: 0,
    title: '',
    url: '',
    content: '',
    contentLength: 0,
    isRead: false,
    isDownloaded: false,
    isCached: false,
    duration: 0,
    audioUrl: '',
    createTime: 0,
    updateTime: 0,
  };
}
