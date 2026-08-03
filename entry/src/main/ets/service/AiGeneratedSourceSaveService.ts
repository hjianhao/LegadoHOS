import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { AiSourceDiscoveryService } from './AiSourceDiscoveryService';
import { BookSourceChangeNotifier } from './BookSourceChangeNotifier';
import { SourceRevisionService } from './SourceRevisionService';

export type AiGeneratedSourceSaveStatus = 'created' | 'updated' | 'unchanged' | 'skipped';

export interface AiGeneratedSourceSaveResult {
  status: AiGeneratedSourceSaveStatus;
  sourceId: number;
  changedFields: string[];
  message: string;
}

/** AI 单站生成和搜书发现批量生成共用的保存语义。 */
export class AiGeneratedSourceSaveService {
  static async findExistingByNormalizedUrl(sourceUrl: string): Promise<BookSource | null> {
    await AppDatabase.getInstance().waitForInit();
    const sources = await new BookSourceTable(AppDatabase.getInstance().rdbStore).getAllSources();
    const normalized = AiSourceDiscoveryService.normalizeHomepageUrl(sourceUrl);
    if (!normalized) return null;
    return sources.find((source: BookSource): boolean =>
      AiSourceDiscoveryService.normalizeHomepageUrl(source.sourceUrl) === normalized) || null;
  }

  static async createGeneratedSource(candidate: BookSource,
    enabled: boolean): Promise<AiGeneratedSourceSaveResult> {
    await AppDatabase.getInstance().waitForInit();
    const source: BookSource = { ...candidate } as BookSource;
    const now = Date.now();
    source.id = 0;
    source.enabled = enabled;
    source.group = source.group.trim() || 'AI生成';
    source.isAiGenerated = true;
    source.createTime = source.createTime || now;
    source.updateTime = now;
    const id = await new BookSourceTable(AppDatabase.getInstance().rdbStore).insertSource(source);
    BookSourceChangeNotifier.notify();
    return {
      status: 'created',
      sourceId: id,
      changedFields: [],
      message: enabled ? '书源已新增并启用' : '书源已新增（未启用）',
    };
  }

  static async updateGeneratedSource(existing: BookSource, candidate: BookSource,
    reason: string, preserveSourceName: boolean): Promise<AiGeneratedSourceSaveResult> {
    const next: BookSource = { ...candidate } as BookSource;
    // SourceRevisionService 用 sourceUrl 作为版本身份键；候选首页可能是
    // www/移动别名，更新时必须恢复数据库中的原始 URL。
    next.sourceUrl = existing.sourceUrl;
    const changedFields = await SourceRevisionService.applyRepair(
      existing, next, reason, preserveSourceName);
    return {
      status: changedFields.length > 0 ? 'updated' : 'unchanged',
      sourceId: existing.id,
      changedFields: changedFields,
      message: changedFields.length > 0
        ? '书源已更新，修改 ' + changedFields.length.toString() + ' 个字段'
        : '配置无变化，无需更新',
    };
  }
}
