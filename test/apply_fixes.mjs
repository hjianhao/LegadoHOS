/**
 * 保守修复：只更新确定能匹配的 bookList 选择器
 * 
 * 从第一轮诊断已知：
 * - 八零小说: .storelistbt5 → ul li (53个, 25书籍链接)
 * - 一米小说: .bd li → ul li (38个, 38书籍链接)  
 * - 小书本网: .item → dd (54个, 18书籍链接)
 * - 达文小说: .result li → ul li (5个, 3书籍链接)
 * 
 * 其他源的选择器不确定，保持原样。
 */

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SOURCES_FILE = path.resolve(__dirname, 'source.json');
const OUTPUT_FILE = path.resolve(__dirname, 'source_fixed.json');

const raw = fs.readFileSync(SOURCES_FILE, 'utf-8');
const allSources = JSON.parse(raw);

// ====== 确定的修复 ======
// 只更新 bookList（容器选择器），name/author/coverUrl 保留原样
const fixes = {
  '八零小说': { bookList: 'ul@li' },        // 原 .storelistbt5 → 53个元素
  '一米小说': { bookList: 'ul@li' },        // 原 .bd@li → 38个元素
  '小书本网': { bookList: 'dd' },           // 原 .item → 54个元素
  '达文小说': { bookList: 'ul@li' },         // 原 .result@li → 5个元素
};

let modified = 0;
let notFound = [];

for (const [namePattern, updates] of Object.entries(fixes)) {
  const source = allSources.find(s => (s.bookSourceName || '').includes(namePattern));
  if (!source) { 
    notFound.push(namePattern);
    continue;
  }

  if (!source.ruleSearch) source.ruleSearch = {};

  const oldVal = source.ruleSearch.bookList || source.ruleSearch.list || '(空)';
  source.ruleSearch.bookList = updates.bookList;

  modified++;
  console.log(`✅ ${source.bookSourceName}`);
  console.log(`  bookList: ${oldVal} → ${updates.bookList}`);
  console.log(`  name/author/bookUrl 保留原样`);
  console.log();
}

if (notFound.length > 0) {
  console.log(`❌ 未找到 (${notFound.length}): ${notFound.join(', ')}\n`);
}

// 写入
fs.writeFileSync(OUTPUT_FILE, JSON.stringify(allSources, null, 2), 'utf-8');

// ====== 输出需要手动修复的源 ======
console.log('========== 需要手动修复的源 ==========\n');
console.log('以下源的 bookList 选择器失效，但无法自动确定正确选择器：');
console.log('(需要查看实际 HTML 结构才能找到正确的 CSS 类/标签)\n');

const knownFailing = [
  '🎉 当阅读网', '🎉 搜搜小说', '🎉 西瓜小说', '🎉 多多书院',
  '🎉 歌书小说', '🎉 独步小说', '🎉 手机小说',
  '💐 言情小说', '💐 爱久久网', '💐 ACGZC',
  '💠 乐库小说', '💠 书满屋网', '💠 手机看书',
  '💠 猪猪书网', '📚 中华典藏', '📚 参考期刊',
];

for (const name of knownFailing) {
  const keyword = name.replace(/^[^\w]+\s*/, '');
  const source = allSources.find(s => (s.bookSourceName || '').includes(keyword));
  if (source) {
    const rs = source.ruleSearch || {};
    console.log(`  ${source.bookSourceName}`);
    console.log(`    bookList: ${rs.bookList || rs.list || '(空)'}`);
    console.log(`    搜索URL: ${(source.searchUrl || '').substring(0, 70)}`);
    console.log();
  }
}

console.log(`========== 完成 ==========`);
console.log(`修改了 ${modified} 个源`);
console.log(`输出: source_fixed.json`);
console.log(`\n💡 使用: cp test/source_fixed.json test/source.json 替换源文件`);
