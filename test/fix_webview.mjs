/**
 * 修复 source_fixed.json 中的 webView 标记
 * 问题: 之前的脚本添加了 ##webView 后缀，但正确的格式是 JSON 选项 {"webView":true}
 * 修复: 移除所有 ##webView，已有的 {"webView":true} 保持原样
 */
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const raw = fs.readFileSync(path.resolve(__dirname, 'source_fixed.json'), 'utf-8');
const data = JSON.parse(raw);

let fixCount = 0;

for (const s of data) {
  const name = s.bookSourceName || '';
  const searchUrl = s.searchUrl || '';
  if (!searchUrl) continue;

  // 移除所有 ##webView 后缀（之前脚本错误添加的）
  let newUrl = searchUrl.replace(/##webView/g, '');

  if (newUrl !== searchUrl) {
    console.log(`🔧 ${name}: 已移除错误的 ##webView 标记`);
    s.searchUrl = newUrl;
    fixCount++;
  }
}

fs.writeFileSync(path.resolve(__dirname, 'source_fixed.json'), JSON.stringify(data, null, 2), 'utf-8');
console.log(`\n✅ 修复了 ${fixCount} 个源的 WebView 标记`);
console.log(`文件: source_fixed.json`);
console.log(`使用: cp test/source_fixed.json test/source.json`);
