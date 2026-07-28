import { BookSource } from '../model/BookSource';
import { CheckResult } from './SourceChecker';

const MANAGED_NON_FAILURE_GROUPS: string[] = ['搜索链接规则为空', '发现规则为空'];

export function splitSourceGroups(value: string): string[] {
  return (value || '').split(/[,，;；|｜\n\r\t]+/)
    .map((item: string): string => item.trim()).filter((item: string): boolean => item.length > 0);
}

export function isManagedCheckGroup(value: string): boolean {
  return value.includes('失效') || value === '校验超时' || MANAGED_NON_FAILURE_GROUPS.includes(value);
}

export function removeCheckErrorComment(comment: string): string {
  return (comment || '').split(/\n\n+/).filter((part: string): boolean => !part.trim().startsWith('// Error:'))
    .join('\n\n').trim();
}

/** Mutates the source exactly once after a check, ready for BookSourceTable.updateSource(). */
export function applyCheckResultToSource(source: BookSource, result: CheckResult, timeout: number): BookSource {
  const groups = splitSourceGroups(source.group).filter((group: string): boolean => !isManagedCheckGroup(group));
  for (const group of result.invalidGroups) {
    if (group && !groups.includes(group)) groups.push(group);
  }
  source.group = groups.join(',');
  const oldComment = removeCheckErrorComment(source.bookSourceComment);
  if (result.status === 'fail') {
    const reason = result.errorMessage || result.invalidGroups.join(', ') || '校验失败';
    source.bookSourceComment = '// Error: ' + reason + (oldComment ? '\n\n' + oldComment : '');
    source.respondTime = timeout + result.duration;
  } else {
    source.bookSourceComment = oldComment;
    source.respondTime = result.duration;
  }
  return source;
}
