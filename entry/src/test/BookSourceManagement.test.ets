import { describe, it, expect } from '@ohos/hypium';
import { BookSourceChapter, createEmptyBookSource, parseBookSource } from '../main/ets/model/BookSource';
import {
  CheckConfig, createSourceForCheck, firstExploreUrlFromText, isSearchCheckDisabled, normalizeCheckConfig,
  selectCheckResult, selectReadableChapters
} from '../main/ets/service/SourceChecker';
import { createSearchResult, SearchResult } from '../main/ets/model/SearchResult';
import {
  decodeSourceScriptEvaluation, hasExplicitTocPaginationRule, isDuplicateTocPage,
  hasUsableSearchIdentity,
  isExplicitlyDisabledSearchTemplate, isTransientGetFailure, isWafProbeHtml,
  needsWebViewDocument, resolveContentPageUrl, boundedSearchParseCount,
  sanitizeAiGeneratedTocUrlRule, aiTitleAttributeRule, formatLegadoBookName,
  preferCompleteBookName, normalizeMediaUrlValue
} from '../main/ets/engine/source/SourceExecutor';
import {
  DISABLE_COOKIE_HEADER, SourceNetworkPolicy
} from '../main/ets/engine/source/SourceNetworkPolicy';
import { applyCheckResultToSource, removeCheckErrorComment } from '../main/ets/service/SourceCheckPersistence';
import {
  inferSearchRequest, isAiBookNameConsistent, isAiLinkExtractionRule,
  isLikelyAiBookDetailUrl, isLikelyImageCaptchaPage, isPlausibleAiBookInfo,
  isUsableAiCoverRule, correctAiCoverRuleFromHtml, materializeAgentRequest, prepareSourceAgentHtml
} from '../main/ets/engine/ai/AiSourceAgent';
import { supportedAiRuleContract } from '../main/ets/engine/ai/AiPromptKnowledge';
import { changedSourceFields } from '../main/ets/service/SourceRevisionService';
import { WebViewFetcher } from '../main/ets/engine/web/WebViewFetcher';
import { AiSearchPageLink } from '../main/ets/model/AiSourceDiscovery';
import { AiSourceDiscoveryService } from '../main/ets/service/AiSourceDiscoveryService';
import {
  buildOnlineSearchUrl, isOnlineSearchResultPage, normalizeOnlineSearchEngine
} from '../main/ets/service/OnlineSearchEngineService';

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

    it('sharesOnlineSearchEngineSemantics', 0, () => {
      expect(normalizeOnlineSearchEngine('unknown')).assertEqual('bing');
      expect(buildOnlineSearchUrl('baidu', '斗罗大陆'))
        .assertEqual('https://www.baidu.com/s?wd=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86');
      expect(isOnlineSearchResultPage('https://cn.bing.com/search?q=斗罗大陆')).assertTrue();
      expect(isOnlineSearchResultPage('https://example.com/search?q=斗罗大陆')).assertFalse();
    });

    it('normalizesAndDeduplicatesDiscoveredSites', 0, () => {
      const existing = createEmptyBookSource();
      existing.id = 7;
      existing.sourceName = '已有站点';
      existing.sourceUrl = 'https://site-b.com/';
      const links: AiSearchPageLink[] = [
        { href: 'https://www.site-a.com/book/1?from=bing#top', text: '斗罗大陆', title: '斗罗大陆', context: '斗罗大陆 作者甲', dataUrl: '' },
        { href: 'https://site-a.com/chapter/1/1', text: '斗罗大陆 第一章', title: '', context: '斗罗大陆', dataUrl: '' },
        { href: 'https://site-b.com/novel/2', text: '斗罗大陆', title: '斗罗大陆', context: '已有站点', dataUrl: '' },
      ];
      const candidates = AiSourceDiscoveryService.buildCandidates(
        'bing', '斗罗大陆', 'https://cn.bing.com/search?q=斗罗大陆', links, [existing]);
      const siteA = candidates.find((item) => item.normalizedSiteKey === 'site-a.com');
      const siteB = candidates.find((item) => item.normalizedSiteKey === 'site-b.com');
      expect(siteA?.hitCount || 0).assertEqual(2);
      expect(siteA?.homepageUrl || '').assertEqual('https://site-a.com');
      expect(siteA?.samples.length || 0).assertEqual(2);
      expect(siteA?.selected || false).assertTrue();
      expect(siteB?.duplicate || 'none').assertEqual('exact');
      expect(siteB?.selected || false).assertFalse();
    });

    it('filtersUnsafeUrlsAndDecodesSearchRedirects', 0, () => {
      expect(AiSourceDiscoveryService.isCandidateUrl('file:///tmp/a')).assertFalse();
      expect(AiSourceDiscoveryService.isCandidateUrl('http://127.0.0.1/book')).assertFalse();
      expect(AiSourceDiscoveryService.isCandidateUrl('https://talent.baidu.com/jobs/list')).assertFalse();
      const encoded = encodeURIComponent('https://example.com/book/1?key=1');
      const link: AiSearchPageLink = {
        href: 'https://cn.bing.com/ck?u=' + encoded,
        text: '斗罗大陆', title: '', context: '', dataUrl: ''
      };
      expect(AiSourceDiscoveryService.decodeKnownSearchRedirect('bing', link))
        .assertEqual('https://example.com/book/1?key=1');
      expect(AiSourceDiscoveryService.normalizedSiteKey('https://www.example.com/book/1'))
        .assertEqual('example.com');
      expect(AiSourceDiscoveryService.normalizedSiteKey('https://m.example.com/book/1'))
        .assertEqual('m.example.com');
    });

    it('keepsOnlyRelevantSearchSitesAndStableCandidateIds', 0, () => {
      const links: AiSearchPageLink[] = [
        { href: 'https://talent.baidu.com/jobs/list', text: '校园招聘', title: '',
          context: '斗罗大陆 校园招聘', dataUrl: '' },
        { href: 'https://www.baidu.com/s?wd=斗罗大陆', text: '斗罗大陆', title: '',
          context: '搜索导航', dataUrl: '' },
        { href: 'https://reader.example.com/book/1', text: '斗罗大陆', title: '斗罗大陆',
          context: '斗罗大陆 作者甲 小说目录', dataUrl: '' },
        { href: 'https://reader.example.com/book/1?from=copy', text: '斗罗大陆', title: '',
          context: '斗罗大陆 作者甲', dataUrl: '' },
        { href: 'https://www.baidu.com/link?url=opaque-a', text: '斗罗大陆', title: '',
          context: '斗罗大陆', dataUrl: '' },
        { href: 'https://www.baidu.com/link?url=opaque-b', text: '斗罗大陆', title: '',
          context: '斗罗大陆', dataUrl: '' },
      ];
      const candidates = AiSourceDiscoveryService.buildCandidates(
        'baidu', '斗罗大陆', 'https://www.baidu.com/s?wd=斗罗大陆', links, []);
      expect(candidates.find((item) => item.host === 'talent.baidu.com') === undefined).assertTrue();
      expect(candidates.find((item) => item.normalizedSiteKey === 'reader.example.com')?.hitCount || 0)
        .assertEqual(2);
      const ids: string[] = candidates.map((item) => item.id);
      expect(new Set(ids).size).assertEqual(ids.length);
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

    it('keepsSelectedSearchTypeInPostSearchForm', 0, () => {
      const form = '<form action="https://m.example.com/s.php" method="post">' +
        '<input name="s" id="s_key" placeholder="输入书名">' +
        '<select name="type"><option value="articlename">书名</option>' +
        '<option value="author">作者</option></select></form>';
      const request = inferSearchRequest(form, 'https://m.example.com/', '快穿');
      expect(request?.ruleSearchUrl || '').assertContain('s={{key}}&type=articlename');
      const spec = materializeAgentRequest(
        request?.ruleSearchUrl || '', '快穿', 1, 'https://m.example.com');
      expect(spec.method).assertEqual('POST');
      expect(spec.body).assertContain('type=articlename');
    });

    it('usesDeclaredBaseUrlForMigratedSearchForm', 0, () => {
      const html = '<script>var baseurl = "https://new.example.com";</script>' +
        '<form action="https://old.example.com/search" method="get">' +
        '<input name="q" placeholder="搜索小说"><button>搜索</button></form>';
      const request = inferSearchRequest(html, 'https://old.example.com/', '三体');
      expect(request?.ruleSearchUrl || '').assertEqual(
        'https://new.example.com/search?q={{key}}');
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

    it('decodesArkWebOuterHtmlBeforeRuleParsing', 0, () => {
      const encoded = '"\\u003Chtml\\u003E\\u003Cbody class=\\"books\\"\\u003E小说\\n列表' +
        '\\u003C/body\\u003E\\u003C/html\\u003E"';
      const decoded = WebViewFetcher.decodeJavaScriptString(encoded);
      expect(decoded).assertEqual('<html><body class="books">小说\n列表</body></html>');
      expect(WebViewFetcher.decodeJavaScriptString('<html>直接结果</html>'))
        .assertEqual('<html>直接结果</html>');
    });

    it('distinguishesCaptchaFormFromNormalCloudflareScript', 0, () => {
      const captcha = '<script>var url_search="/searchcode.php?t=1"</script>' +
        '<input id="__17mb_input" title="请输入验证码">';
      expect(WebViewFetcher.isInteractiveChallengeHtml(captcha)).assertTrue();
      const normalPage = '<table class="table"><tr><td><a href="/book/1">书名</a></td></tr></table>' +
        '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(normalPage)).assertFalse();
      // 七猫首页会预渲染登录二维码，并在脚本中保留 smcaptchaStatus；这些只是
      // 登录/统计元数据，不代表当前页面要求用户完成验证码验证。
      const normalHomepage = '<img class="qrcode-img" src="/login-code.png">' +
        '<script>var smcaptchaStatus = false;</script><h1>七猫小说</h1>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(normalHomepage)).assertFalse();
      const completedSearch = '<script>var url_search="/searchcode.php?t=1"</script>' +
        '<table class="table"><tr><td><a href="/0/book1/">四合院</a></td></tr></table>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(completedSearch)).assertFalse();
      expect(WebViewFetcher.isInteractiveChallengeHtml(
        completedSearch + '<script>var _cf_chl_opt = {};</script>')).assertFalse();
    });

    it('doesNotTreatBookDetailHiddenLoginAsVerification', 0, () => {
      // 九五书包等老站会在每个详情页中嵌入隐藏登录/注册表单，表单同时带有
      // searchcode.php、__17mb_input 和“验证码”字段，但页面本身是可解析的书籍主页。
      const detail = '<div class="info"><h1>从四合院开始的影视穿越</h1>' +
        '<div class="author">作者：测试作者</div></div>' +
        '<div class="r_cons">作品简介：这是一本小说</div>' +
        '<div class="r_tools"><a href="/167/167031/">目录</a></div>' +
        '<div id="login_regist"><form class="login_form" action="/login.php">' +
        '<input type="password"><input id="__17mb_input" title="请输入验证码">' +
        '<script src="/searchcode.php?t=1"></script></form></div>';
      expect(WebViewFetcher.isLikelyBookDocumentHtml(detail)).assertTrue();
      expect(WebViewFetcher.isInteractiveChallengeHtml(detail)).assertFalse();
      expect(needsWebViewDocument(detail, 'https://example.com/bookbook/167031.html')).assertFalse();
    });

    it('normalizesCssBackgroundImageForBookCover', 0, () => {
      expect(normalizeMediaUrlValue(
        "background-image: url('https://www.pinshuzhai.com/wp-content/uploads/cover.jpg')"))
        .assertEqual('https://www.pinshuzhai.com/wp-content/uploads/cover.jpg');
      expect(normalizeMediaUrlValue('url("/images/cover.webp")'))
        .assertEqual('/images/cover.webp');
      expect(normalizeMediaUrlValue('https://example.com/cover.jpg'))
        .assertEqual('https://example.com/cover.jpg');
    });

    it('requiresAiCoverRulesToExtractImageUrls', 0, () => {
      expect(isUsableAiCoverRule('div.cover@img@src')).assertTrue();
      expect(isUsableAiCoverRule('img@data-original')).assertTrue();
      expect(isUsableAiCoverRule('meta[property="og:image"]@content')).assertTrue();
      expect(isUsableAiCoverRule('div.cover@style')).assertFalse();
      expect(isUsableAiCoverRule('div.cover@html')).assertFalse();
      expect(isUsableAiCoverRule('background-image: url(cover.jpg)')).assertFalse();
      expect(supportedAiRuleContract('detail')).assertContain('禁止 @style');
    });

    it('repairsInvalidAiCoverRulesFromPageEvidence', 0, () => {
      const html = '<div class="book-cover"><img data-original="/cover.jpg" ' +
        'alt="封面"></div>';
      expect(correctAiCoverRuleFromHtml('div.book-cover@style', html))
        .assertEqual('div.book-cover img@data-original');
      expect(correctAiCoverRuleFromHtml('background-image: url(cover.jpg)',
        '<table class="table"><tr><td>书名</td></tr></table>')).assertEqual('');
      expect(correctAiCoverRuleFromHtml('div.cover@style',
        '<img src="/logo.png" alt="站点 Logo">')).assertEqual(null);
    });

    it('rejectsImageCaptchaWithoutSubmitFlowAndUnsupportedSelectors', 0, () => {
      const captchaPage = '<script>var url_search="/searchcode.php?t=1"</script>' +
        '<input id="__17mb_input" title="请输入验证码">' +
        '<table class="table"><tr><th>类型</th><th>书名</th></tr></table>';
      expect(isLikelyImageCaptchaPage(captchaPage)).assertTrue();
      expect(isLikelyImageCaptchaPage(
        '<li class="dba_bookcase"><a href="/mybook.html">书架</a></li>' + captchaPage)).assertTrue();
      expect(isLikelyImageCaptchaPage(
        '<table class="table"><tr><td><a href="/book/1">四合院</a></td></tr></table>' +
        '<input id="__17mb_input" title="请输入验证码">')).assertFalse();
      expect(supportedAiRuleContract('search')).assertContain('java.getVerificationCode');
    });

    it('rejectsNavigationPagesAndTextRulesFromAiSourceSamples', 0, () => {
      expect(isLikelyAiBookDetailUrl(
        'https://www.pinshuzhai.com/bookcat/shuxiangwenku')).assertFalse();
      expect(isLikelyAiBookDetailUrl(
        'https://www.pinshuzhai.com/book/1648.html')).assertTrue();
      expect(isLikelyAiBookDetailUrl(
        'https://www.ghjun.com/mybook.html')).assertFalse();
      expect(isAiLinkExtractionRule('div.bookinfo h4 a')).assertFalse();
      expect(isAiLinkExtractionRule('div.bookinfo h4 a@text')).assertFalse();
      expect(isAiLinkExtractionRule('div.bookinfo h4 a@href')).assertTrue();
      expect(isAiLinkExtractionRule('$.data[*].url')).assertTrue();
    });

    it('requiresSearchAndDetailBookNamesToDescribeTheSameBook', 0, () => {
      expect(isAiBookNameConsistent('马可瓦尔多 - 品书斋', '《马可瓦尔多》')).assertTrue();
      expect(isAiBookNameConsistent('书香文库', '马可瓦尔多')).assertFalse();
      expect(isAiBookNameConsistent(
        '马可瓦尔多 - 作者 - 无广告阅读 - 很长的网站名称', '马可瓦尔多')).assertFalse();
      expect(isAiBookNameConsistent(
        '马可瓦尔多 body{--wp--preset--color--black:#000} new Vue({})',
        '马可瓦尔多')).assertFalse();
    });

    it('rejectsWholePageTextExtractedAsBookInfo', 0, () => {
      expect(isPlausibleAiBookInfo({
        name: '夏天、烟火和我的尸体',
        author: '乙一',
        coverUrl: 'https://example.com/cover.jpg',
        introduce: '作品简介',
        kind: '悬疑推理',
        wordCount: '5.3万字',
        lastUpdateTime: '',
        tocUrl: 'https://example.com/book/1504.html',
        chapters: [],
      }, '夏天、烟火和我的尸体')).assertTrue();
      expect(isPlausibleAiBookInfo({
        name: '夏天、烟火和我的尸体 body{--wp--preset--color--black:#000}',
        author: '乙一 new Vue({ el: "#app" })',
        coverUrl: '',
        introduce: '',
        kind: '',
        wordCount: '',
        lastUpdateTime: '',
        chapters: [],
      }, '夏天、烟火和我的尸体')).assertFalse();
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

    it('boundsHtmlSearchParsingToKeepMainThreadResponsive', 0, () => {
      expect(boundedSearchParseCount(5201)).assertEqual(200);
      expect(boundedSearchParseCount(20)).assertEqual(20);
      expect(boundedSearchParseCount(-1)).assertEqual(0);
    });

    it('rejectsSearchTableHeadersWithoutBookUrl', 0, () => {
      expect(hasUsableSearchIdentity('类型书名', '')).assertFalse();
      expect(hasUsableSearchIdentity('四合院之饮食男女', '/book/1')).assertTrue();
    });

    it('doesNotReuseAiAnalysisSampleCatalogForEveryBook', 0, () => {
      expect(sanitizeAiGeneratedTocUrlRule(
        'https://www.ghjun.com/0/uxiijz9/1/', true)).assertEqual('');
      expect(sanitizeAiGeneratedTocUrlRule('/0/uxiijz9/1/', true)).assertEqual('');
      expect(sanitizeAiGeneratedTocUrlRule(
        'https://www.ghjun.com/{{bookUrl}}/1/', true))
        .assertEqual('https://www.ghjun.com/{{bookUrl}}/1/');
      expect(sanitizeAiGeneratedTocUrlRule(
        'https://www.ghjun.com/0/uxiijz9/1/', false))
        .assertEqual('https://www.ghjun.com/0/uxiijz9/1/');
    });

    it('keepsCompleteBookNamesFromAiSearchAndDetailPages', 0, () => {
      expect(aiTitleAttributeRule('td:nth-child(2) a@href'))
        .assertEqual('td:nth-child(2) a@title');
      expect(preferCompleteBookName(
        '四合院：我从四三年开', '四合院：我从四三年开始打鬼子'))
        .assertEqual('四合院：我从四三年开始打鬼子');
      expect(preferCompleteBookName('四合院：从中医开始', '网站首页'))
        .assertEqual('四合院：从中医开始');
      expect(formatLegadoBookName('我，刘立东，专治四合院各种不服'))
        .assertEqual('我，刘立东，专治四合院各种不服');
      expect(formatLegadoBookName('三体 作者：刘慈欣')).assertEqual('三体');
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
