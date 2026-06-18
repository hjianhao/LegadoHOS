/**
 * 章节数据模型
 * 对应原 Legado Chapter 实体
 */
export interface Chapter {
  id: number;
  bookId: number;
  title: string;
  url: string;
  index: number;
  urlIndex: number;
  bookUrl: string;
  // 正文内容（阅读时加载）
  content: string;
  // 状态
  isRead: boolean;
  isDownload: boolean;
  // 时间
  createTime: number;
  updateTime: number;
}

/**
 * 创建默认章节
 */
export function createDefaultChapter(): Chapter {
  return {
    id: 0,
    bookId: 0,
    title: '',
    url: '',
    index: 0,
    urlIndex: 0,
    bookUrl: '',
    content: '',
    isRead: false,
    isDownload: false,
    createTime: Date.now(),
    updateTime: Date.now(),
  };
}
