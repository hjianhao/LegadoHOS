/**
 * 中文小说文本规范化 — 用于 TTS 合成预处理
 *
 * 将屏幕上的可读文本转换为更适合朗读的格式:
 *   - 数字、日期、单位转换为中文读法
 *   - 英文缩写按字母读出
 *   - 特殊标点处理
 */

export class TextNormalizer {
  /**
   * 规范化中文小说文本
   *
   * @param text 原始文本
   * @param mode 'novel' | 'technical' — 小说模式和技术书模式规范化策略不同
   */
  static normalize(text: string, mode: 'novel' | 'technical' = 'novel'): string {
    if (!text || text.length === 0) return text;

    let result = text;

    // ---- 通用规范化（小说和技术书共用） ----

    // 日期: 2026-07-11 → 2026年7月11日
    result = result.replace(/(\d{4})-(\d{1,2})-(\d{1,2})/g,
      (_m, y, mo, d) => `${y}年${parseInt(mo)}月${parseInt(d)}日`);

    // 百分号: 80% → 百分之八十
    result = result.replace(/(\d+(?:\.\d+)?)%/g,
      (_m, n) => '百分之' + TextNormalizer.numberToChinese_(parseFloat(n)));

    // 破折号 → 停顿
    result = result.replace(/——/g, '，');
    result = result.replace(/……/g, '。');

    if (mode === 'novel') {
      result = TextNormalizer.normalizeNovel_(result);
    } else {
      result = TextNormalizer.normalizeTechnical_(result);
    }

    return result;
  }

  // ---- 小说模式 ----

  private static normalizeNovel_(text: string): string {
    let result = text;

    // 第X章 → 保留格式（朗读器识别章节边界用）
    // 不做转换

    // 小数点数字: 3.14 → 三点一四
    result = result.replace(/(\d+)\.(\d+)/g,
      (_m, intPart, decPart) => {
        const intStr = TextNormalizer.numberToChinese_(parseInt(intPart));
        const decStr = decPart.split('').map((d: string) =>
          TextNormalizer.digitToChinese_(d)).join('');
        return intStr + '点' + decStr;
      });

    // 对话引导——特殊处理
    // 他说："你来了。" → 不做 speaker 切换，但可以加停顿标记
    // 这里保持简洁，交由上层分句逻辑处理

    return result;
  }

  // ---- 技术书模式 ----

  private static normalizeTechnical_(text: string): string {
    let result = text;

    // 英文缩写按字母读出: CPU → C P U
    result = result.replace(/\b([A-Z]{2,})\b/g,
      (_m, abbr) => abbr.split('').join(' '));

    // 单位: 1.5 GB → 一点五吉字节
    result = result.replace(/(\d+(?:\.\d+)?)\s*(GB|MB|KB|km|kg)/gi,
      (_m, num, unit) => {
        const chineseNum = TextNormalizer.numberToChinese_(parseFloat(num));
        const chineseUnit = TextNormalizer.unitToChinese_(unit);
        return chineseNum + chineseUnit;
      });

    return result;
  }

  // ---- 数字/单位转换 ----

  /** 0-9999 整数转中文（简化实现） */
  static numberToChinese_(n: number): string {
    if (n === 0) return '零';
    if (n < 0) return '负' + TextNormalizer.numberToChinese_(-n);

    const digits = n.toString();
    const chars = '零一二三四五六七八九';

    // 简单版本：逐位转换
    if (digits.length <= 4) {
      return TextNormalizer.intToChinese4_(parseInt(digits), chars);
    }
    // 超长数字：逐位读出
    return digits.split('').map((d: string) =>
      TextNormalizer.digitToChinese_(d)).join('');
  }

  private static intToChinese4_(n: number, chars: string): string {
    if (n === 0) return '零';
    const units = ['', '十', '百', '千'];
    const s = n.toString();
    let result = '';
    for (let i = 0; i < s.length; i++) {
      const digit = parseInt(s[i]);
      const unitIdx = s.length - 1 - i;
      if (digit === 0) {
        // 跳过连续的零，但在末尾添加一个零
        if (result.length > 0 && !result.endsWith('零')) {
          result += '零';
        }
      } else {
        if (unitIdx > 0 && digit === 1 && unitIdx === 1 && i === 0) {
          // "一十" → "十"
          result += units[unitIdx];
        } else {
          result += chars[digit] + units[unitIdx];
        }
      }
    }
    // 去掉末尾的零
    result = result.replace(/零+$/, '');
    return result || '零';
  }

  private static digitToChinese_(d: string): string {
    const map: Record<string, string> = {
      '0': '零', '1': '一', '2': '二', '3': '三', '4': '四',
      '5': '五', '6': '六', '7': '七', '8': '八', '9': '九',
    };
    return map[d] || d;
  }

  private static unitToChinese_(unit: string): string {
    const map: Record<string, string> = {
      'gb': '吉字节', 'mb': '兆字节', 'kb': '千字节',
      'km': '千米', 'kg': '千克',
    };
    return map[unit.toLowerCase()] || unit;
  }
}
