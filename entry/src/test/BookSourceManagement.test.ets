import { describe, it, expect } from '@ohos/hypium';
import {
  BookSourceChapter, BookSourceFormat, BookSourceType, bookSourceToJsonObject,
  createEmptyBookSource, isQysgSourceObject, parseBookSource, qysgHtmlUrlCandidates
} from '../main/ets/model/BookSource';
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
  unwrapJsCallUrlValue_, buildUrl, sniffNextTocPageUrl, isLoginDocument,
  substituteJavaGetStringCall_, substituteJavaGetElementCall_, seedWebViewCookieUrl_
} from '../main/ets/engine/source/SourceExecutor';
import {
  DISABLE_COOKIE_HEADER, SourceNetworkPolicy
} from '../main/ets/engine/source/SourceNetworkPolicy';
import { normalizeQysgTomatoTocUrl } from '../main/ets/engine/qysg/QysgSourceCodec';
import { applyCheckResultToSource, removeCheckErrorComment } from '../main/ets/service/SourceCheckPersistence';
import {
  inferSearchRequest, isAiBookNameConsistent, isAiLinkExtractionRule,
  isLikelyAiBookDetailUrl, isPlausibleAiBookInfo,
  isUsableAiCoverRule, correctAiCoverRuleFromHtml, materializeAgentRequest,
  prepareSourceAgentHtml, isLikelyAiLoginPage, isLikelyAiLoginResultPage,
  hasAiSearchResultMarkup_, hasAiSearchCardMetadata_, isUnevaluableSearchTemplate_,
  inferMobileCanonicalOrigin_, isSearchKeywordTooShortAlert_, extractSearchAlertInfo_,
  isLikelyAiEmptySearchResultPage_, nextAiFallbackSearchKeyword_,
  plainRateLimitWaitMs_, patchSearchRuleCharset_, inferAiSearchNameCleanupRule_,
  buildAiVisibleNameRuleCandidates_, extractSearchFormFromJsSource_,
  inferSearchApiRequestFromJsSource_, resolveSourceRedirectUrl_
} from '../main/ets/engine/ai/AiSourceAgent';
import { supportedAiRuleContract } from '../main/ets/engine/ai/AiPromptKnowledge';
import { changedSourceFields } from '../main/ets/service/SourceRevisionService';
import { WebViewFetcher, isSamePathMirrorUrl_ } from '../main/ets/engine/web/WebViewFetcher';
import { AiSearchPageLink } from '../main/ets/model/AiSourceDiscovery';
import { AiSourceDiscoveryService } from '../main/ets/service/AiSourceDiscoveryService';
import { getHtmlParser, HtmlElement } from '../main/ets/util/HtmlParser';
import {
  buildOnlineSearchUrl, isOnlineSearchResultPage, normalizeOnlineSearchEngine
} from '../main/ets/service/OnlineSearchEngineService';
import {
  isRedirectLoopError, normalizeVisitedUrl_, resolveRelativeUrl_, shouldKeepPostBodyOnRedirect_,
  migrateLegacySourceUrl, registerSourceOriginAlias, NetUtil
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

    it('recognizesExternalQysgHtmlAsQysg', 0, () => {
      const external = JSON.parse('{"bookSourceName":"外链轻悦源",' +
        '"bookSourceUrl":"https://example.com",' +
        '"enabledExplore":true,"enabled":true,"bookSourceGroup":"测试",' +
        '"html":"https://mirror.example/qysg.html\\nhttps://backup.example/qysg.html",' +
        '"login":false,"lastUpdateTime":"123"}') as Object;
      expect(qysgHtmlUrlCandidates((external as Record<string, Object>)['html']).length).assertEqual(2);
      expect(isQysgSourceObject(external)).assertTrue();
      const source = parseBookSource(external);
      expect(source.sourceFormat).assertEqual(BookSourceFormat.QYSG);
      expect(source.sourceType).assertEqual(BookSourceType.MIXED);
      const exported = bookSourceToJsonObject(source);
      expect(exported['sourceFormat']).assertEqual(BookSourceFormat.QYSG);
    });

    it('normalizesTomatoMultiDetailToOfficialDirectory', 0, () => {
      const stale = 'https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/multi-detail/v/' +
        '?aid=1967&iid=1&version_code=999&book_id=7269278400190090280';
      expect(normalizeQysgTomatoTocUrl(stale))
        .assertEqual('https://fanqienovel.com/api/reader/directory/detail?bookId=7269278400190090280');
      expect(normalizeQysgTomatoTocUrl('https://fanqienovel.com/api/reader/directory/detail?bookId=1'))
        .assertEqual('https://fanqienovel.com/api/reader/directory/detail?bookId=1');
      expect(normalizeQysgTomatoTocUrl('https://example.com/reading/bookapi/multi-detail/v/?book_id=1234567890'))
        .assertEqual('https://example.com/reading/bookapi/multi-detail/v/?book_id=1234567890');
    });

    it('doesNotTreatLegadoHtmlExtensionAsQysg', 0, () => {
      const legado = JSON.parse('{"bookSourceName":"普通源",' +
        '"bookSourceUrl":"https://example.com",' +
        '"html":"https://example.com/template.html",' +
        '"ruleSearch":{"bookList":".book"}}') as Object;
      expect(isQysgSourceObject(legado)).assertFalse();
      expect(parseBookSource(legado).sourceFormat).assertEqual(BookSourceFormat.LEGADO);
    });

    it('migratesLegacyManwaHostBeforeNetworkRequests', 0, () => {
      expect(migrateLegacySourceUrl('https://www.manware.cc/api/search?keyword=%E6%A3%8B%E9%AD%82'))
        .assertEqual('https://manwari.cc/api/search?keyword=%E6%A3%8B%E9%AD%82');
      expect(migrateLegacySourceUrl('https://manware.cc/comic/97606'))
        .assertEqual('https://manwari.cc/comic/97606');
      expect(migrateLegacySourceUrl('https://example.com/comic/97606'))
        .assertEqual('https://example.com/comic/97606');
    });

    it('resolvesSourceOriginRedirectBeforeAgentFetch', 0, () => {
      expect(resolveSourceRedirectUrl_('/new-home/', 'https://legacy.example/'))
        .assertEqual('https://legacy.example/new-home/');
      expect(resolveSourceRedirectUrl_('https://new.example/', 'https://legacy.example/'))
        .assertEqual('https://new.example/');
      expect(resolveSourceRedirectUrl_('', 'https://legacy.example/')).assertEqual('');
    });

    it('infersSearchApiFromExternalJs', 0, () => {
      const js = \"const state = { currentPage: 1, pageSize: 20, searchField: 'keyword', currentType: 'mh' };\\n\" +
        \"const searchData = { type: state.currentType, page: page, pageSize: state.pageSize };\\n\" +
        \"searchData[state.searchField] = state.searchValue;\\n\" +
        \"$.ajax({ url: '/api/search', data: searchData, type: 'GET' });\";
      const inferred = inferSearchApiRequestFromJsSource_(js, 'https://manwari.cc/search/', '棋魂');
      expect(inferred !== null).assertTrue();
      expect(inferred!.ruleSearchUrl)
        .assertEqual('https://manwari.cc/api/search?type=mh&page={{page}}&pageSize=20&keyword={{key}}');
      expect(inferred!.probeUrl)
        .assertEqual('https://manwari.cc/api/search?type=mh&page=1&pageSize=20&keyword=%E6%A3%8B%E9%AD%82');
    });

    it('appliesVerifiedRuntimeSourceOriginAlias', 0, () => {
      registerSourceOriginAlias('https://legacy.example', 'https://new.example');
      expect(migrateLegacySourceUrl('https://legacy.example/book/1'))
        .assertEqual('https://new.example/book/1');
      expect(migrateLegacySourceUrl('https://www.legacy.example/book/1'))
        .assertEqual('https://new.example/book/1');
      expect(migrateLegacySourceUrl('https://legacy.example.evil/book/1'))
        .assertEqual('https://legacy.example.evil/book/1');
    });

    it('sharesOnlineSearchEngineSemantics', 0, () => {
      expect(normalizeOnlineSearchEngine('unknown')).assertEqual('bing');
      expect(buildOnlineSearchUrl('baidu', '斗罗大陆'))
        .assertEqual('https://www.baidu.com/s?wd=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86');
      expect(isOnlineSearchResultPage('https://cn.bing.com/search?q=斗罗大陆')).assertTrue();
      expect(isOnlineSearchResultPage('https://example.com/search?q=斗罗大陆')).assertFalse();
    });

    it('sniffsSemanticTocNextPage', 0, () => {
      const page = '<div class="index-container">' +
        '<a class="index-container-btn" href="/bqg/1381944_2/">上一页</a>' +
        '<a class="index-container-btn" href="/bqg/1381944_3/">下一页</a></div>';
      expect(sniffNextTocPageUrl(page, 'https://www.douyinxs.com/bqg/1381944_2/'))
        .assertEqual('https://www.douyinxs.com/bqg/1381944_3/');
      expect(sniffNextTocPageUrl(
        '<a class="index-container-btn" href="/bqg/1381944_2/">上一页</a>',
        'https://www.douyinxs.com/bqg/1381944_3/')).assertEqual('');
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

    it('infersPathSearchFromClientRenderedUnnamedForm', 0, () => {
      // Vue 站点首页的搜索框可能没有 action/name，点击按钮后由客户端跳到
      // /search/<关键词>。不能把首页本身拼成 ?keyword=，否则不同关键词会
      // 得到同一批推荐书。
      const html = '<a href="/search">全部作品</a>' +
        '<div class="search-bar"><form><input id="searchkeyword" type="text">' +
        '<button type="submit">搜索</button></form></div>';
      const request = inferSearchRequest(html, 'https://example.com/', '四合院');
      expect(request?.ruleSearchUrl || '').assertEqual(
        'https://example.com/search/{{key}}');
      expect(request?.probeUrl || '').assertEqual(
        'https://example.com/search/%E5%9B%9B%E5%90%88%E9%99%A2');
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
      const linkParts: string[] = [];
      for (let i = 0; i < 8; i++) {
        linkParts.push(`<a href="http://www.lewendu8.net/books/${i}/${i}00/6527350${i}.html">书${i}</a>`);
      }
      const links = linkParts.join('');
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

    it('doesNotTreatAikanJsdSearchOrChapterAsChallenge', 0, () => {
      const jsd = '<script>window.__CF$cv$params={r:"ray"};</script>' +
        '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>';
      const searchPage = '<div class="hot_sale"><a href="/ks123/">' +
        '<p class="title">四合院之光</p><p class="author">作者：测试</p></a></div>' + jsd;
      expect(WebViewFetcher.isInteractiveChallengeHtml(searchPage)).assertFalse();

      const chapterPage = '<div id="chaptercontent" class="Readarea ReadAjax_content">' +
        '<p>正文内容</p></div>' + jsd;
      expect(WebViewFetcher.isInteractiveChallengeHtml(chapterPage)).assertFalse();
    });

    it('doesNotTreatTurnstileEmbeddedBookPageAsChallenge', 0, () => {
      // 禁漫天堂等站点在正常详情页嵌入 Cloudflare Turnstile 脚本和挂载点
      // （用于登录/注册弹窗）。完整渲染的详情页已含书籍 DOM，不能因页面
      // 出现 cf-turnstile 就误判为未完成验证，否则每次进详情/目录都弹交互
      // WebView，且弹窗加载原地址被 WAF 拒绝显示“无法访问地址”。
      const albumWithTurnstile = '<html><head>' +
        '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>' +
        '</head><body><div id="login-modal"><div class="cf-turnstile" data-sitekey="xxx"></div></div>' +
        '<div id="intro-block"><h1>隨心一聽</h1>' +
        '<div class="intro-collapse-content">简介：短篇漫画集</div>' +
        '<div class="btn-toolbar"><a href="/photo/1458662/?shunt=1">第1话</a></div>' +
        '</div></body></html>';
      expect(WebViewFetcher.isLikelyBookDocumentHtml(albumWithTurnstile)).assertTrue();
      expect(WebViewFetcher.isInteractiveChallengeHtml(albumWithTurnstile)).assertFalse();
      // 登录弹窗还带验证码输入框（如 id="code" + “验证码”文案）：此前仅靠
      // 弹窗 id 白名单判断，这类弹窗会漏过并误判为独立验证页。有书籍 DOM
      // 的页面一律不应触发交互验证。
      const albumWithCaptchaModal = '<html><body>' +
        '<div id="login-box"><form action="/login"><input type="text" name="code" placeholder="验证码">' +
        '<img src="/captcha.png"></form></div>' +
        '<div id="intro-block"><h1>隨心一聽</h1>' +
        '<div class="btn-toolbar"><a href="/photo/1458662/?shunt=1">第1话</a></div>' +
        '</div></body></html>';
      expect(WebViewFetcher.isLikelyBookDocumentHtml(albumWithCaptchaModal)).assertTrue();
      expect(WebViewFetcher.isInteractiveChallengeHtml(albumWithCaptchaModal)).assertFalse();
      // 真正的 Turnstile 挑战页（无书籍 DOM）仍应判为需要交互验证。
      const realChallenge = '<html><body><div class="cf-turnstile" data-sitekey="xxx"></div>' +
        '<p>正在检查您的浏览器...</p></body></html>';
      expect(WebViewFetcher.isInteractiveChallengeHtml(realChallenge)).assertTrue();
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
        '<script>$(document).ready(function(){var url=$(\'#jump\').attr(\'href\');' +
        'var remain=15;var timer=setInterval(function(){remain--;' +
        'if(remain<=0){clearInterval(timer);window.location.href=url;}else{' +
        '$("#countdown").text("请等待 "+remain+" 秒后重新搜索");}},1000);});</script>';
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

    it('detectsJieqiSearchRateLimitPage', 0, () => {
      // 天籁小说网（picdg.com/wxc8.com）回归：jieqi 系站点用 cookie 记录上次
      // 搜索时间，两次搜索间隔不足 10 秒时返回 title="出现错误！"、正文
      // "错误原因：对不起，两次搜索的间隔时间不得少于 10 秒"的 1-2KB 错误页。
      // AI Agent 取证成功后会种下 jieqiVisitTime cookie，SrcEx 验证 3 秒后
      // 再次 POST 即触发限频，此前被误判成"内容过短"烧完所有轮次。修复：
      // 识别该文案并等待窗口结束再重试。
      const jieqiRateLimit = '<!DOCTYPE html><html><head><meta http-equiv="content-type" ' +
        'content="text/html; charset=gbk" /><title>出现错误！</title>' +
        '<link rel="stylesheet" type="text/css" media="all" href="https://www.picdg.com/themes/17mb/style.css" />' +
        '<script language="javascript" type="text/javascript" src="https://www.picdg.com/scripts/common.js"></script>' +
        '</head><body><div style="width:100%; text-align:center;">' +
        '<div style="width:500px; margin-top:150px;"><div class="block">' +
        '<div class="blocktitle">出现错误！</div><div class="blockcontent">' +
        '<div style="padding:10px"><br />错误原因：对不起，两次搜索的间隔时间不得少于 10 秒<br /><br />' +
        '请 <a href="javascript:history.back(1)">返 回</a> 并修正<br /><br /></div>' +
        '<div style="width:100%; text-align: right; line-height:200%; padding-right:10px;">' +
        '[<a href="javascript:window.close()">关闭本窗口</a>]</div></div>' +
        '<div class="blocknote">版权所有&copy; <a href="https://www.picdg.com/">天籁小说网</a></div>' +
        '</div></div></div></body></html>';
      expect(jieqiRateLimit.length > 500).assertTrue();
      expect(searchRateLimitWaitMs_(jieqiRateLimit)).assertEqual(10000);
      // Agent 取证路径（prepareSourceAgentHtml 清理脚本/样式后）同样识别。
      expect(plainRateLimitWaitMs_(jieqiRateLimit)).assertEqual(10000);
      // 正常搜索结果页（含 .html 书籍链接）不误判。
      const normalSearch = '<html><head><title>四合院 搜索结果</title></head>' +
        '<body><div class="result-list"><div class="result-item result-game-item">' +
        '<a href="/60_60141/">深空彼岸</a></div></div></body></html>';
      expect(searchRateLimitWaitMs_(normalSearch)).assertEqual(0);
      expect(plainRateLimitWaitMs_(normalSearch)).assertEqual(0);
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

    it('detectsEmptySearchResultPage', 0, () => {
      // yqk.net（言情库）搜索不存在的书名时只返回导航/推荐栏：
      // 无书籍卡片、无书籍链接，只有"很抱歉，暂时找不到结果！！"文案。
      // 此前模型在空页上 4 轮生成规则全是 0 条，Agent 以搜索规则验证失败终止。
      const yqkEmpty = '<html><head><title>搜索结果 - 言情库</title></head><body>' +
        '<div class="menu"><a href="/">言情小说首页</a><a href="/zuozhe/">作家列表</a></div>' +
        '<div class="main"><div class="left"><ul><p>很抱歉，暂时找不到结果！！</p></ul></div></div>' +
        '<dl><dt>小说故事情节</dt><dd><a href="/qingjie/1/">欢喜冤家</a></dd></dl></body></html>';
      expect(isLikelyAiEmptySearchResultPage_(yqkEmpty)).assertTrue();
      // 帝国 CMS 的"没有搜索到相关的内容"页。
      const empireCmsEmpty = '<html><head><title>没有搜索到相关的内容</title></head><body>' +
        '<p>没有搜索到相关的内容</p></body></html>';
      expect(isLikelyAiEmptySearchResultPage_(empireCmsEmpty)).assertTrue();
      // 其他常见无结果文案。
      expect(isLikelyAiEmptySearchResultPage_('<p>抱歉，没有找到您要的书籍</p>')).assertTrue();
      expect(isLikelyAiEmptySearchResultPage_('<p>搜索无结果</p>')).assertTrue();
      expect(isLikelyAiEmptySearchResultPage_('<p>搜索结果为空</p>')).assertTrue();
      // 真实结果页：yqk 的书籍卡片是 <li> + /yanqing/ 链接，页面无“无结果”文案。
      const yqkResult = '<html><body><ul><li>' +
        '<p><strong>《<a href="/yanqing/fuguitaojia/">富贵饕家</a>》</strong></p>' +
        '<p>作家：<a href="/zuozhe/50.html">席绢</a></p>' +
        '<p>最新章节：<a href="/yanqing/fuguitaojia/263915.html">后记</a></p></li>' +
        '<li><p><strong>《<a href="/yanqing/gaomen/">高门</a>》</strong></p></li>' +
        '<li><p><strong>《<a href="/yanqing/huolu/">活路</a>》</strong></p></li></ul></body></html>';
      expect(isLikelyAiEmptySearchResultPage_(yqkResult)).assertFalse();
      // 页面有真实书籍标记时，即使出现"还没有找到…"的推荐文案也不能判空。
      const withRecommendation = '<html><body><p>还没有找到喜欢的小说？看看推荐</p>' +
        '<ul class="book-list"><li><a href="/book/1">书名一</a></li>' +
        '<li><a href="/book/2">书名二</a></li><li><a href="/book/3">书名三</a></li></ul></body></html>';
      expect(isLikelyAiEmptySearchResultPage_(withRecommendation)).assertFalse();
      // 空页面不触发。
      expect(isLikelyAiEmptySearchResultPage_('')).assertFalse();
      expect(isLikelyAiEmptySearchResultPage_('<html><body></body></html>')).assertFalse();
    });

    it('picksNextFallbackSearchKeyword', 0, () => {
      // 关键词阶梯：空结果页时依次换用未试过的兜底关键词，避免言情站
      // 对"斗罗大陆外传"也无结果时没有下一个可用关键词。
      expect(nextAiFallbackSearchKeyword_('四合院', [])).assertEqual('斗罗大陆外传');
      expect(nextAiFallbackSearchKeyword_('斗罗大陆外传', ['四合院'])).assertEqual('穿越');
      expect(nextAiFallbackSearchKeyword_('穿越', ['四合院', '斗罗大陆外传'])).assertEqual('重生');
      // 全部尝试过（含当前词）后返回空串，Agent 报明确错误而不是无限换词。
      expect(nextAiFallbackSearchKeyword_('重生',
        ['四合院', '斗罗大陆外传', '穿越', '重生'])).assertEqual('');
      // 当前词不在阶梯中且已尝试过阶梯首词时，跳到下一个未试过的词。
      expect(nextAiFallbackSearchKeyword_('四合院', ['斗罗大陆外传'])).assertEqual('穿越');
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

      // 漫蛙详情页使用 &#x...; 返回书名；文本提取应与 Android/Jsoup 一样
      // 解码实体，避免 AI 把同一本书误判为详情书名不一致。
      const encodedDoc = parser.parse('<h2 id="page-title">&#x6551;&#x8D4E;&#x6211;&#xFF0C;&#x6740;&#x6B7B;&#x6211;</h2>');
      expect(parser.extractAttr(encodedDoc, '#page-title@text')).assertEqual('救赎我，杀死我');
    });

    it('supportsCssNotPseudoClassForListRule', 0, () => {
      // yqk.net（言情库）搜索结果页：div.left ul 里有书籍 li 和分页 li
      // class="jumppage"。模型生成 `div.left ul li:not(.jumppage)` 排除
      // 分页条。此前执行器未实现 :not()，括号里的 .jumppage 被误当作选择器
      // 自身的类名，语义反转：只有分页 li 匹配、书籍 li 全部被过滤，搜索
      // 验证误判"ruleSearchAuthor 没有提取到作者字段"导致 Agent 停止。
      const parser = getHtmlParser();
      const doc = parser.parse(
        '<div class="main"><div class="left"><ul>' +
        '<li><p class="img"><a href="/yanqing/a/"></a></p>' +
        '<p><strong><a href="/yanqing/a/">《书名一》</a></strong></p>' +
        '<p><a href="/zuozhe/1.html">作家一</a></p></li>' +
        '<li><p class="img"><a href="/yanqing/b/"></a></p>' +
        '<p><strong><a href="/yanqing/b/">《书名二》</a></strong></p>' +
        '<p><a href="/zuozhe/2.html">作家二</a></p></li>' +
        '<li class="jumppage"><span>当前页:<b>1</b>，总页数:<b>1</b>,共<b>2</b>本言情小说。</span>' +
        '<em id="pagestats">1/1</em><a href="/search.php?searchkey=x">下一页</a></li>' +
        '</ul></div></div>');
      // :not(.jumppage) 排除分页条，只剩书籍 li
      const books = parser.querySelectorAll(doc, 'div.left ul li:not(.jumppage)');
      expect(books.length).assertEqual(2);
      expect(parser.extractAttr(books[0], 'p strong a@text')).assertEqual('《书名一》');
      expect(parser.extractAttr(books[1], 'p strong a@text')).assertEqual('《书名二》');
      // 分页 li 上提取不到书名（无 p strong a 结构）
      const pager = parser.querySelectorAll(doc, 'div.left ul li.jumppage');
      expect(pager.length).assertEqual(1);
      expect(parser.extractAttr(pager[0], 'p strong a@text')).assertEqual('');
      // 不带 :not 的规则匹配全部 li（含分页），不回归
      expect(parser.querySelectorAll(doc, 'div.left ul li').length).assertEqual(3);
      // :not 与 :has 组合：书籍 li 有 /yanqing/ 链接，分页 li 只有 searchkey
      const withHas = parser.querySelectorAll(doc,
        'div.left ul li:has(p strong a[href^="/yanqing/"]):not(.jumppage)');
      expect(withHas.length).assertEqual(2);
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

    it('doesNotTreatDiscuzMangaPlayPageAsLogin', 0, () => {
      // antbyw 等 Discuz 系漫画站：每个页面 header 都预渲染标准快速登录框
      // （lsform/ls_password，action 含 login），但页面主体是漫画播放页。
      // 不能因为带密码框就误判为登录门禁，否则每次取目录都弹验证窗。
      const playPage = '<html><head><title>战斗吧！！闪耀英雄★漫画_天野リサ</title></head><body>' +
        '<div id="hd"><div class="hdc cl"><h2><a href="./">ant搬运网</a></h2></div>' +
        '<form method="post" id="lsform" action="member.php?mod=logging&amp;action=login">' +
        '<input type="password" name="password" id="ls_password" class="px vm">' +
        '<button type="submit"><em>登录</em></button></form></div>' +
        '<div class="pg_jameson_manhua" id="jameson_manhua">' +
        '<a href="./plugin.php?id=jameson_manhua&amp;a=read&amp;zjid=1595049&amp;kuid=198930" class="uk-button uk-button-danger">阅读</a>' +
        '</div><div class="uk-breadcrumb"><a href="./plugin.php?id=jameson_manhua&amp;c=index&amp;a=bofang&amp;kuid=146322">阅读426</a></div>' +
        '</body></html>';
      expect(WebViewFetcher.isLikelyBookDocumentHtml(playPage)).assertTrue();
      expect(isLoginDocument(playPage,
        'https://www.antbyw.com/plugin.php?id=jameson_manhua&c=index&a=bofang&kuid=198930')).assertFalse();
      expect(needsWebViewDocument(playPage,
        'https://www.antbyw.com/plugin.php?id=jameson_manhua&c=index&a=bofang&kuid=198930')).assertFalse();
      // URL 不含内容参数时仍要能识别页面主体：播放标记+章节导航兜底。
      expect(isLoginDocument(playPage, 'https://www.antbyw.com/')).assertFalse();
      // 真实登录页（无书籍内容）仍应判定为登录门禁。
      const realLogin = '<html><head><title>会员登录</title></head><body>' +
        '<form id="loginform" action="/member.php?mod=logging&amp;action=login">' +
        '<input type="password" name="password"></form></body></html>';
      expect(isLoginDocument(realLogin, 'https://www.example.com/member.php?mod=logging&action=login')).assertTrue();
    });

    it('doesNotTreatJmComicAlbumDetailAsLogin', 0, () => {
      // 禁漫天堂（jmcomic-zzz.one）专辑详情页：头部预渲染登录/验证码弹窗，
      // 但页面主体是 `id="intro-block"` 的书籍信息和 `class="btn-toolbar"` 的
      // 目录（/photo/<bookId>/?shunt=… 章节链接）。若被误判为登录门禁，
      // 每次取详情/目录都会被路由进 WebView，白等一轮 60s 超时。
      const album = '<html><head><title>难缠姐妹偏要和我同居-家教住我家-無碼版</title></head><body>' +
        '<div id="navbar"><form id="login-regist" action="/login"><input type="password"></form></div>' +
        '<div id="intro-block"><h1>难缠姐妹偏要和我同居</h1>' +
        '<div class="intro-collapse-content">简介：姐妹两人与家教同居的故事</div>' +
        '<div data-type="tags"><a>純愛</a></div></div>' +
        '<div class="btn-toolbar"><a href="/photo/1255565/?shunt=1">第1话</a>' +
        '<a href="/photo/1255565/?shunt=1">第2话</a></div>' +
        '</body></html>';
      expect(WebViewFetcher.isLikelyBookDocumentHtml(album)).assertTrue();
      expect(WebViewFetcher.isInteractiveChallengeHtml(album)).assertFalse();
      expect(isLoginDocument(album, 'https://jmcomic-zzz.one/album/1255565/难缠姐妹')).assertFalse();
      expect(needsWebViewDocument(album, 'https://jmcomic-zzz.one/album/1255565/难缠姐妹')).assertFalse();
    });

    it('allowsSamePathMirrorRedirect', 0, () => {
      // 禁漫天堂把 jmcomic-zzz.one 302 到 jm18c-dfg.cc，album 路径完全一致。
      // 这类站点自身 CDN/镜像跳转必须放行，否则 WebView 导航被拦截后收不到
      // onPageEnd，整轮 fetch 卡到总超时。
      expect(isSamePathMirrorUrl_(
        'https://jm18c-dfg.cc/album/1255565/%E9%9A%BE%E7%BC%A0%E5%A7%90%E5%A6%B9',
        'https://jmcomic-zzz.one/album/1255565/难缠姐妹')).assertTrue();
      // 目标带尾斜杠/分流参数，路径剥掉后仍一致。
      expect(isSamePathMirrorUrl_(
        'https://jm18c-dfg.cc/album/1255565/?shunt=1',
        'https://jmcomic-zzz.one/album/1255565/')).assertTrue();
      // 路径不同（广告/验证码跳转）不视为镜像。
      expect(isSamePathMirrorUrl_(
        'https://ads.example.com/promo?url=album/1255565',
        'https://jmcomic-zzz.one/album/1255565/难缠姐妹')).assertFalse();
      expect(isSamePathMirrorUrl_(
        'https://jm18c-dfg.cc/album/other/2',
        'https://jmcomic-zzz.one/album/1255565/难缠姐妹')).assertFalse();
    });

    it('seedsWebViewCookieForSearch', 0, () => {
      // 58小说网 搜索走 /api/search XHR：直接访问 /user/search.html 时 SID
      // cookie 的 Path=/user/，POST 不带 cookie 被服务器以“搜索太频繁”拒绝。
      // 同源预访问书源首页可种下 Path=/ 的会话 cookie（复现真实浏览器流程）。
      // 同域不同路径：返回源 URL 用于预访问。
      expect(seedWebViewCookieUrl_(
        'https://m.xbfdc.net', 'https://m.xbfdc.net/user/search.html?q=%E5%9B%9B%E5%90%88%E9%99%A2')).assertEqual(
        'https://m.xbfdc.net');
      // 路径剥掉 www/端口差异后同域，仍应预访问。
      expect(seedWebViewCookieUrl_(
        'https://www.m.xbfdc.net:443', 'https://m.xbfdc.net/user/search.html?q=x')).assertEqual(
        'https://www.m.xbfdc.net:443');
      // 跨域（书源主页与搜索页不同站）：预访问无意义，不返回。
      expect(seedWebViewCookieUrl_(
        'https://m.xbfdc.net', 'https://other.example.com/user/search.html?q=x')).assertEqual('');
      // 源 URL 与搜索页路径相同：首页即搜索页，无需预访问。
      expect(seedWebViewCookieUrl_(
        'https://m.xbfdc.net/user/search.html', 'https://m.xbfdc.net/user/search.html?q=x')).assertEqual('');
    });

    it('substitutesJavaGetStringInJsRules', 0, () => {
      // Android Legado 的 java.getString('rule') 在 QuickJS 沙箱中不存在，
      // 求值前必须替换为用当前文档提取的字面量，否则整段 @js: 规则抛
      // TypeError。生产路径先 normalizeCssRule（@[ 链式→后代）再提取；
      // 这里用 normalize 后的选择器验证替换语义（禁漫天堂详情 kind 规则）。
      const album = '<html><head><title>难缠姐妹偏要和我同居-家教住我家-無碼版</title></head><body>' +
        '<div id="intro-block"><h1>难缠姐妹偏要和我同居</h1>' +
        '<div data-type="tags"><a>純愛</a></div></div></body></html>';
      const parser = getHtmlParser();
      const doc = parser.parse(album);
      // 原始 Legado 链式规则（normalize 后为后代选择器）。
      const rawChain = '#intro-block@[data-type=tags]@a@text';
      const normalizedChain = '#intro-block [data-type="tags"] a@text';
      const substituted = substituteJavaGetStringCall_('java.getString(\'' + rawChain + '\')',
        (cssRule: string): string => parser.extractAttr(doc, normalizedChain));
      // 替换后是字面量（JSON 字符串），不再是函数调用；提取值落入其中。
      expect(substituted.indexOf('java.getString')).assertEqual(-1);
      expect(substituted).assertContain('純愛');
      // 含引号/中文的规则名也要能替换（JSON 转义一致）。
      const quoted = substituteJavaGetStringCall_(
        'var k = java.getString("div[data-type=tags]@text")',
        (cssRule: string): string => parser.extractAttr(doc, 'div[data-type="tags"] a@text'));
      expect(quoted.indexOf('java.getString')).assertEqual(-1);
      // 无 getString 调用的规则保持原样。
      const plain = 'baseUrl + "/album/1255565"';
      expect(substituteJavaGetStringCall_(plain,
        (cssRule: string): string => parser.extractAttr(doc, normalizedChain))).assertEqual(plain);
    });

    it('staticizesJavaGetElementInFieldRules', 0, () => {
      // 可乐小说等移动站卡片把跳转写在 onclick（URL 编码的 base64），书源用
      // <js> 块 + java.getElement 取详情 URL。QuickJS 没有 DOM，必须静态化为
      // ArkTS HtmlParser 提取的字面量，其余 JS 逻辑（base64 解码）才能执行。
      const html = '<html><body><div class="book-card">' +
        '<a href="/book/AII0G0A.html">在四合院当大哥</a>' +
        '<div class="book-card__title">四合院：在四合院当大哥</div>' +
        '</div></body></html>';
      const parser = getHtmlParser();
      const doc = parser.parse(html);
      const item = parser.querySelectorAll(doc, '.book-card')[0] as HtmlElement;
      // 双参数 java.getElement(result, 'sel')：在搜索结果元素内查询。
      const dual = substituteJavaGetElementCall_(
        'java.getElement(result, \'a\').getAttribute(\'href\')', parser, doc, item);
      expect(dual.indexOf('java.getElement')).assertEqual(-1);
      expect(dual).assertContain('/book/AII0G0A.html');
      // 单参数 java.getElement('sel')：按 Android 语义查询整个文档。
      const single = substituteJavaGetElementCall_(
        'java.getElement(\'div.book-card__title\').text()', parser, doc, item);
      expect(single).assertContain('四合院：在四合院当大哥');
      // attr 别名与 getAttr 同样支持。
      const alias = substituteJavaGetElementCall_(
        'java.getElement(result, \'a\').attr(\'href\')', parser, doc, item);
      expect(alias.indexOf('java.getElement')).assertEqual(-1);
      expect(alias).assertContain('/book/AII0G0A.html');
      // 元素不存在替换为 null（Android getElement 语义）。
      const missing = substituteJavaGetElementCall_(
        'java.getElement(result, \'a.missing\').attr(\'href\')', parser, doc, item);
      expect(missing).assertEqual('null');
      // 无 getElement 调用的代码保持原样。
      const plain = 'Base64.decode(result)';
      expect(substituteJavaGetElementCall_(plain, parser, doc, item)).assertEqual(plain);
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
      // GET 规则同样补全 charset：GBK 站点的 URL 关键字必须按 GBK 编码，
      // 否则站点按 gb2312 解码 UTF-8 乱码并返回空结果页（与 POST 同理）。
      const getRule = 'https://example.com/search?q={{key}}';
      expect(patchSearchRuleCharset_(getRule, pageHtml))
        .assertEqual('https://example.com/search?q={{key}},{"charset":"gbk"}');
    });

    it('encodesSearchKeyBySourceCharset', 0, () => {
      // yqk.net（言情库）按 gb2312 解释 URL 参数。此前 {{key}} 固定按 UTF-8
      // 百分号编码（%E7%A9%BF%E8%B6%8A），站点按 GBK 解码成乱码并返回空结果页，
      // Agent 关键词阶梯全部换词仍失败。修复后 URL 中的 {{key}} 按书源 charset
      // 编码（穿越 → %B4%A9%D4%BD），与 Android Legado AnalyzeUrl 语义一致。
      // 注意：单测环境 mock 的 @ohos.util 无编解码能力（TextDecoder 返回空、
      // TextEncoder 返回 0 字节），GBK 映射表构建失败时回退 UTF-8 编码，
      // 保证关键词不丢失；GBK 字节输出（%B4%A9%D4%BD）依赖真机系统编码器。
      // buildUrl（SourceExecutor 真实执行路径）
      const gbkGet = buildUrl('https://www.yqk.net/search.php?searchkey={{key}},{"charset":"gbk"}',
        '穿越', 1, 'https://www.yqk.net');
      // charset 声明被解析并透出。
      expect(gbkGet.charset).assertEqual('gbk');
      // {{key}} 被按 charset 编码替换（非空、无模板残留），且编码结果与
      // encodeUrlComponent 一致 —— 保证 buildUrl 真实走了 charset 编码路径。
      const encoded = NetUtil.encodeUrlComponent('穿越', 'gbk');
      expect(encoded.length > 0).assertTrue();
      expect(gbkGet.url).assertEqual('https://www.yqk.net/search.php?searchkey=' + encoded);
      // 无 charset 声明时保持 UTF-8，且纯 {{key}} URL 不能被误判截断（重构前
      // 无逗号 JSON 模式会把 {{key}} 的首 { 吞掉，URL 被截成 ?q={）。
      const utf8Get = buildUrl('https://example.com/search?q={{key}}', '穿越', 1, 'https://example.com');
      expect(utf8Get.url).assertEqual('https://example.com/search?q=%E7%A9%BF%E8%B6%8A');
      // POST body：buildUrl 返回的即最终提交体，按 charset 转 GBK；编码器
      // 不可用时保持原 UTF-8 百分号形式，参数不丢失。
      const gbkPost = buildUrl(
        'https://www.example.com/search.php,{"method":"POST","body":"searchkey={{key}}","charset":"gbk"}',
        '穿越', 1, 'https://www.example.com');
      expect(gbkPost.url).assertEqual('https://www.example.com/search.php');
      expect(gbkPost.method).assertEqual('POST');
      const postBody = gbkPost.body || '';
      expect(postBody.indexOf('searchkey=') === 0).assertTrue();
      expect(postBody.length > 'searchkey='.length).assertTrue();
      // 单引号 charset 与 {{keyword}} 变量同样生效。
      const singleQuote = buildUrl("https://www.yqk.net/search.php?searchkey={{keyword}},{'charset':'gb2312'}",
        '穿越', 1, 'https://www.yqk.net');
      expect(singleQuote.url).assertEqual('https://www.yqk.net/search.php?searchkey=' + encoded);
      // materializeAgentRequest（Agent 取证路径）：URL 按 charset 编码，POST
      // body 保持 UTF-8 百分号形式，由 fetchRulePage_ 提交前 encodeFormBody 转 GBK。
      const agent = materializeAgentRequest(
        'https://www.example.com/search.php,{"method":"POST","body":"searchkey={{key}}","charset":"gbk"}',
        '穿越', 1, 'https://www.example.com');
      expect(agent.url).assertEqual('https://www.example.com/search.php');
      expect(agent.method).assertEqual('POST');
      expect(agent.charset).assertEqual('gbk');
      expect(agent.body).assertEqual('searchkey=%E7%A9%BF%E8%B6%8A');
    });

    it('patchesModelGeneratedGbkSearchUrlEndToEnd', 0, () => {
      // 天籁小说网（picdg.com/wxc8.com）回归：模型直接生成 GET 搜索 URL
      // modules/article/search.php?searchkey={{key}}，未带 charset 选项。
      // 该站是 GBK 编码，关键词按 UTF-8 提交会被站点按 GBK 解码成乱码并返回
      // 空结果页（.result-list 为空），模型在空页上只能生成无效规则（如
      // .result-list .book / .result-list .item），验证轮次全部失败后 Agent
      // 终止。修复：生成搜索 URL 后按页面 charset 补全，取证请求再按 GBK 编码。
      const homepageHtml = '<html><head><meta http-equiv="Content-Type" ' +
        'content="text/html; charset=gbk"></head><body>' +
        '<div class="navitor"><a href="/">首页</a></div></body></html>';
      // 模型生成的 GET 规则（无 charset）→ 补全后带上 charset 选项。
      const modelRule = 'https://www.picdg.com/modules/article/search.php?searchkey={{key}}';
      const patched = patchSearchRuleCharset_(modelRule, homepageHtml);
      expect(patched).assertEqual(
        'https://www.picdg.com/modules/article/search.php?searchkey={{key}},{"charset":"gbk"}');
      // 取证路径按书源 charset 编码关键词（单测 mock 环境无 GBK 映射表时
      // 回退 UTF-8，真机上输出 %CB%C4%BA%CF%D4%BA；断言编码与
      // NetUtil.encodeUrlComponent 一致即可证明走了 charset 编码路径）。
      const spec = materializeAgentRequest(patched, '四合院', 1, 'https://www.picdg.com');
      expect(spec.charset).assertEqual('gbk');
      const encodedKey = NetUtil.encodeUrlComponent('四合院', 'gbk');
      expect(encodedKey.length > 0).assertTrue();
      expect(spec.url).assertEqual(
        'https://www.picdg.com/modules/article/search.php?searchkey=' + encodedKey);
      // 真实执行路径（SourceExecutor.buildUrl）同样按 charset 编码。
      const exec = buildUrl(patched, '四合院', 1, 'https://www.picdg.com');
      expect(exec.charset).assertEqual('gbk');
      expect(exec.url).assertEqual(
        'https://www.picdg.com/modules/article/search.php?searchkey=' + encodedKey);
    });

    it('extractsSearchFormFromWritelnFragmentsInExternalJs', 0, () => {
      // 天籁小说网（picdg.com/wxc8.com）第二种失败模式：首页 HTML 没有静态
      // <form>，搜索框由外部 header.js 用多条 document.writeln 分片拼接渲染。
      // 新建书源时此前只对 repairMode 走外部脚本提取，模型看不到表单就猜了
      // /search.php?keyword= 这个 404 路径。修复：从 JS 源码按出现顺序拼接
      // writeln 片段（反转义 \" 等）还原出完整表单，得到真实 POST 接口
      // modules/article/search.php + searchkey 字段。
      const headerJs = 'function login(){document.write(\'<form name="mylogin" action="/login.php">' +
        '<input name="username" type="text"></form>\');}\n' +
        'function panel(){\n' +
        '    document.writeln("<div class=\\"search\\"><form action=\'/modules/article/search.php\' method=\'post\'>");\n' +
        '    document.writeln("<input type=\\"hidden\\" name=\\"action\\" value=\\"login\\">");\n' +
        '    document.writeln("<input type=\\"hidden\\" name=\\"ie\\" value=\\"gbk\\">");\n' +
        '    document.writeln("<input name=\\"searchkey\\" id=\\"keyword\\" type=\\"text\\" value=\\"输入需要搜索的小说\\"/>");\n' +
        '    document.writeln("</form></div>");\n' +
        '}\n';
      const request = extractSearchFormFromJsSource_(
        headerJs, 'https://www.picdg.com', '四合院', '');
      expect(request !== null).assertTrue();
      expect(request!.method).assertEqual('POST');
      // 拼接还原后 action 指向真实搜索接口，而不是 /search.php?keyword= 这种 404。
      expect(request!.ruleSearchUrl).assertContain('/modules/article/search.php');
      expect(request!.ruleSearchUrl.indexOf('/search.php?keyword=')).assertEqual(-1);
      expect(request!.ruleSearchUrl).assertContain('searchkey={{key}}');
      // 拼接还原后的表单能正常物化成可请求的规则（含 hidden 固定参数）。
      const spec = materializeAgentRequest(
        request!.ruleSearchUrl, '四合院', 1, 'https://www.picdg.com');
      expect(spec.method).assertEqual('POST');
      expect(spec.url).assertEqual('https://www.picdg.com/modules/article/search.php');
      expect(spec.body.indexOf('searchkey=')).assertEqual(0);
      expect(spec.body).assertContain('action=login');
      expect(spec.body).assertContain('ie=gbk');
      // 登录表单（无搜索字段）分数低；与搜索表单同源时 inferSearchRequest
      // 必须选择分数更高的搜索表单（上面已断言）。这里仅验证不抛异常。
      extractSearchFormFromJsSource_(
        'document.write(\'<form name="mylogin" action="/login.php"><input name="username"></form>\');',
        'https://www.picdg.com', '四合院', '');
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
      expect(WebViewFetcher.isLikelyImageCaptchaPage(captchaPage)).assertTrue();
      expect(WebViewFetcher.isLikelyImageCaptchaPage(
        '<li class="dba_bookcase"><a href="/mybook.html">书架</a></li>' + captchaPage)).assertTrue();
      expect(WebViewFetcher.isLikelyImageCaptchaPage(
        '<table class="table"><tr><td><a href="/book/1">四合院</a></td></tr></table>' +
        '<input id="__17mb_input" title="请输入验证码">')).assertFalse();
      expect(supportedAiRuleContract('search')).assertContain('java.getVerificationCode');
    });

    it('rejectsNavigationPagesAndTextRulesFromAiSourceSamples', 0, () => {
      expect(isLikelyAiBookDetailUrl(
        'https://www.pinshuzhai.com/bookcat/shuxiangwenku')).assertFalse();
      expect(isLikelyAiBookDetailUrl(
        'http://www.xs3000.com/index/cate/id/3.html')).assertFalse();
      expect(isLikelyAiBookDetailUrl(
        'http://www.xs3000.com/index/top/sort/click')).assertFalse();
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
      expect(isAiBookNameConsistent('&#x9A6C;&#x53EF;&#x74E6;&#x5C14;&#x591A;', '马可瓦尔多')).assertTrue();
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
      expect(buildAiVisibleNameRuleCandidates_('dt a[title]@title')
        .includes('dt > a[title]@text')).assertTrue();
      const pollutedResults: SearchResult[] = [
        { name: '抖音小说-笔趣阁 都市 七零农村大旱，我家挖出地下暗河', noteUrl: '/book/1' } as SearchResult,
        { name: '抖音小说-笔趣阁 都市 四合院从签到开始崛起', noteUrl: '/book/2' } as SearchResult,
      ];
      expect(inferAiSearchNameCleanupRule_('dt a[title]@title', pollutedResults, '🎉 抖音小说'))
        .assertEqual('dt a[title]@title##^抖音小说-笔趣阁\\s*##');
      expect(inferAiSearchNameCleanupRule_('dt a[title]@title', [
        { name: '抖音小说家', noteUrl: '/book/1' } as SearchResult,
      ], '🎉 抖音小说')).assertEqual('');
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
