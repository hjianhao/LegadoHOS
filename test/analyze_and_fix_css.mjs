/**
 * 全面 CSS 选择器分析和修复脚本
 * 为所有 CSS 失效的源探测正确的选择器
 */
import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 15000;
const KEYWORD = '冲出四合院';
const SRC = path.resolve(__dirname, 'source.json');

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
      const o = JSON.parse(jr.replace(/'/g, '"').replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3'));
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
      'Accept': 'text/html,application/json,*/*'
    };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(t); }
}

// 候选 CSS 选择器（按优先级排列）
const CANDIDATE_SELECTORS = [
  'li', 'tr', 'dd', 'dl dd', 'ul li',
  'div.item', 'div.book-item', 'div.search-item', 'div.result-item',
  'div[class*="item"]', 'div[class*="book"]', 'div[class*="result"]',
  'div[class*="list"]', 'div[class*="search"]',
  'li[class*="item"]', 'li[class*="book"]',
  'tbody tr', 'table tr',
  '.bookbox', '.hot_sale', '.txt-list-row5 li', '.novelslist2 li',
  '.search-list li', '.search-list div',
  '.list li', '.list div',
];

// 从日志中确定的 CSS 失效源
const TARGET_NAMES = [
  '🎉 七猫小说', '🎉 狗狗书籍', '🎉 饿狼小说', '🎉 多多书院',
  '🎉 手机小说', '🎉 歌书小说', '🎉 抖音小说', '🎉 唐三中文',
  '🎉 必去小说', '🎉 乐文阁网', '🎉 香书小说', '🎉 就爱文学',
  '🎉 当阅读网', '🎉 搜搜小说', '🎉 黄易小说', '🎉 久久小说',
  '💐 言情小说', '💐 爱久久网', '💠 乐库小说', '💠 手机看书',
  '💠 书满屋网', '💠 笔趣阁22', '💠 蚂蚁文学',
];

async function analyzePage($, name, html) {
  console.log(`\n========== ${name} ==========`);
  console.log(`HTML大小: ${html.length} bytes`);

  // 寻找包含 KEYWORD 的文本
  const hasKeyword = html.includes(KEYWORD);
  console.log(`包含"${KEYWORD}": ${hasKeyword ? '✅' : '❌'}`);

  // 分析 common selectors
  const selResults = [];
  for (const sel of CANDIDATE_SELECTORS) {
    try {
      const els = $(sel);
      if (els.length < 2 || els.length > 200) continue;
      let bookLinks = 0, hasImg = 0, hasKeyword = 0;
      els.each((i, el) => {
        const h = $(el).find('a').first().attr('href') || '';
        const t = $(el).text().trim();
        if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || 
            h.includes('/info/') || /\/\d{4,}\/?$/.test(h) || h.includes('read')) bookLinks++;
        if ($(el).find('img').length > 0) hasImg++;
        if (t.includes(KEYWORD)) hasKeyword++;
      });
      if (bookLinks >= 2) {
        selResults.push({ sel, total: els.length, bookLinks, hasImg, hasKeyword,
          score: bookLinks * 3 + hasImg * 2 + hasKeyword * 10 });
      }
    } catch (_) {}
  }

  if (selResults.length === 0) {
    console.log('❌ 未找到任何可用选择器');
    return null;
  }

  // 按分数排序（包含关键词的更高分）
  selResults.sort((a, b) => b.score - a.score);
  
  console.log(`候选选择器 (top 5):`);
  selResults.slice(0, 5).forEach((r, i) => {
    console.log(`  ${i+1}. "${r.sel}" → ${r.total}个元素, ${r.bookLinks}个书链, ${r.hasImg}个图, ${r.hasKeyword}含关键词, 评分:${r.score}`);
  });

  const best = selResults[0];
  
  // 验证最佳选择器是否能提取书名
  console.log(`\n最佳: "${best.sel}"`);
  const bestEls = $(best.sel);
  let sampleTitles = [];
  bestEls.each((i, el) => {
    if (i < 3) {
      const a = $(el).find('a').first();
      const href = a.attr('href') || '';
      const text = a.text().trim().substring(0, 30);
      if (text) sampleTitles.push(`"${text}" → ${href.substring(0, 50)}`);
    }
  });
  sampleTitles.forEach((t, i) => console.log(`  书名${i+1}: ${t}`));

  return best;
}

