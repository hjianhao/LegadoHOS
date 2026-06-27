/**
 * 书源规则验证脚本
 *
 * 测试场景：搜索 "冲出四合院"
 * 1. 对比 CSS 提取 vs 正则兜底能搜到多少源
 * 2. 验证 ruleBookInfoAuthor 能否从书籍详情页提取作者
 *
 * 用法: node test/verify_source.mjs
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ========== 配置 ==========
const SEARCH_KEYWORD = '冲出四合院';
const SOURCES_FILE = path.resolve(__dirname, 'source.json');
const OUTPUT_DIR = path.resolve(__dirname, 'output');
const TIMEOUT_MS = 15000;

// ========== 工具函数 ==========

function getBaseUrl(rawUrl) {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 构建搜索 URL（模拟 SourceExecutor.buildUrl） */
function buildSearchUrl(template, keyword, page, baseUrl) {
  if (!template) return null;
  let url = template;

  // @js: 开头 → 无法处理
  if (url.trimStart().startsWith('@js:')) {
    console.warn('  ⚠️  template starts with @js:, skipping');
    return null;
  }

  const encoded = encodeURIComponent(keyword);

  // 替换模板占位符
  url = url
    .replace(/\{\{key\}\}/g, encoded)
    .replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page))
    .replace(/\{\{pageNum\}\}/g, String(page + 1));
  url = url.replace(/\{\{[^}]*\}\}/g, '');

  // 移除 <js>...</js>
  url = url.replace(/<js>[\s\S]*?<\/js>/gi, '');

  // 处理 @js: 表达式
  while (url.includes('@js:')) {
    const jsIdx = url.indexOf('@js:');
    const jsonOptStart = url.indexOf(',{', jsIdx);
    if (jsonOptStart > jsIdx) {
      url = url.substring(0, jsIdx) + url.substring(jsonOptStart);
    } else {
      url = url.substring(0, jsIdx);
    }
  }

  // 处理页码分组 <选项1,选项2,...>
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    const idx = Math.min(page - 1, items.length - 1);
    url = url.replace(pageGroupMatch[0], items[idx].trim());
  }

  // 分离 JSON 选项
  let jsonRaw = '';
  const jsonMatch = url.match(/^(.+?),?\s*(\{[\s\S]*\})$/);
  if (jsonMatch) {
    url = jsonMatch[1].trim();
    jsonRaw = jsonMatch[2];
  }

  // 相对路径处理
  if (!url.startsWith('http://') && !url.startsWith('https://') && baseUrl) {
    const base = baseUrl.replace(/\/+$/, '');
    url = base + (url.startsWith('/') ? url : '/' + url);
  }

  // 解析 JSON 选项
  let method = 'GET';
  let body = '';
  if (jsonRaw) {
    try {
      const opts = JSON.parse(
        jsonRaw
          .replace(/'/g, '"')
          .replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3')
      );
      if (opts.method) method = opts.method.toUpperCase();
      if (opts.body) body = opts.body
        .replace(/\{\{key\}\}/g, encoded)
        .replace(/\{\{keyword\}\}/g, encoded)
        .replace(/\{\{page\}\}/g, String(page));
    } catch (_e) { /* ignore */ }
  }

  url = url.trim();
  if (!url) return null;
  return { url, method, body };
}

