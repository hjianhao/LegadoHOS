/** 搜书发现与批量生成使用的轻量数据模型。 */

export interface AiSearchPageLink {
  href: string;
  text: string;
  title: string;
  context: string;
  dataUrl: string;
}

export interface AiSourceCandidateSample {
  title: string;
  url: string;
  context: string;
}

export type AiSourceCandidateDuplicate = 'none' | 'exact' | 'same_host';

export type AiSourceCandidateStatus =
  'candidate' | 'queued' | 'running' | 'waiting_user' | 'ready' | 'created' | 'updated' |
  'unchanged' | 'failed' | 'skipped' | 'cancelled';

export interface AiSourceCandidate {
  id: string;
  engineId: string;
  keyword: string;
  resultPageUrl: string;
  displayName: string;
  landingUrl: string;
  homepageUrl: string;
  normalizedSiteKey: string;
  host: string;
  hitCount: number;
  samples: AiSourceCandidateSample[];
  confidence: number;
  selected: boolean;
  safe: boolean;
  duplicate: AiSourceCandidateDuplicate;
  existingSourceId: number;
  existingSourceName: string;
  status: AiSourceCandidateStatus;
  currentStep: number;
  stepSummary: string;
  logs: string[];
  savedSourceId: number;
  error: string;
}

export interface AiSourceBatchSummary {
  /** 已完成全链路分析、等待用户在导入预览中选择的书源数量。 */
  ready: number;
  created: number;
  updated: number;
  unchanged: number;
  failed: number;
  skipped: number;
  cancelled: number;
  createdSourceIds: number[];
}

export function createAiSourceBatchSummary(): AiSourceBatchSummary {
  return {
    ready: 0,
    created: 0,
    updated: 0,
    unchanged: 0,
    failed: 0,
    skipped: 0,
    cancelled: 0,
    createdSourceIds: [],
  };
}
