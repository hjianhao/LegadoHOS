/**
 * 深度修复：对每个选择器失效的源，分析页面结构并生成新配置
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 12000;
const KEYWORD = '冲出四合院';

const SOURCES_FILE = path.resolve(__dirname, 'source.json');
const OUTPUT_FILE = path.resolve(__dirname, 'source_fixed.json');

function getBaseUrl(raw) { return raw ? raw.replace(/##.*$/, '').replace(/\/+$/, '') : ''; }

function buildUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const enc = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '').replace(/\{\{key\}\}/g, enc).replace(/\{\{keyword\}\}/g, enc);
  url = url.replace(/\{\{page\}\}/g, page).replace(/\{\{pageNum\}\}/g, page + 1);
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
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return await r.text();
  } finally { clearTimeout(t); }
}

/** 从 HTML 链接中提取信息 */
function analyzeHtmlLinks($, baseUrl) {
  const links = [];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href') || '';
    const text = $(el).text().trim();
    if (href && !href.startsWith('#') && !href.startsWith('javascript:')) {
      let url = href;
      if (url && !url.startsWith('http')) url = baseUrl + (url.startsWith('/') ? url : '/' + url);
      links.push({ href: url, text: text, rawHref: href });
    }
  });
  return links;
}

/** 找到最可能的书籍容器 */
function findBookContainer($, links, baseUrl) {
  // 找到所有同时包含书名和作者/封面信息的容器
  const candidates = [];
  
  // 常见书籍容器列表
  const containers = [
    'li', 'tr', 'dd', 'div.item', 'div.book', 'div.novel-item', 'div.list-item',
    'div.result-item', 'div.search-item', 'div.book-item', 'li.item', 'li.book',
    'div[class*="item"]', 'div[class*="book"]', 'div[class*="result"]',
    'div[class*="list"]', 'li[class*="item"]', 'li[class*="book"]',
  ];

  for (const sel of containers) {
    try {
      const els = $(sel);
      if (els.length < 2 || els.length > 200) continue;
      
      // 统计书籍链接
      let bookLinks = 0, imgCount = 0;
      els.each((i, el) => {
        const h = $(el).find('a').first().attr('href') || '';
        if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || h.includes('/info/') || /\/\d{4,}\/?$/.test(h)) bookLinks++;
        if ($(el).find('img').length > 0) imgCount++;
      });
      
      if (bookLinks >= 2) {
        const avgLinks = bookLinks / els.length;
        const sampleText = els.length > 0 ? $(els[0]).text().trim().substring(0, 60) : '';
        candidates.push({
          selector: sel,
          total: els.length,
          bookLinks,
          hasImgs: imgCount,
          avgLinks,
          sample: sampleText,
        });
      }
    } catch (_) {}
  }

  // 按书籍链接数排序
  candidates.sort((a, b) => b.bookLinks - a.bookLinks);

  // 如果有找到容器，分析第一个容器中的书籍信息模式
  if (candidates.length > 0) {
    const best = candidates[0];
    const $els = $(best.selector);
    const bookItems = [];
    
    $els.each((i, el) => {
      if (i >= 10) return false;
      const $el = $(el);
      const nameEl = $el.find('a').first();
      const name = nameEl.text().trim();
      const href = nameEl.attr('href') || '';
      
      const authorEl = $el.find('a').eq(1);
      const author = authorEl.text().trim();
      
      const imgEl = $el.find('img').first();
      const cover = imgEl.attr('src') || imgEl.attr('data-src') || '';
      
      bookItems.push({ name, author: author.length < 10 ? author : '', href, cover, html: $.html(el).substring(0, 200) });
    });

    return { candidates, bookItems };
  }
  return { candidates, bookItems: [] };
}

/** 为容器元素生成合适的规则 */
function generateRules(containerSel, bookItems, baseUrl) {
  const rules = {
    bookList: '',
    name: '',
    author: '',
    coverUrl: '',
    bookUrl: '',
  };

  rules.bookList = containerSel;

  if (bookItems.length > 0) {
    const first = bookItems[0];
    // name: 第一个 <a> 的文本
    rules.name = 'a.0@text';
    // author: 第二个 <a> 的文本
    rules.author = 'a.1@text';
    // cover: <img> 的 src
    rules.coverUrl = 'img.0@src';
    // url: 第一个 <a> 的 href
    rules.bookUrl = 'a.0@href';
  }

  return rules;
}

// ====== 诊断单个源 ======

async function diagnoseAndFix(source) {
  const name = source.bookSourceName || '?';
  const searchUrl = source.searchUrl || '';
  const baseUrl = getBaseUrl(source.bookSourceUrl || '');
  const rs = source.ruleSearch || {};
  const listRule = rs.bookList || rs.list || '';
  
  if (!searchUrl || listRule.startsWith('$.') || listRule.startsWith('@json:') ||
      searchUrl.trimStart().startsWith('@js:')) return null;

  const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
  if (!built) return null;

  let body;
  try {
    body = await doFetch(built.url, built.method, built.body);
    if (!body || body.length < 100) return null;
  } catch (e) { return null; }

  if (body.trimStart().startsWith('{') || body.trimStart().startsWith('[')) return null;

  const $ = cheerio.load(body);
  const links = analyzeHtmlLinks($, baseUrl);
  const { candidates, bookItems } = findBookContainer($, links, baseUrl);

  // 找含"四合院"的链接
  const targetLinks = links.filter(l => l.text.includes('四合院'));

  const newRules = candidates.length > 0 ? generateRules(candidates[0].selector, bookItems, baseUrl) : null;

  return {
    name, body, links, candidates, bookItems, targetLinks, newRules,
    builtUrl: built.url, baseUrl,
    oldListRule: listRule,
  };
}

