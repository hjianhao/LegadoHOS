/** 龙的天空“推书试读”板块 GraphQL 访问服务。 */
import { NetUtil } from '../util/NetUtil';
import { HtmlUtil } from '../util/HtmlUtil';

export const LKONG_BASE_URL = 'https://www.lkong.com';
export const LKONG_LOGIN_URL = LKONG_BASE_URL + '/member/login';
export const LKONG_FORUM_URL = LKONG_BASE_URL + '/forum/60';
export const LKONG_API_URL = 'https://api.lkong.com/api';
export const LKONG_FORUM_ID = 60;

export type LkongForumFilter = 'all' | 'digest' | 'new';

export interface LkongThreadItem {
  tid: number;
  title: string;
  author: string;
  authorId: number;
  dateline: string;
  timestamp: number;
  replies: number;
  views: number;
  digest: boolean;
  url: string;
}

export interface LkongThreadPage {
  threads: LkongThreadItem[];
  page: number;
  hasMore: boolean;
  loginRequired: boolean;
}

export interface LkongThreadContent {
  thread: LkongThreadItem;
  content: string;
}

/** 龙空板块公开展示的可浏览标签，url 与网页端 /tag/{id} 保持一致。 */
export interface LkongTagItem {
  id: number;
  name: string;
  url: string;
}

interface LkongGraphqlEnvelope {
  data?: Record<string, Object>;
  errors?: Array<Record<string, Object>>;
}

export class LkongService {
  static async loadThreads(filter: LkongForumFilter, page: number = 1): Promise<LkongThreadPage> {
    const query = `query ViewForumPage($fid:Int!,$page:Int,$action:String){
      threads(fid:$fid,page:$page,action:$action){
        tid title dateline lastpost digest replies views
        author{name uid}
      }
    }`;
    const data = await this.graphql(query, {
      'fid': LKONG_FORUM_ID,
      'page': page,
      'action': this.actionOf(filter),
    });
    const rows = data['threads'] as Array<Record<string, Object>> | undefined;
    const threads = this.parseThreads(rows || []);
    return {
      threads: threads,
      page: page,
      hasMore: threads.length >= 75,
      loginRequired: false,
    };
  }

  /** 网页端“今日热门”：threadsFragment(fid, type: "hot")。 */
  static async loadHotThreads(): Promise<LkongThreadPage> {
    const query = `query ViewForumHotThreads($fid:Int!){
      hots:threadsFragment(fid:$fid,type:"hot"){tid title author authorid}
    }`;
    const data = await this.graphql(query, { 'fid': LKONG_FORUM_ID });
    const rows = data['hots'] as Array<Record<string, Object>> | undefined;
    return {
      threads: this.parseThreads(rows || [], true),
      page: 1,
      hasMore: false,
      loginRequired: false,
    };
  }

  /** 读取推书试读板块网页端的 viewTags，并保留原始标签链接语义。 */
  static async loadTags(): Promise<LkongTagItem[]> {
    const query = `query ViewForumTags($fid:Int!){
      forumCount(fid:$fid){viewTags{id name}}
    }`;
    const data = await this.graphql(query, { 'fid': LKONG_FORUM_ID });
    const count = data['forumCount'] as Record<string, Object> | undefined;
    const rows = count ? count['viewTags'] as Array<Record<string, Object>> | undefined : undefined;
    const tags: LkongTagItem[] = [];
    for (const row of rows || []) {
      const id = Number(row['id'] || 0);
      const name = String(row['name'] || '').trim();
      if (!id || !name) continue;
      tags.push({ id: id, name: name, url: LKONG_BASE_URL + '/tag/' + id.toString() });
    }
    return tags;
  }

  /** 按 /tag/{id} 对应的 tagThreads 接口读取标签帖子。 */
  static async loadTagThreads(tag: LkongTagItem, page: number = 1): Promise<LkongThreadPage> {
    const query = `query ViewTagPage($tag:Int!,$page:Int!,$action:String){
      threads:tagThreads(tag:$tag,page:$page,action:$action){
        tid title dateline lastpost digest replies views author{name uid}
      }
    }`;
    const data = await this.graphql(query, {
      'tag': tag.id,
      'page': page,
      'action': '',
    });
    const rows = data['threads'] as Array<Record<string, Object>> | undefined;
    const threads = this.parseThreads(rows || []);
    return {
      threads: threads,
      page: page,
      hasMore: threads.length >= 50,
      loginRequired: false,
    };
  }

