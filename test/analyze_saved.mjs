import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname, 'output');

const targets = [
  '___手机小说.html',
  '___言情小说.html',
  '___当阅读网.html',
  '___手机看书.html',
  '___搜搜小说.html',
];

for (const file of targets) {
  const fp = path.join(outDir, file);
  if (!fs.existsSync(fp)) { console.log(`\n=== ${file} ===\n文件不存在`); continue; }
  
  const html = fs.readFileSync(fp, 'utf-8');
  const $ = cheerio.load(html);
  
  console.log(`\n=== ${file} ===`);
  console.log(`大小: ${html.length} bytes`);
  console.log(`Title: ${$('title').text().trim()}`);
  
  // 列出所有链接
  const links = [];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href') || '';
    const text = $(el).text().trim();
    if (text && text.length >= 2 && !href.startsWith('#') && !href.startsWith('javascript:')) {
      links.push({ text, href });
    }
  });
  
  console.log(`链接数: ${links.length}`);
  
  // 找包含"四合院"的
  const siheyuan = links.filter(l => l.text.includes('四合院'));
  if (siheyuan.length > 0) {
    console.log(`含"四合院"的链接: ${siheyuan.length}`);
    siheyuan.slice(0, 5).forEach((l, i) => console.log(`  ${i+1}. ${l.text.substring(0,30)} → ${l.href.substring(0,60)}`));
  } else {
    console.log('无"四合院"相关链接');
    // 显示前20个链接
    links.slice(0, 20).forEach((l, i) => console.log(`  ${i+1}. ${l.text.substring(0,30)} → ${l.href.substring(0,60)}`));
  }

  // 检查常见布局
  const lis = $('li').length;
  const trs = $('tr').length;
  const dds = $('dd').length;
  const imgs = $('img').length;
  console.log(`li=${lis} tr=${trs} dd=${dds} img=${imgs}`);

  // 对于言情小说，检查 .left 区域
  const leftLen = $('.left').length;
  const leftLiLen = $('.left li').length;
  if (leftLen > 0) console.log(`.left=${leftLen} .left li=${leftLiLen}`);

  // 检查常见书籍容器
  for (const sel of ['ul li', 'table tr', 'dl dd', '.item', '.book', '.list-item', '.search-item', 'div[class*="book"]']) {
    try {
      const els = $(sel);
      if (els.length >= 2 && els.length <= 200) {
        const withLinks = els.filter((i, el) => $(el).find('a[href]').length > 0).length;
        if (withLinks >= 2) console.log(`${sel}: ${els.length}个, 含链接: ${withLinks}`);
      }
    } catch (_) {}
  }
}
