/** AI 单本网页导入的可刷新解析档案，不属于全局书源。 */
export interface AiBookProfile {
  id: number;
  bookId: number;
  bookUrl: string;
  baseUrl: string;
  tocUrl: string;
  /** 序列化的 BookSource 子集，仅用于该书目录/正文解析。 */
  sourceJson: string;
  createdAt: number;
  updatedAt: number;
  lastRefreshAt: number;
  consecutiveFailures: number;
  ruleVersion: number;
}

export function createDefaultAiBookProfile(): AiBookProfile {
  return {
    id: 0,
    bookId: 0,
    bookUrl: '',
    baseUrl: '',
    tocUrl: '',
    sourceJson: '',
    createdAt: 0,
    updatedAt: 0,
    lastRefreshAt: 0,
    consecutiveFailures: 0,
    ruleVersion: 1,
  };
}
