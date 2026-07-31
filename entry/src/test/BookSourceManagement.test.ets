import { describe, it, expect } from '@ohos/hypium';
import { BookSourceChapter, createEmptyBookSource, parseBookSource } from '../main/ets/model/BookSource';
import {
  CheckConfig, createSourceForCheck, firstExploreUrlFromText, isSearchCheckDisabled, normalizeCheckConfig,
  selectCheckResult, selectReadableChapters
} from '../main/ets/service/SourceChecker';
import { createSearchResult, SearchResult } from '../main/ets/model/SearchResult';
import {
  decodeSourceScriptEvaluation, hasExplicitTocPaginationRule, isDuplicateTocPage,
  isExplicitlyDisabledSearchTemplate, isTransientGetFailure, isWafProbeHtml,
  needsWebViewDocument, resolveContentPageUrl
} from '../main/ets/engine/source/SourceExecutor';
import {
  DISABLE_COOKIE_HEADER, SourceNetworkPolicy
} from '../main/ets/engine/source/SourceNetworkPolicy';
import { applyCheckResultToSource, removeCheckErrorComment } from '../main/ets/service/SourceCheckPersistence';
import {
  inferSearchRequest, materializeAgentRequest, prepareSourceAgentHtml
} from '../main/ets/engine/ai/AiSourceAgent';
import { changedSourceFields } from '../main/ets/service/SourceRevisionService';

