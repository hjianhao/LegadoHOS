/**
 * AI 书源配置生成器
 *
 * 自动分析网站结构，生成 Legado 格式书源配置
 *
 * 流程：
 *   首页 → 定位搜索表单 → 测试搜索 → 分析结果页 →
 *   生成搜索规则 → 跟入详情页 → 生成详情/目录/内容规则 →
 *   检测分页 → 输出完整配置
 *
 * 用法：
 *   node test/ai_source_generator.mjs [源名称关键词]
 *   不加参数则分析所有需修复的源
 */
import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 15000;
const KEYWORD = '冲出四合院';

// ============ HTTP 工具 ============

async function fetch(url, method = 'GET', body = null, headers = {}) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      ...headers,
    };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
      o.body = body;
    }
    const r = await globalThis.fetch(url, o);
    return { status: r.status, text: await r.text(), ok: r.ok };
  } catch (e) {
    return { status: 0, text: '', ok: false, error: e.message };
  } finally {
    clearTimeout(t);
  }
}

// ============ 选择器探测 ============

/** 常见容器选择器（按优先级） */
const CONTAINER_SELECTORS = [
  'li', 'tr', 'dd', 'dl dd', 'ul li',
  'div[class*="item"]', 'div[class*="book"]', 'div[class*="result"]',
  'div[class*="search"]', 'div[class*="list"]',
  'tbody tr', '.bookbox', '.hot_sale',
  '.txt-list-row5 li', '.novelslist2 li',
  '.search-list li', '.list li',
];

/** 判断一个 URL 是否像是书籍链接 */
function isBookUrl(url) {
  if (!url || url.startsWith('#') || url.startsWith('javascript:')) return false;
  return /\.html|\/book\/|\/novel\/|\/read\/|\/info\/|\/txt\/|\d{5,}/i.test(url);
}

/** 判断文本是否像是书名 */
function isBookTitle(text) {
  if (!text || text.length < 2 || text.length > 40) return false;
  if (/^第[一二三四五六七八九十\d零○]/.test(text)) return false;
  if (/^[\d\s.．\-—·,，。、：:？?!！…a-zA-Z/.]+$/.test(text)) return false;
  const bad = new Set(['首页','书架','分类','排行','榜单','完本','全本','免费','登录','注册',
    '上一页','下一页','尾页','目录','返回','搜索','推荐','公告','设置','全部',
    '完本感言','作者的话','作家的话','新书推荐','热门推荐','相关推荐',
    '开始阅读','TXT下载','加入书架','推荐此书']);
  if (bad.has(text)) return false;
  if (!/[\u4e00-\u9fff]/.test(text)) return false;
  return true;
}

/** 探测页面中正确的容器选择器 */
function detectContainer($, keyword) {
  const results = [];
  for (const sel of CONTAINER_SELECTORS) {
    try {
      const els = $(sel);
      if (els.length < 2 || els.length > 200) continue;
      let bookLinks = 0, hasImg = 0, hasKeyword = 0;
      els.each((i, el) => {
        const href = $(el).find('a').first().attr('href') || '';
        if (isBookUrl(href)) bookLinks++;
        if ($(el).find('img').length > 0) hasImg++;
        if ($(el).text().includes(keyword)) hasKeyword++;
      });
      if (bookLinks >= 2) {
        results.push({ sel, total: els.length, bookLinks, hasImg, hasKeyword,
          score: bookLinks * 3 + hasImg * 2 + hasKeyword * 10 });
      }
    } catch (_) { /* ignore */ }
  }
  results.sort((a, b) => b.score - a.score);
  return results[0] || null;
}