/** CSS 提取（用 cheerio 模拟 HtmlParser CSS 提取） */
function extractWithCSS($, source, baseUrl) {
  const ruleList = source.ruleSearchList;
  const ruleName = source.ruleSearchName;
  const ruleAuthor = source.ruleSearchAuthor;
  const ruleCover = source.ruleSearchCover;
  const ruleNoteUrl = source.ruleSearchNoteUrl;

  if (!ruleList) return [];

  // 简化规则处理：主要支持 @css:、class.、id.、tag 等格式
  let cssSelector = ruleList;

  // 处理 Legado Default 规则 → CSS
  cssSelector = normalizeCssRule(cssSelector);

  const items = [];
  try {
    const $items = $(cssSelector);
    if ($items.length === 0) return [];

    $items.each((idx, el) => {
      const $el = $(el);

      // 提取书名
      let name = '';
      if (ruleName) {
        name = extractAttr($el, ruleName);
      }
      // 兜底：第一个 <a> 的文本
      if (!name) {
        const $a = $el.find('a').first();
        name = $a.text().trim();
      }
      // 兜底：元素自身文本
      if (!name) {
        name = $el.text().trim();
      }
      if (!name || name.length < 1) return;

      // 过滤
      if (name.length < 2 || name.length > 40) return;
      const cleaned = name.replace(/\s+作\s*者[:：\s].*$/g, '').replace(/\s+\S+\s+著\s*$/g, '').trim();
      if (!cleaned) return;
      if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(cleaned)) return;
      if (/^(最新章节|最后更新|今日更新)/.test(cleaned)) return;

      const navWords = ['首页','书架','分类','排行','榜单','完本','全本','免费',
        '会员','充值','登录','注册','关于','帮助','联系我们','投稿','我的',
        '个人中心','手机版','电脑版','客户端','推荐','公告','活动','合作','广告',
        '联系','QQ群','意见反馈','用户协议','隐私政策','免责声明','网站地图',
        '友情链接','设为首页','收藏本站','RSS','订阅','热门','随机','标签',
        '热门标签','全部小说','全部','设置','搜索','热搜','猜你喜欢',
        '上一页','下一页','尾页','首页','末页','返回','目录',
        '点击榜','推荐榜','月票榜','打赏榜','收藏榜','订阅榜',
        '玄幻小说','武侠小说','仙侠小说','都市小说','言情小说',
        '历史小说','军事小说','游戏小说','科幻小说','悬疑小说',
        '女生小说','男生小说','完本小说','最新小说','热门小说',
        '推荐小说','连载小说','免费小说','全本小说',
        '书名','作者','分类','状态','字数','更新','更新时间','最后更新',
        '最新章节','章节','简介','操作','查看','点击'];
      if (navWords.includes(cleaned)) return;
      if (/^(玄幻|武侠|仙侠|都市|言情|历史|军事|游戏|科幻|悬疑|奇幻|魔法|异界|穿越|重生|修真|言情|女生|男生|校园|青春|同人|轻小说|竞技|网游|耽美|百合|女频|男频|二次元|总裁|幻想)[a-zA-Z]/.test(cleaned)) return;
      if (/^(玄幻|仙侠|历史|科幻|都市|言情|武侠|奇幻|悬疑|网游|竞技|恐怖|灵异|军事|游戏|女生|男生|免费|完本|全本|排行|榜单|热门|推荐|分类|首页|书架|全部|连载|总裁|幻想)$/.test(cleaned)) return;

      // 提取作者
      let author = '';
      if (ruleAuthor) {
        author = extractAttr($el, ruleAuthor);
      }

      // 提取封面
      let coverUrl = '';
      if (ruleCover) {
        coverUrl = extractAttr($el, ruleCover);
      }
      if (!coverUrl) {
        const $img = $el.find('img').first();
        coverUrl = $img.attr('src') || $img.attr('data-src') || '';
      }

      // 提取详情页 URL
      let noteUrl = '';
      if (ruleNoteUrl) {
        noteUrl = extractAttr($el, ruleNoteUrl);
      }
      if (!noteUrl) {
        const $a = $el.find('a').first();
        noteUrl = $a.attr('href') || '';
      }
      if (!noteUrl) return;

      // 相对路径转绝对
      if (noteUrl && !noteUrl.startsWith('http')) {
        noteUrl = baseUrl + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      }
      if (coverUrl && !coverUrl.startsWith('http') && !coverUrl.startsWith('data:')) {
        coverUrl = baseUrl + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      }

      items.push({
        name: name,
        author,
        coverUrl,
        noteUrl,
        origin: source.bookSourceName,
      });
    });
  } catch (e) {
    console.warn(`    CSS error: ${e.message}`);
  }

  return items;
}

