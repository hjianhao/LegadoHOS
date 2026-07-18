import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { parseBookSource, serializeBookSource } from '../main/ets/model/BookSource';
import { LkongService } from '../main/ets/service/LkongService';
import { LkongBookAgent } from '../main/ets/engine/ai/LkongBookAgent';
import { YoushuBookService } from '../main/ets/service/YoushuBookService';
import { YoushuBooklistService } from '../main/ets/service/YoushuBooklistService';
import { AiProviderProfile, detectAiProvider, normalizeAiTimeoutSeconds, upsertAiProfile } from '../main/ets/data/preferences/SettingsStore';

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
    });
    it('lkongTimestampAndRecentFilter', 0, () => {
      const now = Date.now();
      const recent = now - 2 * 24 * 60 * 60 * 1000;
      const old = now - 10 * 24 * 60 * 60 * 1000;
      const rows = [
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
      const response = JSON.stringify({ choices: [{ message: { content:
        '```json\n[{"name":"测试书","author":"甲","reason":"节奏好"},{"name":"测试书","author":"甲","reason":"重复"}]\n```' } }] });
      const books = new LkongBookAgent().parseResponse(response);
      expect(books.length).assertEqual(1);
      expect(books[0].name).assertEqual('测试书');
      expect(books[0].author).assertEqual('甲');
    });
    it('lkongAgentParsesWrappedAndSegmentedContent', 0, () => {
      const response = JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content: [
        { type: 'text', text: '{"books":[' },
        { type: 'text', text: '{"name":"分段书","author":"","reason":"设定有趣"}]}' },
      ] } }], model: 'free-model' });
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
  });
}
