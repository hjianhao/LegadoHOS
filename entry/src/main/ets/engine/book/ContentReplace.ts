/**
 * 内容替换引擎
 *
 * 应用用户配置的替换规则对阅读内容进行过滤/净化。
 * 支持：
 * - 正则替换
 * - 纯文本替换
 * - 全局/书源/单书范围
 */
import { ReplaceRule, ReplaceScope } from '../../model/ReplaceRule';

export class ContentReplaceEngine {
  private rules: ReplaceRule[] = [];

  /**
   * 加载替换规则
   */
  async loadRules(ruleTable: any): Promise<void> {
    try {
      this.rules = await ruleTable.getAllEnabled();
    } catch (err) {
      console.error('[ContentReplace] Failed to load rules:', err);
    }
  }

  /**
   * 应用替换规则到文本
   * @param text 原始文本
   * @param sourceUrl 当前书源 URL（用于范围过滤）
   * @param bookUrl 当前书籍 URL（用于范围过滤）
   * @returns 替换后的文本
   */
  apply(text: string, sourceUrl?: string, bookUrl?: string): string {
    if (!text || this.rules.length === 0) return text;

    let result = text;

    for (const rule of this.rules) {
      // 范围过滤
      if (rule.scope !== ReplaceScope.GLOBAL) {
        if (rule.scope === ReplaceScope.SOURCE && rule.scopeValue !== sourceUrl) continue;
        if (rule.scope === ReplaceScope.BOOK && rule.scopeValue !== bookUrl) continue;
      }

      try {
        if (rule.isRegex) {
          const regex = new RegExp(rule.pattern, 'gi');
          result = result.replace(regex, rule.replacement);
        } else {
          result = result.split(rule.pattern).join(rule.replacement);
        }
      } catch (err) {
        console.warn('[ContentReplace] Rule error:', rule.name, err);
      }
    }

    return result;
  }

  /**
   * 简繁转换
   */
  static simplifiedToTraditional(text: string): string {
    // 简化实现 — 生产环境使用完整的简繁映射表
    const map: Record<string, string> = {
      '的': '的', '了': '了', '是': '是', '我': '我',
      '门': '門', '开': '開', '关': '關', '机': '機',
      '电': '電', '话': '話', '国': '國', '会': '會',
      '发': '發', '见': '見', '长': '長', '风': '風',
      '书': '書', '读': '讀', '说': '說', '时': '時',
      '间': '間', '样': '樣', '点': '點', '经': '經',
      '红': '紅', '绿': '綠', '马': '馬', '鱼': '魚',
      '鸟': '鳥', '龙': '龍', '学': '學', '习': '習',
      '为': '為', '与': '與', '产': '產', '业': '業',
      // 实际应有完整映射表，这里仅示意
    };
    return text.split('').map(c => map[c] || c).join('');
  }

  static traditionalToSimplified(text: string): string {
    // 同上反向映射
    const map: Record<string, string> = {
      '門': '门', '開': '开', '關': '关', '機': '机',
      '電': '电', '話': '话', '國': '国', '會': '会',
      '發': '发', '見': '见', '長': '长', '風': '风',
      '書': '书', '讀': '读', '說': '说', '時': '时',
      '間': '间', '樣': '样', '點': '点', '經': '经',
      '紅': '红', '綠': '绿', '馬': '马', '魚': '鱼',
      '鳥': '鸟', '龍': '龙', '學': '学', '習': '习',
      '為': '为', '與': '与', '產': '产', '業': '业',
    };
    return text.split('').map(c => map[c] || c).join('');
  }
}
