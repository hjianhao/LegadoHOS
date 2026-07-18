/**
 * 换源章节匹配工具
 * 移植自 Android Legado BookHelp.getDurChapter()：
 *   先按「纯章节名 Jaccard 相似度」在窗口内找最佳匹配，
 *   相似度不足时按「章节号」就近匹配，
 *   都不可靠时回退到原索引位置。
 */

export interface ChapterTitleLike {
  title: string;
}

/** 中文字符 → 数字映射（含大写） */
const CHN_MAP: Record<string, number> = {
  '零': 0, '〇': 0,
  '一': 1, '壹': 1,
  '二': 2, '贰': 2, '两': 2,
  '三': 3, '叁': 3,
  '四': 4, '肆': 4,
  '五': 5, '伍': 5,
  '六': 6, '陆': 6,
  '七': 7, '柒': 7,
  '八': 8, '捌': 8,
  '九': 9, '玖': 9,
  '十': 10, '拾': 10,
  '百': 100, '佰': 100,
  '千': 1000, '仟': 1000,
  '万': 10000,
  '亿': 100000000,
};

/** 全角 → 半角（对齐 StringUtils.fullToHalf） */
function fullToHalf(input: string): string {
  const chars: string[] = input.split('');
  for (let i = 0; i < chars.length; i++) {
    const code = chars[i].charCodeAt(0);
    if (code === 12288) {
      chars[i] = ' ';
    } else if (code >= 65281 && code <= 65374) {
      chars[i] = String.fromCharCode(code - 65248);
    }
  }
  return chars.join('');
}

/** 中文数字 → int（对齐 StringUtils.chineseNumToInt），失败返回 -1 */
function chineseNumToInt(chNum: string): number {
  if (!chNum) return -1;
  const cn = chNum.split('');
  for (const c of cn) {
    if (CHN_MAP[c] === undefined) return -1;
  }
  // "一零二五" 逐位数字形式（不含单位字符）
  const hasUnit = cn.some((c: string) => (CHN_MAP[c] ?? 0) >= 10);
  if (!hasUnit) {
    let digits = '';
    for (const c of cn) digits += String(CHN_MAP[c]);
    const v = parseInt(digits, 10);
    return isNaN(v) ? -1 : v;
  }
  // "一千零二十五"、"一千二" 形式
  try {
    let result = 0;
    let tmp = 0;
    let billion = 0;
    for (let i = 0; i < cn.length; i++) {
      const tmpNum = CHN_MAP[cn[i]];
      if (tmpNum === 100000000) {
        result += tmp;
        result *= tmpNum;
        billion = billion * 100000000 + result;
        result = 0;
        tmp = 0;
      } else if (tmpNum === 10000) {
        result += tmp;
        result *= tmpNum;
        tmp = 0;
      } else if (tmpNum >= 10) {
        if (tmp === 0) tmp = 1;
        result += tmpNum * tmp;
        tmp = 0;
      } else {
        if (i >= 2 && i === cn.length - 1 && CHN_MAP[cn[i - 1]] > 10) {
          tmp = tmpNum * CHN_MAP[cn[i - 1]] / 10;
        } else {
          tmp = tmp * 10 + tmpNum;
        }
      }
    }
    result += tmp + billion;
    return result;
  } catch (_e) {
    return -1;
  }
}

/** 字符串转数字（对齐 StringUtils.stringToInt）：先按阿拉伯数字，再按中文数字 */
function stringToInt(str: string | null | undefined): number {
  if (!str) return -1;
  const num = fullToHalf(str).replace(/\s+/g, '');
  const v = parseInt(num, 10);
  if (!isNaN(v) && String(v) === num) return v;
  if (!isNaN(v) && /^\d+$/.test(num)) return v;
  return chineseNumToInt(num);
}

const CH_NUM_CHARS = '\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟';
// 第X章/节/篇/回/集/话
const CHAPTER_NUM_PATTERN_1 = new RegExp('.*?第([' + CH_NUM_CHARS + ']+)[章节篇回集话]');
// 开头的 "12、" "1.2、" "十二:" 等形式
const CHAPTER_NUM_PATTERN_2 = new RegExp(
  '^(?:[' + CH_NUM_CHARS + ']+[,:、])*([' + CH_NUM_CHARS + ']+)(?:[,:、]|\\.[^\\d])');

