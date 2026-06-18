/**
 * 搜索结果模型
 */
export interface SearchResult {
  /** 书籍唯一标识 (originUrl + bookUrl) */
  key: string;
  /** 书名 */
  name: string;
  /** 作者 */
  author: string;
  /** 封面 URL */
  coverUrl: string;
  /** 详情页 URL */
  noteUrl: string;
  /** 来源书源名 */
  origin: string;
  /** 来源书源 URL */
  originUrl: string;
  /** 分类 */
  kind: string;
  /** 字数 */
  wordCount: string;
  /** 最后更新时间 */
  lastUpdateTime: string;
  /** 简介 */
  introduce: string;
  /** 帮助信息（用于调试） */
  helperMsg: string;
  /** 搜索耗时 (ms) */
  duration: number;
  /** 搜索时间戳 */
  searchTime: number;
  /** 有多少个书源搜索到此书 */
  sourceCount: number;
  /** 所有搜索到此书的源列表 */
  sourceOrigins: string[];
}

/**
 * 获取书籍合并键（用于去重）
 * 相同 书名+作者 视为同一本书
 */
export function getBookMergeKey(name: string, author: string): string {
  const n = name.replace(/[\s·・]/g, '').substring(0, 20).toLowerCase();
  const a = (author || '').replace(/[\s·・]/g, '').substring(0, 10).toLowerCase();
  return n + '|' + a;
}

/**
 * 创建带默认值的 SearchResult
 */
export function createSearchResult(): SearchResult {
  return {
    key: '', name: '', author: '', coverUrl: '', noteUrl: '',
    origin: '', originUrl: '', kind: '', wordCount: '', lastUpdateTime: '',
    introduce: '', helperMsg: '', duration: 0, searchTime: 0,
    sourceCount: 1, sourceOrigins: []
  };
}

/**
 * 合并搜索结果：同名+同作者的书合并，统计来源数量
 */
export function mergeSearchResults(results: SearchResult[]): SearchResult[] {
  const map = new Map<string, SearchResult>();
  for (const r of results) {
    const mergeKey = getBookMergeKey(r.name, r.author);
    const existing = map.get(mergeKey);
    if (existing) {
      // 合并来源
      if (!existing.sourceOrigins.includes(r.origin)) {
        existing.sourceOrigins.push(r.origin);
        existing.sourceCount = existing.sourceOrigins.length;
      }
      // 保留更完整的封面
      if (!existing.coverUrl && r.coverUrl) {
        existing.coverUrl = r.coverUrl;
      }
      // 保留更长简介
      if ((r.introduce || '').length > (existing.introduce || '').length) {
        existing.introduce = r.introduce;
      }
    } else {
      map.set(mergeKey, {
        key: r.key, name: r.name, author: r.author,
        coverUrl: r.coverUrl, noteUrl: r.noteUrl,
        origin: r.origin, originUrl: r.originUrl,
        kind: r.kind, wordCount: r.wordCount, lastUpdateTime: r.lastUpdateTime,
        introduce: r.introduce, helperMsg: r.helperMsg,
        duration: r.duration, searchTime: r.searchTime,
        sourceCount: 1,
        sourceOrigins: r.origin ? [r.origin] : []
      });
    }
  }
  return Array.from(map.values());
}
