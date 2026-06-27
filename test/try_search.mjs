import * as cheerio from 'cheerio';

const TIMEOUT = 15000;

async function fetchUrl(u, method = 'GET', body = null) {
  const c = new AbortController(); setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
  finally { clearTimeout(c); }
}

async function main() {
  // 手机小说 - 用不同参数搜索
  const tests = [
    ['POST', 'https://www.shoujix.com/search/', 'searchkey=仙'],
    ['GET', 'https://www.shoujix.com/search.php?searchkey=仙', null],
    ['GET', 'https://www.shoujix.com/e/search/?searchkey=仙', null],
    ['GET', 'https://www.shoujix.com/s.php?q=仙', null],
  ];

  for (const [method, url, body] of tests) {
    process.stdout.write(`手机小说 ${method} ${url.substring(0, 60)}... `);
    const r = await fetchUrl(url, method, body);
    if (r.text && r.text.length > 500) {
      try {
        const $ = cheerio.load(r.text);
        console.log(`(${r.text.length} bytes, title="${$('title').text().trim().substring(0, 40)}")`);
        
        // 找结果链接
        let found = [];
        $('a[href]').each((i, el) => {
          const href = $(el).attr('href') || '';
          const text = $(el).text().trim();
          if (text.length >= 2 && !href.startsWith('#') && !href.startsWith('javascript:') && 
              !text.includes('首页') && !text.includes('分类')) {
            if (found.length < 10) found.push({ text, href });
          }
        });
        if (found.length > 0) {
          found.slice(0, 5).forEach((l, i) => console.log(`  ${i+1}. "${l.text.substring(0,25)}" → ${l.href.substring(0,50)}`));
        }
      } catch (e) {
        console.log(`(${r.text.length} bytes, parse error)`);
      }
    } else {
      console.log(`❌ (${r.text?.length || 0} bytes)`);
    }
  }

  // 手机看书
  console.log('\n--- 手机看书 ---');
  for (const params of ['keyboard=仙&show=title', 'keyboard=仙&show=title&submit=搜索']) {
    process.stdout.write(`POST /e/search/index.php ${params.substring(0, 30)}... `);
    const r = await fetchUrl('https://www.sjks88.com/e/search/index.php', 'POST', params);
    console.log(`(${r.text?.length || 0} bytes)`);
    if (r.text && r.text.length > 500) {
      const $ = cheerio.load(r.text);
      console.log(`  title="${$('title').text().trim().substring(0, 40)}"`);
      let found = [];
      $('a[href]').each((i, el) => {
        const href = $(el).attr('href') || '';
        const text = $(el).text().trim();
        if (text.length >= 2 && (href.includes('.html') || href.includes('/book/'))) {
          if (found.length < 5) found.push({ text, href });
        }
      });
      found.forEach((l, i) => console.log(`  ${i+1}. "${l.text.substring(0,25)}" → ${l.href.substring(0,50)}`));
    }
  }
}

main().catch(console.error);
