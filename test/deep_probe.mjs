/**
 * 深入分析有希望的页面结构
 */
import * as cheerio from 'cheerio';

const TIMEOUT = 15000;

async function fetch(u, method = 'GET', body = null) {
  const c = new AbortController(); setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
}

async function main() {
  // === 就爱文学 ===
  console.log('=== 就爱文学 deep probe ===');
  const resp = await fetch('http://www.92xs.info/modules/article/search.php', 'POST', 
    'searchtype=articlename&searchkey=冲出四合院');
  if (resp.text && resp.text.length > 200) {
    const $ = cheerio.load(resp.text);
    console.log('table count:', $('table').length);
    console.log('.grid tables:', $('.grid').length);
    console.log('tr.odd:', $('tr.odd').length, 'tr.even:', $('tr.even').length);
    console.log('#author:', $('#author').length);
    
    // All tr classes
    const trClasses = new Set();
    $('tr').each((i, el) => {
      const cls = $(el).attr('class') || '';
      if (cls) trClasses.add(cls);
    });
    console.log('tr classes:', [...trClasses]);
    
    // First 3 tr content
    $('tr').slice(0, 3).each((i, el) => {
      console.log(`tr[${i}]: "${$(el).text().trim().substring(0, 80)}"`);
    });
    
    // Find 冲出四合院
    $('tr').each((i, el) => {
      if ($(el).text().includes('冲出四合院')) {
        console.log(`\n冲出四合院 in tr[${i}]:`);
        const html = $(el).html() || '';
        console.log(html.substring(0, 400));
      }
    });

    // Check if id=alistbox exists (old selector for 多多书院 style)
    console.log('#alistbox:', $('#alistbox').length);
    
    // Check page structure
    console.log('div.grid tr:', $('.grid tr').length);
  } else {
    console.log('empty response:', resp.status, resp.text?.length);
    // Try different POST body format
    const resp2 = await fetch('http://www.92xs.info/modules/article/search.php', 'POST',
      'searchkey=冲出四合院');
    if (resp2.text?.length > 200) {
      console.log('2nd try OK, size:', resp2.text.length);
    }
  }

  // === 抖音小说 ===
  console.log('\n=== 抖音小说 deep probe ===');
  const resp2 = await fetch('https://www.douyinxs.com/search/', 'POST', 'searchkey=冲出四合院');
  if (resp2.text && resp2.text.length > 200) {
    const $ = cheerio.load(resp2.text);
    console.log('HTML:', resp2.text.length, 'bytes');
    console.log('title:', $('title').text());
    
    // Find classes on div/ul/li
    const divClasses = [...new Set([...$('div')].map(d => $(d).attr('class')).filter(Boolean))].slice(0, 20);
    console.log('div classes:', divClasses);
    console.log('ul count:', $('ul').length);
    console.log('Has 冲出四合院:', resp2.text.includes('冲出四合院'));
    
    if (resp2.text.includes('冲出四合院')) {
      const idx = resp2.text.indexOf('冲出四合院');
      console.log('HTML around keyword:', resp2.text.substring(Math.max(0, idx - 300), idx + 100));
    }
  } else {
    console.log('douyinxs response:', resp2.status, resp2.text?.length);
  }

  // === 笔趣阁22 ===
  console.log('\n=== 笔趣阁22 deep probe ===');
  const resp3 = await fetch('https://www.bqg.fun/search.php?searchkey=冲出四合院');
  if (resp3.text && resp3.text.length > 200) {
    const $ = cheerio.load(resp3.text);
    console.log('HTML:', resp3.text.length, 'bytes');
    console.log('title:', $('title').text());
    console.log('Has 冲出四合院:', resp3.text.includes('冲出四合院'));
    if (resp3.text.includes('冲出四合院')) {
      const idx = resp3.text.indexOf('冲出四合院');
      console.log('HTML around keyword:', resp3.text.substring(Math.max(0, idx - 300), idx + 100));
    }
    // Find common containers
    for (const sel of ['li', 'tr', 'dd', 'div.result-item', 'div.search-item', '.search-list li', 
                       '.bookbox', '.hot_sale', '.list li', 'ul li', 'dl dd']) {
      const els = $(sel);
      if (els.length > 0) {
        let hasBookLink = 0;
        els.each((i, el) => {
          const h = $(el).find('a').first().attr('href') || '';
          if (h.includes('.html') || h.includes('/book/')) hasBookLink++;
        });
        if (hasBookLink >= 2) console.log(`${sel}: ${els.length} items, ${hasBookLink} book links`);
      }
    }
  }
}

main().catch(console.error);
