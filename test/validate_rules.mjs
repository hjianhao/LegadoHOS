/**
 * 根据 doc/source.md 规则体系验证所有源的配置格式
 */
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
const allSources = JSON.parse(raw);

/*
 * Legado 规则类型检测：
 *
 * Default: `tag.class.index@tag.class.index@attr`
 * CSS: `@css:selector`
 * JSONPath: `$.path` or `@json:$.path`
 * XPath: `//node` or `@xpath://node`
 * JS: `@js:code` or `<js>code</js>`
 * Regex: `##pattern##replacement`
 * URL: `{{expression}}`
 * OR: `ruleA||ruleB`
 */

function detectRuleType(rule) {
  if (!rule || typeof rule !== 'string') return null;
  if (rule.startsWith('@js:')) return 'js';
  if (rule.startsWith('@css:')) return 'css';
  if (rule.startsWith('@json:')) return 'jsonpath';
  if (rule.startsWith('@xpath:') || rule.startsWith('//')) return 'xpath';
  if (rule.startsWith('$.')) return 'jsonpath';
  if (rule.includes('||')) return 'or';
  if (rule.includes('##')) return 'regex-chain';
  if (rule.startsWith('@put:')) return 'put';
  // Default rule: contains @ or starts with tag/./#
  if (rule.includes('@') || /^[a-zA-Z.#]/.test(rule)) return 'default';
  return 'unknown';
}

function parseDefaultRule(rule) {
  // Default rule format: type.name.index@type.name.index@attr
  // Types: class (.), id (#), tag (direct), text, children
  const segments = rule.split('@');
  return segments.map((seg, i) => {
    const isLast = i === segments.length - 1;
    const parts = seg.split('.');

    // Try to detect type
    let type = 'tag';
    let name = seg;
    let index = undefined;
    let attr = 'text'; // default extraction

    if (isLast) {
      // Last segment can have @attr suffix
      const attrMatch = seg.match(/^(.*)@(text|href|src|html|ownText)$/);
      if (attrMatch) {
        name = attrMatch[1];
        attr = attrMatch[2];
        parts = name.split('.');
      }
    }

    if (parts.length >= 1) {
      const first = parts[0];
      if (first === '') {
        type = 'class';
        name = parts.slice(1).join('.');
      } else if (first.startsWith('#')) {
        type = 'id';
        name = first.substring(1);
      } else if (/^[a-zA-Z][a-zA-Z0-9]*$/.test(first)) {
        type = 'tag';
        name = first;
      } else if (first === 'id') {
        type = 'id';
        name = parts[1] || '';
      } else if (['text', 'children'].includes(first)) {
        type = first;
        name = parts[1] || '';
      } else {
        type = 'tag';
        name = first;
      }
      
      // Check for index suffix (numeric)
      if (parts.length > 1) {
        const potentialIdx = parts[parts.length - 1];
        if (/^-?\d+$/.test(potentialIdx)) {
          index = parseInt(potentialIdx);
          name = parts.slice(1, -1).join('.');
        } else if (parts.length > 2) {
          name = parts.slice(1).join('.');
        }
      }
    }
    return { type, name, index, attr, raw: seg };
  });
}

function validateRuleField(source, field, rule) {
  if (!rule) return { valid: true, issues: [] };
  const issues = [];
  
  // Check for @js: in rule - can't execute without JS engine
  if (rule.startsWith('@js:')) {
    issues.push('包含 @js: 表达式（需 JS 引擎，当前无法执行）');
  }
  
  // Check for <js> tags
  if (rule.includes('<js>')) {
    issues.push('包含 <js> 标签（需 JS 引擎计算）');
  }
  
  const type = detectRuleType(rule);
  
  if (type === 'default') {
    try {
      const parsed = parseDefaultRule(rule);
      for (const seg of parsed) {
        if (seg.type === 'text') {
          // text rules are less common - might not be implemented
        }
        // Check for position index > 10 (likely wrong)
        if (seg.index !== undefined && Math.abs(seg.index) > 10) {
          issues.push(`位置索引 ${seg.index} 过大，可能选择器有误`);
        }
      }
    } catch (e) {
      issues.push(`解析 Default 规则出错: ${e.message}`);
    }
  }
  
  if (type === 'jsonpath') {
    // Check for common JSONPath syntax issues
    if (rule.startsWith('$.')) {
      // Valid JSONPath
    }
  }
  
  return { valid: issues.length === 0, issues };
}

// ========== 主验证 ==========

console.log('=== 书源规则验证报告 ===\n');

let errorCount = 0;
let warningCount = 0;

for (const source of allSources) {
  const name = source.bookSourceName || source.sourceName || '?';
  const rs = source.ruleSearch || {};
  const rb = source.ruleBookInfo || {};
  const issues = [];

  // 验证各个规则字段
  const ruleFields = [
    { section: 'ruleSearch', name: 'bookList', value: rs.bookList || rs.list },
    { section: 'ruleSearch', name: 'name', value: rs.name },
    { section: 'ruleSearch', name: 'author', value: rs.author },
    { section: 'ruleSearch', name: 'coverUrl', value: rs.coverUrl || rs.cover },
    { section: 'ruleSearch', name: 'bookUrl', value: rs.bookUrl || rs.noteUrl },
    { section: 'ruleBookInfo', name: 'author', value: rb.author },
    { section: 'ruleBookInfo', name: 'name', value: rb.name },
    { section: 'ruleBookInfo', name: 'coverUrl', value: rb.coverUrl || rb.cover },
  ];

  for (const f of ruleFields) {
    if (!f.value) continue;
    const result = validateRuleField(source, f.field, f.value);
    for (const issue of result.issues) {
      issues.push(`[${f.section}.${f.name}] ${issue} (值: ${f.value.substring(0, 60)})`);
    }
  }

  // 检查 searchUrl 格式
  const searchUrl = source.searchUrl || '';
  if (searchUrl.startsWith('@js:')) {
    issues.push('[searchUrl] 包含 @js: 表达式，无法构建 URL');
  }

  if (issues.length > 0) {
    const isError = issues.some(i => i.includes('包含 @js:') || i.includes('包含 <js>'));
    if (isError) {
      console.log(`❌ ${name} (${issues.length} 个问题):`);
      errorCount++;
    } else {
      console.log(`⚠️ ${name} (${issues.length} 个提示):`);
      warningCount++;
    }
    issues.forEach(i => console.log(`    ${i}`));
    console.log('');
  }
}

console.log(`\n共计: ${allSources.length} 个源`);
console.log(`❌ 有问题: ${errorCount}`);
console.log(`⚠️ 有提示: ${warningCount}`);
console.log(`✅ 无问题: ${allSources.length - errorCount - warningCount}`);

// 输出 @js: 规则的源（需要 JS 引擎）
console.log('\n=== 包含 @js: 表达式的源（需要 JS 引擎支持）===');
for (const source of allSources) {
  const name = source.bookSourceName || '?';
  const searchUrl = source.searchUrl || '';
  if (searchUrl.startsWith('@js:')) {
    console.log(`  ${name}: searchUrl 含 @js:`);
  }
  const rs = source.ruleSearch || {};
  const fields = ['searchUrl', rs.bookList || rs.list, rs.name, rs.author, rs.coverUrl || rs.cover, rs.bookUrl || rs.noteUrl,
    rs.kind, rs.wordCount, rs.intro];
  for (const f of [source.searchUrl, source.ruleBookInfo?.author, source.ruleBookInfo?.coverUrl || source.ruleBookInfo?.cover]) {
    if (f && (f.startsWith('@js:') || f.includes('<js>'))) {
      console.log(`  ${name}: ${f.substring(0, 60)}`);
    }
  }
}