  /** 获取主题首屏（主帖 + 最多 74 条回复），作为分析 Agent 的上下文。 */
  static async loadThreadContent(item: LkongThreadItem): Promise<LkongThreadContent> {
    const query = `query ViewThread($tid:Int!,$page:Int,$pid:String,$authorid:Int){
      thread(tid:$tid,authorid:$authorid,pid:$pid){tid title dateline digest replies views author{name uid}}
      posts(tid:$tid,page:$page,pid:$pid,authorid:$authorid){lou content dateline user{name uid} quote{content author{name}}}
    }`;
    const data = await this.graphql(query, {
      'tid': item.tid,
      'page': 1,
      'pid': '',
      'authorid': 0,
    });
    const posts = data['posts'] as Array<Record<string, Object>> | undefined;
    const content = this.formatPostsForAnalysis(posts || []);
    console.info('[LkongService] thread=' + item.tid + ', posts=' + (posts ? posts.length : 0) +
      ', analysisChars=' + content.length);
    return { thread: item, content: content };
  }

  /** 主帖必须优先且完整；回复在后，防止总上下文截断时丢掉主帖书单。 */
  static formatPostsForAnalysis(posts: Array<Record<string, Object>>): string {
    let mainPost = '';
    const replies: string[] = [];
    for (const post of posts) {
      const raw = String(post['content'] || '');
      // 保留换行和编号列表，这些结构能帮助模型完整识别书单。
      const text = HtmlUtil.toPlainText(raw, 80000)
        .replace(/[ \t\f\v]+/g, ' ')
        .replace(/\n\s*\n\s*\n/g, '\n\n')
        .trim();
      if (!text) continue;
      const user = post['user'] as Record<string, Object> | undefined;
      const floor = String(post['lou'] || '');
      const name = user ? String(user['name'] || '') : '';
      if (!mainPost) {
        // 龙空主帖最多保留 80000 字，最终由 Agent 按单次请求上限精确裁剪。
        mainPost = '【主帖，优先完整分析】\n' + (name ? '作者：' + name + '\n' : '') + text;
      } else {
        const prefix = (floor ? floor + '楼 ' : '') + (name ? name + '：' : '');
        replies.push(prefix + text.substring(0, 3000));
      }
    }
    if (!mainPost) return '';
    return mainPost + (replies.length > 0 ? '\n\n【跟帖讨论】\n' + replies.join('\n') : '');
  }

  static filterSince(threads: LkongThreadItem[], sinceTimestamp: number): LkongThreadItem[] {
    return threads.filter((item: LkongThreadItem): boolean => item.timestamp >= sinceTimestamp);
  }

  static parseTimestamp(value: string): number {
    if (!value) return 0;
    const numeric = Number(value);
    if (!isNaN(numeric) && numeric > 0) {
      return numeric < 100000000000 ? numeric * 1000 : numeric;
    }
    const parsed = Date.parse(value);
    return isNaN(parsed) ? 0 : parsed;
  }

  private static parseThreads(rows: Array<Record<string, Object>>, isTodayHot: boolean = false): LkongThreadItem[] {
    const threads: LkongThreadItem[] = [];
    for (const row of rows) {
      const tid = Number(row['tid'] || 0);
      const title = String(row['title'] || '').trim();
      if (!tid || !title) continue;
      const authorValue = row['author'];
      const author = typeof authorValue === 'object' ? authorValue as Record<string, Object> : undefined;
      const dateline = String(row['dateline'] || '');
      threads.push({
        tid: tid,
        title: title,
        author: author ? String(author['name'] || '') : String(authorValue || ''),
        authorId: author ? Number(author['uid'] || 0) : Number(row['authorid'] || 0),
        dateline: dateline,
        // 今日热门的 ShortThread 不提供时间；以当天时间标记，方便复用最近一天选择逻辑。
        timestamp: dateline ? this.parseTimestamp(dateline) : (isTodayHot ? Date.now() : 0),
        replies: Number(row['replies'] || 0),
        views: Number(row['views'] || 0),
        digest: Boolean(row['digest']),
        url: LKONG_BASE_URL + '/thread/' + tid.toString(),
      });
    }
    return threads;
  }

  private static actionOf(filter: LkongForumFilter): string {
    return filter === 'all' ? '' : filter;
  }

  private static async graphql(query: string, variables: Record<string, Object>): Promise<Record<string, Object>> {
    const body = JSON.stringify({ 'query': query, 'variables': variables });
    const response = await NetUtil.httpPost(LKONG_API_URL, body, {
      'Content-Type': 'application/json',
      'Origin': LKONG_BASE_URL,
      'Referer': LKONG_FORUM_URL,
      'Accept': 'application/json',
    }, 30000);
    const envelope = JSON.parse(response) as LkongGraphqlEnvelope;
    if (envelope.errors && envelope.errors.length > 0) {
      const message = String(envelope.errors[0]['message'] || '龙空接口请求失败');
      if (message.includes('登录')) throw new Error('LOGIN_REQUIRED:' + message);
      throw new Error(message);
    }
    if (!envelope.data) throw new Error('龙空接口返回为空');
    return envelope.data;
  }
}
