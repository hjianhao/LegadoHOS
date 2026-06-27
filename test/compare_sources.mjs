import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const orig = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8'));
const fixed = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'source_fixed.json'), 'utf-8'));

const origMap = {};
orig.forEach(s => { origMap[s.bookSourceName || s.sourceName || '?'] = s; });

let changes = 0;
for (const s of fixed) {
  const name = s.bookSourceName || s.sourceName || '?';
  const o = origMap[name];
  if (!o) { console.log('新增:', name); continue; }
  
  const rs1 = o.ruleSearch || {};
  const rs2 = s.ruleSearch || {};
  const oldList = rs1.bookList || rs1.list || '';
  const newList = rs2.bookList || rs2.list || '';
  if (oldList !== newList) {
    changes++;
    console.log(name + ' bookList 变更:');
    console.log('  旧:', oldList);
    console.log('  新:', newList);
  }
  
  // 检查 searchUrl
  if (o.searchUrl !== s.searchUrl) {
    // 只显示差异（排除换行符差异）
    if (o.searchUrl?.trim() !== s.searchUrl?.trim()) {
      changes++;
      console.log(name + ' searchUrl 变更');
      console.log('  旧:', (o.searchUrl || '').substring(0, 80));
      console.log('  新:', (s.searchUrl || '').substring(0, 80));
    }
  }
  
  // 检查 ruleSearch 其他字段
  for (const field of ['name', 'author', 'coverUrl', 'bookUrl', 'cover']) {
    const f1 = rs1[field] || '';
    const f2 = rs2[field] || '';
    if (f1 !== f2) {
      changes++;
      console.log(name + ' ruleSearch.' + field + ' 变更:');
      console.log('  旧:', f1.substring(0, 60));
      console.log('  新:', f2.substring(0, 60));
    }
  }
}

console.log('\n共 ' + changes + ' 处差异');