/** 归一化 Legado Default 规则到 CSS */
function normalizeCssRule(rule) {
  // 已经是 CSS 选择器格式
  if (rule.startsWith('@css:')) {
    return rule.slice(5);
  }

  // 处理 || 连接符（优先）
  if (rule.includes('||')) {
    return normalizeCssRule(rule.split('||')[0]);
  }

  // 处理 @ 分隔符
  rule = rule.replace(/@text\b/g, '');
  rule = rule.replace(/@href\b/g, '');
  rule = rule.replace(/@src\b/g, '');

  // @@class → .class
  rule = rule.replace(/@@/g, '.');

  // id.xxx → #xxx
  rule = rule.replace(/id\./g, '#');

  // .class@tag → .class tag
  rule = rule.replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');

  // 处理位置索引 a.0 → 保留
  // 处理排除索引 a!0 → 保留

  return rule;
}

/** 提取属性值 */
function extractAttr($el, rule) {
  let attrSuffix = 'text';
  let cssSel = rule;

  // 处理 @text, @href, @src, @html
  const attrMatch = rule.match(/^(.*?)@(text|href|src|html|ownText)$/i);
  if (attrMatch) {
    cssSel = attrMatch[1].trim();
    attrSuffix = attrMatch[2].toLowerCase();
  }

  // Normalize
  cssSel = normalizeCssRule(cssSel);

  if (!cssSel) {
    // 没有CSS选择器，直接从当前元素提取
    switch (attrSuffix) {
      case 'text': return $el.text().trim();
      case 'href': return $el.attr('href') || '';
      case 'src': return $el.attr('src') || '';
      case 'html': return $el.html() || '';
      default: return $el.text().trim();
    }
  }

  try {
    const $found = $el.find(cssSel);
    if ($found.length === 0) return '';

    const el = $found.first();
    switch (attrSuffix) {
      case 'text': return el.text().trim();
      case 'href': return el.attr('href') || '';
      case 'src': return el.attr('src') || '';
      case 'html': return el.html() || '';
      default: return el.text().trim();
    }
  } catch (_e) {
    return '';
  }
}

/**
 * 正则兜底提取（模拟 SourceExecutor.extractBookNamesFromHtml）
 */
