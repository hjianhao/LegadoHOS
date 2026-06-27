/**
 * 分析并修复失效的源配置
 * 
 * 对 CSS 选择器无匹配的源，抓取搜索页面，
 * 分析实际 HTML 结构，更新规则。
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT_MS = 12000;
const KEYWORD = '冲出四合院';

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
  const c = new AbortController(); const t = setTimeout(() => c.abort(), TIMEOUT_MS);
  try {
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return await r.text();
  } finally { clearTimeout(t); }
}

// 将 Legado 规则归一化为 CSS
function norm(rule) {
  if (!rule) return '';
  let r = rule;
  if (r.startsWith('@css:')) r = r.slice(5);
  const h = r.indexOf('##');
  if (h >= 0) r = r.substring(0, h);
  if (r.includes('||')) r = r.split('||')[0];
  // 处理 Legado 格式
  r = r.replace(/@text\b/g, '').replace(/@href\b/g, '').replace(/@src\b/g, '')
    .replace(/@html\b/g, '').replace(/@ownText\b/g, '');
  r = r.replace(/@@/g, '.').replace(/id\./g, '#');
  r = r.replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');
  // 移除 Legado 特殊语法
  r = r.replace(/!\d+/g, ''); // 移除 !0 !1
  r = r.replace(/\.\d+/g, ''); // 移除位置索引
  return r.trim();
}

async function analyzeSource(source) {
  const name = source.bookSourceName || '?';
  const searchUrl = source.searchUrl || '';
  const baseUrl = getBaseUrl(source.bookSourceUrl || '');
  const rs = source.ruleSearch || {};
  const listRule = rs.bookList || rs.list || '';
  const isJson = listRule.startsWith('$.') || listRule.startsWith('@json:');
  const hasJsUrl = searchUrl.trimStart().startsWith('@js:');

  if (!searchUrl || isJson || hasJsUrl) return null;

  const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
  if (!built) return null;

  let body;
  try {
    body = await doFetch(built.url, built.method, built.body);
    if (!body || body.length < 100) return null;
  } catch (e) { return null; }

  // 检查 JSON 响应
  if (body.trimStart().startsWith('{') || body.trimStart().startsWith('[')) return null;

  const $ = cheerio.load(body);
  const cssSel = norm(listRule);
  const matched = cssSel ? $(cssSel).length : -1;

  return {
    name, source, body, $,
    cssSel, matched,
    listRule, baseUrl,
    builtUrl: built.url,
  };
}

function suggestSelectors($, baseUrl, body) {
  const suggestions = [];
  const html = body;

  // 找包含"冲出四合院"或"四合院"的链接
  const targetLinks = [];
  const linkR = /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,50})[^<]*四合院[^<]*<\/a>/gi;
  let m;
  while ((m = linkR.exec(html)) !== null) {
    targetLinks.push({ href: m[1], text: m[2] });
  }

  // 找所有包含多个链接的容器
  const containers = {};
  const allLinks = [];
  const linkR2 = /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,40})<\/a>/gi;
  while ((m = linkR2.exec(html)) !== null) {
    allLinks.push({ href: m[1], text: m[2] });
  }

  // 分析链接密度：找重复出现的父容器
  const parentCandidates = {};
  for (const link of allLinks) {
    // 找 href 中常见的路径模式
    const pathM = link.href.match(/\/(book|novel|info|read|txt|chapter)\//);
    if (pathM) {
      // 找这个链接在 HTML 中的上下文
      const idx = html.indexOf(link.href);
      if (idx > 0) {
        const ctx = html.substring(Math.max(0, idx - 300), idx);
        // 找最近的 <li>、<tr>、<div>、<dd> 等
        for (const tag of ['li', 'tr', 'dd', 'div', 'p', 'dl']) {
          const tagIdx = ctx.lastIndexOf('<' + tag);
          if (tagIdx >= 0) {
            const cls = ctx.substring(tagIdx, tagIdx + 80).match(/class=["']([^"']*)["']/);
            const clsStr = cls ? '.' + cls[1].replace(/\s+/g, '.') : '';
            const key = tag + clsStr;
            parentCandidates[key] = (parentCandidates[key] || 0) + 1;
          }
        }
      }
    }
  }

  // 找到出现次数最多的容器类型
  const sorted = Object.entries(parentCandidates).sort((a, b) => b[1] - a[1]);
  if (sorted.length > 0 && sorted[0][1] >= 3) {
    suggestions.push({ type: 'list', selector: sorted[0][0], count: sorted[0][1] });
  }

  // 尝试直接找表格结构
  const trs = $('tr').length;
  const lis = $('li').length;
  const items = $('.item, .book, .novel, .list-item, .search-item').length;

  suggestions.push({ type: 'stats', trs, lis, items,
    combined: allLinks.filter(l => l.href.includes('.html') || l.href.includes('/book/') || l.href.includes('/novel/')).length
  });

  return { suggestions, targetLinks, allLinksCount: allLinks.length };
}

// ====== 主逻辑 ======

async function main() {
  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const allSources = JSON.parse(raw);
  console.log('分析 CSS 选择器失效的源...\n');

  // 分析前几个 HTML 源（排除 JSON、@js:）
  const htmlSources = allSources.filter(s =>
    s.searchUrl && !s.searchUrl.trimStart().startsWith('@js:') &&
    !((s.ruleSearch?.bookList || s.ruleSearch?.list || '').startsWith('$.')) &&
    !((s.ruleSearch?.bookList || s.ruleSearch?.list || '').startsWith('@json:'))
  );

  console.log(`HTML 搜索源: ${htmlSources.length} / ${allSources.length}\n`);

  const results = [];
  const concurrency = 4;
  let idx = 0;

  async function worker() {
    while (idx < htmlSources.length) {
      const i = idx++;
      const result = await analyzeSource(htmlSources[i]);
      if (result) results.push(result);
      const icon = result && result.matched === 0 ? '❌' : (result && result.matched > 0 ? '✅' : '⏭️');
      process.stdout.write(`${icon} [${i+1}/${htmlSources.length}] ${result?.name || htmlSources[i].bookSourceName} (${result?.cssSel || '跳过'}: ${result?.matched ?? '-'})\n`);
    }
  }

  await Promise.all(Array(concurrency).fill().map(() => worker()));

  // ====== 输出分析结果 ======

  const zeroMatch = results.filter(r => r.matched === 0);
  console.log(`\n========== 分析报告 ==========\n`);
  console.log(`成功获取页面: ${results.length}/${htmlSources.length}`);
  console.log(`选择器有匹配: ${results.filter(r => r.matched > 0).length}`);
  console.log(`选择器无匹配: ${zeroMatch.length}\n`);

  // 对每个无匹配的源，分析页面结构
  let updatedCount = 0;

  for (const r of zeroMatch.slice(0, 20)) {
    console.log(`\n【${r.name}】`);
    console.log(`  当前 list 规则: ${r.listRule}`);
    console.log(`  归一化 CSS: ${r.cssSel}`);
    console.log(`  搜索URL: ${r.builtUrl.substring(0, 80)}`);

    const analysis = suggestSelectors(r.$, r.baseUrl, r.body);
    console.log(`  页面结构: tr=${analysis.suggestions[1]?.trs} li=${analysis.suggestions[1]?.lis} .item=${analysis.suggestions[1]?.items}`);
    console.log(`  书籍链接数: ${analysis.suggestions[1]?.combined}`);
    console.log(`  总链接数: ${analysis.allLinksCount}`);

    if (analysis.targetLinks.length > 0) {
      console.log(`  ✅ 找到含"四合院"的链接: ${analysis.targetLinks.length}`);
      analysis.targetLinks.slice(0, 3).forEach((t, i) =>
        console.log(`    ${i+1}. ${t.text.substring(0, 30)} → ${t.href.substring(0, 60)}`));
    } else {
      console.log(`  ❌ 页面中未找到含"四合院"的结果`);
    }

    if (analysis.suggestions[0]) {
      const sug = analysis.suggestions[0];
      console.log(`  💡 建议 list 选择器: ${sug.selector} (匹配${sug.count}次)`);
    }

    // 查找实际的书籍列表容器
    const $ = r.$;
    // 尝试找到包含多个书籍链接的容器
    for (const sel of ['ul li', 'tr', 'dd', '.list li', '.book-list li', '.search-list li', '.result-item']) {
      try {
        const els = $(sel);
        if (els.length >= 3 && els.length <= 100) {
          // 检查是否包含书籍链接
          let bookLinkCount = 0;
          els.each((i, el) => {
            const href = $(el).find('a').first().attr('href') || '';
            if (href.includes('.html') || href.includes('/book/') || href.includes('/novel/')) {
              bookLinkCount++;
            }
          });
          if (bookLinkCount >= 2) {
            console.log(`  📋 候选容器: "${sel}" (${els.length}个, 含${bookLinkCount}个书籍链接)`);
          }
        }
      } catch (_) {}
    }
  }

  // 生成更新后的源配置
  console.log(`\n\n========== 待更新源 ==========\n`);
  console.log(`发现 ${zeroMatch.length} 个选择器失效的 HTML 源。`);
  console.log(`其中 ${zeroMatch.filter(r => {
    // 估算哪些可以通过分析修复
    return r.body && r.body.length > 500;
  }).length} 个含有实际搜索结果（页面>500字节），可以尝试修复选择器。\n`);

  // 输出每个失效源的详细数据
  for (const r of zeroMatch) {
    console.log(`${r.name}|${r.listRule}|${r.builtUrl.substring(0, 100)}`);
  }
}

main().catch(console.error);
