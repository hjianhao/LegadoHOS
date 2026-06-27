/**
 * 内容清洗工具
 *
 * 完整移植 Legado Android 的正文清洗逻辑：
 * 1. HtmlFormatter — 保留图片的 HTML 清洗
 * 2. 书源级 replaceRegex 替换
 * 3. 用户自定义替换规则引擎（去重标题 → 规则替换 → 分段格式化）
 *
 * 参考: HtmlFormatter.kt + ContentProcessor.kt + ReplaceRule.kt
 */
import { ReplaceRule } from '../model/ReplaceRule';

export class ContentCleaner {

  // ============================================================
  // 第 1 层：HtmlFormatter（保留图片的 HTML 清洗）
  // ============================================================

  /** 简单版 HTML 格式化：移除所有标签，整理空白 */
  static formatHtml(html: string): string {
    if (!html) return '';
    return this.removeNavText(html
      .replace(/&nbsp;/g, ' ')
      .replace(/&ensp;|&emsp;/g, ' ')
      .replace(/&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D/g, '')
      .replace(/<\/?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>/gi, '\n')
      .replace(/<!--[^>]*-->/g, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<\/?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>/g, '')
      .replace(/\s*\n+\s*/g, '\n　　')
      .replace(/^[\n\s]+/, '　　')
      .replace(/[\n\s]+$/, '')
      .trim());
  }

  /** 保留 <img> 标签的 HTML 格式化 */
  static formatKeepImg(html: string, baseUrl?: string): string {
    if (!html) return '';
    let s = html
      .replace(/&nbsp;/g, ' ')
      .replace(/&ensp;|&emsp;/g, ' ')
      .replace(/&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D/g, '')
      .replace(/<\/?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>/gi, '\n')
      .replace(/<!--[^>]*-->/g, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<\/?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>/g, '')
      .replace(/\s*\n+\s*/g, '\n　　')
      .replace(/^[\n\s]+/, '　　')
      .replace(/[\n\s]+$/, '')
      .trim();

    // 处理图片 URL：提取 data-src 或 src，做绝对路径
    if (baseUrl) {
      const base = baseUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
      s = s.replace(/<img[^>]*\s(?:data-src|src)\s*=\s*["']([^"']+)["'][^>]*>/gi,
        (match: string, url: string) => {
          if (url.startsWith('http')) return match;
          const absUrl = base + (url.startsWith('/') ? url : '/' + url);
          return match.replace(url, absUrl);
        });
    }
    return this.removeNavText(s);
  }

  /**
   * 移除常见的中文导航/运营文字
   * 参考 HtmlUtil.cleanHtmlToText 的导航过滤逻辑
   */
  static removeNavText(text: string): string {
    if (!text) return '';
    // 1. 把全角空格/制表符/连续空白转为单个换行（便于行首匹配）
    let s = text.replace(/[\u3000\t]+/g, '\n');
    // 2. 合并连续换行
    s = s.replace(/\n{3,}/g, '\n\n');

    // 3. 常见导航文字（先全局删除再行首匹配，应对单行排列的情况）
    //    注意：长词必须排在短词前（如 免费VIP 在 免费 和 VIP 之前，
    //    排行榜 在 排行 之前，免费小说 在 免费 和 小说 之前）
    const navGlobalPatterns = [
      // 长词优先：网站名
      /\s*(?:我的书架|免费VIP|免费小说|小说推荐|热门小说|完本小说|全本小说|网络小说|全部小说|分类小说|最新小说|更新小说|完本推荐|热门推荐|猜你喜欢|大家都在看|最近阅读|阅读记录|浏览历史|搜索历史|热门搜索|热搜|排行榜|月票|打赏|催更|订阅|购买|加入书架|开始阅读|男生站|女生站)\s*/g,
      // 通用导航词
      /\s*(?:首页|上一章|下一章|回目录|目录|设置|书架|排名|排行|搜索|分类|推荐|我的|登录|注册|充值|投票|分享|举报|全本|完本|免费|最新|更新|公告|活动|帮助|关于|更多|返回|确定|取消|男|女|男生|女生|全部|题材|个人中心|退出|书库|VIP)\s*/g,
      // 断词/缩写（"生站"≈"男生站|女生站"的缩写, "榜"≈"排行榜"残留, "综合"常见导航页）
      /\s*(?:综合|生站|榜|书城|阅读|读书|文学|中文|书网|书屋)\s*/g,
      // 元信息
      /\s*(?:作者：|作者:|更新于|更新日期|发布时间|阅读量|点击量|人气|字数|总点击|总推荐|总收藏|总字数)\s*/g,
      // 卷/章标题前缀
      /\s*(?:正文|正文卷|VIP章|VIP卷|免费章|免费卷|第一卷|第二卷|第三卷|第[一二三四五六七八九十\d零○]卷)\s*/g,
      // 通用 XXX小说/书库/书城
      /\s*[\u4e00-\u9fff]{2,6}(?:小说|书库|书城)\s*/g,
      // 网址信息（如 "网址:https://xxx" 或 "地址:xxx"）
      /[\s\u3000]*(?:网址|地址|链接|来源|URL|url|网站)[:：\s]*[a-zA-Z0-9./:?=&%-]+\s*/g,
    ];
    for (const pattern of navGlobalPatterns) {
      s = s.replace(pattern, '');
    }

    // 4. 再次行首匹配（清理残留）
    const navLinePatterns = [
      /^(?:首页|上一章|下一章|回目录|目录|设置|书架|排名|排行|搜索|分类|推荐|我的|登录|注册|充值|投票|分享|举报|全本|完本|免费|最新|更新|公告|活动|帮助|关于|更多|返回|确定|取消|男|女|男生|女生|男生站|女生站|全部|题材|个人中心|退出|书库|VIP|综合|生站|榜)\s*/gm,
      /^(?:我的书架|免费VIP|免费小说|小说推荐|热门小说|完本小说|全本小说|网络小说|全部小说|分类小说|最新小说|更新小说|完本推荐|热门推荐|猜你喜欢|大家都在看|最近阅读|阅读记录|浏览历史|搜索历史|热门搜索|热搜|排行榜|月票|打赏|催更|订阅|购买|加入书架|开始阅读)\s*/gm,
    ];
    for (const pattern of navLinePatterns) {
      s = s.replace(pattern, '');
    }

    // 5. 清理连续空白和残留短词
    s = s.replace(/\n{2,}/g, '\n');

    // 6. 恢复 全角空格缩进（用于段落，不用于导航）
    s = s.replace(/\n+/g, '\n\u3000\u3000');
    return s.trim();
  }

