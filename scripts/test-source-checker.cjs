// Run with: node scripts/test-source-checker.cjs
// Exercise the real checker with deterministic adapters; no device or network required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const path = require('node:path');
const calls = [];
const book = { name: '测试书', noteUrl: 'opaque-book-id', author: '作者', introduce: '' };
const info = { name: '测试书', tocUrl: 'opaque-toc-id' };
const adapter = {
  search: async () => { calls.push('search'); return [book]; },
  getExploreItems: async () => [{ kind: 'heading' }, { kind: 'books', target: 'category' }],
  explore: async () => { calls.push('find'); return [book]; },
  getBookInfo: async () => { calls.push('info'); return info; },
  getToc: async (_source, toc, identity) => {
    assert.equal(toc, 'opaque-toc-id');
    assert.equal(identity, 'opaque-book-id');
    calls.push('chapter');
    return [{ url: 'opaque-chapter-id', title: '第一章' }];
  },
  getContent: async (_source, chapter, identity) => {
    assert.equal(chapter, 'opaque-chapter-id');
    assert.equal(identity, 'opaque-book-id');
    calls.push('content');
    return { raw: '正文' };
  },
};
const legacy = new Proxy({}, { get: (_target, method) => async () => {
  calls.push('legacy:' + method);
  if (method === 'searchForCheck') return [book];
  throw new Error('Unexpected legacy call: ' + method);
} });
const moduleObject = { exports: {} };
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/service/SourceChecker.ts'), 'utf8');
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, {
  exports: moduleObject.exports, module: moduleObject,
  require: (name) => {
    if (name.endsWith('/BookSource')) return {
      BookSourceFormat: { QYSG: 'qysg' }, BookSourceType: { FILE: 3 }, isImageSource: () => false,
    };
    if (name.endsWith('/SourceExecutor')) return {
      globalSourceExecutor: legacy, isExplicitlyDisabledSearchTemplate: () => false,
    };
    if (name.endsWith('/JsExpressionEvaluator')) return { JsExpressionEvaluator: { releaseWorker() {} } };
    if (name.endsWith('/NetUtil')) return { NetUtil: {
      startRequestGroup() {}, finishRequestGroup() {}, cancelRequestGroup() {},
    } };
    throw new Error('Unexpected import: ' + name);
  },
  console, setTimeout, clearTimeout, setInterval, clearInterval,
});
const { SourceChecker } = moduleObject.exports;
const qysg = {
  id: 1, sourceUrl: 'https://example.com', sourceName: '轻悦测试', sourceFormat: 'qysg',
  enabled: false, ruleSearchUrl: '', ruleSearchCheckKeyWord: '', exploreUrl: '', ruleExplores: '',
};
async function check(overrides = {}, config = {}, sourceOverrides = {}) {
  return new SourceChecker(config, { ...adapter, ...overrides })
    .checkSource({ ...qysg, ...sourceOverrides });
}
(async () => {
  let result = await check();
  assert.equal(result.status, 'success');
  assert.equal(result.passedChecks, 8);
  assert.deepEqual(calls, ['search', 'info', 'chapter', 'content', 'find', 'info', 'chapter', 'content']);
  for (const overrides of [
    { search: async () => [] },
    { search: async () => { throw new Error('脚本错误'); } },
    { getBookInfo: async () => ({ tocUrl: 'opaque-book-id' }) },
    { getToc: async () => [] },
    { getContent: async () => ({ raw: '' }) },
  ]) {
    result = await check(overrides, { checkDiscovery: false });
    assert.equal(result.status, 'fail');
  }
  result = await check({ getExploreItems: async () => [{ kind: 'webview' }] }, { checkSearch: false });
  assert.equal(result.status, 'fail');
  assert.ok(result.details.some(item => item.message.includes('未执行任何校验')));
  result = await check({}, {}, { sourceFormat: 'legado' });
  assert.equal(result.status, 'fail'); // Empty Legado rules must not pass either.
  calls.length = 0;
  result = await check({}, { checkDiscovery: false, checkInfo: false },
    { sourceFormat: 'legado', ruleSearchUrl: '/search' });
  assert.equal(result.status, 'success');
  assert.deepEqual(calls, ['legacy:searchForCheck']);
  const checker = new SourceChecker({ checkDiscovery: false }, {
    ...adapter, search: async () => new Promise(resolve => setTimeout(() => resolve([book]), 150)),
  });
  const pending = checker.checkSource(qysg);
  setTimeout(() => checker.cancel(), 10);
  await assert.rejects(pending, /校验已取消/);
  console.log('PASS: QYSG chain, failures, zero checks, Legado routing and cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });
