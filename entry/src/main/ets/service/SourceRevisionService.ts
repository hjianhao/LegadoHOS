import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { SourceRevisionTable } from '../data/database/SourceRevisionTable';
import {
  BookSource, bookSourceToJsonObject, parseBookSource, serializeBookSource
} from '../model/BookSource';
import { createSourceRevision } from '../model/SourceRevision';
import { BookSourceChangeNotifier } from './BookSourceChangeNotifier';
import { RdbUtil } from '../data/database/RdbUtil';

/** 不应被 AI 修复流程隐式修改的身份和用户管理字段。 */
const IGNORED_DIFF_FIELDS: Set<string> = new Set([
  'id', 'bookSourceUrl', 'bookSourceName', 'bookSourceGroup', 'enabled',
  'customOrder', 'weight', 'lastUpdateTime',
]);

export function changedSourceFields(before: BookSource, after: BookSource): string[] {
  const oldValue = bookSourceToJsonObject(before) as Record<string, Object>;
  const newValue = bookSourceToJsonObject(after) as Record<string, Object>;
  const fields: string[] = [];
  for (const key of Object.keys(newValue)) {
    if (IGNORED_DIFF_FIELDS.has(key)) continue;
    if (JSON.stringify(oldValue[key]) !== JSON.stringify(newValue[key])) fields.push(key);
  }
  return fields;
}

export class SourceRevisionService {
  static async applyRepair(before: BookSource, candidate: BookSource, reason: string,
    preserveSourceName: boolean = true): Promise<string[]> {
    if (!before.id || before.sourceUrl !== candidate.sourceUrl) {
      throw new Error('修复版本与原书源身份不一致');
    }
    candidate.id = before.id;
    candidate.sourceName = preserveSourceName ? before.sourceName :
      (candidate.sourceName.trim() || before.sourceName);
    candidate.sourceUrl = before.sourceUrl;
    candidate.group = before.group;
    candidate.enabled = before.enabled;
    candidate.weight = before.weight;
    candidate.customOrder = before.customOrder;
    candidate.createTime = before.createTime;
    // 修复阶段可能只返回了详情/目录规则，不能因为模型没有回传搜索入口
    // 就把一个原本可搜索的书源保存成“当前范围没有可搜索书源”。
    // 只有候选值为空时才复用旧值；模型明确生成了新搜索 URL 时仍允许更新。
    if (!candidate.ruleSearchUrl || !candidate.ruleSearchUrl.trim()) {
      candidate.ruleSearchUrl = before.ruleSearchUrl;
    }
    candidate.updateTime = Date.now();

    const changed = changedSourceFields(before, candidate);
    if (!preserveSourceName && before.sourceName !== candidate.sourceName) {
      changed.unshift('bookSourceName');
    }
    // Agent 可能只是重新验证了已经正确的规则；这不是保存异常，也不应创建空版本。
    if (changed.length === 0) return [];

    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const sourceDao = new BookSourceTable(db);
    const revisionDao = new SourceRevisionTable(db);
    const revision = createSourceRevision();
    revision.sourceId = before.id;
    revision.sourceUrl = before.sourceUrl;
    revision.beforeJson = serializeBookSource(before);
    revision.afterJson = serializeBookSource(candidate);
    revision.reason = reason;
    revision.changedFields = JSON.stringify(changed);
    revision.createdAt = Date.now();
    revision.applied = true;

    await RdbUtil.transaction(db, async (): Promise<void> => {
      await revisionDao.insert(revision);
      await sourceDao.updateSource(candidate);
    });
    BookSourceChangeNotifier.notify();
    return changed;
  }

  static async rollbackLatest(sourceUrl: string): Promise<boolean> {
    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const sourceDao = new BookSourceTable(db);
    const revisionDao = new SourceRevisionTable(db);
    const current = await sourceDao.getSourceByUrl(sourceUrl);
    const revision = await revisionDao.getLatestApplied(sourceUrl);
    if (!current || !revision || !revision.beforeJson) return false;

    const restored = parseBookSource(JSON.parse(revision.beforeJson));
    restored.rawJson = revision.beforeJson;
    restored.id = current.id;
    restored.sourceUrl = current.sourceUrl;
    restored.isAiGenerated = current.isAiGenerated;
    restored.createTime = current.createTime;
    restored.updateTime = Date.now();
    await RdbUtil.transaction(db, async (): Promise<void> => {
      await sourceDao.updateSource(restored);
      await revisionDao.markRolledBack(revision.id);
    });
    BookSourceChangeNotifier.notify();
    return true;
  }
}
