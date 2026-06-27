/**
 * AllInOne 正则解析器
 *
 * 处理 Legado AllInOne 正则规则（以 : 开头的列表规则）。
 * 支持使用 && 连接多个正则做链式匹配，最后一个正则提取列表。
 *
 * 参考：legado AnalyzeByRegex.kt
 */

/**
 * 从文本中提取单个元素（链式正则匹配）
 * @param text 原始文本
 * @param regexPatterns 正则表达式列表（按 && 分割）
 * @param index 当前处理的正则索引
 * @returns 匹配结果，每个捕获组一个元素
 */
export function getRegexElement(
  text: string,
  regexPatterns: string[],
  index: number = 0
): string[] | null {
  let vIndex = index;
  try {
    const reg = new RegExp(regexPatterns[vIndex], 'g');
    const m = reg.exec(text);
    if (!m) return null;

    // 如果这是最后一个正则，返回捕获组
    if (vIndex + 1 === regexPatterns.length) {
      const result: string[] = [];
      for (let i = 0; i <= m.length - 1; i++) {
        result.push(m[i] !== undefined ? m[i] : '');
      }
      return result;
    }

    // 否则拼接所有匹配，继续链式匹配
    const resultBuilder: string[] = [];
    do {
      resultBuilder.push(m[0]);
    } while ((m as any).index < text.length && reg.lastIndex > 0 && (reg.exec(text) as RegExpExecArray | null));
    
    if (resultBuilder.length === 0) return null;
    const combined = resultBuilder.join('');
    return getRegexElement(combined, regexPatterns, ++vIndex);
  } catch (_e) {
    return null;
  }
}

/**
 * 从文本中提取多个元素（列表）
 * @param text 原始文本
 * @param regexPatterns 正则表达式列表（按 && 分割）
 * @param index 当前处理的正则索引
 * @returns 匹配结果列表，每个元素是一个捕获组数组
 */
export function getRegexElements(
  text: string,
  regexPatterns: string[],
  index: number = 0
): string[][] {
  let vIndex = index;
  const results: string[][] = [];

  try {
    const reg = new RegExp(regexPatterns[vIndex], 'g');

    // 如果是最后一个正则，提取所有匹配的捕获组
    if (vIndex + 1 === regexPatterns.length) {
      let m: RegExpExecArray | null;
      while ((m = reg.exec(text)) !== null) {
        const groups: string[] = [];
        for (let i = 0; i < m.length; i++) {
          groups.push(m[i] !== undefined ? m[i] : '');
        }
        results.push(groups);
      }
      return results;
    }

    // 链式：先匹配当前正则，拼接后递归
    let m: RegExpExecArray | null;
    while ((m = reg.exec(text)) !== null) {
      // 收集所有匹配片段
      const builder: string[] = [];
      builder.push(m[0]);
      while ((m = reg.exec(text)) !== null) {
        builder.push(m[0]);
      }
      const combined = builder.join('');
      const subResults = getRegexElements(combined, regexPatterns, ++vIndex);
      results.push(...subResults);
      // 回退 index
      vIndex = index;
    }

    return results;
  } catch (_e) {
    return results;
  }
}

/**
 * 从文本中提取单个字符串（AllInOne 模式或 ##regex##replacement## 模式）
 * @param text 原始文本
 * @param rule 规则字符串（可能以 : 开头）
 * @returns 提取的字符串
 */
export function getRegexString(text: string, rule: string): string {
  if (!rule) return '';
  
  // 去掉开头的 :
  let cleanRule = rule;
  if (cleanRule.startsWith(':')) {
    cleanRule = cleanRule.substring(1);
  }

  // 分割 && 链
  const patterns = cleanRule.split('&&').map(p => p.trim()).filter(p => p);
  if (patterns.length === 0) return '';

  const element = getRegexElement(text, patterns);
  if (!element || element.length < 2) return '';

  // 返回第一个捕获组 ($1)
  return element[1] || '';
}
