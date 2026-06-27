/**
 * Test the HtmlParser's CSS selector engine against actual source HTML
 * Replicates the app's parser logic to find why selectors return 0 items
 */
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import * as cheerio from 'cheerio';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 15000;

async function fetch(u, method = 'GET', body = null) {
  const c = new AbortController(); setTimeout(() => c.abort(), TIMEOUT);
  try {
    const h = { 
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*'
    };
    const o = { method, headers: h, signal: c.signal };
    if (body && method === 'POST') { h['Content-Type'] = 'application/x-www-form-urlencoded'; o.body = body; }
    const r = await globalThis.fetch(u, o);
    return { status: r.status, text: await r.text() };
  } catch (e) { return { status: 0, text: '', error: e.message }; }
}

// Simulate HtmlParser's splitSelector exactly
function splitSelector(selector) {
  const parts = [];
  let current = '';
  let i = 0;
  let inBracket = 0;
  while (i < selector.length) {
    const c = selector[i];
    if (c === '[') { inBracket++; current += c; i++; continue; }
    if (c === ']') { inBracket--; current += c; i++; continue; }
    if (inBracket > 0) { current += c; i++; continue; }
    if (c === '>' || c === '+' || c === '~') {
      if (current.trim()) parts.push(current.trim());
      parts.push(c);
      current = '';
      i++;
      while (i < selector.length && selector[i] === ' ') i++;
    } else if (c === ' ') {
      if (current.trim()) {
        parts.push(current.trim());
        current = '';
      }
      i++;
      while (i < selector.length && selector[i] === ' ') i++;
    } else {
      current += c;
      i++;
    }
  }
  if (current.trim()) parts.push(current.trim());
  return parts;
}

async function main() {
  // Fetch 就爱文学 search page
  console.log('=== Fetching 就爱文学 search page ===');
  const resp = await fetch('http://www.92xs.info/modules/article/search.php', 'POST',
    'searchtype=articlename&searchkey=冲出四合院');
  
  const html = resp.text;
  if (!html || html.length < 200) {
    console.log('Empty response');
    return;
  }
  
  console.log(`HTML ${html.length} bytes`);
  
  // Save raw HTML for analysis
  fs.writeFileSync(path.join(__dirname, 'output/___就爱文学_raw.html'), html);
  console.log('Saved to output/___就爱文学_raw.html');
  
  // Analyze with cheerio (reference selector engine)
  const $ = cheerio.load(html);
  
  // Test various selectors
  console.log('\n=== Cheerio selector tests ===');
  for (const sel of [
    '.grid', 'table.grid', 'table', 
    '.grid tr', 'table.grid tr', 'table tr',
    '.grid > tr', 'table.grid > tr',
    '.grid tbody', 'table.grid tbody',
    '.grid tbody tr', 'table.grid tbody tr',
    '.grid > tbody > tr',
    '#author', '#author tr', '#author > tr',
    '#author table', '#author table.grid',
    '#author table tr', '#author > table > tr',
    '#author > table > tbody > tr',
  ]) {
    try {
      const els = $(sel);
      if (els.length > 0) {
        const samples = [];
        els.slice(0, 3).each((i, el) => {
          const text = $(el).text().trim().substring(0, 40);
          samples.push(text);
        });
        console.log(`${sel}: ${els.length} items [${samples.join(', ')}]`);
      }
    } catch(e) {
      console.log(`${sel}: ERROR ${e.message}`);
    }
  }
  
  // Also check the raw HTML for tbody
  console.log('\n=== HTML structure check ===');
  const tbodyMatch = html.match(/<tbody[^>]*>/gi);
  console.log('tbody tags:', tbodyMatch ? tbodyMatch.length : 0);
  const tableMatch = html.match(/<table[^>]*>/gi);
  console.log('table tags:', tableMatch ? tableMatch.length : 0);
  const gridMatch = html.match(/<table[^>]*class="[^"]*grid[^"]*"[^>]*>/gi);
  console.log('table.grid tags:', gridMatch ? gridMatch.length : 0);
  
  // Check if grid is a class on table
  const gridClassRe = /class="[^"]*grid[^"]*"/gi;
  const gridClasses = html.match(gridClassRe);
  console.log('Elements with class containing "grid":', gridClasses ? gridClasses.length : 0);
  gridClasses?.forEach((c, i) => console.log(`  [${i}] ${c.substring(0, 60)}`));
  
  // Show table structure
  $('table').each((i, table) => {
    const cls = $(table).attr('class') || '';
    const id = $(table).attr('id') || '';
    const trCount = $(table).find('tr').length;
    const directTrCount = $(table).children('tr').length;
    const tbodyCount = $(table).children('tbody').length;
    const tbodyTrCount = $(table).children('tbody').children('tr').length;
    console.log(`\ntable[${i}]: class="${cls}" id="${id}"`);
    console.log(`  tr descendants: ${trCount}`);
    console.log(`  direct tr children: ${directTrCount}`);
    console.log(`  tbody children: ${tbodyCount}`);
    console.log(`  tr in tbody: ${tbodyTrCount}`);
    
    // Show first 2 rows
    $(table).find('tr').slice(0, 2).each((ri, tr) => {
      const tds = [];
      $(tr).find('td').each((j, td) => {
        tds.push(`"${$(td).text().trim().substring(0, 20)}"`);
      });
      console.log(`  tr[${ri}]: [${tds.join(', ')}]`);
    });
  });

  // Test the splitSelector
  console.log('\n=== splitSelector tests ===');
  for (const sel of ['.grid tr', '.grid > tr', '#author tr']) {
    console.log(`"${sel}" → ${JSON.stringify(splitSelector(sel))}`);
  }
}

main().catch(console.error);
