/** AI 书源修复产生的可回滚版本。 */
export interface SourceRevision {
  id: number;
  sourceId: number;
  sourceUrl: string;
  beforeJson: string;
  afterJson: string;
  reason: string;
  changedFields: string;
  createdAt: number;
  applied: boolean;
}

export function createSourceRevision(): SourceRevision {
  return {
    id: 0,
    sourceId: 0,
    sourceUrl: '',
    beforeJson: '',
    afterJson: '',
    reason: '',
    changedFields: '',
    createdAt: 0,
    applied: false,
  };
}
