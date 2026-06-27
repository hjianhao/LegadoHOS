/**
 * 全量分析：逐个源搜索"冲出四合院"
 * 1. 测试每个源的搜索是否能找到精确匹配
 * 2. 分析 CSS 选择器是否正确
 * 3. 诊断需要 WebView 的源
 * 4. 生成修复后的 source.json
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 12000;
const KEYWORD = '冲出四合院';
const SRC_FILE = path.resolve(__dirname, 'source.json');
const OUT_FILE = path.resolve(__dirname, 'source_fixed.json');
const SAVE_DIR = path.resolve(__dirname, 'output');

if (!fs.existsSync(SAVE_DIR)) fs.mkdirSync(SAVE_DIR, { recursive: true });

// ========== 工具 ==========

function getBaseUrl(raw) { return raw ? raw.replace(/##.*$/, '').replace(/\/+$/, '') : ''; }

function buildUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const enc = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '')
    .replace(/\{\{key\}\}/g, enc).replace(/\{\{keyword\}\}/g, enc)
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
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) {
    return { status: 0, text: '', error: e.message };
  } finally { clearTimeout(t); }
}

function normCss(rule) {
  if (!rule) return '';
  let r = rule;
  if (r.startsWith('@css:')) r = r.slice(5);
  const h = r.indexOf('##'); if (h >= 0) r = r.substring(0, h);
  if (r.includes('||')) r = r.split('||')[0];
  r = r.replace(/@text\b/g, '').replace(/@href\b/g, '').replace(/@src\b/g, '').replace(/@html\b/g, '');
  r = r.replace(/@@/g, '.').replace(/id\./g, '#');
  r = r.replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');
  r = r.replace(/!\d+/g, '').replace(/\.\d+/g, '');
  return r.trim();
}

function extractEl($el, rule) {
  if (!rule) return '';
  let attr = 'text', css = rule;
  const m = rule.match(/^(.*?)@(text|href|src|html|ownText)$/i);
  if (m) { css = m[1].trim(); attr = m[2].toLowerCase(); }
  css = normCss(css);
  try {
    const $f = css ? $el.find(css) : $el;
    if ($f.length === 0) return '';
    const first = $f.first();
    switch (attr) {
      case 'text': return first.text().trim();
      case 'href': return first.attr('href') || '';
      case 'src': return first.attr('src') || '';
      case 'html': return first.html() || '';
      default: return first.text().trim();
    }
  } catch (_) { return ''; }
}

function extractCSS(body, source, baseUrl) {
  const rs = source.ruleSearch || {};
  const listR = rs.bookList || rs.list || '';
  const nameR = rs.name || '';
  const authorR = rs.author || '';
  const coverR = rs.coverUrl || rs.cover || '';
  const urlR = rs.bookUrl || rs.noteUrl || '';
  if (!listR || listR.startsWith('$.') || listR.startsWith('@json:')) return [];

  const $ = cheerio.load(body);
  const sel = normCss(listR);
  let $items;
  try { $items = $(sel); } catch (_) { return []; }
  if ($items.length === 0) return [];

  const results = [];
  $items.each((i, el) => {
    const $el = $(el);
    let name = extractEl($el, nameR);
    if (!name) { const $a = $el.find('a').first(); name = $a.text().trim(); }
    if (!name) name = $el.text().trim();
    if (!name || name.length < 2) return;

    const author = authorR ? extractEl($el, authorR) : '';
    let cover = coverR ? extractEl($el, coverR) : '';
    if (!cover) { const $i = $el.find('img').first(); cover = $i.attr('src') || $i.attr('data-src') || ''; }
    let url = urlR ? extractEl($el, urlR) : '';
    if (!url) { const $a = $el.find('a').first(); url = $a.attr('href') || ''; }
    if (!url) return;
    if (url && !url.startsWith('http')) url = baseUrl + (url.startsWith('/') ? url : '/' + url);
    if (cover && !cover.startsWith('http')) cover = baseUrl + (cover.startsWith('/') ? cover : '/' + cover);
    results.push({ name, author, cover, url });
  });
  return results;
}

function getJson(obj, p) {
  if (!p || !obj) return undefined;
  if (p.includes('||')) { for (const a of p.split(/\|\|/)) { const v = getJson(obj, a.trim()); if (v !== undefined && v !== null && v !== '') return v; } return undefined; }
  let path = p.replace(/^\$\.?/, '').replace(/^@json:\$\.?/, '');
  const parts = path.split('.');
  let cur = obj;
  for (const part of parts) {
    if (cur == null) return undefined;
    const am = part.match(/^(\w+)(?:\[(\d+|\*)])?$/);
    if (am) { const [_, k, idx] = am; cur = Array.isArray(cur) ? (idx === '*' || !idx ? cur[0]?.[k] : cur[parseInt(idx)]?.[k]) : cur[k]; }
    else cur = cur[part];
  }
  return cur;
}

function extractJSON(body, source, baseUrl) {
  const rs = source.ruleSearch || {};
  const listR = rs.bookList || rs.list || '';
  const nameR = rs.name || '';
  const authorR = rs.author || '';
  const coverR = rs.coverUrl || rs.cover || '';
  const urlR = rs.bookUrl || rs.noteUrl || '';
  let json;
  try { json = JSON.parse(body); } catch (_) { return []; }
  let list = null;
  if (listR) { const r = getJson(json, listR); if (Array.isArray(r)) list = r; }
  if (!list) { if (Array.isArray(json)) list = json; else for (const p of ['data', 'list', 'items', 'results', 'books']) { const r = json[p]; if (Array.isArray(r)) { list = r; break; } } }
  if (!list) return [];
  return list.map(item => ({
    name: String(getJson(item, nameR) || item.novelName || item.name || item.title || ''),
    author: String(getJson(item, authorR) || item.authorName || item.author || ''),
    cover: String(getJson(item, coverR) || ''),
    url: String(getJson(item, urlR) || item.noteUrl || item.bookUrl || ''+item.id || ''),
  })).filter(i => i.name);
}

/** 分析 HTML 结构，找到合适的书籍容器 */
function analyzeHtmlStructure($, body, baseUrl, source) {
  const fixes = { suggested: false, bookList: '', name: '', author: '', coverUrl: '', bookUrl: '', needsWebView: false, issues: [] };

  // 检测是否需要 WebView
  if (body.includes('cloudflare') || body.includes('Cloudflare') || body.includes('_cf_chl_opt')) {
    fixes.needsWebView = true;
    fixes.issues.push('Cloudflare 防护，需 WebView');
  }
  if (body.includes('just a moment') || body.includes('Just a moment')) {
    fixes.needsWebView = true;
    fixes.issues.push('Cloudflare 验证页，需 WebView');
  }
  if (body.includes('<script') && body.match(/src=["']https?:\/\/[^"']+\.js/g)?.length > 3) {
    // 大量外部 JS -> 可能需要 WebView
  }

  // 找包含关键词的链接
  const links = [];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href') || '';
    const text = $(el).text().trim();
    if (href && !href.startsWith('#') && !href.startsWith('javascript:') && text.length >= 2) {
      links.push({ href, text });
    }
  });

  const targetLinks = links.filter(l => l.text.includes('四合院') || l.text.includes(KEYWORD));
  
  // 找最可能的书籍容器
  const candidates = [];
  for (const sel of ['li', 'tr', 'dd', 'div.item', 'div.book', '.search-item', '.result-item',
    'div[class*="item"]', 'div[class*="book"]', 'li[class*="item"]', '.book-list li',
    '.novelslist2 li', '.txt-list-row5 li', '.hot_sale li', 'tbody tr']) {
    try {
      const els = $(sel);
      if (els.length < 2 || els.length > 200) continue;
      let bookCount = 0, hasImg = 0;
      els.each((i, el) => {
        const h = $(el).find('a').first().attr('href') || '';
        if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || /\/\d{4,}\/?$/.test(h)) bookCount++;
        if ($(el).find('img').length > 0) hasImg++;
      });
      if (bookCount >= 2) {
        candidates.push({ sel, total: els.length, bookLinks: bookCount, hasImgs: hasImg });
      }
    } catch (_) {}
  }

  // 如果找到了书籍容器，生成新规则
  if (candidates.length > 0) {
    const best = candidates.sort((a, b) => b.bookLinks - a.bookLinks)[0];
    fixes.bookList = best.sel;
    fixes.name = 'a.0@text';
    fixes.author = 'span.0@text';
    fixes.coverUrl = 'img.0@src';
    fixes.bookUrl = 'a.0@href';
    
    // 检查当前规则是否已经匹配
    const rs = source.ruleSearch || {};
    const currentList = rs.bookList || rs.list || '';
    if (currentList && currentList !== best.sel) {
      fixes.suggested = true;
      fixes.issues.push(`bookList 建议从 "${currentList}" 改为 "${best.sel}" (匹配${best.bookLinks}个书籍链接)`);
    }
  }

  // 检测搜索结果数量
  if (links.length === 0 && body.length > 500) {
    fixes.issues.push('页面无链接，可能需 WebView 渲染');
    fixes.needsWebView = true;
  }

  return fixes;
}

