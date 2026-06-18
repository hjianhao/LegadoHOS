/**
 * 发现页规则引擎
 *
 * 解析书源的 ruleExplores 配置，生成发现页的
 * 分类/模块/书籍列表。
 *
 * 支持格式：
 * - [{name:"分类名", url:"..."}, ...]
 * - JSON 数组或单条规则的字符串
 */
import { BookSource } from '../../model/BookSource';
import { SearchResult } from '../../model/SearchResult';
import { globalSourceExecutor } from './SourceExecutor';
import { RuleParser } from './RuleParser';

export interface ExploreModule {
  name: string;           // 模块名（如"热门小说"）
  sourceName: string;     // 书源名
  books: SearchResult[];
}

export class ExploreEngine {
  /**
   * 从所有启用的书源获取发现页内容
   */
  static async exploreAll(sources: BookSource[]): Promise<ExploreModule[]> {
    const modules: ExploreModule[] = [];

    for (const source of sources) {
      if (!source.ruleExplores) continue;

      try {
        const mods = await this.exploreSingle(source);
        modules.push(...mods);
      } catch (err) {
        console.warn(`[Explore] Source ${source.sourceName} failed:`, err);
      }
    }

    return modules;
  }

  /**
   * 从单个书源获取发现页
   */
  static async exploreSingle(source: BookSource): Promise<ExploreModule[]> {
    const modules: ExploreModule[] = [];

    // 解析 ruleExplores
    let exploreRules: ExploreRuleItem[];

    try {
      exploreRules = this.parseExploreRules(source.ruleExplores);
    } catch (err) {
      console.warn(`[Explore] Parse rules failed for ${source.sourceName}:`, err);
      return [];
    }

    for (const rule of exploreRules) {
      try {
        const searchResults = await globalSourceExecutor.search(
          rule.keyword || '',
          [source]
        );

        modules.push({
          name: rule.name || source.sourceName,
          sourceName: source.sourceName,
          books: searchResults,
        });
      } catch (err) {
        console.warn(`[Explore] Module ${rule.name} failed:`, err);
      }
    }

    return modules;
  }

  /**
   * 解析发现页规则
   * 支持 JSON 数组格式:
   * [
   *   {"name":"热门","url":"https://...","keyword":"周排行榜"},
   *   {"name":"分类","url":"https://.../list?type=xxx"},
   *   {"name":"{"key":"自定义JSON"}..."}
   * ]
   */
  static parseExploreRules(ruleExplores: string): ExploreRuleItem[] {
    if (!ruleExplores || ruleExplores.trim() === '') return [];

    // 尝试解析 JSON
    try {
      const parsed = JSON.parse(ruleExplores);
      if (Array.isArray(parsed)) {
        return parsed.map((item: any) => ({
          name: this.getNestedValue(item, 'name') || '未知',
          url: this.getNestedValue(item, 'url') || '',
          keyword: this.getNestedValue(item, 'keyword') || '',
          style: this.getNestedValue(item, 'style') || '',
          bookUrl: this.getNestedValue(item, 'bookUrl') || '',
        }));
      }
      if (typeof parsed === 'object') {
        return [{
          name: this.getNestedValue(parsed, 'name') || '发现',
          url: this.getNestedValue(parsed, 'url') || '',
          keyword: this.getNestedValue(parsed, 'keyword') || '',
          style: this.getNestedValue(parsed, 'style') || '',
          bookUrl: this.getNestedValue(parsed, 'bookUrl') || '',
        }];
      }
    } catch {
      // 不是 JSON，可能是 URL 字符串
      if (ruleExplores.startsWith('http')) {
        return [{ name: '发现', url: ruleExplores, keyword: '', style: '', bookUrl: '' }];
      }
    }

    return [];
  }

  private static getNestedValue(obj: any, path: string): string {
    const parts = path.split('.');
    let current = obj;
    for (const part of parts) {
      if (current && typeof current === 'object' && part in current) {
        current = current[part];
      } else {
        return '';
      }
    }
    return typeof current === 'string' ? current : JSON.stringify(current);
  }
}

export interface ExploreRuleItem {
  name: string;
  url: string;
  keyword: string;
  style: string;
  bookUrl: string;
}
