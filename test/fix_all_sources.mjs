/**
 * 全面分析所有 CSS 失效源，修复选择器和子规则
 * 自动抓取搜索页 → 分析 HTML 结构 → 生成正确配置
 */
import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 15000;
const KEYWORD = '冲出四合院';

function getBaseUrl(raw) { return raw ? raw.replace(/##.*$/, '').replace(/\/+$/, '') : ''; }

function buildUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const enc = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '')
    .replace(/\{key\}/g, enc).replace(/\{\{key\}\}/g, enc)
    .replace(/\{\{keyword\}\}/g, enc)
    .replace(/\{\{page\}\}/g, page).replace(/\{\{pageNum\}\}/g, page + 1);
  url = url.replace(/\{\{[^}]*\}\}/g, '').replace(/<js>[\s\S]*?<\/js>/gi, '');
  url = url.replace(/\n\s*\n/g, '\n').replace(/\n\s*/g, '');
  while (url.includes('@js:')) {
    const ji = url.indexOf('@js:'); const jo = url.indexOf(',{', ji);
    url = jo > ji ? url.substring(0, ji) + url.substring(jo) : url.substring(0, ji);
  }
  const pg = url.match(/<([^<>]+)>/);
  if (pg) { const items = pg[1].split(','); url = url.replace(pg[0], items[Math.min(page - 1, items.length - 1)].trim()); }
  let jr = '';
  const jm = url.match(/^(.+?),?\s*(\{[\s\S]*\})$/);
  if (jm) { url = jm[1].trim(); jr = jm[2]; }
  if (!url.startsWith('http') && baseUrl) url = baseUrl.replace(/\/+$/, '') + (url.startsWith('/') ? url : '/' + url);
  let method = 'GET', body = '';
  if (jr) {
    try {
      let cleaned = jr.replace(/'/g, '"').replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3');
      const o = JSON.parse(cleaned);
      if (o.method) method = o.method.toUpperCase();
      if (o.body) body = o.body.replace(/\{\{key\}\}/g, enc).replace(/\{\{keyword\}\}/g, enc);
    } catch (_) {}
  }
  return url.trim() ? { url: url.trim(), method, body } : null;
}

async function doFetch(u, method = 'GET', body = null) {
  const c = new AbortController(); const t = setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = { 
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(t); }
}

// 候选选择器（按优先级）
const CANDIDATES = [
  'li', 'tr', 'dd', 'dl dd', 'ul li', 'div[class*="item"]', 'div[class*="book"]',
  'div[class*="result"]', 'div[class*="search"]', 'div[class*="list"]',
  'tbody tr', '.bookbox', '.hot_sale', '.txt-list-row5 li', '.novelslist2 li',
  '.search-list li', '.list li', '.result-item', '.search-item',
];

// 从日志中筛选出 CSS=0 但返回有效 HTML 的源
const BROKEN_SOURCES = [
  '🎉 狗狗书籍', '🎉 饿狼小说', '🎉 七猫小说', '🎉 抖音小说',
  '🎉 唐三中文', '🎉 手机小说', '🎉 歌书小说', '🎉 黄易小说',
  '🎉 必去小说', '🎉 乐文阁网', '🎉 香书小说', '🎉 小说三千',
  '💠 笔趣阁22', '💠 八一中文', '💐 ＵＣ书库', '💠 女生文学',
  '💠 零零小说', '💠 文桑小说', '💠 书满屋网', '💠 亿软小说',
  '📚 中华典藏', '💠 猪猪书网', '📚 参考期刊', '💠 玄幻阁网',
  '💠 乐库小说',
];

// 已知子规则模板
function guessSubRules($, container, baseUrl) {
  const html = $(container).html() || '';
  const firstA = $(container).find('a').first();
  const firstHref = firstA.attr('href') || '';
  const allAs = $(container).find('a');
  
  let nameRule = 'a.0@text';
  let authorRule = 'a.0@text';
  let urlRule = 'a.0@href';
  let coverRule = 'img.0@src';
  
  // 如果有多个a标签，尝试区分书名和作者
  if (allAs.length >= 2) {
    const a0 = $(allAs[0]).text().trim();
    const a1 = $(allAs[1]).text().trim();
    // 如果第二个文本更短，可能是作者
    if (a1.length < a0.length && a1.length < 10) {
      nameRule = 'a.0@text';
      authorRule = 'a.1@text';
    }
  }
  
  // 检查是否有 span 或 small 标签可能是作者
  const spans = $(container).find('span, small, em');
  if (spans.length > 0) {
    authorRule = 'span.0@text';
  }
  
  // 尝试找到封面图
  const firstImg = $(container).find('img').first();
  if (firstImg.length > 0) {
    const src = firstImg.attr('src') || firstImg.attr('data-src') || '';
    if (src) coverRule = 'img.0@src';
  }
  
  return { nameRule, authorRule, urlRule, coverRule };
}

