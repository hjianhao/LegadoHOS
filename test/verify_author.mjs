/**
 * 验证作者提取 — 端到端测试
 *
 * 流程：搜索 → 取第一个结果的详情页 → 提取作者和书名
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT_MS = 15000;
const SEARCH_KEYWORD = '冲出四合院';

async function fetchUrl(url, method = 'GET', body = null) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const opts = { method, headers, signal: controller.signal };
    if (body && method === 'POST') {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      opts.body = body;
    }
    const resp = await fetch(url, opts);
    return await resp.text();
  } finally {
    clearTimeout(timeout);
  }
}

function getBaseUrl(rawUrl) {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

function buildSearchUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const encoded = encodeURIComponent(keyword);
  // 移除 cookie 操作
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '');
  url = url.replace(/\{\{key\}\}/g, encoded).replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page)).replace(/\{\{pageNum\}\}/g, String(page + 1));
  url = url.replace(/\{\{[^}]*\}\}/g, '').replace(/<js>[\s\S]*?<\/js>/gi, '');

  // 合并多行：找到 URL 行和后续 JSON 行
  // 移除空行和纯注释行
  url = url.replace(/\n\s*\n/g, '\n');
  // 将换行替换为空格（但保留 JSON 结构的 {} 完整性）
  url = url.replace(/\n\s*/g, '');
  // 处理 @js: 表达式
  while (url.includes('@js:')) {
    const jsIdx = url.indexOf('@js:');
    const jsonOptStart = url.indexOf(',{', jsIdx);
    url = jsonOptStart > jsIdx ? url.substring(0, jsIdx) + url.substring(jsonOptStart) : url.substring(0, jsIdx);
  }
  while (url.includes('@js:')) {
    const jsIdx = url.indexOf('@js:');
    const jsonOptStart = url.indexOf(',{', jsIdx);
    url = jsonOptStart > jsIdx ? url.substring(0, jsIdx) + url.substring(jsonOptStart) : url.substring(0, jsIdx);
  }
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    url = url.replace(pageGroupMatch[0], items[Math.min(page - 1, items.length - 1)].trim());
  }
  let jsonRaw = '';
  const jsonMatch = url.match(/^(.+?),?\s*(\{[\s\S]*\})$/);
  if (jsonMatch) { url = jsonMatch[1].trim(); jsonRaw = jsonMatch[2]; }
  if (!url.startsWith('http') && baseUrl) {
    url = baseUrl.replace(/\/+$/, '') + (url.startsWith('/') ? url : '/' + url);
  }
  let method = 'GET';
  let body = '';
  if (jsonRaw) {
    try {
      const opts = JSON.parse(jsonRaw.replace(/'/g, '"').replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3'));
      if (opts.method) method = opts.method.toUpperCase();
      if (opts.body) body = opts.body.replace(/\{\{key\}\}/g, encoded).replace(/\{\{keyword\}\}/g, encoded);
    } catch (_e) {}
  }
  url = url.trim();
  return url ? { url, method, body } : null;
}

function getJsonPath(obj, path) {
  if (!path || !obj) return undefined;
  if (path.includes('||')) {
    for (const alt of path.split(/\|\|/)) {
      const v = getJsonPath(obj, alt.trim());
      if (v !== undefined && v !== null && v !== '') return v;
    }
    return undefined;
  }
  const parts = path.replace(/^\$\.?/, '').split('.');
  let current = obj;
  for (const part of parts) {
    if (current == null) return undefined;
    const am = part.match(/^(\w+)(?:\[(\d+|\*)])?$/);
    if (am) {
      const [_, key, index] = am;
      current = Array.isArray(current) ? (index === '*' || !index ? current[0]?.[key] : current[parseInt(index)]?.[key]) : current[key];
    } else {
      current = current[part];
    }
  }
  return current;
}

function extractJsonResults(json, source, baseUrl) {
  let list = null;
  if (source.ruleSearchList) {
    const raw = getJsonPath(json, source.ruleSearchList);
    if (Array.isArray(raw)) list = raw;
  }
  if (!list) {
    if (Array.isArray(json)) list = json;
    else for (const p of ['data', 'list', 'items', 'results', 'books']) {
      const raw = json[p];
      if (Array.isArray(raw)) { list = raw; break; }
    }
  }
  if (!list) return [];
  return list.map(item => ({
    name: String(getJsonPath(item, source.ruleSearchName) || item.novelName || item.name || item.title || ''),
    author: String(getJsonPath(item, source.ruleSearchAuthor) || item.authorName || item.author || ''),
    coverUrl: String(getJsonPath(item, source.ruleSearchCover) || ''),
    noteUrl: String(getJsonPath(item, source.ruleSearchNoteUrl) || item.noteUrl || item.bookUrl || item.id || ''),
  })).filter(i => i.name);
}

// ======== 主测试 ========

async function main() {
  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const allSources = JSON.parse(raw);

  // 选 4 个代表性的 HTML 源来测试（从搜索结果中 CSS=100 或 正则多）
  const targets = [
    // HTML 源（搜索结果里 CSS 提取正常）
    { name: '当阅读网', key: '当阅读网' },
    { name: '独步小说', key: '独步小说' },
    { name: '抖音小说', key: '抖音小说' },
    // HTML 源（CSS=0 但正则救回了）
    { name: '香书小说', key: '香书小说' },
  ];

  for (const target of targets) {
    const source = allSources.find(s => (s.bookSourceName || '').includes(target.key));
    if (!source) { console.log(`\n❌ 未找到源: ${target.key}`); continue; }

    console.log(`\n========== ${source.bookSourceName} ==========`);

    const baseUrl = getBaseUrl(source.bookSourceUrl || '');
    const built = buildSearchUrl(source.searchUrl, SEARCH_KEYWORD, 1, baseUrl);
    if (!built) { console.log('⏭️  搜索 URL 构建失败'); continue; }

    // 1. 搜索
    console.log(`搜索 URL: ${built.url.substring(0, 80)}...`);
    try {
      const searchBody = await fetchUrl(built.url, built.method, built.body);
      if (!searchBody || searchBody.length < 100) {
        console.log(`❌ 搜索无响应 (${searchBody?.length || 0})`);
        continue;
      }
      console.log(`搜索响应: ${searchBody.length} bytes`);

      // 2. 从搜索 HTML 中提取第一个详情页 URL
      let detailUrl = '';
      let bookName = '';

      // a) 尝试 JSON 提取
      let isJson = searchBody.trimStart().startsWith('[') || searchBody.trimStart().startsWith('{');
      if (isJson) {
        try {
          const json = JSON.parse(searchBody);
          const rs = source.ruleSearch || {};
          const results = extractJsonResults(json, {
            ruleSearchList: rs.bookList || rs.list || '',
            ruleSearchName: rs.name || '',
            ruleSearchAuthor: rs.author || '',
            ruleSearchCover: rs.coverUrl || '',
            ruleSearchNoteUrl: rs.bookUrl || '',
          }, baseUrl);
          if (results.length > 0) {
            detailUrl = results[0].noteUrl;
            bookName = results[0].name;
            console.log(`JSON 搜索结果: ${bookName} | 作者: ${results[0].author} | url: ${detailUrl.slice(0, 60)}`);
          }
        } catch (_e) {}
      }

      // b) 尝试 CSS 提取
      if (!detailUrl) {
        const $ = cheerio.load(searchBody);
        const rs = source.ruleSearch || {};
        // 简化找第一个 link 的 href
        const firstLink = $('a[href]').first();
        if (firstLink.length) {
          detailUrl = firstLink.attr('href') || '';
          if (detailUrl && !detailUrl.startsWith('http')) {
            detailUrl = baseUrl.replace(/\/+$/, '') + (detailUrl.startsWith('/') ? detailUrl : '/' + detailUrl);
          }
        }
        bookName = '冲出四合院';
        if (detailUrl) console.log(`CSS 找到详情页 URL: ${detailUrl.slice(0, 80)}`);
      }

      if (!detailUrl) {
        console.log('❌ 无法获取详情页 URL');
        continue;
      }

      // 3. 取详情页
      console.log(`\n抓取详情页: ${detailUrl.slice(0, 80)}`);
      const detailBody = await fetchUrl(detailUrl);
      if (!detailBody || detailBody.length < 200) {
        console.log(`❌ 详情页响应太短 (${detailBody?.length || 0})`);
        continue;
      }
      console.log(`详情页响应: ${detailBody.length} bytes`);

      // 4. 用 ruleBookInfo 提取作者
      const rb = source.ruleBookInfo || {};
      const authorRule = rb.author || '';
      const nameRule = rb.name || '';

      console.log(`\nruleBookInfo.author: "${authorRule}"`);
      console.log(`ruleBookInfo.name: "${nameRule}"`);

      if (!authorRule) {
        console.log('❌ 无作者规则');
        continue;
      }

      let extractedAuthor = '';
      let extractedName = '';

      // JSON 路径
      if (authorRule.startsWith('$.') || authorRule.startsWith('@json:')) {
        try {
          const json = JSON.parse(detailBody);
          const path = authorRule.replace(/^@json:/, '');
          extractedAuthor = String(getJsonPath(json, path) || '');
          if (nameRule) {
            const namePath = nameRule.replace(/^@json:/, '');
            extractedName = String(getJsonPath(json, namePath) || '');
          }
        } catch (_e) {
          // not JSON
        }
      }

      // CSS 规则
      if (!extractedAuthor) {
        const $ = cheerio.load(detailBody);

        // 归一化 Legado 规则
        let cssSel = authorRule
          .replace(/@@/g, '.')
          .replace(/id\./g, '#')
          .replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');

        let attrSuffix = 'text';
        const attrMatch = cssSel.match(/^(.*?)@(text|href|src|html|ownText)$/i);
        if (attrMatch) {
          cssSel = attrMatch[1].trim();
          attrSuffix = attrMatch[2].toLowerCase();
        }

        // 处理位置索引 tag.N
        let posIdx = -1;
        const posMatch = cssSel.match(/\.(\d+)$/);
        if (posMatch) {
          posIdx = parseInt(posMatch[1]);
          cssSel = cssSel.replace(/\.\d+$/, '');
        }

        try {
          const $els = cssSel ? $(cssSel) : $('body');
          const $el = posIdx >= 0 ? $els.eq(posIdx) : $els.first();
          if ($el.length) {
            switch (attrSuffix) {
              case 'text': extractedAuthor = $el.text().trim(); break;
              case 'href': extractedAuthor = $el.attr('href') || ''; break;
              case 'src': extractedAuthor = $el.attr('src') || ''; break;
              case 'html': extractedAuthor = $el.html() || ''; break;
              default: extractedAuthor = $el.text().trim();
            }
          }
        } catch (e) {
          console.log(`  CSS 解析错误: ${e.message}`);
        }

        // 提取书名
        if (nameRule) {
          let nameCss = nameRule.replace(/@@/g, '.').replace(/id\./g, '#')
            .replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');
          const nameAttrM = nameCss.match(/^(.*?)@(text|href|src|html|ownText)$/i);
          if (nameAttrM) { nameCss = nameAttrM[1].trim(); }
          let nPosIdx = -1;
          const nPosM = nameCss.match(/\.(\d+)$/);
          if (nPosM) { nPosIdx = parseInt(nPosM[1]); nameCss = nameCss.replace(/\.\d+$/, ''); }
          try {
            const $nEls = nameCss ? $(nameCss) : $('body');
            const $nEl = nPosIdx >= 0 ? $nEls.eq(nPosIdx) : $nEls.first();
            if ($nEl.length) extractedName = $nEl.text().trim();
          } catch (_e) {}
        }
      }

      // 清理作者（移除"作者："前缀等）
      if (extractedAuthor) {
        extractedAuthor = extractedAuthor.replace(/^作者[：:]\s*/i, '').trim();
      }

      console.log(`\n📌 提取作者: "${extractedAuthor}" ${extractedAuthor ? '✅' : '❌'}`);
      if (extractedName) console.log(`📌 提取书名: "${extractedName}"`);

      // 从页面标题提取对比
      const titleM = detailBody.match(/<title>([^<]+)<\/title>/i);
      if (titleM) console.log(`📌 页面标题: "${titleM[1].trim()}"`);

    } catch (e) {
      console.log(`❌ 错误: ${e.message?.substring(0, 120)}`);
    }
  }
}

main().catch(console.error);
