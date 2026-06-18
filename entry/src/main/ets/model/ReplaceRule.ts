/**
 * 内容替换规则模型
 */
export enum ReplaceScope {
  GLOBAL = 0,     // 全局
  SOURCE = 1,     // 按书源
  BOOK = 2,       // 按书籍
}

export interface ReplaceRule {
  id: number;
  name: string;
  pattern: string;       // 匹配模式（正则或文本）
  replacement: string;   // 替换文本
  isRegex: boolean;      // 是否正则
  isEnabled: boolean;
  scope: ReplaceScope;
  scopeValue: string;    // 范围值（书源URL/书籍URL）
  sortOrder: number;
  createTime: number;
  updateTime: number;
}