async function main() {
  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const sources = JSON.parse(raw);
  const updated = JSON.parse(raw);
  let fixCount = 0;

  for (const target of BROKEN_SOURCES) {
    const kw = target.replace(/^[^ ]+ /, '');
    const source = sources.find(s => (s.bookSourceName || '').includes(kw));
    if (!source) { console.log(`❌ 未找到: ${target}`); continue; }

    const name = source.bookSourceName;
    const searchUrl = source.searchUrl || source.ruleSearchUrl || '';
    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const oldList = (source.ruleSearch || {}).bookList || source.ruleSearchList || '';
    
    process.stdout.write(`\n【${name}】旧="${oldList}" → `);

    const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
    if (!built) { console.log('⏭️ @js: 跳过'); continue; }

    const resp = await doFetch(built.url, built.method, built.body);
    if (!resp.text || resp.text.length < 500) {
      console.log(`⏭️ 响应太小 (${resp.status}, ${resp.text?.length || 0} bytes)`);
      continue;
    }
    if (resp.status >= 400) { console.log(`⏭️ HTTP ${resp.status}`); continue; }

    const $ = cheerio.load(resp.text);
    const hasKeyword = resp.text.includes(KEYWORD);
    console.log(`${resp.text.length} bytes, 含关键词:${hasKeyword ? '✅' : '❌'}`);

    // 探测选择器
    const results = [];
    for (const sel of CANDIDATES) {
      try {
        const els = $(sel);
        if (els.length < 2 || els.length > 200) continue;
        let bookLinks = 0, hasImg = 0, hasKw = 0;
        els.each((i, el) => {
          const h = $(el).find('a').first().attr('href') || '';
          const t = $(el).text().trim();
          if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || 
              h.includes('/info/') || /\/\d{4,}\/?$/.test(h)) bookLinks++;
          if ($(el).find('img').length > 0) hasImg++;
          if (t.includes(KEYWORD)) hasKw++;
        });
        if (bookLinks >= 2) {
          results.push({ sel, total: els.length, bookLinks, hasImg, hasKeyword: hasKw,
            score: bookLinks * 3 + hasImg + hasKw * 10 });
        }
      } catch (_) {}
    }

    if (results.length === 0) { console.log('  ❌ 未找到可用选择器'); continue; }

    results.sort((a, b) => b.score - a.score);
    const best = results[0];
    
    // 验证最佳选择器
    const sample = $(best.sel).first();
    const sub = guessSubRules($, sample, baseUrl);
    
    // 转换成 Legado 格式
    let newList = best.sel.replace(/ > /g, '@');
    
    // 如果包含关键词，排除表头行
    if (best.hasKeyword > 0 && best.sel === 'tr') {
      newList = 'tr!0';
    }
    
    if (newList === oldList) { console.log(`  ⏭️ 相同选择器`); continue; }

    console.log(`  ✅ "${newList}" (评分:${best.score}, ${best.bookLinks}书链)`);
    console.log(`     子规则: name=${sub.nameRule} author=${sub.authorRule}`);

    // 更新
    const idx = updated.findIndex(s => (s.bookSourceName || '') === name);
    if (idx >= 0) {
      if (!updated[idx].ruleSearch) updated[idx].ruleSearch = {};
      updated[idx].ruleSearch.bookList = newList;
      if (!updated[idx].ruleSearch.name || updated[idx].ruleSearch.name === '-') 
        updated[idx].ruleSearch.name = sub.nameRule;
      if (!updated[idx].ruleSearch.author || updated[idx].ruleSearch.author === '-') 
        updated[idx].ruleSearch.author = sub.authorRule;
      if (!updated[idx].ruleSearch.coverUrl || updated[idx].ruleSearch.coverUrl === '-') 
        updated[idx].ruleSearch.coverUrl = sub.coverRule;
      if (!updated[idx].ruleSearch.bookUrl || updated[idx].ruleSearch.bookUrl === '-') 
        updated[idx].ruleSearch.bookUrl = sub.urlRule;
      fixCount++;
    }
  }

  console.log(`\n========== 完成 ==========`);
  console.log(`修复: ${fixCount} 个源`);
  if (fixCount > 0) {
    fs.writeFileSync(path.resolve(__dirname, 'source_fixed_all.json'), JSON.stringify(updated, null, 2), 'utf-8');
    console.log(`输出: source_fixed_all.json`);
    console.log(`使用: cp test/source_fixed_all.json test/source.json`);
  }
}

main().catch(console.error);
