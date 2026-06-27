/**
 * 逐个修复6个CSS失效源 — 抓取页面 → 分析HTML → 更新配置
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

async function doFetch(u, method = 'GET', body = null, uaIdx = 0) {
  const c = new AbortController(); const t = setTimeout(() => c.abort(), TIMEOUT);
  const agents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.165 Mobile Safari/537.36',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  ];
  try {
    const h = { 'User-Agent': agents[uaIdx % agents.length],
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': u.substring(0, u.indexOf('/', 8) > 0 ? u.indexOf('/', 8) : u.length) };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(t); }
}

function analyzeHTML($, body, baseUrl) {
  const result = { containers: [], targetLinks: [] };
  const links = [];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href') || '';
    const text = $(el).text().trim();
    if (href && !href.startsWith('#') && !href.startsWith('javascript:') && text.length >= 2) {
      links.push({ href, text });
    }
  });
  result.targetLinks = links.filter(l => l.text.includes('四合院') || l.text.includes(KEYWORD));
  result.allLinks = links;

  // 找书籍容器
  for (const sel of ['li', 'tr', 'dd', '.item', '.book', '.search-item', '.result-item',
    '.list-item', '.book-item', 'div[class*="item"]', 'div[class*="book"]',
    'div[class*="list"]', 'li[class*="item"]', 'ul li', 'tbody tr',
    '.novelslist2 li', '.txt-list-row5 li', '.hot_sale li', '.book-list li',
    '.search-list li', '.list li', 'dl dd']) {
    try {
      const els = $(sel);
      if (els.length < 2 || els.length > 200) continue;
      let bookCount = 0, hasImg = 0, hasAuthor = 0;
      els.each((i, el) => {
        const $el = $(el);
        const h = $el.find('a').first().attr('href') || '';
        if (h.includes('.html') || h.includes('/book/') || h.includes('/novel/') || /\/\d{4,}\/?$/.test(h)) bookCount++;
        if ($el.find('img').length > 0) hasImg++;
        if ($el.text().includes('作者') || $el.find('.author').length > 0) hasAuthor++;
      });
      if (bookCount >= 2) {
        const sample = els.length > 0 ? $(els[0]).text().trim().substring(0, 60) : '';
        result.containers.push({ sel, total: els.length, bookLinks: bookCount, hasImgs: hasImg, hasAuthor, sample });
      }
    } catch (_) {}
  }
  result.containers.sort((a, b) => b.bookLinks - a.bookLinks);
  return result;
}

function generateRules(containerSel, analysis, baseUrl) {
  const rules = { bookList: containerSel, name: 'a.0@text', author: 'span.0@text', coverUrl: 'img.0@src', bookUrl: 'a.0@href' };
  return rules;
}

// ==== MAIN ====
const raw = fs.readFileSync(SRC, 'utf-8');
const data = JSON.parse(raw);
const updated = JSON.parse(raw);

const needFix = [
  { name: '🎉 当阅读网', via: 'sososhu', direct: false },
  { name: '🎉 搜搜小说', via: 'sososhu', direct: false },
  { name: '🎉 手机小说', via: 'shoujix', direct: true },
  { name: '💐 言情小说', via: 'yqk', direct: true },
  { name: '💠 手机看书', via: 'sjks88', direct: true },
  { name: '💠 望书阁网', via: 'wangshugu', direct: true },
];

let fixedCount = 0;

async function main() {
  for (const target of needFix) {
    const keyword = target.name.replace(/^[^ ]+ /, '');
    const source = data.find(s => (s.bookSourceName || '').includes(keyword));
    if (!source) { console.log(`❌ 未找到: ${target.name}`); continue; }

    const name = source.bookSourceName;
    const searchUrl = source.searchUrl || '';
    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const rs = source.ruleSearch || {};
    const oldList = rs.bookList || rs.list || '';

    console.log(`\n=== ${name} ===`);
    console.log(`旧选择器: bookList="${oldList}"`);

    const built = buildUrl(searchUrl, KEYWORD, 1, baseUrl);
    if (!built) { console.log('⏭️ URL构建失败'); continue; }

    console.log(`搜索URL: ${built.url.substring(0, 100)}`);

    let body = '';
    let htmlSaved = false;

    // 尝试3个不同的 User-Agent
    for (let uaIdx = 0; uaIdx < 3; uaIdx++) {
      const resp = await doFetch(built.url, built.method, built.body, uaIdx);
      if (resp.text && resp.text.length > 200) {
        body = resp.text;
        // 保存HTML
        const safeName = name.replace(/[^\w\u4e00-\u9fff]/g, '_');
        fs.writeFileSync(path.resolve(__dirname, 'output', `${safeName}.html`), body);
        htmlSaved = true;
        console.log(`✅ 获取成功 (${body.length} bytes), HTML已保存`);
        break;
      }
      if (uaIdx < 2) console.log(`  尝试UA${uaIdx+1}失败(${resp.status})，换UA重试...`);
    }

    if (!body) { console.log('❌ 无法获取页面'); continue; }

    const $ = cheerio.load(body);
    const analysis = analyzeHTML($, body, baseUrl);

    if (analysis.containers.length === 0) {
      console.log(`❌ 未找到书籍容器 (共${analysis.allLinks.length}个链接)`);
      if (analysis.targetLinks.length > 0) {
        console.log(`  但页面含"四合院"链接: ${analysis.targetLinks.length}个`);
        analysis.targetLinks.forEach((l, i) => console.log(`    ${i+1}. "${l.text.substring(0,30)}" → ${l.href.substring(0,60)}`));
      }
      continue;
    }

    const best = analysis.containers[0];
    console.log(`✅ 最佳容器: "${best.sel}" (${best.total}个, ${best.bookLinks}个书籍链接, ${best.hasImgs}个含图)`);
    console.log(`  示例: ${best.sample}`);

    if (analysis.targetLinks.length > 0) {
      console.log(`  含目标结果: ${analysis.targetLinks.length}条`);
    }

    // 显示前3个容器的信息
    analysis.containers.slice(0, 3).forEach((c, i) => {
      console.log(`  候选${i+1}: "${c.sel}" (${c.total}个, ${c.bookLinks}书籍, ${c.hasImgs}图)`);
    });

    // 更新配置
    const rules = generateRules(best.sel, analysis, baseUrl);
    const idx = updated.findIndex(s => (s.bookSourceName || '') === name);
    if (idx >= 0) {
      if (!updated[idx].ruleSearch) updated[idx].ruleSearch = {};
      updated[idx].ruleSearch.bookList = rules.bookList;
      updated[idx].ruleSearch.name = rules.name;
      updated[idx].ruleSearch.author = rules.author;
      updated[idx].ruleSearch.coverUrl = rules.coverUrl;
      updated[idx].ruleSearch.bookUrl = rules.bookUrl;
      console.log(`\n📝 建议更新:`);
      console.log(`  bookList: ${oldList} → ${rules.bookList}`);
      console.log(`  name: ${rs.name || '(空)'} → ${rules.name}`);
      console.log(`  author: ${rs.author || '(空)'} → ${rules.author}`);
      console.log(`  coverUrl: ${rs.coverUrl || rs.cover || '(空)'} → ${rules.coverUrl}`);
      console.log(`  bookUrl: ${rs.bookUrl || rs.noteUrl || '(空)'} → ${rules.bookUrl}`);
      fixedCount++;
    }
  }

  if (fixedCount > 0) {
    fs.writeFileSync(path.resolve(__dirname, 'source_fixed_6.json'), JSON.stringify(updated, null, 2), 'utf-8');
    console.log(`\n✅ 修复了 ${fixedCount} 个源`);
    console.log(`文件: source_fixed_6.json`);
    console.log(`使用: cp test/source_fixed_6.json test/source.json`);
  } else {
    console.log('\n❌ 没有源可修复');
  }
}

main().catch(console.error);