// ====== 主逻辑 ======

async function main() {
  const raw = fs.readFileSync(SOURCES_FILE, 'utf-8');
  const allSources = JSON.parse(raw);
  console.log('深度分析选择器失效的源...\n');

  // 选需要修复的源
  const fixTargets = [
    '🎉 八零小说', '🎉 多多书院', '🎉 独步小说', '🎉 歌书小说',
    '🎉 搜搜小说', '🎉 一米小说', '🎉 小书本网',
    '💐 言情小说', '💠 达文小说', '💠 书满屋网',
    '🎉 手机小说', '🎉 西瓜小说',
  ];

  const results = [];

  for (const target of fixTargets) {
    // 去掉前缀表情和空格（表情可能占1-2个字符）
    const keyword = target.replace(/^[^a-zA-Z\u4e00-\u9fff]+/, '');
    if (!keyword) continue;
    const source = allSources.find(s => (s.bookSourceName || '').includes(keyword));
    if (!source) { console.log(`❌ 未找到源: ${target} (关键字: ${keyword})`); continue; }
    
    if (!source.searchUrl) { console.log(`[${keyword}] 无 searchUrl`); continue; }
    if (source.searchUrl.trimStart().startsWith('@js:')) { console.log(`[${keyword}] ⏭️ @js: URL`); continue; }
    
    process.stdout.write(`解析【${keyword}】... `);
    const r = await diagnoseAndFix(source);
    if (!r) { 
      console.log('❌ 获取失败');
      // Debug
      const baseUrl2 = getBaseUrl(source.bookSourceUrl || '');
      const built2 = buildUrl(source.searchUrl, KEYWORD, 1, baseUrl2);
      if (!built2) console.log(`   URL构建失败: ${source.searchUrl?.substring(0,80)}`);
      continue; 
    }

    const hasTarget = r.targetLinks.length > 0;
    const hasContainer = r.candidates.length > 0;

    if (hasContainer) {
      // 显示候选容器
      const best = r.candidates[0];
      console.log(`✅ 找到容器: ${best.selector} (${best.total}个, ${best.bookLinks}个书籍链接, ${best.hasImgs}个含图)`);
      if (hasTarget) console.log(`   含目标结果: ${r.targetLinks.length}条`);
      
      // 显示前3条解析结果
      r.bookItems.slice(0, 3).forEach((item, i) => {
        const nameStr = item.name.substring(0, 25);
        const authStr = item.author ? `作者=${item.author}` : '无作者';
        const coverStr = item.cover ? '有图' : '无图';
        console.log(`   ${i+1}. "${nameStr}" ${authStr} ${coverStr}`);
      });

      results.push({ source, result: r });
    } else {
      console.log(`❌ 未找到合适容器 (${r.links.length}个链接)`);
      if (hasTarget) console.log(`   含"四合院"的链接: ${r.targetLinks.map(l => l.text).join(', ')}`);
    }
  }

  // ====== 生成更新后的 source.json ======

  console.log('\n\n========== 生成更新配置 ==========\n');

  // 深拷贝原始源
  const updatedSources = JSON.parse(JSON.stringify(allSources));

  let modifiedCount = 0;
  for (const { source, result } of results) {
    if (!result.newRules) continue;
    
    const idx = updatedSources.findIndex(s => s.bookSourceName === source.bookSourceName);
    if (idx < 0) continue;

    // 更新规则
    if (!updatedSources[idx].ruleSearch) updatedSources[idx].ruleSearch = {};
    updatedSources[idx].ruleSearch.bookList = result.newRules.bookList;
    updatedSources[idx].ruleSearch.name = result.newRules.name;
    updatedSources[idx].ruleSearch.author = result.newRules.author;
    updatedSources[idx].ruleSearch.coverUrl = result.newRules.coverUrl;
    updatedSources[idx].ruleSearch.bookUrl = result.newRules.bookUrl;
    
    modifiedCount++;
    console.log(`✅ ${source.bookSourceName}:`);
    console.log(`   bookList: ${result.oldListRule} → ${result.newRules.bookList}`);
    console.log(`   name: ${source.ruleSearch?.name || '(空)'} → ${result.newRules.name}`);
    console.log(`   author: ${source.ruleSearch?.author || '(空)'} → ${result.newRules.author}`);
    console.log(`   coverUrl: ${source.ruleSearch?.coverUrl || '(空)'} → ${result.newRules.coverUrl}`);
    console.log(`   bookUrl: ${source.ruleSearch?.bookUrl || '(空)'} → ${result.newRules.bookUrl}`);

    // 保存页面 HTML 供分析
    const saveName = source.bookSourceName.replace(/[^\w\u4e00-\u9fff]/g, '_');
    fs.writeFileSync(path.resolve(__dirname, 'output', `${saveName}.html`), result.body);
    console.log(`   HTML saved to output/${saveName}.html`);
    console.log();
  }

  // 写入更新后的 JSON
  fs.writeFileSync(OUTPUT_FILE, JSON.stringify(updatedSources, null, 2), 'utf-8');
  console.log(`\n========== 完成 ==========`);
  console.log(`修改了 ${modifiedCount} 个源的配置`);
  console.log(`更新后的文件: source_fixed.json`);
  console.log(`请将 source_fixed.json 替换 test/source.json 后重新导入`);
}

main().catch(console.error);