export default function bookSourceManagementTest() {
  describe('bookSourceManagement', () => {
    it('usesAndroidCompatibleSourceDefaults', 0, () => {
      const source = parseBookSource(JSON.parse(
        '{"bookSourceName":"测试源","bookSourceUrl":"https://example.com","concurrentRate":"2/1000"}'));
      expect(source.respondTime).assertEqual(180000);
      expect(source.concurrentRate).assertEqual('2/1000');
      expect(source.enabledCookieJar).assertTrue();
      expect(createEmptyBookSource().respondTime).assertEqual(180000);
    });

    it('infersGetAndPostSearchFormsWithoutLlmGuessing', 0, () => {
      const getForm = '<form action="/search" method="get"><input type="hidden" name="type" value="book">' +
        '<input type="search" name="q" placeholder="搜索小说"><button>搜索</button></form>';
      const getRequest = inferSearchRequest(getForm, 'https://example.com/index.html', '三体');
      expect(getRequest?.ruleSearchUrl || '').assertEqual(
        'https://example.com/search?q={{key}}&type=book');
      expect(getRequest?.probeUrl || '').assertContain('q=%E4%B8%89%E4%BD%93');

      const postForm = '<form action="/api/search" method="post">' +
        '<input name="keyword" placeholder="书名"><button>查询</button></form>';
      const postRequest = inferSearchRequest(postForm, 'https://example.com/', '诡秘之主');
      expect(postRequest?.method || '').assertEqual('POST');
      const spec = materializeAgentRequest(
        postRequest?.ruleSearchUrl || '', '诡秘之主', 1, 'https://example.com');
      expect(spec.url).assertEqual('https://example.com/api/search');
      expect(spec.body).assertContain('keyword=%E8%AF%A1%E7%A7%98%E4%B9%8B%E4%B8%BB');
    });

    it('redactsCredentialValuesButKeepsSelectorDom', 0, () => {
      const html = '<html><head><script>ignore()</script></head><body>' +
        '<input type="password" name="password" value="secret">' +
        '<ul class="books"><li><a href="/book/1">书名</a></li></ul></body></html>';
      const prepared = prepareSourceAgentHtml(html);
      expect(prepared).assertContain('class="books"');
      expect(prepared).assertContain('href="/book/1"');
      expect(prepared.indexOf('secret')).assertEqual(-1);
      expect(prepared.indexOf('ignore()')).assertEqual(-1);
    });

    it('reportsOnlyRepairRuleChanges', 0, () => {
      const before = createEmptyBookSource();
      before.id = 1;
      before.sourceUrl = 'https://example.com';
      before.sourceName = '测试';
      const after = parseBookSource(JSON.parse(JSON.stringify(before)));
      after.ruleToc = '.new-list@li';
      after.updateTime = Date.now();
      const changed = changedSourceFields(before, after);
      expect(changed.length).assertEqual(1);
      expect(changed[0]).assertEqual('ruleToc');
    });

    it('normalizesCheckDependencies', 0, () => {
      const rawConfig: CheckConfig = {
        keyword: '  ',
        timeout: 200,
        checkSearch: false,
        checkDiscovery: false,
        checkInfo: false,
        checkCategory: false,
        checkContent: true,
        concurrency: 100
      };
      const config = normalizeCheckConfig(rawConfig);
      expect(config.keyword).assertEqual('我的');
      expect(config.timeout).assertEqual(1000);
      expect(config.checkSearch).assertTrue();
      expect(config.checkCategory).assertFalse();
      expect(config.checkContent).assertFalse();
      expect(config.concurrency).assertEqual(32);
    });

    it('checksDisabledSourcesWithoutChangingTheirSavedState', 0, () => {
      const source = createEmptyBookSource();
      source.enabled = false;
      const checkSource = createSourceForCheck(source);
      expect(checkSource.enabled).assertTrue();
      expect(source.enabled).assertFalse();
    });

    it('recognizesExplicitlyDisabledSearchWithoutRunningInvalidScript', 0, () => {
      const source = createEmptyBookSource();
      source.ruleSearchUrl = "<js>/search.php,{'method':'POST'};result='';result;</js>";
      expect(isExplicitlyDisabledSearchTemplate(source.ruleSearchUrl)).assertTrue();
      expect(isSearchCheckDisabled(source)).assertTrue();
      source.ruleSearchUrl = 'https://example.com/search?q={{key}}';
      source.group = '搜索暂不可用';
      expect(isSearchCheckDisabled(source)).assertTrue();
    });

    it('retriesOnlyTransientGatewayFailures', 0, () => {
      expect(isTransientGetFailure('HTTP 504: Gateway Timeout')).assertTrue();
      expect(isTransientGetFailure('HTTP 503: Service Unavailable')).assertTrue();
      expect(isTransientGetFailure('HTTP 404: Not Found')).assertFalse();
    });

    it('recognizesSuccessfulWafProbeResponses', 0, () => {
      const probe = '<html><script>var buid="ffff-1234"</script>' +
        '<script src="/C2WF946J0/probe.js?v=1"></script><body></body></html>';
      expect(isWafProbeHtml(probe)).assertTrue();
      expect(isWafProbeHtml('<html><body><p>正常正文</p></body></html>')).assertFalse();
      expect(needsWebViewDocument('<div id="app"></div>',
        'https://example.com/book/1')).assertTrue();
      expect(needsWebViewDocument(
        '<form><input type="password"><button>登录</button></form>',
        'https://example.com/book/1')).assertTrue();
      expect(needsWebViewDocument('{"data":{"title":"三体"}}',
        'https://example.com/api/book/1')).assertFalse();
    });

    it('stopsDuplicateFullCatalogPagination', 0, () => {
      let first = '<ul>';
      let duplicate = '<ul>';
      let different = '<ul>';
      for (let i = 1; i <= 20; i++) {
        first += `<li><a href="/book/1/${i}.html">第${i}章</a></li>`;
        duplicate += `<li><a href="/book/1/${i}.html">第${i}章 标题</a></li>`;
        different += `<li><a href="/book/1/${i + 20}.html">第${i + 20}章</a></li>`;
      }
      first += '</ul>';
      duplicate += '</ul>';
      different += '</ul>';
      expect(isDuplicateTocPage(first, 'https://example.com/book/1/', duplicate,
        'https://example.com/book/1_2/')).assertTrue();
      expect(isDuplicateTocPage(first, 'https://example.com/book/1/', different,
        'https://example.com/book/1_2/')).assertFalse();
    });

    it('loadsTocPaginationOnlyWhenTheSourceDeclaresIt', 0, () => {
      expect(hasExplicitTocPaginationRule('')).assertFalse();
      expect(hasExplicitTocPaginationRule('   ')).assertFalse();
      expect(hasExplicitTocPaginationRule('select[name=pageselect] option@value')).assertTrue();
    });

    it('returnsCaptchaVariablesWithTheSameWorkerEvaluation', 0, () => {
      const decoded = decodeSourceScriptEvaluation(JSON.stringify({
        __legadoSourceEval: true,
        body: '<html><div class="list">搜索结果</div></html>',
        variableBlob: '4821'
      }));
      expect(decoded.body).assertContain('搜索结果');
      expect(decoded.variableBlob).assertEqual('4821');
      const plain = decodeSourceScriptEvaluation('<html>普通结果</html>');
      expect(plain.body).assertEqual('<html>普通结果</html>');
      expect(plain.variableBlob).assertEqual('');
    });

    it('resolvesFallbackChaptersAgainstTheActualTocPage', 0, () => {
      expect(resolveContentPageUrl(
        '/131/131009/48367353.html', 'http://www.xbiqugu.la/131/131009/'
      )).assertEqual('http://www.xbiqugu.la/131/131009/48367353.html');
    });

    it('selectsOnlyReadableChaptersForContentCheck', 0, () => {
      const chapters: BookSourceChapter[] = [
        { title: '第一卷', url: '第一卷0', index: 0, isVolume: true },
        { title: '第一章', url: 'https://example.com/1', index: 1 },
        { title: '第二章', url: 'https://example.com/2', index: 2 },
      ];
      const readable = selectReadableChapters(chapters, 2);
      expect(readable.length).assertEqual(2);
      expect(readable[0].title).assertEqual('第一章');
      expect(readable[1].title).assertEqual('第二章');
    });

    it('skipsExploreSectionHeadersAndInvalidBookCandidates', 0, () => {
      expect(firstExploreUrlFromText('[{"title":"榜单","url":""},{"title":"三江","url":"/rank/1"}]'))
        .assertEqual('/rank/1');
      const source = createEmptyBookSource();
      source.sourceUrl = 'https://books.example.com';
      const placeholder: SearchResult = createSearchResult();
      placeholder.name = '{{title}}';
      placeholder.noteUrl = 'https://books.example.com/novel/{{slug}}';
      const advertisement: SearchResult = createSearchResult();
      advertisement.name = '广告';
      advertisement.noteUrl = 'https://ads.example.net/?ref_id=1';
      const book: SearchResult = createSearchResult();
      book.name = '真实书籍';
      book.author = '作者';
      book.noteUrl = 'https://books.example.com/novel/123';
      expect(selectCheckResult(source, [placeholder, advertisement, book])?.noteUrl)
        .assertEqual(book.noteUrl);
    });

    it('appliesTimeoutAndCookiePolicyWithoutMutatingHeaders', 0, () => {
      const source = createEmptyBookSource();
      source.respondTime = 12345;
      source.enabledCookieJar = false;
      const original: Record<string, string> = { 'Accept': 'text/html' };
      const headers = SourceNetworkPolicy.headers(source, original);
      expect(SourceNetworkPolicy.timeout(source)).assertEqual(60000);
      expect(SourceNetworkPolicy.timeout(source, 90000)).assertEqual(90000);
      expect(headers[DISABLE_COOKIE_HEADER]).assertEqual('1');
      expect(original[DISABLE_COOKIE_HEADER] === undefined).assertTrue();
    });

    it('persistsAndroidCompatibleCheckOutcome', 0, () => {
      const source = createEmptyBookSource();
      source.group = '自用,搜索失效,校验超时';
      source.bookSourceComment = '// Error: old\n\n保留备注';
      applyCheckResultToSource(source, {
        sourceUrl: source.sourceUrl, sourceName: source.sourceName, status: 'fail',
        totalChecks: 2, passedChecks: 1, details: [], errorMessage: '正文为空',
        invalidGroups: ['搜索正文失效'], duration: 5000
      }, 180000);
      expect(source.group).assertEqual('自用,搜索正文失效');
      expect(source.respondTime).assertEqual(185000);
      expect(source.bookSourceComment.startsWith('// Error: 正文为空')).assertTrue();
      expect(removeCheckErrorComment(source.bookSourceComment)).assertEqual('保留备注');
    });

    it('clearsStaleFailuresAfterSuccessfulCheck', 0, () => {
      const source = createEmptyBookSource();
      source.group = '自用,网站失效';
      source.bookSourceComment = '// Error: old\n\n人工备注';
      applyCheckResultToSource(source, {
        sourceUrl: source.sourceUrl, sourceName: source.sourceName, status: 'success',
        totalChecks: 1, passedChecks: 1, details: [], errorMessage: '',
        invalidGroups: [], duration: 1234
      }, 180000);
      expect(source.group).assertEqual('自用');
      expect(source.respondTime).assertEqual(1234);
      expect(source.bookSourceComment).assertEqual('人工备注');
    });
  });
}