// ========== 主诊断 ==========

async function main() {
  const raw = fs.readFileSync(SRC_FILE, 'utf-8');
  const allSources = JSON.parse(raw);
  console.log(`共 ${allSources.length} 个书源\n`);

  const results = [];
  const concurrency = 4;
  let idx = 0;

  async function worker() {
    while (idx < allSources.length) {
      const i = idx++;
      const source = allSources[i];
      const name = source.bookSourceName || '?';
      const searchUrl = source.searchUrl || '';
      const baseUrl = getBaseUrl(source.bookSourceUrl || '');
      const rs = source.ruleSearch || {};

      process.stdout.write(`[${i+1}/${allSources.length}] ${name}... `);

      const info = {
        name, index: i,
        hasSearchUrl: !!searchUrl,
        searchUrl: searchUrl?.substring(0, 60),
        isJsUrl: searchUrl?.trimStart().startsWith('@js:'),
        ruleSearch: {
          bookList: rs.bookList || rs.list || '',
          name: rs.name || '',
          author: rs.author || '',
          cover: rs.coverUrl || rs.cover || '',
          bookUrl: rs.bookUrl || rs.noteUrl || '',
        },
        isJsonAPI: (rs.bookList || rs.list || '').startsWith('$.') || (rs.bookList || rs.list || '').startsWith('@json:'),
        jsonResults: [],
        cssResults: [],
        exactMatch: false,
        fuzzyMatch: false,
        hasAuthor: false,
        hasCover: false,
        totalResults: 0,
        needsWebView: false,
        webViewCurrent: false,
        bodyLength: 0,
        status: 0,
        error: '',
        fixes: null,
      };

      // 检测当前是否标记了 WebView
      if (searchUrl && searchUrl.includes('webView')) info.webViewCurrent = true;

      if (!searchUrl) { console.log('⏭️ 无 searchUrl'); results.push(info); continue; }

      const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
      if (!built) {
        if (info.isJsUrl) {
          info.needsWebView = true; // @js: URL 理论上需要 WebView/JS引擎
          console.log('⏭️ @js: URL（需 WebView）');
        } else {
          console.log('❌ URL 构建失败');
        }
        results.push(info);
        continue;
      }

      const resp = await doFetch(built.url, built.method, built.body);
      info.status = resp.status;
      info.bodyLength = resp.text?.length || 0;

      if (!resp.text || resp.text.length < 50) {
        console.log(`❌ 响应为空 (${resp.status}, ${info.bodyLength})`);
        if (resp.error) info.error = resp.error;
        results.push(info);
        continue;
      }

      // 检测 Cloudflare
      if (resp.text.includes('cloudflare') || resp.text.toLowerCase().includes('just a moment')) {
        info.needsWebView = true;
      }

      // 检测是否为 JSON
      const trimmed = resp.text.trimStart();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        info.jsonResults = extractJSON(resp.text, source, baseUrl);
      }

      // CSS 提取
      if (!info.isJsonAPI) {
        info.cssResults = extractCSS(resp.text, source, baseUrl);
      }

      // 分析结果
      const primary = info.jsonResults.length > 0 ? info.jsonResults : info.cssResults;
      info.totalResults = primary.length;
      info.exactMatch = primary.some(r => r.name === KEYWORD);
      info.fuzzyMatch = primary.some(r => r.name.includes(KEYWORD));
      info.hasAuthor = primary.some(r => r.author);
      info.hasCover = primary.some(r => r.cover);

      // 如果 CSS 提取不到结果，分析页面结构
      if (!info.isJsonAPI && info.cssResults.length === 0 && resp.text.length > 500) {
        const $ = cheerio.load(resp.text);
        info.fixes = analyzeHtmlStructure($, resp.text, baseUrl, source);
        if (info.fixes.needsWebView) info.needsWebView = true;
      }

      // 统计
      const tag = info.jsonResults.length > 0 ? 'JSON' : (info.cssResults.length > 0 ? 'CSS' : '❌');
      const exact = info.exactMatch ? ' ✅' : (info.fuzzyMatch ? ' ⚠️' : '');
      const authorTag = info.hasAuthor ? ' 📝' : '';
      const coverTag = info.hasCover ? ' 🖼' : '';
      const wvTag = info.needsWebView ? ' 🌐' : '';
      console.log(`${tag}=${info.totalResults}${exact}${authorTag}${coverTag}${wvTag}`);
      if (info.exactMatch) console.log(`   ${primary.filter(r => r.name === KEYWORD).map(r => `${r.name} 作者=${r.author||'-'} 封面=${r.cover?'✓':'✗'}`).join('\n    ')}`);
      else if (info.fuzzyMatch) console.log(`   模糊: ${primary.filter(r => r.name.includes(KEYWORD)).slice(0, 2).map(r => r.name).join(', ')}`);
      else if (info.cssResults.length > 0) console.log(`   例: ${info.cssResults.slice(0, 3).map(r => r.name).join(', ')}`);
      else if (info.jsonResults.length > 0) console.log(`   JSON例: ${info.jsonResults.slice(0, 3).map(r => r.name+','+r.author).join(' | ')}`);

      results.push(info);
    }
  }

  await Promise.all(Array(concurrency).fill().map(() => worker()));

  // ========== 汇总报告 ==========

  console.log('\n\n========== 汇总报告 ==========\n');

  const exact = results.filter(r => r.exactMatch);
  const fuzzy = results.filter(r => r.fuzzyMatch && !r.exactMatch);
  const jsonOk = results.filter(r => r.jsonResults.length > 0);
  const cssOk = results.filter(r => r.cssResults.length > 0);
  const noResults = results.filter(r => r.totalResults === 0 && !r.isJsUrl && !r.error && r.bodyLength > 0);
  const needsWv = results.filter(r => r.needsWebView);

  console.log(`✅ 精确匹配"${KEYWORD}": ${exact.length} 个源`);
  exact.forEach(r => console.log(`  ${r.name} (${r.jsonResults.length > 0 ? 'JSON' : 'CSS'}, 含作者=${r.hasAuthor}, 含封面=${r.hasCover})`));

  console.log(`\n⚠️ 模糊匹配（含"${KEYWORD}"）: ${fuzzy.length} 个源`);
  fuzzy.forEach(r => console.log(`  ${r.name}`));

  console.log(`\n📊 JSON API 源成功: ${jsonOk.length}`);
  console.log(`📊 CSS 提取成功: ${cssOk.length} (含作者: ${cssOk.filter(r=>r.hasAuthor).length}, 含封面: ${cssOk.filter(r=>r.hasCover).length})`);
  console.log(`📊 无结果(有响应但提取失败): ${noResults.length}`);
  console.log(`📊 需要 WebView: ${needsWv.length}`);
  console.log(`📊 @js: URL (无法构建): ${results.filter(r => r.isJsUrl).length}`);

  // 输出需要修复的源
  const needFix = results.filter(r => r.fixes && r.fixes.suggested);
  if (needFix.length > 0) {
    console.log(`\n=== 建议修复的源 (${needFix.length}) ===`);
    for (const r of needFix) {
      console.log(`\n【${r.name}】`);
      r.fixes.issues.forEach(i => console.log(`  ${i}`));
      const src = allSources[r.index];
      if (!src.ruleSearch) src.ruleSearch = {};
      console.log(`  建议 bookList: ${r.fixes.bookList}`);
      console.log(`  建议 name: ${r.fixes.name}`);
      console.log(`  建议 author: ${r.fixes.author}`);
      console.log(`  建议 coverUrl: ${r.fixes.coverUrl}`);
      console.log(`  建议 bookUrl: ${r.fixes.bookUrl}`);
      if (r.fixes.needsWebView && !r.webViewCurrent) {
        console.log(`  ⚠️ 需要标记 WebView`);
      }
    }
  }

  // 输出 WebView 状态
  console.log(`\n=== WebView 状态 ===`);
  const needsWvList = results.filter(r => r.needsWebView);
  const hasWvList = results.filter(r => r.webViewCurrent && !r.needsWebView);
  console.log(`需要 WebView（未标记）: ${needsWvList.filter(r => !r.webViewCurrent).length}`);
  needsWvList.filter(r => !r.webViewCurrent).forEach(r => console.log(`  ⬆️ ${r.name} (需添加 webView)`));
  console.log(`已标记但不再需要: ${hasWvList.length}`);
  hasWvList.forEach(r => console.log(`  ⬇️ ${r.name} (可移除 webView 标记)`));

  // ========== 生成修复后的 JSON ==========

  console.log('\n\n=== 生成修复后的 source.json ===\n');

  const updated = JSON.parse(JSON.stringify(allSources));
  let modCount = 0;

  for (const r of needFix) {
    const src = updated[r.index];
    if (!r.fixes || !r.fixes.bookList) continue;
    
    if (!src.ruleSearch) src.ruleSearch = {};
    const oldList = src.ruleSearch.bookList || src.ruleSearch.list || '';
    src.ruleSearch.bookList = r.fixes.bookList;
    if (r.fixes.name) src.ruleSearch.name = r.fixes.name;
    if (r.fixes.author) src.ruleSearch.author = r.fixes.author;
    if (r.fixes.coverUrl) src.ruleSearch.coverUrl = r.fixes.coverUrl;
    if (r.fixes.bookUrl) src.ruleSearch.bookUrl = r.fixes.bookUrl;

    // 标记 WebView
    if (r.fixes.needsWebView && !r.webViewCurrent && src.searchUrl) {
      if (!src.searchUrl.includes('webView')) {
        // 在 URL 模板中添加 webView 标记
        src.searchUrl = src.searchUrl + '##webView';
      }
    }

    modCount++;
    console.log(`✅ ${r.name}`);
    console.log(`   bookList: ${oldList} → ${r.fixes.bookList}`);
  }

  // 更新 WebView 标记
  for (const r of results) {
    const src = updated[r.index];
    if (!src.searchUrl) continue;
    
    // 需要 WebView 但未标记
    if (r.needsWebView && !r.webViewCurrent) {
      if (!src.searchUrl.includes('webView')) {
        src.searchUrl = src.searchUrl + '##webView';
        console.log(`🌐 ${r.name}: 添加 webView 标记`);
        modCount++;
      }
    }
    // 标记了但不需要
    if (!r.needsWebView && r.webViewCurrent) {
      src.searchUrl = src.searchUrl.replace(/##webView/g, '');
      console.log(`🔽 ${r.name}: 移除 webView 标记`);
      modCount++;
    }
  }

  fs.writeFileSync(OUT_FILE, JSON.stringify(updated, null, 2), 'utf-8');
  console.log(`\n修改了 ${modCount} 个源，已保存到 source_fixed.json`);
  console.log(`使用: cp test/source_fixed.json test/source.json`);
}

main().catch(console.error);