function extractRegexFallback(html, baseUrl) {
  const items = [];
  const seen = new Set();

  function isBookPath(url) {
    return /(?:\/book\/|\/novel\/|\/read\/|\/txt\/|\/info\/|\/chapter\/|\d{5,})/i.test(url);
  }

  function isBookTitle(text) {
    if (!text || text.length < 2 || text.length > 40) return false;
    const cleaned = text
      .replace(/\s+作\s*者[:：\s].*$/g, '')
      .replace(/\s+\S+\s+著\s*$/g, '')
      .trim();
    if (!cleaned) return false;
    if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(cleaned)) return false;
    if (/最新[：:]\s*第/.test(cleaned) || /^(最新章节|最后更新|今日更新)/.test(cleaned)) return false;

    const commonNonBook = [
      '首页','书架','分类','排行','榜单','完本','全本','免费',
      '会员','充值','登录','注册','关于','帮助','联系我们','投稿','我的',
      '个人中心','手机版','电脑版','客户端','推荐','公告','活动','合作','广告',
      '联系','QQ群','意见反馈','用户协议','隐私政策','免责声明','网站地图',
      '友情链接','设为首页','收藏本站','RSS','订阅',
      '热门','随机','标签','热门标签',
      '玄幻小说','武侠小说','仙侠小说','都市小说','言情小说',
      '历史小说','军事小说','游戏小说','科幻小说','悬疑小说',
      '女生小说','男生小说','全部小说','完本小说','最新小说',
      '热门小说','推荐小说','连载小说','免费小说','全本小说',
      '我的书架','我的收藏','阅读记录','浏览记录','最近阅读','最近更新',
      '全部','全部小说','小说书库','临时书架','永久书架','网站首页',
      '设置','搜索','热搜','相关推荐','猜你喜欢',
      '新书推荐','强推','编辑推荐','精品推荐','重磅推荐',
      '上一页','下一页','尾页','首页','末页','返回','目录',
      '新书','完本感言','最新更新','今日更新','网友上传','网站公告',
      '点击榜','推荐榜','月票榜','打赏榜','收藏榜','订阅榜',
      '书库','其他小说','其它小说','推理小说','恐怖小说',
      '玄幻奇幻','武侠仙侠','奇幻玄幻','科幻灵异','网游竞技',
      '历史军事','都市言情','奇幻魔法','魔法校园','言情小说',
      '网游小说','穿越小说','修真小说',
      '玄幻魔法','武侠修真','恐怖灵异','侦探推理',
      '东方传奇','王朝争霸','江湖武侠','未来幻想','灵异鬼怪',
      '探险揭秘','历史传记','特种军旅','竞技','魔幻女强',
      '都市婚姻','百合之恋','同人美文','穿越架空','王室贵族',
      '乡土布衣','官职商战','间谍暗战','唯美言情','诗歌文集',
      '奇幻修真','异术超能',
      '饿狼小说','文桑小说','文桑视界',
      '就爱看文学网','就爱文学网','就爱文学',
      '蚂蚁文学','零零小说','独步小说网','必去小说网',
      '关于七猫','七猫招聘','七猫小说','七猫免费小说',
      '联系我们','关于我们','点此举报','网站公告',
      '书名','作者','分类','状态','字数','更新','更新时间','最后更新',
      '最新章节','章节','简介','操作','查看','点击','推荐',
    ];
    if (commonNonBook.some(w => cleaned === w)) return false;

    const cjkCount = (cleaned.match(/[\u4e00-\u9fff]/g) || []).length;
    if (cjkCount === 0) return false;
    if (/^[\d\s.．\-—·,，。、：:？?!！…]+$/.test(cleaned)) return false;

    return true;
  }

  // 1. 从 <h2>/<h3>/<h4> 中的 <a> 提取
  const headerRegex = /<h([2-4])[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,50})<\/a>[\s]*<\/h\1>/gi;
  let match;
  while ((match = headerRegex.exec(html)) !== null) {
    const text = match[3].trim();
    let linkUrl = match[2].trim();
    if (isBookTitle(text) && !seen.has(text)) {
      if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
      seen.add(text);
      if (linkUrl && !linkUrl.startsWith('http')) {
        linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
      }
      items.push({ name: text, url: linkUrl });
    }
  }

  // 2. 从 <li>/<dd>/<div>/<p>/<span> 内的 <a> 提取
  const linkRegex = /<(?:li|dd|div|p|span)[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,40})<\/a>/gi;
  while ((match = linkRegex.exec(html)) !== null) {
    const text = match[2].trim();
    let linkUrl = match[1].trim();
    if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
    if (isBookTitle(text) && (isBookPath(linkUrl) || !seen.has(text))) {
      if (!seen.has(text)) {
        seen.add(text);
        if (linkUrl && !linkUrl.startsWith('http')) {
          linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
        }
        items.push({ name: text, url: linkUrl });
      }
    }
  }

  // 3. 普通 <a> 标签（仅当结果不足且 URL 像书籍路径）
  if (items.length < 3) {
    const plainRegex = /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,30})<\/a>/gi;
    while ((match = plainRegex.exec(html)) !== null) {
      const text = match[2].trim();
      let linkUrl = match[1].trim();
      if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
      if (isBookTitle(text) && isBookPath(linkUrl) && !seen.has(text)) {
        seen.add(text);
        if (linkUrl && !linkUrl.startsWith('http')) {
          linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
        }
        items.push({ name: text, url: linkUrl });
      }
    }
  }

  return items.slice(0, 30);
}

/** 从 HTML 中提取第一张图片 */
function extractFirstImg(html) {
  const m = html.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
  return m ? m[1] : '';
}