/** 从容器元素中探测子规则 */
function detectSubRules($, containerEl) {
  const firstA = $(containerEl).find('a').first();
  const firstHref = firstA.attr('href') || '';
  const allAs = $(containerEl).find('a');
  const allSpans = $(containerEl).find('span, small, em, i');
  const imgs = $(containerEl).find('img');

  // 书名：找最有意义的文本链接
  let nameRule = 'a.0@text';
  const nameCandidates = [];
  allAs.each((i, a) => {
    const text = $(a).text().trim();
    const href = $(a).attr('href') || '';
    if (isBookTitle(text) && isBookUrl(href)) {
      nameCandidates.push({ idx: i, text, href, score: text.length });
    }
  });
  // 优先选文本最长的（通常是书名）
  nameCandidates.sort((a, b) => b.score - a.score);
  if (nameCandidates.length > 0) {
    const best = nameCandidates[0];
    nameRule = `a.${best.idx}@text`;
    // 如果找到的 a 在特定容器里，用更精确的选择器
    const parent = $(allAs[best.idx]).parent().prop('tagName')?.toLowerCase();
    if (parent && ['h2','h3','h4','h5','h1','dt','strong','b'].includes(parent)) {
      nameRule = `${parent} a@text`;
    }
  }

  // 作者：找短文本的 span 或 a
  let authorRule = '';
  const authorCandidates = [];
  // 从 span 中找
  allSpans.each((i, sp) => {
    const text = $(sp).text().trim();
    if (text.length >= 2 && text.length <= 8 && /[\u4e00-\u9fff]/.test(text) &&
        !['连载中','已完结','已完本'].includes(text)) {
      authorCandidates.push({ el: 'span', idx: i, text, score: 10 - text.length });
    }
  });
  // 从 a 中找（找短的 like "七五三幺"）
  allAs.each((i, a) => {
    const text = $(a).text().trim();
    if (text.length >= 2 && text.length <= 6 && isBookUrl($(a).attr('href') || '') === false &&
        !nameCandidates.some(n => n.idx === i)) {
      authorCandidates.push({ el: 'a', idx: i, text, score: 5 - text.length });
    }
  });
  authorCandidates.sort((a, b) => b.score - a.score);
  if (authorCandidates.length > 0) {
    const best = authorCandidates[0];
    authorRule = `${best.el}.${best.idx}@text`;
  } else {
    authorRule = 'span.0@text';
  }

  // 封面图
  let coverRule = '';
  if (imgs.length > 0) {
    const firstImg = imgs.first();
    const src = firstImg.attr('src') || firstImg.attr('data-src') || firstImg.attr('data-original') || '';
    if (src && src.length > 10) {
      coverRule = 'img.0@src';
    }
  }

  // 书籍 URL
  let bookUrlRule = '';
  if (nameCandidates.length > 0) {
    const best = nameCandidates[0];
    bookUrlRule = `a.${best.idx}@href`;
  } else if (firstHref && isBookUrl(firstHref)) {
    bookUrlRule = 'a.0@href';
  }

  return { nameRule, authorRule, coverRule, bookUrlRule };
}

// ============ URL 构建 ============

function getBaseUrl(raw) {
  return raw ? raw.replace(/##.*$/, '').replace(/\/+$/, '') : '';
}

function buildSearchUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const enc = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '')
    .replace(/\{key\}/g, enc).replace(/\{\{key\}\}/g, enc)
    .replace(/\{\{keyword\}\}/g, enc)
    .replace(/\{\{page\}\}/g, page).replace(/\{\{pageNum\}\}/g, page + 1);
  url = url.replace(/\{\{[^}]*\}\}/g, '').replace(/<js>[\s\S]*?<\/js>/gi, '');
  url = url.replace(/\n\s*\n/g, '\n').replace(/\n\s*/g, '');
  // Strip @js: blocks
  while (url.includes('@js:')) {
    const ji = url.indexOf('@js:');
    const jo = url.indexOf(',{', ji);
    url = jo > ji ? url.substring(0, ji) + url.substring(jo) : url.substring(0, ji);
  }
  const pg = url.match(/<([^<>]+)>/);
  if (pg) {
    const items = pg[1].split(',');
    url = url.replace(pg[0], items[Math.min(page - 1, items.length - 1)].trim());
  }
  let jr = '';
  const jm = url.match(/^(.+?),?\s*(\{[\s\S]*\})$/);
  if (jm) { url = jm[1].trim(); jr = jm[2]; }
  if (!url.startsWith('http') && baseUrl) {
    url = baseUrl.replace(/\/+$/, '') + (url.startsWith('/') ? url : '/' + url);
  }
  let method = 'GET', body = '';
  if (jr) {
    try {
      const cleaned = jr.replace(/'/g, '"').replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3');
      const o = JSON.parse(cleaned);
      if (o.method) method = o.method.toUpperCase();
      if (o.body) body = o.body.replace(/\{\{key\}\}/g, enc).replace(/\{\{keyword\}\}/g, enc);
    } catch (_) { /* ignore parse errors */ }
  }
  return url.trim() ? { url: url.trim(), method, body } : null;
}