async function main() {
  const raw = fs.readFileSync(SRC, 'utf-8');
  const sources = JSON.parse(raw);
  const updated = JSON.parse(raw);
  let fixCount = 0, skipCount = 0;

  console.log(`共 ${sources.length} 个书源，目标修复 ${TARGET_NAMES.length} 个\n`);

  for (const targetName of TARGET_NAMES) {
    const source = sources.find(s => (s.bookSourceName || '').includes(targetName.replace(/^[^ ]+ /, '')));
    if (!source) { console.log(`❌ 未找到: ${targetName}`); continue; }

    const name = source.bookSourceName;
    const searchUrl = source.searchUrl || source.ruleSearchUrl || '';
    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const oldList = (source.ruleSearch || {}).bookList || 
                    (source.ruleSearch || {}).list || 
                    source.ruleSearchList || '';

    process.stdout.write(`\n【${name}】旧选择器="${oldList}" → `);

    const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
    if (!built) { console.log(`⏭️ @js: URL 跳过`); skipCount++; continue; }

    const resp = await doFetch(built.url, built.method, built.body);
    if (!resp.text || resp.text.length < 200) {
      console.log(`⏭️ 响应为空 (HTTP ${resp.status})`);
      skipCount++; continue;
    }
    if (resp.status >= 400) {
      console.log(`⏭️ HTTP ${resp.status}`);
      skipCount++; continue;
    }

    const $ = cheerio.load(resp.text);
    const best = await analyzePage($, name, resp.text);
    if (!best) { skipCount++; continue; }

    // 检查旧选择器是否实际有效
    let oldWorks = false;
    if (oldList) {
      try {
        const oldEls = $(oldList.replace(/@li\b/g, ' > li').replace(/@/g, ' > ').replace(/!\d+(:\d+)?/g, ''));
        if (oldEls.length >= 2) oldWorks = true;
      } catch (_) {}
    }

    if (oldWorks) {
      console.log(`  旧选择器仍有效 (${$(oldList.replace(/@li\b/g, ' > li').replace(/@/g, ' > ').replace(/!\d+(:\d+)?/g, '')).length}个元素)，跳过`);
      skipCount++; continue;
    }

    // 转换选择器为 Legado 格式（@ 分隔符）
    // cheerio 的 CSS 选择器如 "div.item > li" → Legado 格式 "div.item@li"
    let newList = best.sel.replace(/ > /g, '@');
    
    // 如果跟旧的一样，跳过
    if (newList === oldList) { console.log(`  相同选择器，跳过`); skipCount++; continue; }

    console.log(`✅ 新选择器="${newList}"`);

    // 更新 source
    const idx = updated.findIndex(s => (s.bookSourceName || '') === name);
    if (idx >= 0) {
      if (!updated[idx].ruleSearch) updated[idx].ruleSearch = {};
      updated[idx].ruleSearch.bookList = newList;
      // 如果旧有子字段为空或无效，设置默认值
      const nameRule = updated[idx].ruleSearch.name || '';
      if (!nameRule || nameRule === '-') updated[idx].ruleSearch.name = 'a.0@text';
      const authorRule = updated[idx].ruleSearch.author || '';
      if (!authorRule || authorRule === '-') updated[idx].ruleSearch.author = 'span.0@text';
      const coverRule = updated[idx].ruleSearch.coverUrl || '';
      if (!coverRule || coverRule === '-') updated[idx].ruleSearch.coverUrl = 'img.0@src';
      const urlRule = updated[idx].ruleSearch.bookUrl || '';
      if (!urlRule || urlRule === '-') updated[idx].ruleSearch.bookUrl = 'a.0@href';
      fixCount++;
    }
  }

  console.log(`\n========== 汇总 ==========`);
  console.log(`修复: ${fixCount}, 跳过: ${skipCount}, 总目标: ${TARGET_NAMES.length}`);

  if (fixCount > 0) {
    const outPath = path.resolve(__dirname, 'source_fixed_css.json');
    fs.writeFileSync(outPath, JSON.stringify(updated, null, 2), 'utf-8');
    console.log(`\n✅ 已保存到: source_fixed_css.json`);
    console.log(`使用: cp test/source_fixed_css.json test/source.json`);
  }
}

main().catch(console.error);
