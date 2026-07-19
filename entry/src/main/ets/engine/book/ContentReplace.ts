/**
 * 内容替换引擎
 *
 * 应用用户配置的替换净化规则（对齐 Android ContentProcessor）：
 * - 规则按 scope 在 DAO 层预过滤（findEnabledByContentScope / findEnabledByTitleScope），
 *   加载后按 sort_order 升序逐条应用，上一条的输出是下一条的输入
 * - isRegex=true：正则替换（'g' 标志，支持 $1 分组引用）；否则纯文本 split/join
 * - 单条规则独立 try/catch（含 new RegExp 编译失败），记日志跳过，不中断后续规则
 */
import { ReplaceRule } from '../../model/ReplaceRule';
import { ReplaceRuleTable } from '../../data/database/ReplaceRuleTable';

export class ContentReplaceEngine {
  contentRules: ReplaceRule[] = [];
  titleRules: ReplaceRule[] = [];

  /**
   * 按书名 + 书源 URL 并行加载正文/标题两个 scope 的启用规则
   */
  async loadRules(ruleTable: ReplaceRuleTable, bookName: string, origin: string): Promise<void> {
    try {
      const results: ReplaceRule[][] = await Promise.all([
        ruleTable.findEnabledByContentScope(bookName, origin),
        ruleTable.findEnabledByTitleScope(bookName, origin),
      ]);
      this.contentRules = results[0];
      this.titleRules = results[1];
    } catch (err) {
      console.error('[ContentReplace] Failed to load rules:', err);
    }
  }

  /** 应用正文规则 */
  applyContent(text: string): string {
    return this.applyRules(text, this.contentRules);
  }

  /** 应用标题规则 */
  applyTitle(title: string): string {
    return this.applyRules(title, this.titleRules);
  }

  private applyRules(text: string, rules: ReplaceRule[]): string {
    if (!text || rules.length === 0) return text;

    let result = text;
    for (const rule of rules) {
      if (!rule.pattern) continue;
      try {
        if (rule.isRegex) {
          result = result.replace(new RegExp(rule.pattern, 'g'), rule.replacement);
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
