/**
 * 书籍数据模型
 * 对应原 Legado Book 实体
 */
export enum BookType {
  TEXT = 0,     // 文本
  AUDIO = 1,    // 有声书
  MANGA = 2,    // 漫画
  RSS = 3       // RSS
}

export enum BookGroup {
  ALL = 0,         // 全部
  LOCAL = 1,       // 本地
  AUDIO_BOOK = 2,  // 听书
  MANGA = 3,       // 漫画
  READING = 4,     // 在读
  UNREAD = 5,      // 未读
  FINISHED = 6,    // 已读
  CUSTOM = 10      // 自定义分组起始
}

export interface Book {
  id: number;
  name: string;
  author: string;
  coverUrl: string;
  customCoverPath: string;
  bookUrl: string;          // 来源链接
  origin: string;           // 书源名称
  originUrl: string;        // 书源 URL
  type: BookType;
  groupId: number;

  // 目录信息
  tocUrl: string;
  chapterCount: number;
  totalChapterNum: number;
  latestChapterTitle: string;   // 最新章节标题

  // 阅读进度
  durChapterTitle: string;
  durChapterIndex: number;
  durChapterPos: number;           // 章节内阅读位置 (字符偏移)
  durChapterProgress: number;     // 0.0 ~ 1.0

  // 状态
  isRead: boolean;
  isAudio: boolean;
  isManga: boolean;
  isShelf: boolean;     // 是否在书架
  order: number;        // 排序权重

  // 元数据
  kind: string;         // 分类
  wordCount: string;    // 字数
  introduce: string;    // 简介
  lastUpdateTime: string;

  // 时间戳
  lastOpenTime: number;
  createTime: number;
  updateTime: number;
}

/**
 * 创建默认书籍对象
 */
export function createDefaultBook(): Book {
  return {
    id: 0,
    name: '',
    author: '',
    coverUrl: '',
    customCoverPath: '',
    bookUrl: '',
    origin: '',
    originUrl: '',
    type: BookType.TEXT,
    groupId: BookGroup.ALL,
    tocUrl: '',
    chapterCount: 0,
    totalChapterNum: 0,
    latestChapterTitle: '',
    durChapterTitle: '',
    durChapterIndex: 0,
    durChapterPos: 0,
    durChapterProgress: 0,
    isRead: false,
    isAudio: false,
    isManga: false,
    isShelf: false,
    order: 0,
    kind: '',
    wordCount: '',
    introduce: '',
    lastUpdateTime: '',
    lastOpenTime: 0,
    createTime: 0,
    updateTime: 0,
  };
}
