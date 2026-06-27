/**
 * 分析手机小说和手机看书的网站结构，生成新源配置
 */
import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 15000;

async function fetch(u, method = 'GET', body = null) {
  const c = new AbortController(); setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(c); }
}

function analyzePage($, name, html) {
  console.log(`\n========== ${name} ==========`);
  console.log(`Title: ${$('title').text().trim()}`);
  console.log(`大小: ${html.length} bytes`);

  // 找搜索表单
  const forms = $('form');
  if (forms.length > 0) {
    console.log(`\n搜索表单 (${forms.length}个):`);
    forms.each((i, f) => {
      const action = $(f).attr('action') || '';
      const method = ($(f).attr('method') || 'get').toUpperCase();
      const inputs = [];
      $(f).find('input, select, textarea').each((j, inp) => {
        const name = $(inp).attr('name') || '';
        const type = $(inp).attr('type') || 'text';
        if (type !== 'submit' && type !== 'hidden') inputs.push(name + '=' + type);
      });
      console.log(`  ${i+1}. ${method} ${action} [${inputs.join(', ')}]`);
    });
  }

  // 找搜索相关的链接
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href') || '';
    const text = $(el).text().trim().toLowerCase();
    if (text.includes('搜索') || text.includes('search') || text.includes('搜书')) {
      console.log(`  搜索链接: "${$(el).text().trim()}" → ${href}`);
    }
  });

  // 分析常见类名/结构
  console.log('\n页面统计:');
  console.log(`  li=${$('li').length} tr=${$('tr').length} dd=${$('dd').length} img=${$('img').length}`);
  console.log(`  div=${$('div').length} a=${$('a').length}`);
}

async function main() {
  // 1. 手机小说
  const shoujixResp = await fetch('https://www.shoujix.com/');
  if (shoujixResp.text) {
    const $ = cheerio.load(shoujixResp.text);
    analyzePage($, '手机小说', shoujixResp.text);
    
    // 尝试搜索
    console.log(`\n--- 尝试搜索 ---`);
    const searchResp = await fetch('https://www.shoujix.com/search/', 'POST', 'searchkey=冲出四合院');
    if (searchResp.text && searchResp.text.length > 200) {
      const $2 = cheerio.load(searchResp.text);
      console.log(`搜索结果: ${searchResp.text.length} bytes, title=${$2('title').text().trim()}`);
      
      // 提取链接
      const links = [];
      $2('a[href]').each((i, el) => {
        const href = $2(el).attr('href') || '';
        const text = $2(el).text().trim();
        if (text && text.length >= 2 && !href.startsWith('#') && !href.startsWith('javascript:')) {
          links.push({ text, href });
        }
      });
      links.slice(0, 30).forEach((l, i) => console.log(`  ${i+1}. ${l.text.substring(0,30)} → ${l.href.substring(0,60)}`));
    }
  }

  // 2. 手机看书
  const sjksResp = await fetch('https://www.sjks88.com/');
  if (sjksResp.text) {
    const $ = cheerio.load(sjksResp.text);
    analyzePage($, '手机看书', sjksResp.text);

    // 尝试搜索
    console.log(`\n--- 尝试搜索 ---`);
    const searchResp2 = await fetch('https://www.sjks88.com/e/search/index.php', 'POST', 'keyboard=冲出四合院&show=title&submit=搜索');
    if (searchResp2.text && searchResp2.text.length > 200) {
      const $2 = cheerio.load(searchResp2.text);
      console.log(`搜索结果: ${searchResp2.text.length} bytes, title=${$2('title').text().trim()}`);
      const links = [];
      $2('a[href]').each((i, el) => {
        const href = $2(el).attr('href') || '';
        const text = $2(el).text().trim();
        if (text && text.length >= 2 && !href.startsWith('#') && !href.startsWith('javascript:')) {
          links.push({ text, href });
        }
      });
      links.slice(0, 30).forEach((l, i) => console.log(`  ${i+1}. ${l.text.substring(0,30)} → ${l.href.substring(0,60)}`));
    }
  }
}

main().catch(console.error);
