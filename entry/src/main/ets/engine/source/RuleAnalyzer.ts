/**
 * 规则切分处理器
 *
 * 智能拆分 Legado 规则中的 &&、||、%% 连接符，
 * 同时避开选择器 []、() 内部的连接符避免误拆。
 *
 * 参考：legado RuleAnalyzer.kt
 */

export class RuleAnalyzer {
  private queue: string;
  private pos: number = 0;
  private start: number = 0;
  private startX: number = 0;
  private step: number = 0;
  elementsType: string = '';
  private rules: string[] = [];

  constructor(data: string) {
    this.queue = data;
  }

  resetPos(): void {
    this.pos = 0;
    this.startX = 0;
  }

  /**
   * 修剪当前规则之前的 "@" 或空白符
   */
  trim(): void {
    while (this.pos < this.queue.length &&
      (this.queue[this.pos] === '@' || this.queue[this.pos] < '!')) {
      this.pos++;
    }
    this.start = this.pos;
    this.startX = this.pos;
  }

  /**
   * 查找 seq 在当前剩余字符串中的位置
   */
  private consumeTo(seq: string): boolean {
    this.start = this.pos;
    const offset = this.queue.indexOf(seq, this.pos);
    if (offset !== -1) {
      this.pos = offset;
      return true;
    }
    return false;
  }

  /**
   * 查找多个 seq 中的任意一个
   */
  private consumeToAny(...seq: string[]): boolean {
    let p = this.pos;
    while (p < this.queue.length) {
      for (const s of seq) {
        if (this.queue.substring(p, p + s.length) === s) {
          this.step = s.length;
          this.pos = p;
          return true;
        }
      }
      p++;
    }
    return false;
  }

  /**
   * 查找字符序列中的任意一个
   */
  private findToAny(...chars: string[]): number {
    let p = this.pos;
    while (p < this.queue.length) {
      for (const c of chars) {
        if (this.queue[p] === c) return p;
      }
      p++;
    }
    return -1;
  }