  // ============================================================
  // 第 2 层：书源级 replaceRegex 替换
  // ============================================================

  /**
   * 解析 ##regex##replacement 后缀
   * 返回 { cleanRule, replaceRegex, replacement, replaceFirst }
   */
  static splitRegexSuffix(rule: string): {
    cleanRule: string; replaceRegex: string; replacement: string; replaceFirst: boolean
  } {
    const parts = rule.split('##');
    let cleanRule = parts[0].trim();
    let replaceRegex = '';
    let replacement = '';
    let replaceFirst = false;

    if (parts.length >= 2) replaceRegex = parts[1];
    if (parts.length >= 3) replacement = parts[2];
    if (parts.length >= 4) replaceFirst = true; // ### = only first match

    return { cleanRule, replaceRegex, replacement, replaceFirst };
  }

  /**
   * 应用正则替换
   */
  static applyRegexReplace(
    value: string,
    replaceRegex: string,
    replacement: string,
    replaceFirst: boolean
  ): string {
    if (!replaceRegex) return value;
    try {
      const reg = new RegExp(replaceRegex, 'g');
      if (replaceFirst) {
        // OnlyOne: ### 模式，只替换第一个匹配
        const m = reg.exec(value);
        if (m) {
          return value.substring(0, m.index) +
            (replacement || '') +
            value.substring(m.index + m[0].length);
        }
        return value;
      }
      return value.replace(reg, replacement || '');
    } catch (_e) {
      return value.replace(replaceRegex, replacement || '');
    }
  }

  // ============================================================
  // 第 3 层：用户替换规则引擎（ContentProcessor 移植）
  // ============================================================

  /**
   * 处理正文：去重标题 → 应用替换规则 → 格式化段落
   *
   * @param content      原始正文
   * @param chapterTitle 章节标题
   * @param bookName     书名（用于去重匹配）
   * @param replaceRules 用户替换规则列表（已按 sortOrder 排序）
   * @param enabled      是否启用替换规则
   * @returns 清洗后的正文
   */
  static processContent(
    content: string,
    chapterTitle: string,
    bookName: string,
    replaceRules: ReplaceRule[],
    enabled: boolean = true
  ): string {
    if (!content || content === 'null') return content || '';

    let mContent = content;

    // Step 1: 去重标题（Legado ContentProcessor 逻辑）
    if (chapterTitle) {
      const titleEscaped = chapterTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      // 匹配开头: 可选的空白/标点 + 书名 + 标题
      const nameEscaped = bookName ? bookName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : '';
      const removeTitleRe = new RegExp(
        '^(\\s|\\p{P}|' + nameEscaped + ')*' + titleEscaped.replace(/\s+/g, '\\s*') + '(\\s*)$', '');
      const titleMatch = mContent.match(removeTitleRe);
      if (titleMatch) {
        mContent = mContent.substring(titleMatch[0].length);
      }
    }

    // Step 2: 每行 trim
    mContent = mContent.split('\n').map(l => l.trim()).join('\n');

    // Step 3: 应用替换规则
    if (enabled && replaceRules && replaceRules.length > 0) {
      for (const rule of replaceRules) {
        if (!rule.isEnabled || !rule.pattern) continue;
        try {
          if (rule.isRegex) {
            const reg = new RegExp(rule.pattern, 'g');
            mContent = mContent.replace(reg, rule.replacement || '');
          } else {
            mContent = mContent.replace(rule.pattern, rule.replacement || '');
          }
        } catch (_e) {
          // 单个规则失败不影响后续
        }
      }
    }

    // Step 4: 重新添加标题
    if (chapterTitle) {
      mContent = chapterTitle + '\n' + mContent;
    }

    // Step 5: 分段格式化
    const paragraphs: string[] = [];
    mContent.split('\n').forEach(str => {
      const p = str.trim();
      if (p) {
        if (paragraphs.length === 0) {
          paragraphs.push(p);
        } else {
          paragraphs.push('\u3000\u3000' + p);
        }
      }
    });

    return paragraphs.join('\n');
  }
}
