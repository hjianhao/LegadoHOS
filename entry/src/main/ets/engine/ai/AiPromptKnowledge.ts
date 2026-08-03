/**
 * AI 书源 Agent 经验库。
 *
 * 这里保存已经通过真实页面验证、可以跨站复用的结构识别经验，而不是站点的
 * 固定 URL。每条经验都带有阶段和触发信号，调用模型前只选取少量相关条目，
 * 避免把历史日志无限拼进提示词。新增经验时优先补充本文件，不要把站点 ID
 * 或 Cookie 写入提示词。
 */

export type AiPromptStage = 'homepage' | 'search' | 'discovery' | 'detail' | 'toc' | 'content';

interface AiPromptHint {
  id: string;
  stages: AiPromptStage[];
  priority: number;
  /** 上次错误或页面信号命中任意一项即可提高优先级。 */
  signals: RegExp[];
  instruction: string;
}

export interface AiPromptHintSelection {
  ids: string[];
  text: string;
}

/**
 * AI 书源生成时使用的 LegadoHOS 规则契约。
 *
 * 这部分描述的是当前执行器已经实现并验证过的规则子集，不是某个站点的
 * 经验规则。每次生成规则都注入，避免模型只记住 Android Legado 的宽泛写法，
 * 却生成 ArkTS 执行器无法稳定解析的规则。
 */
export function supportedAiRuleContract(stage: AiPromptStage): string {
  const common = 'LegadoHOS 当前支持：HTML 使用 Default/CSS 选择器并显式提取 @text、@href、@src 或 @textNodes；JSON/API 使用 $.path、[*] 数组路径；规则可用稳定的标签/class/id、后代/子元素、属性选择器、位置索引 .0/.1 和 ##regex##replacement。不要使用 body/html 整页文本或样本书固定 URL/数字 ID。';
  const captcha = '如果搜索响应是图片验证码页（如 searchcode.php、__17mb_input、验证码图片/输入框），不能把它当成普通列表。已有可执行的 java.getVerificationCode + java.ajax/java.post 规则应走验证码对话框；只有页面内置脚本、可由用户在交互 WebView 中完成验证码并出现真实搜索结果时，才允许保留 webView 搜索能力。验证未完成或无法得到真实结果时必须拒绝生成搜索规则，不能把空验证码页当成功。';
  if (stage === 'homepage') {
    return common + '\n' + captcha;
  }
  if (stage === 'search') {
    return common + '\n' + captcha + '\n封面规则：HTML 优先定位 img 元素并提取 @src；只有页面明确使用懒加载时才用 @data-src/@data-original，OpenGraph 可用 meta[property="og:image"]@content；禁止 @style、background-image、@html、@text 作为封面规则。';
  }
  if (stage === 'detail' || stage === 'discovery') {
    const list = stage === 'discovery'
      ? '发现/分类表格中可能同时存在最新章节和“加入书签/阅读”等操作链接；ruleExploreName 必须定位书名主链接，ruleExploreNoteUrl 必须提取同一书名主链接的 @href。table 列表优先使用 table.table tr!0 与 a[title]@title/a[title]@href，不能使用 td.N a@href 读取任意链接。'
      : '';
    return common + '\n' + list + '封面规则：HTML 优先定位 img 元素并提取 @src；只有页面明确使用懒加载时才用 @data-src/@data-original，OpenGraph 可用 meta[property="og:image"]@content；禁止 @style、background-image、@html、@text 作为封面规则，禁止把 CSS 声明或整段 HTML 当图片地址。目录链接必须提取当前页面真实的 @href。';
  }
  if (stage === 'toc') {
    return common + '\n目录规则：ruleToc 命中章节列表，ruleTocTitle 与 ruleTocUrlItem 分别提取标题和同一章节链接的 @href；ruleTocNextTocUrl 只能是目录分页下一页。';
  }
  if (stage === 'content') {
    return common + '\n正文规则：命中正文容器或段落节点，优先使用 @textNodes 保留段落边界；不要用 body/html 或把登录、验证、导航区域当正文。';
  }
  return common;
}

