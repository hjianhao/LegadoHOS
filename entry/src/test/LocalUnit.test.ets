import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { parseBookSource, serializeBookSource } from '../main/ets/model/BookSource';
import { LkongService, LkongThreadItem } from '../main/ets/service/LkongService';
import { LkongBookAgent } from '../main/ets/engine/ai/LkongBookAgent';
import { YoushuBookService } from '../main/ets/service/YoushuBookService';
import { YoushuBooklistService } from '../main/ets/service/YoushuBooklistService';
import { AiProviderProfile, detectAiProvider, normalizeAiTimeoutSeconds, upsertAiProfile } from '../main/ets/data/preferences/SettingsStore';
import { HtmlParser } from '../main/ets/util/HtmlParser';
import { extractAiBookMetadata, isSafeAiImportUrl, parseAiRulesJson,
  prepareHtmlForAi, normalizeAiChapters, extractAiFullTocUrl,
  inferAiContentRule, isLikelySameAiBookPage,
  isUsableAiExtractedContent } from '../main/ets/engine/ai/AiBookImporter';
import { isInvalidAiContentResult, isLikelySameChapterPageUrl,
  sniffNextContentPageUrl } from '../main/ets/engine/source/SourceExecutor';
import { OpdsParser } from '../main/ets/service/cloud/OpdsParser';
import { mapGutenbergFeedToGutendex } from '../main/ets/service/cloud/OpdsCloudProvider';
import { WebDavHttp } from '../main/ets/service/cloud/WebDavHttp';
import { buildBaiduSearchRequestUrl } from '../main/ets/service/cloud/BaiduNetdiskProvider';
import {
  createDefaultOpdsCloudConfig,
  PROJECT_GUTENBERG_OPDS_ENDPOINT,
} from '../main/ets/model/CloudSource';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });
    it('opds1ParsesNavigationAcquisitionAndNextPage', 0, () => {
      const xml = '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">' +
        '<title>测试书库</title><link rel="next" href="/opds/?page=2" title="Next Page"/>' +
        '<link rel="search" type="application/opensearchdescription+xml" href="/opds/search.xml"/>' +
        '<entry><id>book-1</id><title>测试书</title><author><name>作者甲</name></author>' +
        '<updated>2026-07-24T00:00:00Z</updated>' +
        '<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" ' +
        'title="EPUB" length="1234" href="/files/book.epub"/></entry>' +
        '<entry><title>分类</title><link rel="subsection" ' +
        'type="application/atom+xml;profile=opds-catalog" href="categories/1"/></entry></feed>';
      const page = OpdsParser.parse(xml, 'https://example.com/opds/index.xml');
      expect(page.title).assertEqual('测试书库');
      expect(page.acquisitions.length).assertEqual(1);
      expect(page.acquisitions[0].author).assertEqual('作者甲');
      expect(page.acquisitions[0].url).assertEqual('https://example.com/files/book.epub');
      expect(OpdsParser.fileName(page.acquisitions[0])).assertEqual('测试书 · EPUB.epub');
      expect(page.navigation.length).assertEqual(2);
      expect(page.navigation[0].url).assertEqual('https://example.com/opds/categories/1');
      expect(page.navigation[1].isNextPage).assertTrue();
      expect(page.searchUrl).assertEqual('https://example.com/opds/search.xml');
      expect(page.searchType).assertEqual('application/opensearchdescription+xml');
    });
    it('opdsOpenSearchParsesAtomTemplate', 0, () => {
      const xml = '<?xml version="1.0"?><OpenSearchDescription ' +
        'xmlns="http://a9.com/-/spec/opensearch/1.1/">' +
        '<Url type="text/html" template="/search?q={searchTerms}"/>' +
        '<Url type="application/atom+xml" template="/opds/search?query={searchTerms}&amp;page={startPage?}"/>' +
        '</OpenSearchDescription>';
      const template = OpdsParser.parseOpenSearchTemplate(
        xml,
        'https://example.com/opds/description.xml'
      );
      expect(template)
        .assertEqual('https://example.com/opds/search?query={searchTerms}&page={startPage?}');
    });
    it('opds2ParsesPublicationAndRelativeUrl', 0, () => {
      // ArkTS 严格模式禁止 JSON.stringify 传无类型对象字面量，直接写 JSON 字符串
      const json = '{"metadata":{"title":"OPDS 2"},' +
        '"publications":[{"metadata":{"title":"JSON 书","author":[{"name":"作者乙"}],' +
        '"identifier":"urn:book:2"},"links":[{"rel":"http://opds-spec.org/acquisition",' +
        '"type":"application/pdf","href":"../download/book.pdf","length":2048}]}],' +
        '"links":[{"rel":"next","href":"?page=2"}]}';
      const page = OpdsParser.parse(json, 'https://example.com/opds/v2/catalog.json');
      expect(page.acquisitions.length).assertEqual(1);
      expect(page.acquisitions[0].author).assertEqual('作者乙');
      expect(page.acquisitions[0].url).assertEqual('https://example.com/opds/download/book.pdf');
      expect(page.navigation[0].url).assertEqual('https://example.com/opds/v2/catalog.json?page=2');
    });
    it('opdsDefaultUserAgentIdentifiesHarmonyClientContact', 0, () => {
      const userAgent = createDefaultOpdsCloudConfig().userAgent;
      expect(userAgent).assertContain('LegadoHOS/');
      expect(userAgent).assertContain('github.com/hjianhao/LegadoHOS/issues');
      expect(userAgent.indexOf('github.com/gedoor/legado')).assertEqual(-1);
      expect(PROJECT_GUTENBERG_OPDS_ENDPOINT).assertEqual('https://www.gutenberg.org/ebooks.opds/');
    });
    it('gutendexFallbackMapsMetadataAndOfficialMirrorDownload', 0, () => {
      const json = '{"count":1,"next":"https://gutendex.com/books/?page=2","previous":null,' +
        '"results":[{"id":2701,"title":"Moby Dick",' +
        '"authors":[{"name":"Melville, Herman"}],' +
        '"formats":{"application/epub+zip":"https://www.gutenberg.org/ebooks/2701.epub3.images"}}]}';
      const page = OpdsParser.parse(json, 'https://gutendex.com/books/');
      expect(page.acquisitions.length).assertEqual(1);
      expect(page.acquisitions[0].author).assertEqual('Melville, Herman');
      expect(page.acquisitions[0].url)
        .assertEqual('https://gutenberg.pglaf.org/cache/epub/2701/pg2701-images.epub');
      expect(page.navigation[0].isNextPage).assertTrue();
    });
    it('gutenbergCategoryFeedMapsToGutendex', 0, () => {
      expect(mapGutenbergFeedToGutendex(
        'https://www.gutenberg.org/ebooks/search.opds?sort_order=downloads'
      )).assertEqual('https://gutendex.com/books/?sort=popular');
      expect(mapGutenbergFeedToGutendex(
        'https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date'
      )).assertEqual('https://gutendex.com/books/?sort=descending');
      expect(mapGutenbergFeedToGutendex(
        'https://www.gutenberg.org/ebooks/search.opds?query=Moby+Dick'
      )).assertEqual('https://gutendex.com/books/?search=Moby%20Dick');
      expect(mapGutenbergFeedToGutendex('https://example.com/search.opds')).assertEqual('');
    });
    it('baiduNetdiskSearchUsesRecursiveCurrentDirectory', 0, () => {
      const url = buildBaiduSearchRequestUrl(
        'test token',
        '/apps/阅读/科幻',
        '三体 完整版',
        2,
        1000
      );
      expect(url).assertContain('method=search');
      expect(url).assertContain('access_token=test%20token');
      expect(url).assertContain('dir=%2Fapps%2F%E9%98%85%E8%AF%BB%2F%E7%A7%91%E5%B9%BB');
      expect(url).assertContain('key=%E4%B8%89%E4%BD%93%20%E5%AE%8C%E6%95%B4%E7%89%88');
      expect(url).assertContain('recursion=1');
      expect(url).assertContain('page=2');
      expect(url).assertContain('num=1000');
    });
    it('webDavBasicSearchEscapesScopeAndLikeWildcards', 0, () => {
      const body = WebDavHttp.basicSearchBody(
        'https://dav.example.com/books/?owner=a&kind=epub',
        '三体_100%'
      );
      expect(body).assertContain('<D:basicsearch>');
      expect(body).assertContain('<D:depth>infinity</D:depth>');
      expect(body).assertContain('https://dav.example.com/books/?owner=a&amp;kind=epub');
      expect(body).assertContain('<D:literal>%三体\\_100\\%%</D:literal>');
      expect(body).assertContain('caseless="yes"');
    });
    it('webDavSearchMultiStatusParsesNestedBook', 0, () => {
      const xml = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">' +
        '<D:response><D:href>/dav/books/%E7%A7%91%E5%B9%BB/%E4%B8%89%E4%BD%93.epub</D:href>' +
        '<D:propstat><D:prop><D:resourcetype/><D:getcontentlength>2048</D:getcontentlength>' +
        '<D:getlastmodified>Fri, 24 Jul 2026 10:00:00 GMT</D:getlastmodified>' +
        '<D:getetag>"book-etag"</D:getetag><D:getcontenttype>application/epub+zip</D:getcontenttype>' +
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>';
      const entries = WebDavHttp.parsePropfindResponse(xml, {
        requestUrl: 'https://dav.example.com/dav/books/',
        includeDirectories: true,
      });
      expect(entries.length).assertEqual(1);
      expect(entries[0].name).assertEqual('三体.epub');
      expect(entries[0].contentLength).assertEqual(2048);
      expect(entries[0].etag).assertEqual('book-etag');
      expect(WebDavHttp.hrefToRemotePath(
        entries[0].href,
        'https://dav.example.com/dav',
        'books'
      )).assertEqual('科幻/三体.epub');
    });
    it('htmlTextKeepsInlineChildOrder', 0, () => {
      const parser = new HtmlParser();
      const doc = parser.parse('<div class="title"><mark>四合院</mark>：从晋升工程师开始</div>');
      // querySelector 只返回元素；@text 提取应走 extractAttr（与 Legado @text 语义一致）
      const title = parser.extractAttr(doc, '.title@text');
      expect(title).assertEqual('四合院：从晋升工程师开始');
    });
    it('bookSourceStandardFieldsRoundTrip', 0, () => {
      const source = parseBookSource({
        bookSourceName: '测试源', bookSourceUrl: 'https://example.com', bookSourceGroup: '小说,测试',
        enabledExplore: false, customExtension: 'keep-me',
        ruleSearch: { bookList: '.book', name: '.name', wordCount: '.words' },
        ruleContent: { content: '#content', subContent: '.extra' }
      });
      source.rawJson = JSON.stringify({ customExtension: 'keep-me' });
      const exported = JSON.parse(serializeBookSource(source)) as Record<string, Object>;
      expect(source.group).assertEqual('小说,测试');
      expect(source.ruleSearchWordCount).assertEqual('.words');
      expect(source.ruleBookContentSubContent).assertEqual('.extra');
      expect(String(exported['bookSourceGroup'])).assertEqual('小说,测试');
      expect(String(exported['customExtension'])).assertEqual('keep-me');
      expect(Boolean(exported['enabledExplore'])).assertFalse();
      source.isAiGenerated = true;
      const aiExported = JSON.parse(serializeBookSource(source)) as Record<string, Object>;
      expect(Boolean(aiExported['isAiGenerated'])).assertTrue();
    });
    it('lkongTimestampAndRecentFilter', 0, () => {
      const now = Date.now();
      const recent = now - 2 * 24 * 60 * 60 * 1000;
      const old = now - 10 * 24 * 60 * 60 * 1000;
      const rows: LkongThreadItem[] = [
        { tid: 1, title: '近期', author: '', authorId: 0, dateline: recent.toString(), timestamp: recent,
          replies: 0, views: 0, digest: false, url: '' },
        { tid: 2, title: '较早', author: '', authorId: 0, dateline: old.toString(), timestamp: old,
          replies: 0, views: 0, digest: false, url: '' },
      ];
      expect(LkongService.filterSince(rows, now - 7 * 24 * 60 * 60 * 1000).length).assertEqual(1);
      expect(LkongService.parseTimestamp('1710000000')).assertEqual(1710000000000);
    });
    it('lkongKeepsCompleteMainPostBeforeReplies', 0, () => {
      let main = '';
      for (let i = 1; i <= 15; i++) main += '<p>' + i + '. 书名' + i + '：推荐理由</p>';
      main += '<p>' + '长文'.repeat(13000) + '</p>';
      const content = LkongService.formatPostsForAnalysis([
        { lou: 0, content: main, user: { name: '楼主' } },
        { lou: 1, content: '<p>跟帖书</p>', user: { name: '读者' } },
      ]);
      expect(content.indexOf('【主帖，优先完整分析】')).assertEqual(0);
      expect(content).assertContain('15. 书名15');
      expect(content.indexOf('跟帖书') > content.indexOf('15. 书名15')).assertTrue();
      expect(content.length > 20000).assertTrue();
    });
    it('lkongAgentParsesAndDeduplicatesBooks', 0, () => {
      const response = '{"choices":[{"message":{"content":"' +
        '```json\\n[{\\"name\\":\\"测试书\\",\\"author\\":\\"甲\\",\\"reason\\":\\"节奏好\\"},' +
        '{\\"name\\":\\"测试书\\",\\"author\\":\\"甲\\",\\"reason\\":\\"重复\\"}]```"}}]}';
      const books = new LkongBookAgent().parseResponse(response);
      expect(books.length).assertEqual(1);
      expect(books[0].name).assertEqual('测试书');
      expect(books[0].author).assertEqual('甲');
    });
    it('lkongAgentParsesWrappedAndSegmentedContent', 0, () => {
      const response = '{"choices":[{"finish_reason":"stop","message":{"content":[' +
        '{"type":"text","text":"{\\"books\\":["},' +
        '{"type":"text","text":"{\\"name\\":\\"分段书\\",\\"author\\":\\"\\",\\"reason\\":\\"设定有趣\\"}]}"}' +
        ']}}],"model":"free-model"}';
      const books = new LkongBookAgent().parseResponse(response);
      expect(books.length).assertEqual(1);
      expect(books[0].name).assertEqual('分段书');
      expect(books[0].reason).assertEqual('设定有趣');
    });
    it('youshuLibraryParsesFilterBookAndPagination', 0, () => {
      const html = '<table class="grid"><tr><td>类型：</td><td><a class="hot" href="/books?type=all">全部</a>' +
        '<a href="/books?type=xuanhuan">玄幻</a></td></tr><tr><td colspan="2">筛选条件</td></tr></table>' +
        '<table id="jieqi_page_contents"><tr><td><a class="pop" href="/book/123">测试书</a></td>' +
        '<td><span class="c_rr">8.8</span><span class="stard">(20人)</span></td><td>作者甲</td>' +
        '<td>1000</td><td>2026-07-18</td><td>连载</td></tr></table>' +
        '<div id="pagelink"><a class="next" href="/books?page=2">下一页</a></div><div id="pagestats">1/2</div>';
      const page = YoushuBookService.parsePage(html);
      expect(page.books.length).assertEqual(1);
      expect(page.books[0].name).assertEqual('测试书');
      expect(page.books[0].author).assertEqual('作者甲');
      expect(page.nextPageUrl).assertContain('page=2');
    });
    it('youshuBooklistDetailKeepsAuthorForSearch', 0, () => {
      const html = '<div id="contenti"><h1><span>测试书单</span></h1></div><div id="doulist-info"></div>' +
        '<div class="doulist-item"><span class="pos">1</span><div class="title"><a href="/book/9">书名九</a></div>' +
        '<div class="abstract">作者：作者乙 分类：科幻 字数：20万 更新：2026</div>' +
        '<span class="rating_nums">9.0</span><span class="rating">(10人)</span></div>';
      // parseDetail 是网页端书单详情的公开解析入口。
      const bookDetail = YoushuBooklistService.parseDetail(html, 'https://www.youshu.me/booklist/1');
      expect(bookDetail.books.length).assertEqual(1);
      expect(bookDetail.books[0].author).assertEqual('作者乙');
    });
    it('aiProfilesDetectProviderAndUpsert', 0, () => {
      expect(detectAiProvider('https://openrouter.ai/api/v1/chat/completions')).assertEqual('openrouter');
      expect(detectAiProvider('http://192.168.1.2:11434/v1/chat/completions')).assertEqual('ollama');
      const first: AiProviderProfile = {
        id: 'one', name: '配置一', provider: 'openai', endpoint: 'https://example.com', apiKey: 'key', model: 'm1', timeoutSeconds: 120
      };
      const updated: AiProviderProfile = {
        id: 'one', name: '配置一', provider: 'openai', endpoint: 'https://example.com', apiKey: 'key', model: 'm2', timeoutSeconds: 300
      };
      const added: AiProviderProfile = {
        id: 'two', name: '配置二', provider: 'openrouter', endpoint: 'https://example.com', apiKey: 'key', model: 'm3', timeoutSeconds: 600
      };
      const afterUpdate = upsertAiProfile([first], updated);
      expect(afterUpdate.length).assertEqual(1);
      expect(afterUpdate[0].model).assertEqual('m2');
      expect(afterUpdate[0].timeoutSeconds).assertEqual(300);
      expect(upsertAiProfile(afterUpdate, added).length).assertEqual(2);
      expect(normalizeAiTimeoutSeconds(undefined)).assertEqual(120);
    });
    it('aiImportKeepsDomAndRemovesExecutableMarkup', 0, () => {
      const html = '<html><style>.x{color:red}</style><body><ul class="chapters"><li><a href="/1">第一章</a></li></ul>' +
        '<script>ignorePrompt()</script></body></html>';
      const prepared = prepareHtmlForAi(html, 40000);
      expect(prepared).assertContain('<ul class="chapters">');
      expect(prepared).assertContain('href="/1"');
      expect(prepared.includes('<script>')).assertFalse();
      expect(prepared.includes('<style>')).assertFalse();
    });
    it('aiImportParsesJsonFromExplanatoryResponse', 0, () => {
      const rules = parseAiRulesJson('分析结果如下：\n{"ruleToc":".list a","ruleTocTitle":"@text","ruleTocUrlItem":"@href"}\n请验证');
      expect(rules['ruleToc']).assertEqual('.list a');
      const fenced = parseAiRulesJson('```json\n{"ruleBookContent":"#content@html"}\n```');
      expect(fenced['ruleBookContent']).assertEqual('#content@html');
    });
    it('aiImportRejectsLocalAndNonHttpUrls', 0, () => {
      expect(isSafeAiImportUrl('https://example.com/book/1')).assertTrue();
      expect(isSafeAiImportUrl('http://127.0.0.1/book')).assertFalse();
      expect(isSafeAiImportUrl('http://192.168.1.2/book')).assertFalse();
      expect(isSafeAiImportUrl('https://user:pass@example.com/book')).assertFalse();
      expect(isSafeAiImportUrl('file:///data/book.html')).assertFalse();
    });
    it('aiImportExtractsBookMetadataWithoutCreatingRules', 0, () => {
      const html = '<html><head>' +
        '<meta property="og:novel:book_name" content="测试小说">' +
        '<meta property="og:novel:author" content="测试作者">' +
        '<meta property="og:image" content="http://example.com/cover.jpg">' +
        '<meta property="og:description" content="这是书籍简介">' +
        '<meta property="og:novel:category" content="都市">' +
        '<meta property="og:novel:update_time" content="2026-07-19 08:00:00">' +
        '</head><body><p>字&nbsp;&nbsp;数：<span>553 万</span></p></body></html>';
      const metadata = extractAiBookMetadata(html, 'https://example.com/book/1/');
      expect(metadata.name).assertEqual('测试小说');
      expect(metadata.author).assertEqual('测试作者');
      expect(metadata.coverUrl).assertEqual('https://example.com/cover.jpg');
      expect(metadata.introduce).assertEqual('这是书籍简介');
      expect(metadata.wordCount).assertEqual('553万');
      expect(metadata.kind).assertEqual('都市');
      expect(metadata.lastUpdateTime).assertEqual('2026-07-19 08:00:00');
    });
    it('aiImportNormalizesLatestBlockDuplicatesAndReverseToc', 0, () => {
      const latestFirst = normalizeAiChapters([
        { index: 0, title: '第103章', url: 'https://a/103' },
        { index: 1, title: '第102章', url: 'https://a/102' },
        { index: 2, title: '第1章', url: 'https://a/1' },
        { index: 3, title: '第2章', url: 'https://a/2' },
        { index: 4, title: '第3章', url: 'https://a/3' },
        { index: 5, title: '第102章', url: 'https://a/102#catalog' },
        { index: 6, title: '第103章', url: 'https://a/103' },
      ]);
      expect(latestFirst.length).assertEqual(5);
      expect(latestFirst[0].title).assertEqual('第1章');
      expect(latestFirst[4].title).assertEqual('第103章');

      const reversed = normalizeAiChapters([
        { index: 0, title: '第5章', url: 'https://a/5' },
        { index: 1, title: '第4章', url: 'https://a/4' },
        { index: 2, title: '第3章', url: 'https://a/3' },
        { index: 3, title: '第2章', url: 'https://a/2' },
        { index: 4, title: '第1章', url: 'https://a/1' },
      ]);
      expect(reversed[0].title).assertEqual('第1章');
      expect(reversed[4].title).assertEqual('第5章');
    });
    it('aiImportFindsFullTocEntryBeforeCatalogPagination', 0, () => {
      const detailHtml = '<section class="latest"><ul><li><a href="/6_6706/415.html">最新章</a></li></ul>' +
        '<div class="more"><a href="//s.bageccc.cc/6_6706_1/"><span>查看全部章节</span></a></div></section>';
      expect(extractAiFullTocUrl(detailHtml, 'https://s.bageccc.cc/6_6706/'))
        .assertEqual('https://s.bageccc.cc/6_6706_1/');

      const catalogHtml = '<section id="zjlb"><a href="/6_6706/1.html">第一章</a>' +
        '<div class="pagelink"><a href="//s.bageccc.cc/6_6706_2/">下一页</a></div></section>';
      expect(extractAiFullTocUrl(catalogHtml, 'https://s.bageccc.cc/6_6706_1/')).assertEqual('');
    });
    it('aiImportDetectsRandomBookPageWithoutHttpRedirect', 0, () => {
      const detailHtml = '<meta property="og:novel:book_name" content="四合院：从签到开始崛起最新章节目录全文阅读">' +
        '<ul class="chapter"><li><a href="//m.qntxts.com/473_473149/1/">查看更多章节</a></li></ul>';
      expect(extractAiFullTocUrl(detailHtml, 'https://m.qntxts.com/473_473149/'))
        .assertEqual('https://m.qntxts.com/473_473149/1/');

      const randomBookHtml = '<meta property="og:novel:book_name" content="蒸汽时代的驱魔猫番外">' +
        '<a href="//m.qntxts.com/752_752937/64445740.html">第31章</a>';
      expect(isLikelySameAiBookPage(detailHtml, randomBookHtml,
        'https://m.qntxts.com/473_473149/', 'https://m.qntxts.com/473_473149/1/')).assertFalse();

      const desktopHtml = '<meta property="og:novel:book_name" content="四合院：从签到开始崛起">' +
        '<a href="//www.qntxts.com/473_473149/100.html">第1章</a>' +
        '<a href="//www.qntxts.com/473_473149/101.html">第2章</a>';
      expect(isLikelySameAiBookPage(detailHtml, desktopHtml,
        'https://m.qntxts.com/473_473149/', 'https://www.qntxts.com/473_473149/')).assertTrue();
    });
    it('aiImportSniffsContentPaginationWithoutCrossingChapter', 0, () => {
      const html = '<div id="content">第一页正文</div><div class="pager">' +
        '<a href="/book/8/20.html">下一章</a><a class="next-page" href="/book/8/19_2.html">下一页</a></div>';
      const nextPage = sniffNextContentPageUrl(html, 'https://example.com/book/8/19.html');
      expect(nextPage).assertEqual('https://example.com/book/8/19_2.html');
      expect(isLikelySameChapterPageUrl('https://example.com/book/8/19.html', nextPage)).assertTrue();
      expect(isLikelySameChapterPageUrl('https://example.com/book/8/19.html',
        'https://example.com/book/8/20.html')).assertFalse();
    });
    it('aiImportSniffsQueryAndNestedMarkupPagination', 0, () => {
      const html = '<nav><a aria-label="下一页" href="read?id=19&amp;page=2"><span>›</span></a></nav>';
      const nextPage = sniffNextContentPageUrl(html, 'https://example.com/book/read?id=19&page=1');
      expect(nextPage).assertEqual('https://example.com/book/read?id=19&page=2');
      expect(isLikelySameChapterPageUrl('https://example.com/book/read?id=19&page=1', nextPage)).assertTrue();
    });
    it('aiImportRejectsAdjacentNumericChaptersAndTranscodePlaceholder', 0, () => {
      const chapter = 'https://m.3kxs.net/read/7613/79/4.html';
      expect(isLikelySameChapterPageUrl(chapter, 'https://m.3kxs.net/read/7613/79/3.html')).assertFalse();
      expect(isLikelySameChapterPageUrl(chapter, 'https://m.3kxs.net/read/7613/79/5.html')).assertFalse();
      expect(isInvalidAiContentResult('转码失败！请换以下其他源继续阅读！')).assertTrue();
      expect(isInvalidAiContentResult('这是正常的小说正文内容。')).assertFalse();
      expect(inferAiContentRule('<main><div class="content">真实正文</div></main>')).assertEqual('.content@html');
      expect(inferAiContentRule('<div class="txtnav"><p>第一段正文</p><p>第二段正文</p></div>'))
        .assertEqual('.txtnav p@textNodes');
      expect(inferAiContentRule('<div class="content">转码失败！请换以下其他源继续阅读！</div>')).assertEqual('');
      expect(isUsableAiExtractedContent('这是正常小说正文内容，用足够长度模拟章节段落。' +
        '人物继续交谈并推动情节发展，窗外的雨声逐渐变大。故事仍然在继续，没有混入网页导航。')).assertTrue();
      expect(isUsableAiExtractedContent('首页 排行榜 小说分类 我的书架 阅读记录 意见反馈 设置 黑夜 换源 正文'))
        .assertFalse();
    });
  });
}
