/**
 * 缓存条目模型
 */
export interface CacheEntry {
  id: number;
  key: string;           // 缓存键
  content: string;       // 缓存内容
  contentType: string;   // text/bytes
  deadline: number;      // 过期时间戳 (0=永不过期)
  createTime: number;
  updateTime: number;
}

export interface TxtTocRule {
  id: number;
  name: string;
  rule: string;          // 正则规则
  isEnabled: boolean;
  sortOrder: number;
  createTime: number;
}
