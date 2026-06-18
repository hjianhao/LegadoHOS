/**
 * 字符串工具
 */
export class StrUtil {
  /**
   * 截断字符串
   */
  static truncate(text: string, maxLength: number, suffix: string = '...'): string {
    if (!text || text.length <= maxLength) return text || '';
    return text.slice(0, maxLength - suffix.length) + suffix;
  }

  /**
   * 移除 BOM
   */
  static removeBOM(text: string): string {
    if (text && text.charCodeAt(0) === 0xFEFF) {
      return text.slice(1);
    }
    return text;
  }

  /**
   * 检测是否为中文
   */
  static isChinese(text: string): boolean {
    return /[\u4e00-\u9fff]/.test(text);
  }

  /**
   * 计算中文字数
   */
  static wordCount(text: string): number {
    if (!text) return 0;
    // 中文字计数
    const chineseChars = text.match(/[\u4e00-\u9fff]/g);
    const chineseCount = chineseChars ? chineseChars.length : 0;
    // 英文单词计数
    const englishWords = text.match(/[a-zA-Z]+/g);
    const englishCount = englishWords ? englishWords.length : 0;
    return chineseCount + englishCount;
  }

  /**
   * 格式化阅读时间
   */
  static formatReadTime(seconds: number): string {
    if (seconds < 60) return `${seconds}秒`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}分钟`;
    const hours = Math.floor(minutes / 60);
    const remainMin = minutes % 60;
    return `${hours}小时${remainMin}分钟`;
  }

  /**
   * 格式化文件大小
   */
  static formatFileSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    const kb = bytes / 1024;
    if (kb < 1024) return `${kb.toFixed(1)}KB`;
    const mb = kb / 1024;
    if (mb < 1024) return `${mb.toFixed(1)}MB`;
    const gb = mb / 1024;
    return `${gb.toFixed(2)}GB`;
  }

  /**
   * HTML 解码
   */
  static htmlDecode(text: string): string {
    if (!text) return '';
    return text
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&#x27;/g, "'")
      .replace(/&#x2F;/g, '/')
      .replace(/&#(\d+);/g, (_, dec) => String.fromCharCode(parseInt(dec)));
  }

  /**
   * 移除不可见字符
   */
  static stripInvisible(text: string): string {
    if (!text) return '';
    return text.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '');
  }

  /**
   * 规范化空白
   */
  static normalizeWhitespace(text: string): string {
    if (!text) return '';
    return text
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .replace(/\t/g, ' ')
      .replace(/ +/g, ' ')
      .replace(/\n{3,}/g, '\n\n');
  }
}
