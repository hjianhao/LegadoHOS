/**
 * 替换净化规则模型
 *
 * 对齐 Android io.legado.app.data.entities.ReplaceRule。
 * scope 语义：书名或书源 URL 的子串（可多个拼接），空串 = 作用于全部书籍；
 * excludeScope 同理，书名/书源命中其中子串即排除该规则。
 */

/** 单条规则正则替换超时默认值（毫秒），对齐安卓；ArkTS 暂不做强制中断 */
export const DEFAULT_REPLACE_TIMEOUT = 3000;

export interface ReplaceRule {
  id: number;
  name: string;
  group: string;              // 分组（'' = 未分组；可多个，`,`/`;` 分隔）
  pattern: string;            // 匹配内容（正则或普通文本）
  replacement: string;        // 替换为（空 = 删除）
  scope: string;              // 作用范围（'' = 全部）
  scopeTitle: boolean;        // 作用于标题
  scopeContent: boolean;      // 作用于正文
  excludeScope: string;       // 排除范围
  isEnabled: boolean;
  isRegex: boolean;           // pattern 是否按正则解释
  timeoutMillisecond: number; // 保留数据兼容，暂不做强制中断
  order: number;              // 执行/列表顺序，升序应用
}

export function createDefaultReplaceRule(): ReplaceRule {
  return {
    id: 0,
    name: '',
    group: '',
    pattern: '',
    replacement: '',
    scope: '',
    scopeTitle: false,
    scopeContent: true,
    excludeScope: '',
    isEnabled: true,
    isRegex: true,
    timeoutMillisecond: DEFAULT_REPLACE_TIMEOUT,
    order: 0,
  };
}

/**
 * 规则保存前校验，对齐安卓 ReplaceRule.isValid()：
 * - pattern 非空
 * - isRegex 时试编译 pattern
 * - 拦截「以 `|` 结尾但非 `\|`」的易卡死 pattern
 */
export function isValidRule(rule: ReplaceRule): boolean {
  if (!rule.pattern) {
    return false;
  }
  if (rule.isRegex) {
    try {
      new RegExp(rule.pattern);
    } catch (_e) {
      return false;
    }
    if (rule.pattern.endsWith('|') && !rule.pattern.endsWith('\\|')) {
      return false;
    }
  }
  return true;
}