// ============ 主流程 ============

async function analyzeSource(source, keyword = KEYWORD) {
  const name = source.bookSourceName || '未知';
  const searchUrl = source.searchUrl || source.ruleSearchUrl || '';
  const baseUrl = getBaseUrl(source.bookSourceUrl || '');

  console.log(`\n========== ${name} ==========`);

  // Step 1: 尝试搜索
  const built = buildSearchUrl(searchUrl, keyword, 1, baseUrl);
  if (!built) {
    console.log('  ⏭️ @js: 搜索 URL，跳过');
    return null;
  }

  const resp = await fetch(built.url, built.method, built.body);
  if (!resp.ok || !resp.text || resp.text.length < 200) {
    console.log(`  ⏭️ 搜索失败 (HTTP ${resp.status}, ${resp.text?.length || 0} bytes)`);
    return null;
  }

  console.log(`  搜索 OK: ${resp.text.length} bytes`);
  const $ = cheerio.load(resp.text);
  const hasKeyword = resp.text.includes(keyword);

  // Step 2: 探测选择器
  const container = detectContainer($, keyword);
  if (!container) {
    console.log('  ❌ 未找到合适的容器选择器');
    return null;
  }

  // 转 Legado 格式（@ 代替 >）
  let bookList = container.sel.replace(/ > /g, '@');
  // 排除表头行
  if (bookList === 'tr' && container.total > 2) bookList = 'tr!0';
  if (bookList === 'tbody@tr' && container.total > 2) bookList = 'tbody@tr!0';

  // Step 3: 采样前几个容器元素，探测子规则
  const sample = $(container.sel).first();
  const sub = detectSubRules($, sample);

  const fix = {
    bookList,
    name: sub.nameRule,
    author: sub.authorRule,
    coverUrl: sub.coverRule,
    bookUrl: sub.bookUrlRule,
    hasKeyword,
    containerScore: container.score,
    responseSize: resp.text.length,
  };

  console.log(`  ${hasKeyword ? '✅' : '❌'} 含关键词 | 容器="${bookList}" (评分:${container.score})`);
  console.log(`  子规则: name=${sub.nameRule} author=${sub.authorRule} cover=${sub.coverRule} url=${sub.bookUrlRule}`);

  // Step 4: 如果有结果且含关键词，尝试跟入详情页
  if (hasKeyword && sub.bookUrlRule) {
    try {
      const firstItem = $(container.sel).first();
      const detailUrl = extractAttr(firstItem, sub.bookUrlRule);
      if (detailUrl && detailUrl.startsWith('http')) {
        console.log(`  尝试分析详情页: ${detailUrl.substring(0, 60)}...`);
        const detail = await analyzeDetail(detailUrl, baseUrl, keyword);
        if (detail) Object.assign(fix, detail);
      }
    } catch (_) { /* ignore detail errors */ }
  }

  return fix;
}

