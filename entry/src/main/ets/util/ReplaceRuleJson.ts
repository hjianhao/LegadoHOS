/**
 * 替换净化规则的 JSON 导入/导出序列化。
 *
 * 字段名对齐安卓 ReplaceRule（GSON 序列化结果），保证与安卓互导兼容：
 * id/name/group/pattern/replacement/scope/scopeTitle/scopeContent/excludeScope/
 * isEnabled/isRegex/timeoutMillisecond/order
 *
 * 导入兼容旧格式（help/ReplaceAnalyzer.kt）：
 * regex→pattern、replaceSummary→name、useTo→scope、enable→isEnabled、serialNumber→order。
 * 布尔字段容错 true/false、0/1、'true'/'false'。
 */
import { DEFAULT_REPLACE_TIMEOUT, ReplaceRule, createDefaultReplaceRule, isValidRule } from '../model/ReplaceRule';

/** 导出：规则列表 → 安卓兼容 JSON 数组文本 */
export function replaceRulesToJsonText(rules: ReplaceRule[]): string {
  const arr: Array<Record<string, Object>> = rules.map((rule: ReplaceRule): Record<string, Object> => {
    return {
      'id': rule.id,
      'name': rule.name,
      'group': rule.group,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'scope': rule.scope,
      'scopeTitle': rule.scopeTitle,
      'scopeContent': rule.scopeContent,
      'excludeScope': rule.excludeScope,
      'isEnabled': rule.isEnabled,
      'isRegex': rule.isRegex,
      'timeoutMillisecond': rule.timeoutMillisecond,
      'order': rule.order,
    };
  });
  return JSON.stringify(arr);
}

/**
 * 解析导入文本（先剥 BOM）。支持新格式 JSON 数组 / 单对象、旧格式字段映射。
 * 无效（pattern 为空、正则不合法等）的条目被丢弃；文本整体不合法时抛 Error。
 */
export function parseReplaceRulesJson(text: string): ReplaceRule[] {
  const normalized = text.replace(/^\uFEFF/, '').trim();
  if (!normalized) {
    throw new Error('内容为空');
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(normalized) as Object;
  } catch (_e) {
    throw new Error('JSON 格式错误');
  }
  let items: Object[];
  if (Array.isArray(parsed)) {
    items = parsed as Object[];
  } else {
    items = [parsed];
  }
  const rules: ReplaceRule[] = [];
  const baseId = Date.now();
  for (let i = 0; i < items.length; i++) {
    const rule = parseOneRule(items[i], baseId + i);
    if (rule !== null && isValidRule(rule)) {
      rules.push(rule);
    }
  }
  return rules;
}

/** 单条解析：含 regex 字段按旧格式映射，否则按新格式；字段类型做容错。 */
function parseOneRule(value: Object, fallbackId: number): ReplaceRule | null {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  const item = value as Record<string, Object>;
  const hasNewFormat = item['pattern'] !== undefined;
  const hasOldFormat = item['regex'] !== undefined;
  if (!hasNewFormat && !hasOldFormat) {
    return null;
  }
  const rule = createDefaultReplaceRule();
  if (hasNewFormat) {
    rule.id = numField(item, 'id', fallbackId);
    rule.name = strField(item, 'name');
    rule.group = strField(item, 'group');
    rule.pattern = strField(item, 'pattern');
    rule.replacement = strField(item, 'replacement');
    rule.scope = strField(item, 'scope');
    rule.scopeTitle = boolField(item, 'scopeTitle', false);
    rule.scopeContent = boolField(item, 'scopeContent', true);
    rule.excludeScope = strField(item, 'excludeScope');
    rule.isEnabled = boolField(item, 'isEnabled', true);
    rule.isRegex = boolField(item, 'isRegex', true);
    rule.timeoutMillisecond = numField(item, 'timeoutMillisecond', DEFAULT_REPLACE_TIMEOUT);
    rule.order = numField(item, 'order', 0);
  } else {
    // 旧格式：regex→pattern、replaceSummary→name、useTo→scope、enable→isEnabled、serialNumber→order
    rule.id = numField(item, 'id', fallbackId);
    rule.pattern = strField(item, 'regex');
    rule.name = strField(item, 'replaceSummary');
    rule.replacement = strField(item, 'replacement');
    rule.scope = strField(item, 'useTo');
    rule.isEnabled = boolField(item, 'enable', true);
    rule.isRegex = boolField(item, 'isRegex', true);
    rule.order = numField(item, 'serialNumber', 0);
  }
  return rule;
}

function strField(item: Record<string, Object>, key: string): string {
  const v = item[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return String(v);
  }
  return '';
}

function numField(item: Record<string, Object>, key: string, dft: number): number {
  const v = item[key];
  if (typeof v === 'number') {
    return v;
  }
  if (typeof v === 'string') {
    const n = Number(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  if (typeof v === 'boolean') {
    return v ? 1 : 0;
  }
  return dft;
}

function boolField(item: Record<string, Object>, key: string, dft: boolean): boolean {
  const v = item[key];
  if (typeof v === 'boolean') {
    return v;
  }
  if (typeof v === 'number') {
    return v !== 0;
  }
  if (typeof v === 'string') {
    return v === 'true' || v === '1';
  }
  return dft;
}