  /**
   * 拉出一个规则平衡组（CSS 选择器中的 [ ] 和 ( ) 需要跳过）
   */
  private chompBalanced(open: string, close: string): boolean {
    let p = this.pos;
    let depth = 0;
    let inSingleQuote = false;
    let inDoubleQuote = false;

    // 跳过开括号本身
    if (p < this.queue.length && this.queue[p] === open) {
      p++;
    }

    while (p < this.queue.length) {
      const c = this.queue[p++];
      if (c === '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote;
      else if (c === '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote;
      else if (c === '\\') { p++; continue; } // 转义
      else if (!inSingleQuote && !inDoubleQuote) {
        if (c === open) depth++;
        else if (c === close) {
          if (depth === 0) {
            this.pos = p;
            return true;
          }
          depth--;
        }
      }
    }
    return false;
  }

  /**
   * 分割规则：智能处理 &&, ||, %%
   * 不会拆分选择器 [] 或 () 内部的连接符
   *
   * @param split 分割字符串序列（如 "&&", "||", "%%"）
   * @returns 分割后的规则列表
   */
  splitRule(...split: string[]): string[] {
    this.rules = [];
    this.elementsType = '';

    if (split.length === 0) {
      this.rules.push(this.queue.substring(this.startX));
      return this.rules;
    }

    return this.splitRuleImpl(split);
  }

  private splitRuleImpl(split: string[]): string[] {
    if (split.length === 1) {
      this.elementsType = split[0];
      if (!this.consumeTo(this.elementsType)) {
        this.rules.push(this.queue.substring(this.startX));
        return this.rules;
      }
      this.step = this.elementsType.length;
      return this.splitRuleNext();
    }

    if (!this.consumeToAny(...split)) {
      this.rules.push(this.queue.substring(this.startX));
      return this.rules;
    }

    const end = this.pos;
    this.pos = this.start;

    // 查找选择器位置
    while (true) {
      const st = this.findToAny('[', '(');
      if (st === -1) {
        this.rules.push(this.queue.substring(this.startX, end));
        this.elementsType = this.queue.substring(end, end + this.step);
        this.pos = end + this.step;

        while (this.consumeTo(this.elementsType)) {
          this.rules.push(this.queue.substring(this.start, this.pos));
          this.pos += this.step;
        }

        this.rules.push(this.queue.substring(this.pos));
        return this.rules;
      }

      if (st > end) {
        this.rules.push(this.queue.substring(this.startX, end));
        this.elementsType = this.queue.substring(end, end + this.step);
        this.pos = end + this.step;

        while (this.consumeTo(this.elementsType) && this.pos < st) {
          this.rules.push(this.queue.substring(this.start, this.pos));
          this.pos += this.step;
        }

        if (this.pos > st) {
          this.startX = this.start;
          return this.splitRuleImpl(split);
        } else {
          this.rules.push(this.queue.substring(this.pos));
          return this.rules;
        }
      }

      this.pos = st;
      const next = this.queue[this.pos] === '[' ? ']' : ')';
      if (!this.chompBalanced(this.queue[this.pos], next)) {
        // 不平衡，跳过
        this.pos++;
        continue;
      }
    }
  }

  /**
   * 二段匹配（elementsType 已确定，按 elementsType 分割）
   */
  private splitRuleNext(): string[] {
    const end = this.pos;
    this.pos = this.start;

    while (true) {
      const st = this.findToAny('[', '(');
      if (st === -1) {
        this.rules.push(this.queue.substring(this.startX, end));
        this.pos = end + this.step;

        while (this.consumeTo(this.elementsType)) {
          this.rules.push(this.queue.substring(this.start, this.pos));
          this.pos += this.step;
        }

        this.rules.push(this.queue.substring(this.pos));
        return this.rules;
      }

      if (st > end) {
        this.rules.push(this.queue.substring(this.startX, end));
        this.pos = end + this.step;

        while (this.consumeTo(this.elementsType) && this.pos < st) {
          this.rules.push(this.queue.substring(this.start, this.pos));
          this.pos += this.step;
        }

        if (this.pos > st) {
          this.startX = this.start;
          return this.splitRuleNext();
        } else {
          this.rules.push(this.queue.substring(this.pos));
          return this.rules;
        }
      }

      this.pos = st;
      const next = this.queue[this.pos] === '[' ? ']' : ')';
      if (!this.chompBalanced(this.queue[this.pos], next)) {
        this.pos++;
        continue;
      }
    }
  }

  /**
   * 替换内嵌规则（处理 {{}}、@get:{} 等）
   * @param inner 起始标志，如 "{{"
   * @param startStep 起始标志中不属于规则部分的长度
   * @param endStep 结束标志中不属于规则部分的长度
   * @param fr 解析内嵌规则的回调
   */
  innerRule(
    inner: string,
    startStep: number = 1,
    endStep: number = 1,
    fr: (s: string) => string | null
  ): string {
    const st: string[] = [];
    this.resetPos();

    while (this.consumeTo(inner)) {
      const posPre = this.pos;
      if (this.chompCodeBalanced('{', '}')) {
        const innerContent = this.queue.substring(posPre + startStep, this.pos - endStep);
        const frv = fr(innerContent);
        if (frv !== null && frv !== undefined) {
          st.push(this.queue.substring(this.startX, posPre) + frv);
          this.startX = this.pos;
          continue;
        }
      }
      this.pos += inner.length;
    }

    if (this.startX === 0) return '';
    st.push(this.queue.substring(this.startX));
    return st.join('');
  }

  /**
   * 拉出一个平衡组（支持转义和引号）
   */
  private chompCodeBalanced(open: string, close: string): boolean {
    // Simple version for {{}} and @get:{}
    let p = this.pos;
    let depth = 0;
    let inSingleQuote = false;
    let inDoubleQuote = false;

    while (p < this.queue.length) {
      const c = this.queue[p++];
      if (c === '\\') { p++; continue; }
      if (c === '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote;
      else if (c === '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote;
      else if (!inSingleQuote && !inDoubleQuote) {
        if (c === open) depth++;
        else if (c === close) {
          if (depth === 0) {
            this.pos = p;
            return true;
          }
          depth--;
        }
      }
    }
    return false;
  }
}

/**
 * 便捷函数：按 &&、||、%% 分割规则，返回分割后的规则列表和连接符类型
 */
export function splitConnectorRules(rule: string): { rules: string[]; connector: string } {
  const analyzer = new RuleAnalyzer(rule);
  const result = analyzer.splitRule('&&', '||', '%%');
  return { rules: result, connector: analyzer.elementsType };
}

/**
 * 应用 || 连接符：取首个非空值
 */
export function firstNonEmpty(values: string[]): string {
  for (const v of values) {
    if (v && v.trim()) return v;
  }
  return '';
}

/**
 * 应用 && 连接符：合并所有值
 */
export function mergeAll(values: string[]): string {
  return values.filter(v => v && v.trim()).join('');
}

/**
 * 应用 %% 连接符：交错取数（适用于列表模式）
 * 从多个规则的结果中交错取值
 */
export function interleaveLists(lists: string[][]): string[] {
  const result: string[] = [];
  let maxLen = 0;
  for (const list of lists) {
    if (list.length > maxLen) maxLen = list.length;
  }
  for (let i = 0; i < maxLen; i++) {
    for (const list of lists) {
      if (i < list.length) {
        result.push(list[i]);
      }
    }
  }
  return result;
}