/** 获取 JSON path 的值 */
function getJsonPath(obj, path) {
  if (!path || !obj) return undefined;
  const parts = path.replace(/^\$\.?/, '').split(/\./);
  let current = obj;
  for (const part of parts) {
    if (current == null) return undefined;
    // 处理 [*] 或 [n]
    const arrayMatch = part.match(/^(\w+)(?:\[(\d+|\*)])?$/);
    if (arrayMatch) {
      const key = arrayMatch[1];
      const index = arrayMatch[2];
      if (Array.isArray(current)) {
        if (index === '*') {
          // 取数组第一个
          current = current[0]?.[key];
        } else if (index !== undefined) {
          current = current[parseInt(index)]?.[key];
        } else {
          current = current[0]?.[key];
        }
      } else {
        current = current[key];
      }
    } else if (part === '*') {
      // 数组遍历
      if (Array.isArray(current)) {
        current = current[0];
      }
    } else {
      current = current[part];
    }
  }
  return current;
}

/** JSON 搜索提取（API 类书源） */
function extractJsonResults(json, source, baseUrl) {
  const ruleList = source.ruleSearchList;
  const ruleName = source.ruleSearchName;
  const ruleAuthor = source.ruleSearchAuthor;
  const ruleCover = source.ruleSearchCover;
  const ruleNoteUrl = source.ruleSearchNoteUrl;

  let list = null;
  if (ruleList) {
    const raw = getJsonPath(json, ruleList);
    if (Array.isArray(raw)) list = raw;
  }
  if (!list) {
    if (Array.isArray(json)) { list = json; } else {
      for (const p of ['data', 'list', 'items', 'results', 'books']) {
        const raw = json[p];
        if (Array.isArray(raw)) { list = raw; break; }
      }
    }
  }
  if (!list) return [];

  return list.map((item) => {
    const name = getJsonPath(item, ruleName) || item.novelName || item.name || item.title || item.bookName || '';
    const author = getJsonPath(item, ruleAuthor) || item.authorName || item.author || '';
    const coverUrl = getJsonPath(item, ruleCover) || item.cover || item.coverUrl || item.cover_url || item.pic || item.img || '';
    let noteUrl = getJsonPath(item, ruleNoteUrl) || item.noteUrl || item.bookUrl || item.novelId || item.id || item.url || '';
    if (noteUrl && !noteUrl.startsWith('http') && !/^\d+$/.test(noteUrl)) {
      noteUrl = baseUrl + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
    }
    return { name: String(name), author: String(author), coverUrl: String(coverUrl), noteUrl: String(noteUrl) };
  }).filter(i => i.name && i.name !== 'undefined');
}

// ========== 主逻辑 ==========

