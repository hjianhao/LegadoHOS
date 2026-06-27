/**
 * 深度诊断：逐个源搜索"冲出四合院"，分析解析质量
 * 
 * 对每个源：
 * 1. 构建搜索 URL 并请求
 * 2. 尝试 JSON/CSS/regex 三种方式提取
 * 3. 检查结果中是否有准确匹配"冲出四合院"
 * 4. 分析 CSS 选择器匹配失败的原因
 * 5. 保存有问题的源的原始 HTML 供分析
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT_MS = 15000;
const KEYWORD = '冲出四合院';
const SAVE_DIR = path.resolve(__dirname, 'output');

if (!fs.existsSync(SAVE_DIR)) fs.mkdirSync(SAVE_DIR, { recursive: true });

// ====== 工具 ======

function getBaseUrl(raw) { return raw ? raw.replace(/##.*$/, '').replace(/\/+$/, '') : ''; }

function buildUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const enc = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '');
  url = url.replace(/\{\{key\}\}/g, enc).replace(/\{\{keyword\}\}/g, enc)
    .replace(/\{\{page\}\}/g, page).replace(/\{\{pageNum\}\}/g, page + 1);
  url = url.replace(/\{\{[^}]*\}\}/g, '').replace(/<js>[\s\S]*?<\/js>/gi, '');
  url = url.replace(/\n\s*\n/g, '\n').replace(/\n\s*/g, '');
  while (url.includes('@js:')) {
    const ji = url.indexOf('@js:');
    const jo = url.indexOf(',{', ji);
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
  url = url.trim();
  return url ? { url, method, body } : null;
}