/** 从容器元素和规则中提取属性值 */
function extractAttr(container, rule) {
  if (!rule) return '';
  const $ = cheerio.load(container);
  const attrMatch = rule.match(/^(.*?)@(text|href|src|html|ownText)$/i);
  const cssPart = attrMatch ? attrMatch[1].trim() : rule.trim();
  const attrSuffix = attrMatch ? attrMatch[2].toLowerCase() : 'text';

  // Handle position index
  const posMatch = cssPart.match(/^([a-zA-Z*][a-zA-Z0-9_-]*)?\.(\d+)$/);
  let elements;
  if (posMatch) {
    const tag = posMatch[1] || '*';
    const idx = parseInt(posMatch[2]);
    elements = $(container).find(tag);
    if (idx < elements.length) {
      const el = elements[idx];
      if (attrSuffix === 'href') return $(el).attr('href') || '';
      if (attrSuffix === 'src') return $(el).attr('src') || '';
      if (attrSuffix === 'html') return $(el).html() || '';
      return $(el).text().trim();
    }
    return '';
  }

  elements = $(container).find(cssPart);
  if (elements.length === 0) return '';
  const el = elements[0];
  if (attrSuffix === 'href') return $(el).attr('href') || '';
  if (attrSuffix === 'src') return $(el).attr('src') || '';
  if (attrSuffix === 'html') return $(el).html() || '';
  return $(el).text().trim();
}

/** 分析书籍详情页，生成 bookInfo/toc/content 规则 */
async function analyzeDetail(detailUrl, baseUrl, keyword) {
  // 详细信息页面分析比较复杂，这里先做简化版本
  // TODO: 完整的详情/目录/内容分析
  return null;
}

// ============ 主入口 ============

async function main() {
  const targetFilter = process.argv[2]; // 可选：指定源名称关键词

  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const sources = JSON.parse(raw);
  const updated = JSON.parse(raw);
  let fixed = 0, skipped = 0, failed = 0;

  // 要分析的源：全部或指定
  const targets = targetFilter
    ? sources.filter(s => (s.bookSourceName || '').includes(targetFilter))
    : sources;

  console.log(`分析 ${targets.length}/${sources.length} 个源...`);
  console.log(`搜索关键词: "${KEYWORD}"`);

  for (const source of targets) {
    const name = source.bookSourceName || '未知';

    // 跳过 @js: URL（无法在 Node.js 中执行）
    const searchUrl = source.searchUrl || source.ruleSearchUrl || '';
    if (searchUrl.trimStart().startsWith('@js:')) {
      console.log(`  ⏭️ ${name}: @js: URL 跳过`);
      skipped++;
      continue;
    }

    const result = await analyzeSource(source);
    if (!result) {
      failed++;
      continue;
    }

    // 更新规则
    const idx = updated.findIndex(s => (s.bookSourceName || '') === name);
    if (idx >= 0) {
      if (!updated[idx].ruleSearch) updated[idx].ruleSearch = {};
      updated[idx].ruleSearch.bookList = result.bookList;
      if (result.name) updated[idx].ruleSearch.name = result.name;
      if (result.author) updated[idx].ruleSearch.author = result.author;
      if (result.coverUrl) updated[idx].ruleSearch.coverUrl = result.coverUrl;
      if (result.bookUrl) updated[idx].ruleSearch.bookUrl = result.bookUrl;
      fixed++;
    }
  }

  console.log(`\n========== 汇总 ==========`);
  console.log(`修复: ${fixed} | 跳过(@js:): ${skipped} | 失败: ${failed} | 总计: ${targets.length}`);

  if (fixed > 0) {
    const outPath = path.resolve(__dirname, 'source_ai_generated.json');
    fs.writeFileSync(outPath, JSON.stringify(updated, null, 2), 'utf-8');
    console.log(`\n✅ 输出: source_ai_generated.json`);
    console.log(`使用: cp test/source_ai_generated.json test/source.json`);
  }
}

main().catch(console.error);