async function fetchUrl(url, method = 'GET', body = null) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const options = {
      method,
      signal: controller.signal,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': 'text/html,application/json,*/*',
      }
    };
    if (body && method === 'POST') {
      options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
      options.body = body;
    }

    const resp = await fetch(url, options);
    const text = await resp.text();
    return text;
  } finally {
    clearTimeout(timeout);
  }
}

async function testSearch() {
  console.log('========================================');
  console.log(`搜索测试: "${SEARCH_KEYWORD}"`);
  console.log('========================================\n');

  const raw = fs.readFileSync(SOURCES_FILE, 'utf-8');
  const allSources = JSON.parse(raw);
  console.log(`总书源数: ${allSources.length}\n`);

  // 只测试有 searchUrl 且启用的
  const searchable = allSources.filter(s =>
    s.searchUrl &&
    s.enabled !== false
  );
  console.log(`有搜索能力的源: ${searchable.length}\n`);

  // 结果统计
  const stats = {
    cssOk: 0,
    cssZero: 0,
    regexOk: 0,
    regexZero: 0,
    jsonOk: 0,
    byRegexReason: [], // 哪些源靠正则救回来的
    byCssReason: [],
    failed: 0,
  };

  // 限制并发数
  const concurrency = 5;
  let idx = 0;

  async function nextSource() {
    while (idx < searchable.length) {
      const i = idx++;
      const source = searchable[i];

      // 安全地展开字段
      const ruleSearch = source.ruleSearch || {};
      const flattend = {
        bookSourceName: source.bookSourceName || 'unnamed',
        bookSourceUrl: source.bookSourceUrl || '',
        // searchUrl 在顶层，不在 ruleSearch 内
        ruleSearchUrl: source.searchUrl || ruleSearch.searchUrl || '',
        ruleSearchList: ruleSearch.bookList || ruleSearch.list || '',
        ruleSearchName: ruleSearch.name || '',
        ruleSearchAuthor: ruleSearch.author || '',
        ruleSearchCover: ruleSearch.coverUrl || ruleSearch.cover || '',
        ruleSearchNoteUrl: ruleSearch.bookUrl || ruleSearch.noteUrl || '',
      };

      // 跳过 API/JSON 源（用 searchName 含 $. 或 @json: 来判断）
      const isJsonSource = flattend.ruleSearchList && (
        flattend.ruleSearchList.startsWith('$.') ||
        flattend.ruleSearchList.startsWith('@json:')
      );

      const baseUrl = getBaseUrl(flattend.bookSourceUrl);
      const built = buildSearchUrl(flattend.ruleSearchUrl, SEARCH_KEYWORD, 1, baseUrl);

      if (!built) {
        console.log(`[${i + 1}/${searchable.length}] ${flattend.bookSourceName} — ⏭️ URL 构建失败`);
        stats.failed++;
        continue;
      }

      process.stdout.write(`[${i + 1}/${searchable.length}] ${flattend.bookSourceName}... `);

      try {
        const body = await fetchUrl(built.url, built.method, built.body);

        if (!body || body.length < 100) {
          console.log(`❌ 响应为空或太短 (${body?.length || 0} bytes)`);
          stats.failed++;
          continue;
        }

        // 判断是否是 JSON 响应
        let isJson = false;
        let jsonObj = null;

        if (isJsonSource || body.trimStart().startsWith('[') || body.trimStart().startsWith('{')) {
          try {
            jsonObj = JSON.parse(body);
            isJson = true;
          } catch (_e) { /* not JSON */ }
        }

        // ===== 方式 1: JSON 提取 =====
        let cssResults = [];
        if (jsonObj) {
          cssResults = extractJsonResults(jsonObj, flattend, baseUrl);
          if (cssResults.length > 0) {
            stats.jsonOk++;
          }
        }

        // ===== 方式 2: CSS 提取 =====
        let cssOnlyResults = [];
        if (!isJson && flattend.ruleSearchList && cssResults.length === 0) {
          const $ = cheerio.load(body);
          cssOnlyResults = extractWithCSS($, flattend, baseUrl);
        }

        // 合并
        if (cssResults.length > 0) {
          // 已经是 JSON 结果
        } else if (cssOnlyResults.length > 0) {
          cssResults = cssOnlyResults;
        }

        // ===== 方式 3: 正则兜底 =====
        const regexResults = extractRegexFallback(body, baseUrl);

        // 判断是否有匹配关键词的结果
        const keywordMatchCSS = cssResults.filter(r =>
          r.name.includes(SEARCH_KEYWORD) || r.name.includes('四合院')
        );
        const keywordMatchRegex = regexResults.filter(r =>
          r.name.includes(SEARCH_KEYWORD) || r.name.includes('四合院')
        );

        // 分析
        if (cssResults.length > 0) {
          stats.cssOk++;
          if (regexResults.length > 0 && regexResults.length !== cssResults.length) {
            // CSS 有结果，正则兜底也有不同结果
          }
          console.log(`✅ CSS=${cssResults.length}${keywordMatchCSS.length > 0 ? ` (含目标=${keywordMatchCSS.length})` : ''}${regexResults.length > cssResults.length ? ` 正则=${regexResults.length} (额外+${regexResults.length - cssResults.length})` : ''}`);
        } else if (regexResults.length > 0) {
          stats.cssZero++;
          stats.regexOk++;
          stats.byRegexReason.push(flattend.bookSourceName);
          console.log(`🔴 CSS=0 ❌ 但正则救回=${regexResults.length}${keywordMatchRegex.length > 0 ? ` (含目标=${keywordMatchRegex.length})` : ''} ✅ ← 修复生效`);
        } else {
          stats.cssZero++;
          console.log(`❌ CSS=0, 正则=0`);
        }
      } catch (e) {
        console.log(`❌ 错误: ${e.message?.substring(0, 80) || e.code || e}`);
        stats.failed++;
      }
    }
  }

  // 并发运行
  const workers = Array(concurrency).fill().map(() => nextSource());
  await Promise.all(workers);

  // 输出统计
  console.log('\n========================================');
  console.log('统计结果');
  console.log('========================================');
  console.log(`可搜索源:         ${searchable.length}`);
  console.log(`CSS 提取成功:     ${stats.cssOk} 个`);
  console.log(`CSS 提取失败(0):  ${stats.cssZero} 个`);
  console.log(`正则兜底救回:     ${stats.regexOk} 个`);
  console.log(`请求失败:         ${stats.failed} 个`);
  console.log(`\n正则兜底救回的源 (${stats.byRegexReason.length}):`);
  stats.byRegexReason.forEach(s => console.log(`  - ${s}`));
  console.log();
}