async function doFetch(u, method = 'GET', body = null) {
  const c = new AbortController(); const t = setTimeout(() => c.abort(), TIMEOUT_MS);
  try {
    const h = { 'User-Agent': 'Mozilla/5.0' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return await r.text();
  } finally { clearTimeout(t); }
}

// ====== CSS 提取（简化版） ======

function norm(rule) {
  if (!rule) return rule;
  if (rule.startsWith('@css:')) return rule.slice(5);
  // 取出 ## 之前的部分
  const h = rule.indexOf('##');
  let r = h >= 0 ? rule.substring(0, h) : rule;
  if (r.includes('||')) r = r.split('||')[0];
  r = r.replace(/@text\b/g, '').replace(/@href\b/g, '').replace(/@src\b/g, '').replace(/@html\b/g, '').replace(/@ownText\b/g, '');
  r = r.replace(/@@/g, '.').replace(/id\./g, '#');
  r = r.replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');
  return r;
}

function extractEl($el, rule) {
  if (!rule) return '';
  let attr = 'text', css = rule;
  const m = rule.match(/^(.*?)@(text|href|src|html|ownText)$/i);
  if (m) { css = m[1].trim(); attr = m[2].toLowerCase(); }
  css = norm(css);
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
  if (!listR) return [];

  const $ = cheerio.load(body);
  const sel = norm(listR);
  let $items;
  try { $items = $(sel); } catch (_) { return []; }
  if ($items.length === 0) return [];

  const results = [];
  $items.each((i, el) => {
    const $el = $(el);
    // 尝试用 nameR 取书名
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

// ====== JSON 提取 ======

function getJson(obj, p) {
  if (!p || !obj) return undefined;
  if (p.includes('||')) { for (const a of p.split(/\|\|/)) { const v = getJson(obj, a.trim()); if (v !== undefined && v !== null && v !== '') return v; } return undefined; }
  const parts = p.replace(/^\$\.?/, '').split('.');
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
  if (!list) {
    if (Array.isArray(json)) list = json;
    else for (const p of ['data', 'list', 'items', 'results', 'books']) { const r = json[p]; if (Array.isArray(r)) { list = r; break; } }
  }
  if (!list) return [];

  return list.map(item => ({
    name: String(getJson(item, nameR) || item.novelName || item.name || item.title || ''),
    author: String(getJson(item, authorR) || item.authorName || item.author || ''),
    cover: String(getJson(item, coverR) || ''),
    url: String(getJson(item, urlR) || item.noteUrl || item.bookUrl || item.id || ''),
  })).filter(i => i.name);
}

// ====== 诊断核心 ======

async function diagnose(source, idx, total) {
  const name = source.bookSourceName || '?';
  const searchUrl = source.searchUrl || '';
  const baseUrl = getBaseUrl(source.bookSourceUrl || '');
  const rs = source.ruleSearch || {};
  const isJsonAPI = (rs.author || '').startsWith('$.') || (rs.author || '').startsWith('@json:')
    || (rs.bookList || '').startsWith('$.') || (rs.bookList || '').startsWith('@json:');

  process.stdout.write(`[${idx}/${total}] ${name}... `);

  if (!searchUrl) { console.log('⏭️ 无 searchUrl'); return null; }

  const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
  if (!built) { console.log('⏭️ URL构建失败'); return null; }

  let body;
  try {
    body = await doFetch(built.url, built.method, built.body);
    if (!body || body.length < 50) { console.log(`❌ ${body?.length||0} bytes`); return null; }
  } catch (e) { console.log(`❌ ${e.message?.substring(0,50)}`); return null; }

  // 检测 JSON
  let jsonResults = [];
  let isJson = false;
  if (body.trimStart().startsWith('{') || body.trimStart().startsWith('[')) {
    jsonResults = extractJSON(body, source, baseUrl);
    if (jsonResults.length > 0) isJson = true;
  }

  // CSS
  let cssResults = [];
  if (!isJson && (rs.bookList || rs.list)) {
    cssResults = extractCSS(body, source, baseUrl);
  }

  // 检查结果中是否有"冲出四合院"准确匹配
  const primary = jsonResults.length > 0 ? jsonResults : cssResults;
  const exactMatch = primary.find(r => r.name === '冲出四合院');
  const fuzzyMatch = primary.find(r => r.name.includes('冲出四合院'));
  const hasTarget = primary.some(r => r.name.includes('四合院'));

  // 检查每个结果的名字、作者
  const withAuthor = primary.filter(r => r.author).length;
  const withCover = primary.filter(r => r.cover).length;

  // 输出前 5 个结果
  const snippet = primary.slice(0, 5).map(r =>
    `"${r.name.substring(0,20)}" 作者=${r.author || '?'} 封面=${r.cover ? '✓' : '✗'}`
  ).join(' | ');

  const tag = isJson ? 'JSON' : 'CSS';
  const status = exactMatch ? '✅准确' : (fuzzyMatch ? '⚠️模糊' : (hasTarget ? '🔸含四合院' : '❌无目标'));
  console.log(`${tag}=${primary.length} ${status} 作者=${withAuthor}/${primary.length} 封面=${withCover}/${primary.length}`);
  if (primary.length > 0) console.log(`  例: ${snippet}`);

  // 如果 CSS 没提取到作者或封面，分析原因
  const issues = [];
  if (cssResults.length > 0 && withAuthor === 0) {
    const ar = rs.author || '';
    issues.push(`CSS作者选择器"${ar}"未匹配`);
    // 尝试直接找页面上的作者文本
    const $ = cheerio.load(body);
    if (ar) {
      const cssSel = norm(ar);
      try {
        const found = $(cssSel);
        if (found.length === 0 && cssSel) {
          issues.push(`  选择器"${cssSel}"在页面中无匹配元素`);
        } else if (found.length > 0) {
          issues.push(`  选择器"${cssSel}"匹配了${found.length}个元素，但提取结果为空`);
        }
      } catch (e) {
        issues.push(`  选择器"${cssSel}"解析错误: ${e.message}`);
      }
    }
  }

  // 分析 bookList 选择器是否匹配
  if (!isJson && (rs.bookList || rs.list)) {
    const $ = cheerio.load(body);
    const listSel = norm(rs.bookList || rs.list);
    try {
      const matched = $(listSel).length;
      if (matched === 0) {
        issues.push(`列表选择器"${listSel}"无匹配元素`);
        // 尝试找常见替代
        for (const alt of ['li', '.item', '.book', '.list', 'tr', 'tbody tr', 'ul li']) {
          const c = $(alt).length;
          if (c > 5) { issues.push(`  候选: "${alt}" 匹配了${c}个元素`); break; }
        }
      }
    } catch (e) {
      issues.push(`列表选择器解析错误: ${e.message}`);
    }
  }

  if (issues.length > 0) {
    console.log(`  ⚠️ ${issues.join('\n    ')}`);
  }

  // 对于重点源，保存原始 HTML
  const keySources = ['⭐️ 企鹅阅读', '⭐ 七猫小说', '🎉 饿狼小说'];
  if (keySources.includes(name)) {
    const safeName = name.replace(/[^a-zA-Z0-9\u4e00-\u9fff]/g, '_');
    fs.writeFileSync(path.join(SAVE_DIR, `${safeName}.html`), body);
    console.log(`  📄 HTML已保存到 output/${safeName}.html`);
  }

  return {
    name, type: isJson ? 'json' : 'css',
    total: primary.length, exact: !!exactMatch, fuzzy: !!fuzzyMatch,
    hasTarget, withAuthor, withCover,
    snippet, issues,
    ruleSearch: rs,
    searchUrl: built.url,
    bodyLength: body.length,
  };
}

// ====== 主逻辑 ======

async function main() {
  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const all = JSON.parse(raw);
  console.log(`共 ${all.length} 个书源\n`);
  console.log('格式: [序号] 源名 提取方式=结果数 状态 作者数/总数 封面数/总数');
  console.log('状态: ✅准确=书名完全匹配"冲出四合院" ⚠️模糊=包含"冲出四合院" 🔸含四合院 ❌无目标');
  console.log('');

  const results = [];
  const concurrency = 5;
  let idx = 0;

  async function worker() {
    while (idx < all.length) {
      const i = idx++;
      results.push(await diagnose(all[i], i + 1, all.length));
    }
  }

  await Promise.all(Array(concurrency).fill().map(() => worker()));

  // ====== 报告 ======

  console.log('\n\n========== 汇总报告 ==========\n');

  const valid = results.filter(Boolean);
  const exact = valid.filter(r => r.exact);
  const fuzzy = valid.filter(r => r.fuzzy && !r.exact);
  const hasSiheyuan = valid.filter(r => r.hasTarget && !r.fuzzy && !r.exact);
  const none = valid.filter(r => !r.hasTarget);

  console.log(`成功获取响应: ${valid.length}/${all.length}`);
  console.log(`✅ 准确匹配"${KEYWORD}": ${exact.length}个源`);
  console.log(`⚠️ 模糊匹配(含"${KEYWORD}"): ${fuzzy.length}个源`);
  console.log(`🔸 含"四合院"但不含"冲出": ${hasSiheyuan.length}个源`);
  console.log(`❌ 未找到"四合院"相关: ${none.length}个源\n`);

  if (exact.length > 0) {
    console.log('=== ✅ 准确匹配的源 ===');
    exact.forEach(r => console.log(`  ${r.name} (${r.type}, ${r.total}条, 作者=${r.withAuthor}, 封面=${r.withCover})`));
    console.log();
  }

  if (fuzzy.length > 0) {
    console.log('=== ⚠️ 模糊匹配的源 ===');
    fuzzy.forEach(r => console.log(`  ${r.name} (${r.type}, ${r.total}条, 作者=${r.withAuthor}, 封面=${r.withCover})`));
    console.log();
  }

  // 问题源详情
  const problemSources = valid.filter(r => {
    const noAuthorCSS = r.type === 'css' && r.total > 0 && r.withAuthor === 0;
    const noTarget = !r.exact && !r.fuzzy && r.total > 0;
    return noAuthorCSS || noTarget;
  });

  console.log(`=== 问题源详情 (${problemSources.length}) ===\n`);

  for (const r of problemSources) {
    console.log(`【${r.name}】`);
    console.log(`  类型: ${r.type}, 结果数: ${r.total}`);
    console.log(`  ruleSearchList: ${r.ruleSearch?.bookList || r.ruleSearch?.list || '(空)'}`);
    console.log(`  ruleSearchName: ${r.ruleSearch?.name || '(空)'}`);
    console.log(`  ruleSearchAuthor: ${r.ruleSearch?.author || '(空)'}`);
    console.log(`  ruleSearchCover: ${r.ruleSearch?.coverUrl || '(空)'}`);
    console.log(`  ruleSearchNoteUrl: ${r.ruleSearch?.bookUrl || '(空)'}`);
    if (r.issues.length > 0) console.log(`  问题:\n    ${r.issues.join('\n    ')}`);
    console.log();
  }

  // 特别报告：企鹅阅读、七猫、饿狼小说
  console.log('=== 重点源分析 ===\n');

  for (const keyName of ['⭐️ 企鹅阅读', '⭐ 七猫小说', '🎉 饿狼小说']) {
    const r = valid.find(v => v.name === keyName);
    if (!r) { console.log(`【${keyName}】未获取到数据\n`); continue; }
    console.log(`【${keyName}】`);
    console.log(`  搜索URL: ${r.searchUrl.substring(0, 100)}`);
    console.log(`  响应: ${r.bodyLength} bytes`);
    console.log(`  结果: ${r.total}条 | ${r.exact ? '✅准确' : r.fuzzy ? '⚠️模糊' : r.hasTarget ? '🔸含四合院' : '❌无'}`);
    console.log(`  ruleSearch: ${JSON.stringify(r.ruleSearch, null, 4)}`);

    // 分析可用性
    const rs = r.ruleSearch || {};
    const issues = [];
    if (!rs.bookList && !rs.list) issues.push('缺少 bookList');
    if (!rs.name) issues.push('缺少 name');
    if (!rs.author) issues.push('缺少 author');
    if (issues.length > 0) console.log(`  配置问题: ${issues.join(', ')}`);
    console.log();
  }
}

main().catch(console.error);
