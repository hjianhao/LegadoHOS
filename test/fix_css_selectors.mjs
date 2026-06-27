/**
 * 逐个分析 CSS 失效源，抓取搜索页面，修复选择器
 */
import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 12000;
const KEYWORD = '冲出四合院';
const SRC = path.resolve(__dirname, 'source.json');

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
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(t); }
}

// 需要修复的源
const fixTargets = [
  '🎉 当阅读网', '🎉 歌书小说', '🎉 黄易小说', '🎉 久久小说',
  '🎉 手机小说', '🎉 搜搜小说', '💐 言情小说', '💠 乐库小说',
  '💠 手机看书', '💠 书满屋网', '💠 望书阁网',
];

const raw = fs.readFileSync(SRC, 'utf-8');
const data = JSON.parse(raw);
const updated = JSON.parse(raw);
let fixCount = 0;

async function main() {
  for (const target of fixTargets) {
    const keyword = target.replace(/^[^ ]+ /, '');
    const source = data.find(s => (s.bookSourceName || '').includes(keyword));
    if (!source) { console.log('❌ 未找到:', target); continue; }

    const name = source.bookSourceName;
    const searchUrl = source.searchUrl || '';
    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const rs = source.ruleSearch || {};
    const oldList = rs.bookList || rs.list || '';

    process.stdout.write(`【${name}】旧="${oldList}" → `);

    const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
    if (!built) { console.log('⏭️ URL构建失败'); continue; }

    const resp = await doFetch(built.url, built.method, built.body);
    if (!resp.text || resp.text.length < 200) {
      console.log(`⏭️ 响应为空 (${resp.status})`);
      continue;
    }

    const $ = cheerio.load(resp.text);

    // 分析页面：找包含多个书籍链接的容器
    const candidates = [];
    for (const sel of ['li', 'tr', 'dd', 'div.item', 'div.book', '.book-list li',
      '.search-item', '.result-item', '.novelslist2 li', '.txt-list-row5 li',
      'div[class*="item"]', 'div[class*="book"]', 'li[class*="item"]',
      'tbody tr', 'ul li', 'dl dd']) {
      try {
        const els = $(sel);
        if (els.length < 2 || els.length > 150) continue;
        let bookCount = 0, hasImg = 0;
        els.each((i, el) => {
          const h = $(el).find('a').first().attr('href') || '';
          if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || /\/\d{4,}\/?$/.test(h)) bookCount++;
          if ($(el).find('img').length > 0) hasImg++;
        });
        if (bookCount >= 2) candidates.push({ sel, total: els.length, bookLinks: bookCount, hasImgs: hasImg });
      } catch (_) {}
    }

    if (candidates.length === 0) {
      console.log('❌ 未找到合适容器');
      continue;
    }

    const best = candidates.sort((a, b) => b.bookLinks - a.bookLinks)[0];
    const newList = best.sel;
    console.log(`✅ 新="${newList}" (${best.bookLinks}个书籍链接, ${best.hasImgs}个含图)`);

    // 更新 source
    const idx = updated.findIndex(s => (s.bookSourceName || '') === name);
    if (idx >= 0 && newList !== oldList) {
      if (!updated[idx].ruleSearch) updated[idx].ruleSearch = {};
      updated[idx].ruleSearch.bookList = newList;
      // 用通用子选择器
      if (!updated[idx].ruleSearch.name || updated[idx].ruleSearch.name === '-') {
        updated[idx].ruleSearch.name = 'a.0@text';
      }
      if (!updated[idx].ruleSearch.author || updated[idx].ruleSearch.author === '-') {
        updated[idx].ruleSearch.author = 'span.0@text';
      }
      if (!updated[idx].ruleSearch.coverUrl || updated[idx].ruleSearch.coverUrl === '-') {
        updated[idx].ruleSearch.coverUrl = 'img.0@src';
      }
      if (!updated[idx].ruleSearch.bookUrl || updated[idx].ruleSearch.bookUrl === '-') {
        updated[idx].ruleSearch.bookUrl = 'a.0@href';
      }
      fixCount++;
    }
  }

  if (fixCount > 0) {
    fs.writeFileSync(path.resolve(__dirname, 'source_fixed_css.json'), JSON.stringify(updated, null, 2), 'utf-8');
    console.log(`\n✅ 修复了 ${fixCount} 个源的 CSS 选择器`);
    console.log(`文件: source_fixed_css.json`);
    console.log(`使用: cp test/source_fixed_css.json test/source.json`);
  } else {
    console.log('\n❌ 没有修复任何源');
  }
}

main().catch(console.error);