async function testAuthorExtraction() {
  console.log('\n========================================');
  console.log('作者提取测试');
  console.log('========================================\n');

  const raw = fs.readFileSync(SOURCES_FILE, 'utf-8');
  const allSources = JSON.parse(raw);

  // 找有 ruleBookInfo.author 的源
  const withAuthorRule = allSources.filter(s =>
    s.ruleBookInfo?.author ||
    (typeof s.ruleBookInfoAuthor === 'string' && s.ruleBookInfoAuthor)
  );
  console.log(`有 ruleBookInfoAuthor 的源: ${withAuthorRule.length} 个\n`);

  // 取前 10 个测试（划分 JSON 源和 HTML 源）
  let tested = 0;
  let success = 0;
  let fail = 0;
  const testSources = withAuthorRule.slice(0, 12);

  for (const source of testSources) {
    const ruleBookInfo = source.ruleBookInfo || {};
    const authorRule = ruleBookInfo.author || '';
    const nameRule = ruleBookInfo.name || '';

    console.log(`[${++tested}] ${source.bookSourceName}`);
    console.log(`  作者规则: ${authorRule}`);
    console.log(`  书名规则: ${nameRule}`);
    if (!authorRule) {
      console.log('  ⏭️  无 author 规则，跳过\n');
      continue;
    }

    // 判读是否为 JSON API 源
    const isJsonApi = !!(authorRule.startsWith('$.') || authorRule.startsWith('@json:'));

    const ruleSearchUrl = source.searchUrl || '';
    if (!ruleSearchUrl) {
      console.log('  ⏭️  无搜索 URL，跳过\n');
      continue;
    }

    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const built = buildSearchUrl(ruleSearchUrl, SEARCH_KEYWORD, 1, baseUrl);
    if (!built) {
      console.log('  ⏭️  搜索 URL 构建失败\n');
      continue;
    }

    try {
      const searchBody = await fetchUrl(built.url, built.method, built.body);
      if (!searchBody || searchBody.length < 100) {
        console.log('  ⏭️  搜索无响应\n');
        continue;
      }

      // 尝试从搜索结果中提取第一个详情页 URL 和作者
      let detailUrl = '';
      let bookName = '';
      let searchAuthor = ''; // 搜索结果中已有作者

      // 方式 A：JSON 提取（API 源）
      let isJsonResponse = false;
      if (searchBody.trimStart().startsWith('{') || searchBody.trimStart().startsWith('[')) {
        try {
          const json = JSON.parse(searchBody);
          isJsonResponse = true;

          // 用 JSON path 从搜索结果提取
          const rs = source.ruleSearch || {};
          const results = extractJsonResults(json, {
            ...source,
            ruleSearchList: rs.bookList || rs.list || '$.data',
            ruleSearchName: rs.name || nameRule,
            ruleSearchAuthor: rs.author || '',
            ruleSearchCover: rs.coverUrl || '',
            ruleSearchNoteUrl: rs.bookUrl || '',
          }, baseUrl);

          if (results.length > 0) {
            detailUrl = results[0].noteUrl;
            bookName = results[0].name;
            searchAuthor = results[0].author;
            console.log(`  搜索作者: ${searchAuthor || '(空)'}`);
          }
        } catch (_e) {}
      }

      // 方式 B：CSS 提取（HTML 源）
      if (!detailUrl) {
        const $ = cheerio.load(searchBody);
        const rs = source.ruleSearch || {};
        const results = extractWithCSS($, {
          bookSourceName: source.bookSourceName,
          bookSourceUrl: source.bookSourceUrl,
          ruleSearchList: rs.bookList || rs.list || '',
          ruleSearchName: rs.name || '',
          ruleSearchAuthor: rs.author || '',
          ruleSearchCover: rs.coverUrl || '',
          ruleSearchNoteUrl: rs.bookUrl || '',
        }, baseUrl);

        if (results.length > 0) {
          detailUrl = results[0].noteUrl;
          bookName = results[0].name;
          searchAuthor = results[0].author;
          console.log(`  搜索作者: ${searchAuthor || '(空)'}`);
        }
      }

      if (!detailUrl && !isJsonApi) {
        console.log('  ⏭️  无法从搜索结果找到详情页 URL\n');
        continue;
      }

      // 对于 JSON API 源，搜索结果本身就有完整的信息，直接验证作者提取
      if (isJsonApi && isJsonResponse) {
        if (searchAuthor) {
          console.log(`  ✅ 作者直接从 JSON 搜索结果提取成功: "${searchAuthor}"`);
          success++;
        } else {
          console.log('  ❌ 作者提取失败（JSON 搜索结果中无 author）');
          fail++;
        }
        console.log();
        continue;
      }

      // 对于 HTML 源：需要抓取详情页并验证 ruleBookInfo 提取
      if (detailUrl) {
        console.log(`  详情页: ${detailUrl}`);
        console.log(`  书名: ${bookName}`);

        const detailBody = await fetchUrl(detailUrl);
        if (!detailBody || detailBody.length < 200) {
          console.log('  ⏭️  详情页响应为空或太短\n');
          continue;
        }

        // 判读详情页是否为 JSON
        let detailIsJson = false;
        let detailJson = null;
        if (detailBody.trimStart().startsWith('{') || detailBody.trimStart().startsWith('[')) {
          try {
            detailJson = JSON.parse(detailBody);
            detailIsJson = true;
          } catch (_e) {}
        }

        // 提取作者
        let extractedAuthor = '';
        if (detailIsJson) {
          // JSONPath 提取
          const path = authorRule.replace(/^@json:/, '');
          extractedAuthor = String(getJsonPath(detailJson, path) || '');
        } else {
          // CSS 提取
          const $ = cheerio.load(detailBody);
          extractedAuthor = extractAttr($('body'), authorRule);
        }

        // 提取书名
        let extractedName = bookName;
        if (nameRule && detailIsJson) {
          const path = nameRule.replace(/^@json:/, '');
          extractedName = String(getJsonPath(detailJson, path) || bookName);
        } else if (nameRule && !detailIsJson) {
          const $ = cheerio.load(detailBody);
          const n = extractAttr($('body'), nameRule);
          if (n) extractedName = n;
        }

        if (extractedAuthor) {
          console.log(`  ✅ 作者提取成功: "${extractedAuthor}" （书名: ${extractedName}）`);
          success++;
        } else {
          const reason = detailIsJson ? 'JSONPath 未匹配' : 'CSS 选择器未匹配';
          console.log(`  ❌ 作者提取失败: ${reason} (规则: ${authorRule})`);
          fail++;
        }
      } else {
        // 如果能搜到结果但没有 detailUrl
        console.log('  ⏭️  无详情页 URL\n');
        continue;
      }

      console.log();
    } catch (e) {
      console.log(`  ❌ 错误: ${e.message?.substring(0, 100)}\n`);
      fail++;
    }
  }

  console.log('----------------------------------------');
  console.log(`作者提取测试完成: ${success} 成功, ${fail} 失败`);
}

// ========== 运行 ==========

async function main() {
  // 测试 1: 搜索结果对比
  await testSearch();

  // 测试 2: 作者提取
  await testAuthorExtraction();
}

main().catch(console.error);
