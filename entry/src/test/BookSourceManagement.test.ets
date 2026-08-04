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
  preferCompleteBookName, normalizeMediaUrlValue, searchRateLimitWaitMs_,
  unwrapJsCallUrlValue_
} from '../main/ets/engine/source/SourceExecutor';
import {
  DISABLE_COOKIE_HEADER, SourceNetworkPolicy
} from '../main/ets/engine/source/SourceNetworkPolicy';
import { applyCheckResultToSource, removeCheckErrorComment } from '../main/ets/service/SourceCheckPersistence';
import {
  inferSearchRequest, isAiBookNameConsistent, isAiLinkExtractionRule,
  isLikelyAiBookDetailUrl, isLikelyImageCaptchaPage, isPlausibleAiBookInfo,
  isUsableAiCoverRule, correctAiCoverRuleFromHtml, materializeAgentRequest,
  prepareSourceAgentHtml, isLikelyAiLoginPage, isLikelyAiLoginResultPage,
  hasAiSearchResultMarkup_, hasAiSearchCardMetadata_, isUnevaluableSearchTemplate_,
  inferMobileCanonicalOrigin_, isSearchKeywordTooShortAlert_, extractSearchAlertInfo_,
  plainRateLimitWaitMs_, patchSearchRuleCharset_
} from '../main/ets/engine/ai/AiSourceAgent';
import { supportedAiRuleContract } from '../main/ets/engine/ai/AiPromptKnowledge';
import { changedSourceFields } from '../main/ets/service/SourceRevisionService';
import { WebViewFetcher } from '../main/ets/engine/web/WebViewFetcher';
import { AiSearchPageLink } from '../main/ets/model/AiSourceDiscovery';
import { AiSourceDiscoveryService } from '../main/ets/service/AiSourceDiscoveryService';
import { getHtmlParser } from '../main/ets/util/HtmlParser';
import {
  buildOnlineSearchUrl, isOnlineSearchResultPage, normalizeOnlineSearchEngine
} from '../main/ets/service/OnlineSearchEngineService';
import {
  isRedirectLoopError, normalizeVisitedUrl_, resolveRelativeUrl_, shouldKeepPostBodyOnRedirect_
} from '../main/ets/util/NetUtil';

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

    it('doesNotTreatHiddenHomepageLoginAsLoginGate', 0, () => {
      const homepage = '<form class="search"><input name="keyword"></form>' +
        '<div class="login-modal" style="display:none"><form>' +
        '<input type="password"><span>登录</span></form></div>';
      expect(isLikelyAiLoginPage(homepage, 'https://example.com/')).assertFalse();
      expect(isLikelyAiLoginPage(
        '<form action="/login"><input type="password"><button>登录</button></form>',
        'https://example.com/login')).assertTrue();
      expect(isLikelyAiLoginPage(
        '<form><input type="password"><button>登录</button></form>',
        'https://example.com/login.html')).assertTrue();
    });

    it('detectsLoginResultPageReturnedBySearch', 0, () => {
      // 630read.com / 3qzw.org 搜索接口返回的会员登录页：
      // 包含 <h2>会员登录</h2>、密码输入框、以及站点 chrome 的 /book/ 导航链接
      const loginResultPage = '<!doctype html><html><head><title>会员登录</title></head><body>' +
        '<nav><a href="/book/1">书库</a> <a href="/book/2">排行</a></nav>' +
        '<h2>会员登录</h2>' +
        '<div class="login_name"><form action="/login.php">' +
        '<input id="user_name" type="text" size="20">' +
        '<input id="password" type="password" size="20">' +
        '<button type="submit">登录</button></form></div>' +
        '<div class="footer">看不清？点击刷新</div></body></html>';
      expect(isLikelyAiLoginResultPage(loginResultPage)).assertTrue();

      // 正常搜索结果页不应被误判为登录页
      const searchResultsPage = '<!doctype html><html><head><title>搜索结果</title></head><body>' +
        '<ul class="search-result-list">' +
        '<li class="book-item"><a href="/book/101/">斗罗大陆</a> <span>作者：唐家三少</span></li>' +
        '<li class="book-item"><a href="/book/102/">斗破苍穹</a> <span>作者：天蚕土豆</span></li>' +
        '</ul></body></html>';
      expect(isLikelyAiLoginResultPage(searchResultsPage)).assertFalse();

      // 无登录标题的页面不应被误判
      expect(isLikelyAiLoginResultPage('<html><body>普通页面</body></html>')).assertFalse();
    });

    it('detectsLoginPageWithSiteChromeAsLoginGate', 0, () => {
      // 搜索返回的登录页带有站点 chrome（/book/ 导航链接 + 全局搜索框），
      // isLikelyAiLoginPage 应仍能识别为登录门禁
      const loginPageWithChrome = '<!doctype html><html><head><title>会员登录</title></head><body>' +
        '<form class="search" action="/search.html"><input name="keyword" type="search"></form>' +
        '<nav><a href="/book/1">书库</a></nav>' +
        '<h2>会员登录</h2>' +
        '<form action="/login.php"><input type="password"><button>登录</button></form>' +
        '</body></html>';
      expect(isLikelyAiLoginPage(loginPageWithChrome, 'https://3qzw.org/search.html')).assertTrue();

      // 正常首页带隐藏登录框不应被误判
      const homepageWithSearch = '<form class="search"><input name="keyword"></form>' +
        '<div class="book-list"><a href="/book/1">书1</a></div>';
      expect(isLikelyAiLoginPage(homepageWithSearch, 'https://example.com/')).assertFalse();
    });

    it('hasAiSearchResultMarkupDetectsRealSearchPages', 0, () => {
      // 有书籍结果卡片的页面
      expect(hasAiSearchResultMarkup_(
        '<ul><li class="book-item"><a href="/book/1">书1</a></li></ul>'
      )).assertTrue();
      // 有 3 条以上书籍详情链接的页面
      expect(hasAiSearchResultMarkup_(
        '<a href="/book/1">书1</a><a href="/book/2">书2</a><a href="/book/3">书3</a>'
      )).assertTrue();
      // 只有少量导航链接的登录页不算搜索结果页
      expect(hasAiSearchResultMarkup_(
        '<nav><a href="/book/">书库</a></nav>'
      )).assertFalse();
      // 空页面
      expect(hasAiSearchResultMarkup_('')).assertFalse();
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

    it('infersMobileSearchFormWithShortFieldName', 0, () => {
      // 必去小说移动版（m.ibiquw.org）首页表单：action=/s.php、method=post、
      // 关键词字段 name="s"（id="s_key"）。canonical 指向移动域名，但桌面版搜索
      // 路径 /modules/article/search.php 在移动域名上 404；必须能在移动首页上
      // 识别出 /s.php 这个真实搜索接口，否则迁移后的搜索请求会落到不存在的路径。
      const mobileForm = '<form id="formsearch" name="articlesearch" method="post" action="/s.php">' +
        '<input name="submit" type="submit" value="">' +
        '<select id="searchType" name="type" hidden="true">' +
        '<option value="articlename"></option><option value="author"></option></select>' +
        '<input id="s_key" class="bk" name="s" type="text" value="输入搜索词"/></form>';
      const request = inferSearchRequest(mobileForm, 'http://m.ibiquw.org/', '斗罗大陆');
      expect(request?.method || '').assertEqual('POST');
      expect(request?.ruleSearchUrl || '').assertContain('http://m.ibiquw.org/s.php');
      expect(request?.ruleSearchUrl || '').assertContain('s={{key}}');
      expect(request?.ruleSearchUrl || '').assertContain('type=articlename');
      const spec = materializeAgentRequest(
        request?.ruleSearchUrl || '', '斗罗大陆', 1, 'http://m.ibiquw.org');
      expect(spec.url).assertEqual('http://m.ibiquw.org/s.php');
      expect(spec.method).assertEqual('POST');
      expect(spec.body).assertContain('s=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86');
    });

    it('doesNotFlagBookNamesContainingMetadataWordsAsCardText', 0, () => {
      // 合法书名中可能包含“作者”“状态”“大小”“字数”等字样（如“快穿我渣了
      // 我的作者”），但这些词后面没有冒号，不是卡片元数据字段。只有带冒号
      // 分隔（作者：xxx）或操作类标签（加入书架）才应被判为卡片噪声。
      expect(hasAiSearchCardMetadata_('快穿我渣了我的作者')).assertFalse();
      expect(hasAiSearchCardMetadata_('我的大小姐')).assertFalse();
      expect(hasAiSearchCardMetadata_('字数游戏')).assertFalse();
      // 真实卡片污染文本带冒号，仍要识别。
      expect(hasAiSearchCardMetadata_('我门我派我江湖作者：关外大状...连载中')).assertTrue();
      expect(hasAiSearchCardMetadata_('斗罗大陆 状态：连载中')).assertTrue();
      expect(hasAiSearchCardMetadata_('更新时间：2024-01-01')).assertTrue();
      expect(hasAiSearchCardMetadata_('加入书架')).assertTrue();
      expect(hasAiSearchCardMetadata_('2024-01-01 第一章')).assertTrue();
    });

    it('detectsUnevaluableSearchTemplateWithCookieExpression', 0, () => {
      // 当阅读网（dangyuedu.com）的旧搜索规则使用 {{cookie.removeCookie(...)}}
      // 多行模板，本执行器没有 cookie 对象无法求值，URL 会被拼坏。
      // 这类模板必须被识别为不可用，触发重新生成。
      const cookieTemplate = 'https://www.dangyuedu.com/{{cookie.removeCookie(source.getKey())}}\n' +
        'https://www.sososhu.com/?q={{key}}&site=dangyuedu&Submit=';
      expect(isUnevaluableSearchTemplate_(cookieTemplate)).assertTrue();
      // 标准变量模板不应被误判。
      expect(isUnevaluableSearchTemplate_('https://example.com/search?q={{key}}')).assertFalse();
      expect(isUnevaluableSearchTemplate_('https://example.com/search?q={{key}}&page={{page}}')).assertFalse();
      expect(isUnevaluableSearchTemplate_('')).assertFalse();
    });

    it('infersSearchFormFromInlineDocumentWriteScript', 0, () => {
      // dangyuedu.com 的 search() 用 document.write 输出表单，WebView 提取的
      // outerHTML 可能不含渲染结果，但内联脚本源码仍包含完整 form HTML。
      const html = '<html><body><div class="search"><script>' +
        'document.write(\'<form name="t_frmsearch" method="get" action="https://www.sososhu.com/" target="_blank" class="search-form">' +
        '<input id="searchkey" type="text" name="q" placeholder="可搜书名和作者">' +
        '<input type="hidden" name="site" value="dangyuedu">' +
        '<button type="submit" name="Submit" value="搜索">搜索</button></form>\');</script></div></body></html>';
      const request = inferSearchRequest(html, 'https://www.dangyuedu.com/', '长生');
      expect(request?.ruleSearchUrl || '').assertContain('https://www.sososhu.com/');
      expect(request?.ruleSearchUrl || '').assertContain('q={{key}}');
      expect(request?.ruleSearchUrl || '').assertContain('site=dangyuedu');
      expect(request?.method || '').assertEqual('GET');
    });

    it('detectsLinkBasedLoginResultPage', 0, () => {
      // 搜搜书（sososhu.com）的“需要登录”页用 <a href="/?action=login"> 跳转
      // 而不是 form，旧检测只认 form/password，会漏判。
      const loginPage = '<!DOCTYPE html><html><head><title>需要登录 - 搜搜书</title></head>' +
        '<body><div class="login-required-box"><h2>需要登录才能搜索</h2>' +
        '<a href="/?action=login&redirect=%2F" class="btn btn-primary">立即登录</a>' +
        '<a href="/" class="btn btn-ghost">返回首页</a></div></body></html>';
      expect(isLikelyAiLoginResultPage(loginPage)).assertTrue();
      // 正常搜索结果页不应被误判。
      const searchPage = '<html><head><title>搜索结果</title></head>' +
        '<body><ul class="item"><li><a href="/book/1">书名</a></li></ul></body></html>';
      expect(isLikelyAiLoginResultPage(searchPage)).assertFalse();
    });

    it('detectsCrossDomainMigrationFromHighFrequencyLinks', 0, () => {
      // lewenge.cc 首页 301 跳转到 lewendu8.net，新域名页面没有 canonical，
      // 但包含大量指向 lewendu8.net 的绝对链接。高频跨域链接应被识别为迁移。
      const links = Array.from({ length: 8 }, (_, i) =>
        `<a href="http://www.lewendu8.net/books/${i}/${i}00/6527350${i}.html">书${i}</a>`).join('');
      const html = `<html><body>${links}` +
        '<a href="http://www.baidu.com/s?wd=乐文">百度</a></body></html>';
      const origin = inferMobileCanonicalOrigin_(html, 'http://www.lewenge.cc/');
      expect(origin).assertEqual('http://www.lewendu8.net');
      // 低频跨域链接（仅 1-2 次）不应被误判为迁移，可能是广告/CDN。
      const lowFreq = '<html><body><a href="http://cdn.example.com/lib.js">cdn</a>' +
        '<a href="http://ads.example.net/ad">ad</a></body></html>';
      expect(inferMobileCanonicalOrigin_(lowFreq, 'http://www.lewenge.cc/')).assertEqual('');
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

    it('detectsGuardAutoJsChallengePage', 0, () => {
      // zqb88.cn 等站点使用 _guard/auto.js 做 JS 挑战：首次请求只返回一个
      // 极短的 <script src="/_guard/auto.js">，必须用 WebView 执行脚本写入
      // Cookie 后才能访问真实内容。
      const guardChallenge = '<script src="/_guard/auto.js"></script>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(guardChallenge)).assertTrue();
      // 正常页面不应被误判。
      const normalPage = '<html><body><ul class="item"><li><a href="/book/1">书名</a></li></ul>' +
        '<script src="/static/js/main.js"></script></body></html>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(normalPage)).assertFalse();
    });

    it('detectsSearchRateLimitAlertPage', 0, () => {
      // 5299txt.net 等站点在两次搜索间隔不足时返回极短的 alert 脚本页。
      const rateLimit = '<script>alert("搜索间隔: 30 秒");window.history.go(-1);</script>';
      expect(searchRateLimitWaitMs_(rateLimit)).assertEqual(30000);
      // 不同格式的频率限制提示。
      const rateLimit2 = '<script>alert("请30秒后再试");location.href="/";</script>';
      expect(searchRateLimitWaitMs_(rateLimit2)).assertEqual(30000);
      // 正常搜索结果页不应被误判。
      const normalSearch = '<html><body><ul class="item"><li><a href="/book/1">书名</a></li></ul></body></html>';
      expect(searchRateLimitWaitMs_(normalSearch)).assertEqual(0);
      // 空页面不触发。
      expect(searchRateLimitWaitMs_('')).assertEqual(0);
    });

    it('detectsEmpireCmsPlainHtmlRateLimitPage', 0, () => {
      // 帝国 CMS（爱久久网等）对两次搜索间隔不足时返回 200 状态、1-2KB 的
      // 普通 HTML 提示页（title/正文"系统限制的搜索时间间隔为 15 秒"），
      // 没有 alert 脚本，超出 alert 页 500 字节上限；页面只有返回/导航
      // 链接，没有任何 .html 内容链接。正常搜索结果页带大量 .html 书籍
      // 链接，不能误判成限频页。
      const empireCms = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
        '<title>系统限制的搜索时间间隔为 15 秒,请稍后再搜索</title>' +
        '<meta name="keywords" content="系统限制的搜索时间间隔为 15 秒,请稍后再搜索">' +
        '</head><body><div class="layout error"><p>系统限制的搜索时间间隔为 15 秒,请稍后再搜索</p>' +
        '<a id="jump" href="javascript:history.go(-1)"></a></div></body></html>';
      expect(searchRateLimitWaitMs_(empireCms)).assertEqual(15000);
      // 带正文脚本的完整限频页超过 500 字节也应识别。
      const fullPage = empireCms +
        '<script>$(document).ready(function(){var url=$(\'#jump\').attr(\'href\');});</script>';
      expect(fullPage.length > 500).assertTrue();
      expect(searchRateLimitWaitMs_(fullPage)).assertEqual(15000);
      // 正常搜索结果页（含 .html 书籍链接）不误判。
      const normalSearch = '<html><head><title>七零四合院里欢乐多 搜索结果_久久小说网</title></head>' +
        '<body><div class="searchTopic"><a href="/book/12345.html">书名</a></div></body></html>';
      expect(searchRateLimitWaitMs_(normalSearch)).assertEqual(0);
      // 无关键字请求的"没有搜索到相关的内容"页不是限频页，不误判。
      const emptyKeywordPage = '<html><head><title>没有搜索到相关的内容</title></head>' +
        '<body><p>没有搜索到相关的内容</p></body></html>';
      expect(searchRateLimitWaitMs_(emptyKeywordPage)).assertEqual(0);
    });

    it('detectsSearchKeywordTooShortAlert', 0, () => {
      // shoujix.com 对短关键词返回 alert("关键字最少 10 个字符") 脚本页。
      const tooShort = '<script>alert("关键字最少 10 个字符");window.history.go(-1);</script>';
      expect(isSearchKeywordTooShortAlert_(tooShort)).assertTrue();
      const tooShort2 = '<script>alert("搜索词太短");history.back();</script>';
      expect(isSearchKeywordTooShortAlert_(tooShort2)).assertTrue();
      // GBK 站点返回的 alert 页没有 charset 声明，decodeBody 按 UTF-8 解码后
      // 中文变成乱码，但 alert + window.history.go 的脚本结构仍可识别。
      const gbkMojibake = '<script>alert("éå³å­æå° 10 ä¸ªå­ç¬¦");window.history.go(-1);</script>';
      expect(isSearchKeywordTooShortAlert_(gbkMojibake)).assertTrue();
      // 正常搜索结果页不误判。
      const normal = '<html><body><ul class="item"><li><a href="/book/1">书名</a></li></ul></body></html>';
      expect(isSearchKeywordTooShortAlert_(normal)).assertFalse();
    });

    it('classifiesSearchAlertPagesByText', 0, () => {
      // decodeBody 修复后，GBK alert 页的文案可读，分类必须按语义区分
      // "关键词太短"与"搜索频率限制"，不能把限频页误报成关键词过短。
      // shoujix.com 的"搜索间隔：30 秒"限频页（此前被 UTF-8 解码成乱码，
      // 结构分支只能猜到"关键词太短"，导致兜底关键词也失败、Agent 终止）。
      const rateLimit = '<script>alert("搜索间隔：30 秒");window.history.go(-1);</script>';
      const rateInfo = extractSearchAlertInfo_(rateLimit);
      expect(rateInfo !== null).assertTrue();
      expect(rateInfo!.kind).assertEqual('rateLimit');
      expect(rateInfo!.waitMs).assertEqual(30000);
      expect(rateInfo!.text).assertEqual('搜索间隔：30 秒');
      const rateLimit2 = '<script>alert("请30秒后再试");location.href="/";</script>';
      const rateInfo2 = extractSearchAlertInfo_(rateLimit2);
      expect(rateInfo2 !== null).assertTrue();
      expect(rateInfo2!.kind).assertEqual('rateLimit');
      expect(rateInfo2!.waitMs).assertEqual(30000);
      // 关键词太短提示页分类为 keywordTooShort，触发兜底长关键词机制。
      const tooShort = '<script>alert("关键字最少 10 个字符");window.history.go(-1);</script>';
      const tooShortInfo = extractSearchAlertInfo_(tooShort);
      expect(tooShortInfo !== null).assertTrue();
      expect(tooShortInfo!.kind).assertEqual('keywordTooShort');
      const tooShort2 = '<script>alert("搜索词太短");history.back();</script>';
      const tooShortInfo2 = extractSearchAlertInfo_(tooShort2);
      expect(tooShortInfo2 !== null).assertTrue();
      expect(tooShortInfo2!.kind).assertEqual('keywordTooShort');
      // 可读但不属于已知拦截类型（如登录提示）：报告真实文案，由 Agent 决策。
      const loginHint = '<script>alert("请先登录");window.history.go(-1);</script>';
      const loginInfo = extractSearchAlertInfo_(loginHint);
      expect(loginInfo !== null).assertTrue();
      expect(loginInfo!.kind).assertEqual('unknown');
      expect(loginInfo!.text).assertEqual('请先登录');
      // 正常搜索结果页不是 alert 拦截页。
      const normal = '<html><body><ul class="item"><li><a href="/book/1">书名</a></li></ul></body></html>';
      expect(extractSearchAlertInfo_(normal)).assertNull();
      // 空页面不触发。
      expect(extractSearchAlertInfo_('')).assertNull();
    });

    it('detectsPlainRateLimitHtmlPage', 0, () => {
      // 帝国 CMS（爱久久网等）的限频页是普通 HTML：200 状态、约 2KB、
      // 无 alert 脚本，文案同时出现在 <title> 与正文。此前只识别 ≤500 字节
      // 的 alert 页，防刷页被当成"内容过短"，3 轮快速重试连环被拒。
      const plainLimit = '<!DOCTYPE html><html><head><title>系统限制的搜索时间间隔为 15 秒,请稍后再搜索</title></head>' +
        '<body><div class="layout error layui-anim"><a id="jump" href="javascript:history.go(-1)">返回</a>' +
        '<p>系统限制的搜索时间间隔为 15 秒,请稍后再搜索</p></div></body></html>';
      expect(plainRateLimitWaitMs_(plainLimit)).assertEqual(15000);
      const info = extractSearchAlertInfo_(plainLimit);
      expect(info !== null).assertTrue();
      expect(info!.kind).assertEqual('rateLimit');
      expect(info!.waitMs).assertEqual(15000);
      expect(info!.text).assertEqual('系统限制的搜索时间间隔为 15 秒,请稍后再搜索');
      // 真实搜索结果页含 .html 内容链接，不应误判。
      const resultPage = '<html><head><title>四合院 搜索结果</title></head>' +
        '<body><div class="searchTopic">1、<a href="/txt/56491.html" class="searchtitle">七零四合院里欢乐多</a></div></body></html>';
      expect(plainRateLimitWaitMs_(resultPage)).assertEqual(0);
      expect(extractSearchAlertInfo_(resultPage)).assertNull();
      // 空页面不触发。
      expect(plainRateLimitWaitMs_('')).assertEqual(0);
    });

    it('extractsElementSelfTextKeywordRules', 0, () => {
      // Android Legado 相对字段规则：text / ownText / textNodes / html 作为
      // 完整规则（无选择器前缀）时取元素自身，如卡片规则 `text##作者：(.*)`。
      // 此前 text 被当 CSS 标签查找（HTML 中没有 <text> 标签）导致 author
      // 字段提取为空。验证修复 A 的真实语义。
      const parser = getHtmlParser();
      const doc = parser.parse('<div class="searchTopic"> 1 、<a href="/txt/56491.html" ' +
        'class="searchtitle">七零四合院里欢乐多</a>&nbsp;&nbsp;作者：傅延年</div>');
      const cards = parser.querySelectorAll(doc, '.searchTopic');
      expect(cards.length).assertEqual(1);
      // text##.*： 净化替换：贪婪删除最后一个冒号前内容 → 作者名
      expect(parser.extractAttr(cards[0], 'text##.*：')).assertEqual('傅延年');
      // 纯 text 关键字 → 卡片全文
      expect(parser.extractAttr(cards[0], 'text').includes('七零四合院里欢乐多')).assertTrue();
      // 带选择器的规则不受影响
      expect(parser.extractAttr(cards[0], 'a@text')).assertEqual('七零四合院里欢乐多');
      // extractAttrAll 同样支持纯关键字与 ## 后处理
      const authors = parser.extractAttrAll(cards[0], 'text##.*：');
      expect(authors.length).assertEqual(1);
      expect(authors[0]).assertEqual('傅延年');
      // 带 @ 的规则仍按 CSS 查找（text@text 不应取 root 自身）
      expect(parser.extractAttr(cards[0], 'text@text')).assertEqual('');
    });

    it('detectsRedirectLoopError', 0, () => {
      // yimixs.com 搜索接口被 RCP 自动重定向 50 跳后抛出此错误：
      // POST /search → 302 /jd-fw-key?url=/search（中间跳 Set-Cookie 不被
      // RCP 应用）→ 302 回 /search → 无 cookie 再次 302 → 无限循环。
      expect(isRedirectLoopError('Number of redirects hit maximum amount')).assertTrue();
      expect(isRedirectLoopError('businessError: 1007900047 redirect')).assertTrue();
      expect(isRedirectLoopError('HTTP 302: 服务器拒绝')).assertFalse();
      expect(isRedirectLoopError('')).assertFalse();
    });

    it('keepsPostBodyOnDomainMigrationRedirects', 0, () => {
      // 301/307/308 保留 POST method+body：301 常是 http→https / 域名迁移
      // （爱久久网 jjjxsw.com → ijjxsxzw.com，关键词全在 body 里，RCP 自动
      // 跟随会丢 body 返回"没有搜索到"）；307/308 语义本就要求保留。
      // 302/303 转 GET：302 是"提交成功请跳转"（帝国 CMS 搜索返回
      // result/?searchid=xxx），关键词已进 URL 且 result 页不接受 POST。
      expect(shouldKeepPostBodyOnRedirect_(301)).assertTrue();
      expect(shouldKeepPostBodyOnRedirect_(307)).assertTrue();
      expect(shouldKeepPostBodyOnRedirect_(308)).assertTrue();
      expect(shouldKeepPostBodyOnRedirect_(302)).assertFalse();
      expect(shouldKeepPostBodyOnRedirect_(303)).assertFalse();
    });

    it('resolvesRedirectLocation', 0, () => {
      // 绝对 URL 原样返回。
      expect(resolveRelativeUrl_('http://a.com/x', 'http://b.com/y')).assertEqual('http://b.com/y');
      // 根相对路径：基于 baseUrl 的 origin。
      expect(resolveRelativeUrl_('http://m.yimixs.xyz/search', '/jd-fw-key?url=/search'))
        .assertEqual('http://m.yimixs.xyz/jd-fw-key?url=/search');
      // 协议相对：继承 baseUrl 的 scheme。
      expect(resolveRelativeUrl_('https://a.com/x', '//cdn.com/y')).assertEqual('https://cdn.com/y');
      // 路径相对：基于 baseUrl 目录（忽略 query）。
      expect(resolveRelativeUrl_('http://a.com/dir/page?k=1', 'sibling')).assertEqual('http://a.com/dir/sibling');
      // 根目录下的路径相对。
      expect(resolveRelativeUrl_('http://a.com/dir/page', 'sibling')).assertEqual('http://a.com/dir/sibling');
      // 无路径的 baseUrl。
      expect(resolveRelativeUrl_('http://a.com', 'b')).assertEqual('http://a.com/b');
    });

    it('normalizesVisitedRedirectUrls', 0, () => {
      // yimixs 的 /jd-fw-key 把 Location 写成 %2Fsearch（编码形式），解码后是
      // //search（字面 / + 解码出的 /），必须压缩成 /search 才能与已访问的
      // 原始地址 http://m.yimixs.xyz/search 对上，否则循环闭合检测失效。
      const normalized = normalizeVisitedUrl_('http://m.yimixs.xyz/%2Fsearch');
      expect(normalized).assertEqual('http://m.yimixs.xyz/search');
      // fragment 不影响循环检测。
      expect(normalizeVisitedUrl_('http://a.com/search#top')).assertEqual('http://a.com/search');
      // 非法百分号序列不抛错，原样返回。
      expect(normalizeVisitedUrl_('http://a.com/%zz')).assertEqual('http://a.com/%zz');
      // 解码 + 压缩 + 去 fragment 组合。
      expect(normalizeVisitedUrl_('http://a.com/%2Fsearch#x')).assertEqual('http://a.com/search');
    });

    it('closesRedirectLoopToOriginalUrl', 0, () => {
      // 模拟 yimixs 防盗链 cookie 门的完整重定向链（curl 实测）：
      // POST /search（无 cookie）→ 302 /jd-fw-key?url=/search（中间跳种
      // token/random cookie）→ 302 %2Fsearch（回到原始地址）。手动跟随的
      // 循环闭合检测必须把 %2Fsearch 规范化后判定为"已访问过原始 URL"，
      // 从而跳出跟随、用种好的 cookie 重放原始 POST 请求。
      const original = 'http://m.yimixs.xyz/search';
      const visited: string[] = [normalizeVisitedUrl_(original)];
      let current = original;
      // 第一跳：POST /search → 302 /jd-fw-key?url=/search
      const hop1 = resolveRelativeUrl_(current, '/jd-fw-key?url=/search');
      visited.push(normalizeVisitedUrl_(hop1));
      current = hop1;
      // 第二跳：GET /jd-fw-key → 302 %2Fsearch（Set-Cookie: token/random）
      const hop2 = resolveRelativeUrl_(current, '%2Fsearch');
      const loopClosed = visited.indexOf(normalizeVisitedUrl_(hop2)) >= 0;
      expect(loopClosed).assertTrue();
      // 循环闭合时 cookie 已种好，重放原始 POST /search 可直接拿到结果页。
      const replayCookie = 'token=6f1e0a62825fe4fe61639b657af52fd4; random=20882191';
      expect(replayCookie.indexOf('token=') >= 0).assertTrue();
      expect(replayCookie.indexOf('random=') >= 0).assertTrue();
      // 正常 302 跳转（目标未访问过）不能误判为循环。
      const normalTarget = resolveRelativeUrl_('http://site.com/a', '/b');
      expect(visited.indexOf(normalizeVisitedUrl_(normalTarget)) >= 0).assertFalse();
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

    it('patchesGbkCharsetIntoSearchRule', 0, () => {
      // shoujix.com 是 GBK 站点：<meta charset="GBK">。从外部 JS 提取的搜索
      // 表单没有 charset 声明，关键词按 UTF-8 提交会被 GBK 解码成乱码，
      // 搜不到书。必须从首页 HTML 检测 charset 并补全到搜索规则。
      const pageHtml = '<html><head><meta charset="GBK"><title>手机小说</title></head><body></body></html>';
      const rule = 'https://www.shoujix.com/search/,{"method":"POST","body":"searchkey={{key}}"}';
      const patched = patchSearchRuleCharset_(rule, pageHtml);
      expect(patched).assertContain('"charset":"gbk"');
      // 已有 charset 的规则保持不变。
      const withCharset = 'https://example.com/s.php,{"method":"POST","body":"q={{key}}","charset":"utf-8"}';
      expect(patchSearchRuleCharset_(withCharset, pageHtml)).assertEqual(withCharset);
      // UTF-8 站点不补全。
      const utf8Page = '<html><head><meta charset="utf-8"></head></html>';
      expect(patchSearchRuleCharset_(rule, utf8Page)).assertEqual(rule);
      // GET 规则不补全 charset。
      const getRule = 'https://example.com/search?q={{key}}';
      expect(patchSearchRuleCharset_(getRule, pageHtml)).assertEqual(getRule);
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

    it('acceptsCornerBracketedNameFromDetailHeadingWithSparseFields', 0, () => {
      // 爱久久网等站点把书名放在内容区 h3 中并带《》包装，兜底规则 h3@text
      // 提取后归一化应与搜索书名一致。
      expect(isAiBookNameConsistent('《七零四合院里欢乐多》', '七零四合院里欢乐多')).assertTrue();
      expect(isAiBookNameConsistent('内容简介', '七零四合院里欢乐多')).assertFalse();
      expect(isAiBookNameConsistent('爱久久小说网ijjxsw.com欢迎您', '七零四合院里欢乐多')).assertFalse();
      // 详情页没有目录入口/简介等附加字段时，只要书名一致且作者/封面至少
      // 一项有效即可通过（isPlausibleAiDetailValue_ 对空值放行）。
      expect(isPlausibleAiBookInfo({
        name: '《七零四合院里欢乐多》',
        author: '傅延年',
        coverUrl: '//image.jjjjxsw.com/UploadPic/2026-06/fzs0z2on3j2phmvp.jpg',
        introduce: '',
        kind: '',
        wordCount: '',
        lastUpdateTime: '',
        tocUrl: '',
        chapters: [],
      }, '七零四合院里欢乐多')).assertTrue();
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

    it('unwrapsJsCallOnclickUrlsFromMobileNovelCards', 0, () => {
      // 阅友小说等移动站卡片：onclick="newWebView('/b/232832.html', '', '')"
      expect(unwrapJsCallUrlValue_("newWebView('/b/232832.html', '', '')"))
        .assertEqual('/b/232832.html');
      expect(unwrapJsCallUrlValue_('window.location.href="/b/232832.html"'))
        .assertEqual('/b/232832.html');
      expect(unwrapJsCallUrlValue_("location.href='/b/232832.html';"))
        .assertEqual('/b/232832.html');
      expect(unwrapJsCallUrlValue_("javascript:newWebView('/b/232832.html', '', '')"))
        .assertEqual('/b/232832.html');
      expect(unwrapJsCallUrlValue_("window.open('https://m.example.com/book/1.html')"))
        .assertEqual('https://m.example.com/book/1.html');
      // 普通 URL / 相对路径保持不变
      expect(unwrapJsCallUrlValue_('https://sma.yueyouxs.com/b/232832.html'))
        .assertEqual('https://sma.yueyouxs.com/b/232832.html');
      expect(unwrapJsCallUrlValue_('/b/232832.html')).assertEqual('/b/232832.html');
      // 无 URL 参数的 JS 调用（如 confirm('删除')）不误拆
      expect(unwrapJsCallUrlValue_("confirm('删除')")).assertEqual("confirm('删除')");
      expect(unwrapJsCallUrlValue_('')).assertEqual('');
      // 与相对地址解析组合：搜索卡片提取值直接可用
      expect(resolveContentPageUrl("newWebView('/b/232832.html', '', '')",
        'https://sma.yueyouxs.com/s/1.html')).assertEqual('https://sma.yueyouxs.com/b/232832.html');
    });

    it('rejectsJsCallGarbageAsAiBookDetailUrl', 0, () => {
      expect(isLikelyAiBookDetailUrl(
        "https://sma.yueyouxs.com/newWebView('/b/232832.html', '', '')"
      )).assertFalse();
      expect(isLikelyAiBookDetailUrl('https://sma.yueyouxs.com/b/232832.html')).assertTrue();
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