const HINTS: AiPromptHint[] = [
  {
    id: 'homepage.form-and-canonical',
    stages: ['homepage'],
    priority: 60,
    signals: [/form|搜索表单|action|规范域名|canonical|跳转/i],
    instruction: '优先依据真实 form 的 action、method、关键词 input 和 charset 生成搜索请求；页面跳转后使用同站最终规范域名，不能把页面中的第三方链接当搜索入口。',
  },
  {
    id: 'homepage.login-challenge',
    stages: ['homepage'],
    priority: 45,
    signals: [/登录|验证码|人工验证|challenge|password|captcha/i],
    instruction: '区分登录页、Cloudflare/WAF 人工验证页、图片验证码页和普通首页；loginUrl 只有在页面明确提供登录入口时填写。图片验证码优先复用 java.getVerificationCode 配合 java.ajax/java.post；若只能由站点页面脚本弹窗处理，则请求交互 WebView，让用户完成后确认页面已出现真实结果，不能把空验证码页当普通首页。',
  },
  {
    id: 'search.image-captcha',
    stages: ['search'],
    priority: 115,
    signals: [/searchcode|__17mb|请输入验证码|验证码图片|captcha|图片验证码/i],
    instruction: '搜索响应若只有验证码表单或表头而没有书籍行，判定为图片验证码门禁；已有 java.getVerificationCode + java.ajax/java.post 时走验证码对话框，页面内置脚本则在交互 WebView 中完成后重新取证，必须确认真实书籍行出现后才可继续，不得把空验证码页或未完成的 ##webView 当成功。',
  },
  {
    id: 'search.card-local-fields',
    stages: ['search', 'discovery'],
    priority: 100,
    signals: [/更新日期|更新时间|作者|状态|卡片|整段|整页|ruleSearchName|书名主链接|有效书名/i],
    instruction: '字段规则必须相对于单本书卡片；书名只能取卡片内书名子元素，作者只能取作者字段，不能取 tr@text、整卡片@text 或整列文本。',
  },
  {
    id: 'search.table-index-fields',
    stages: ['search', 'discovery'],
    priority: 95,
    signals: [/表格|table|td\.|odd|even|作者规则|未知作者/i],
    instruction: '表格结果优先使用同一行的单元格/链接索引，例如 .odd.0@text、.odd.1@text、a.0@href；避免 td.odd a@text 这种会把多个链接合并的规则。',
  },
  {
    id: 'search.explicit-book-url',
    stages: ['search', 'discovery'],
    priority: 90,
    signals: [/详情 URL|详情链接|noteUrl|href|章节链接|分类链接|书籍地址/i],
    instruction: 'ruleSearchNoteUrl/ruleExploreNoteUrl 必须提取书名主链接的 @href 或 API 的书籍 ID/URL；排除作者、分类、最新章节和阅读章节链接，不能写入样本书固定 ID。',
  },
  {
    id: 'search.charset-and-response',
    stages: ['homepage', 'search'],
    priority: 75,
    signals: [/乱码|�|gbk|gb2312|charset|编码|无结果/i],
    instruction: '如果响应出现乱码或搜索无结果，先检查页面 charset 与 POST body 编码；使用站点实际 charset 编码关键词，不要用 UTF-8 规则掩盖编码错误。',
  },
  {
    id: 'detail.semantic-metadata',
    stages: ['detail'],
    priority: 105,
    signals: [/作者|类别|字数|更新时间|附加字段|整页内容|页面外壳|管理|举报/i],
    instruction: '详情元数据优先按语义标签定位，避免旧式嵌套表格的 td.N 全局索引；例如 text.者：@text##.*者[：:]、text.别：@text##.*别[：:]，每个字段都要显式提取并去掉标签前缀。',
  },
  {
    id: 'detail.title-fallback',
    stages: ['detail'],
    priority: 95,
    signals: [/书名|没有解析出书名|书名不一致|h1|title|面包屑|截短/i],
    instruction: '详情页没有可靠 h1 时，尝试当前内容区面包屑的书名链接或标题 span；禁止用 title@text、body@text、html@text 作为书名，避免把站点标题和章节信息带入。',
  },
  {
    id: 'detail.media-and-toc',
    stages: ['detail'],
    priority: 90,
    signals: [/封面|cover|目录|toc|固定 URL|数字 ID|href|src/i],
    instruction: '封面规则必须定位 img 并提取 @src（懒加载才用 @data-src/@data-original），保留相对地址解析；禁止 @style、background-image、@html 或 @text。目录规则必须从当前详情页动态提取完整目录入口 @href，不能硬编码本次样本的 URL 或数字 ID。',
  },
  {
    id: 'toc.explicit-title-href',
    stages: ['toc'],
    priority: 105,
    signals: [/ruleTocUrlItem|章节链接|没有可读章节|标题规则相同|章节列表/i],
    instruction: '目录项应是章节链接元素或同级章节卡片；ruleTocTitle 只提取标题，ruleTocUrlItem 必须独立提取同一元素的 @href，二者不能相同，也不能把书籍列表当章节。',
  },
  {
    id: 'toc.pagination-not-chapter',
    stages: ['toc'],
    priority: 85,
    signals: [/分页|下一页|下一章|最新章节|完整目录/i],
    instruction: 'ruleTocNextTocUrl 只能指向目录的下一页；不要把下一章、最新章节或“查看全部章节”链接当目录分页。分页结果要去重后合并并保持章节顺序。',
  },
  {
    id: 'content.text-semantics',
    stages: ['content'],
    priority: 105,
    signals: [/正文|分段|HTML|html|textNodes|段落|内容过短|外壳|正文规则/i],
    instruction: '正文规则必须命中正文容器而不是 body/html；文本小说优先使用正文容器或段落节点的 @textNodes 保留 br、p、div 和全角空格边界，只有富文本确实需要时才使用 @html。',
  },
  {
    id: 'content.pagination-and-antibot',
    stages: ['content'],
    priority: 85,
    signals: [/下一页|分页|反爬|验证码|登录|人工验证|占位页|短/i],
    instruction: '正文下一页必须是同一章节的分页；正文过短时先判断登录/验证码/反爬占位页并请求 WebView，不要用页面外壳或下一章链接冒充正文。',
  },
];