/** 提取章节号（对齐 BookHelp.getChapterNum），无章节号返回 -1 */
export function getChapterNum(chapterName: string | null | undefined): number {
  if (!chapterName) return -1;
  const name = fullToHalf(chapterName).replace(/\s/g, '');
  const m1 = name.match(CHAPTER_NUM_PATTERN_1);
  const m2 = m1 ? null : name.match(CHAPTER_NUM_PATTERN_2);
  const group = m1 ? m1[1] : (m2 ? m2[1] : null);
  return stringToInt(group);
}

// 章节序号前缀（排除序号处于结尾的状况，避免把章节名替换为空串）
const REGEX_SEQ_PREFIX = new RegExp(
  '^.*?第(?:[' + CH_NUM_CHARS + ']+)[章节篇回集话](?!$)' +
  '|^(?:[' + CH_NUM_CHARS + ']+[,:、])*(?:[' + CH_NUM_CHARS + ']+)(?:[,:、](?!$)|\\.(?=[^\\d]))',
  'g');
// 前后附加括号内容
const REGEX_BRACKET =
  /(?!^)(?:[〖【《〔\[{(][^〖【《〔\[{()〕》》】〗\]}]+)?[)〕》》】〗\]}]$|^[〖【《〔\[{(](?:[^〖【《〔\[{()〕》》】〗\]}]+[〕》》】〗\]})])?(?!$)/g;
// 所有非字母数字中日韩文字（CJK 基本区 + 〇 + 扩展 A 区）
const REGEX_OTHER = new RegExp('[^A-Za-z0-9_\\u4E00-\\u9FEF\\u3400-\\u4DBF〇]', 'g');

/** 纯章节名（对齐 BookHelp.getPureChapterName）：去空白、序号、括号附加内容、特殊字符 */
export function getPureChapterName(chapterName: string | null | undefined): string {
  if (!chapterName) return '';
  return fullToHalf(chapterName)
    .replace(/\s/g, '')
    .replace(REGEX_SEQ_PREFIX, '')
    .replace(REGEX_BRACKET, '')
    .replace(REGEX_OTHER, '');
}

/** Jaccard 相似度（对齐 Apache Commons Text JaccardSimilarity：字符集合交并比） */
function jaccardSimilarity(left: string, right: string): number {
  if (left === right) return 1;
  if (!left || !right) return 0;
  const leftSet = new Set<string>(left.split(''));
  const rightSet = new Set<string>(right.split(''));
  if (leftSet.size === 0 && rightSet.size === 0) return 1;
  let intersection = 0;
  leftSet.forEach((c: string) => {
    if (rightSet.has(c)) intersection++;
  });
  const union = leftSet.size + rightSet.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

/**
 * 在新目录中匹配原阅读章节（对齐 BookHelp.getDurChapter）
 * @param oldIndex 原章节索引
 * @param oldTitle 原章节标题
 * @param newTitles 新目录章节（取 title 匹配）
 * @param oldTocSize 原目录总章数（未知传 0）
 * @returns 新目录中的章节索引
 */
export function getDurChapterIndex(
  oldIndex: number,
  oldTitle: string,
  newTitles: ChapterTitleLike[],
  oldTocSize: number = 0
): number {
  if (oldIndex <= 0) return 0;
  if (newTitles.length === 0) return oldIndex;
  const oldChapterNum = getChapterNum(oldTitle);
  const oldName = getPureChapterName(oldTitle);
  const newChapterSize = newTitles.length;
  const durIndex = oldTocSize === 0
    ? oldIndex
    : Math.floor(oldIndex * oldTocSize / newChapterSize);
  const min = Math.max(0, Math.min(oldIndex, durIndex) - 10);
  const max = Math.min(newChapterSize - 1, Math.max(oldIndex, durIndex) + 10);
  let nameSim = 0.0;
  let newIndex = 0;
  let newNum = 0;
  if (oldName.length > 0) {
    for (let i = min; i <= max; i++) {
      const temp = jaccardSimilarity(oldName, getPureChapterName(newTitles[i].title));
      if (temp > nameSim) {
        nameSim = temp;
        newIndex = i;
      }
    }
  }
  if (nameSim < 0.96 && oldChapterNum > 0) {
    for (let i = min; i <= max; i++) {
      const temp = getChapterNum(newTitles[i].title);
      if (temp === oldChapterNum) {
        newNum = temp;
        newIndex = i;
        break;
      } else if (Math.abs(temp - oldChapterNum) < Math.abs(newNum - oldChapterNum)) {
        newNum = temp;
        newIndex = i;
      }
    }
  }
  if (nameSim > 0.96 || Math.abs(newNum - oldChapterNum) < 1) {
    return newIndex;
  }
  return Math.min(Math.max(0, newChapterSize - 1), oldIndex);
}