function signalText(error: string, html: string): string {
  // 只用于本地关键词匹配，不把页面内容直接写入经验库或日志。
  return (error || '') + '\n' + (html || '').substring(0, 12000);
}

/** 选择当前阶段最相关的少量经验，最多注入 4 条，控制提示词长度。 */
export function selectAiPromptHints(stage: AiPromptStage, error: string,
  html: string, limit: number = 4): AiPromptHintSelection {
  const text = signalText(error, html);
  const scored: Array<{ hint: AiPromptHint; score: number }> = [];
  for (const hint of HINTS) {
    if (!hint.stages.includes(stage)) continue;
    let score = hint.priority;
    let matched = false;
    for (const signal of hint.signals) {
      if (signal.test(text)) {
        score += 40;
        matched = true;
        break;
      }
    }
    // 无错误时保留每个阶段的基础经验；有错误时优先命中具体条目。
    if (error && !matched && stage !== 'homepage') score -= 35;
    scored.push({ hint, score });
  }
  scored.sort((left, right) => right.score - left.score);
  const selected = scored.slice(0, Math.max(1, Math.min(limit, 4)));
  return {
    ids: selected.map((item) => item.hint.id),
    text: selected.length === 0 ? '' :
      '经验库提示（仅作为规则识别约束，必须以当前页面真实 DOM 为准）：\n' +
      selected.map((item) => '- [' + item.hint.id + '] ' + item.hint.instruction).join('\n'),
  };
}
