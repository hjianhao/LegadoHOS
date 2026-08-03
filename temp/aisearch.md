# AI 搜书发现并批量生成书源——详细规格与设计方案

> 文档用途：交给其他编码 AI 直接实施。
>
> 目标工程：LegadoHOS（HarmonyOS / ArkTS / ArkUI）。
>
> 实施原则：优先复用现有在线搜书 WebView、`AiSourceAgent` 全链路生成器、书源数据库和版本回滚服务，不重复实现书源解析引擎。

---

## 1. 功能结论

该功能可行。

现有工程已经具备两条独立能力：

1. 在线搜书：输入书名后，在内嵌浏览器打开必应、百度、搜狗、神马或 Google 搜索结果页。
2. AI 生成书源：输入小说网站首页和真实测试书名后，依次分析首页、搜索、发现、详情、目录、正文，并执行完整链路验证。

本功能需要在二者之间增加两层能力：

1. 从在线搜索结果页提取小说网页链接，归一化为“候选小说网站首页列表”。
2. 用户多选候选网站后，串行调用现有 `AiSourceAgent`，生成并保存多个书源。

搜索结果页的候选提取必须优先使用本地 DOM/链接分析，不要先把整个搜索结果页发送给大模型。大模型只用于用户最终选择的网站，并且仍由现有 `AiSourceAgent` 真实执行站内搜索和完整链路验证。

---

## 2. 本次实现范围

### 2.1 必须实现

- 书源管理页顶部现有 `AI` 按钮保持不变，仍进入 `pages/AiSourceGeneratePage`。
- 普通创建模式下，`AiSourceGeneratePage` 顶部增加两个标签：
  - `网址建源`
  - `搜书发现`
- `网址建源`完整保留现有单网站 AI 建源行为。
- `搜书发现`支持：
  - 输入书名。
  - 选择在线搜索引擎。
  - 打开对应搜索结果页。
  - 从当前搜索结果页提取候选网站。
  - 按站点归一化和去重。
  - 标识已有书源和疑似重复书源。
  - 用户多选候选网站。
  - 串行调用 `AiSourceAgent` 生成书源。
  - 单站失败不终止后续站点。
  - 生成成功后立即保存为“未启用”书源。
  - 已有书源默认跳过；用户明确选择更新时才能更新。
  - 展示批量执行进度、单站阶段、成功/失败/跳过结果和错误信息。
  - 批量结束后允许用户启用本次成功生成的书源。
- AI 修复模式保持现状：隐藏两个创建标签，标题仍为 `AI 修复书源`。
- 所有新增 UI 同时支持深色和浅色模式。

### 2.2 本次不实现

- 不使用搜索引擎官方付费 API。
- 不在后台无人值守地同时抓取多个搜索引擎。
- 不并发运行多个 `AiSourceAgent`。
- 不把搜索到的小说加入书架。
- 不允许使用搜索结果中的某一本书详情 URL 绕过站内搜索规则验证。
- 不新增持久化的“批量任务队列表”。
- 不保证应用被系统强杀后恢复正在运行的站点；但已经成功的站点必须立即保存，因此不会丢失已完成成果。
- 不自动更新已有书源，除非用户在候选列表中明确允许。

### 2.3 后续可选增强

- 合并多个搜索引擎的候选结果。
- 持久化批量任务并支持断点续跑。
- 为候选网站增加历史成功率、质量评分和批量测速。
- 自动抓取搜索结果第 2 页及以后页面。
- 增加用户维护的排除域名列表。

---

## 3. 现有代码基础

实施前必须先阅读这些文件，避免重复造轮子：

### 3.1 页面入口

- `entry/src/main/ets/pages/BookSourcePage.ets`
  - 顶部现有 `AI` 按钮已经跳转到 `pages/AiSourceGeneratePage`。
  - 不需要新增顶层入口。
  - 可以把 accessibilityText 从“AI 生成书源”调整为“AI 书源”，但不是硬性要求。

- `entry/src/main/resources/base/profile/main_pages.json`
  - 已注册 `pages/AiSourceGeneratePage`。
  - 本方案不新增页面路由，因此不需要修改该文件。

### 3.2 现有 AI 建源页

- `entry/src/main/ets/pages/AiSourceGeneratePage.ets`
  - 当前同时承担“新建书源”和“修复已有书源”。
  - `startAnalyze()` 调用 `AiSourceAgent.analyze()` 或 `repair()`。
  - `saveGeneratedSource_()` 包含新增、同 URL 冲突、更新和版本回滚逻辑。
  - `aboutToAppear()` 通过 `repairSourceUrl` 路由参数判断修复模式。
  - 页面已经嵌入隐藏的 `WebViewEngine`，供 `WebViewFetcher` 使用。
  - 本次需要增加标签和“搜书发现”面板，但不得破坏修复模式。

### 3.3 在线搜书

- `entry/src/main/ets/pages/SearchPage.ets`
  - `searchMode === 1` 是在线搜书模式。
  - 当前支持：必应、百度、搜狗、神马、Google。
  - `onlineSearchUrl_()` 构造搜索地址。
  - `AiImportPreviewDialog` 打开搜索结果页。
  - 当前行为要求用户进入某一本书详情页，然后执行单本 AI 导入。
  - 本功能不得复制一份容易漂移的搜索引擎配置；应提取公共配置供两处复用。

### 3.4 WebView 页面读取

- `entry/src/main/ets/components/AiImportPreviewDialog.ets`
  - 当前确认时通过 `document.documentElement.outerHTML` 读取渲染后的 DOM。
  - 已处理 ArkWeb `runJavaScript()` 字符串二次 JSON 编码。
  - 本次需要以兼容方式扩展“结构化提取链接”能力。
  - 原有单本导入调用方不应受到行为变化。

- `entry/src/main/ets/engine/web/WebViewFetcher.ts`
  - 是全局隐藏 WebView 获取器。
  - 同时只能处理一个页面，内部已有请求队列。
  - `fetch()` 返回 HTML 和最终跳转 URL。
  - 这是批量任务必须串行执行的重要原因。

### 3.5 AI 全站书源生成器

- `entry/src/main/ets/engine/ai/AiSourceAgent.ts`
  - `analyze(homepageUrl, searchKeyword)` 是本功能的核心复用入口。
  - 完整阶段：
    1. `HOMEPAGE`
    2. `SEARCH`
    3. `DISCOVERY`
    4. `BOOK_INFO`
    5. `TOC`
    6. `CONTENT`
    7. `VALIDATE`
    8. `COMPILE`
  - Agent 内部持有 `draft_`、`results_`、`lastCheck_` 等可变状态。
  - 每个候选网站必须创建独立 Agent 实例，禁止多个任务共用一个实例。
  - 新建草稿默认包含：
    - `enabled = false`
    - `group = 'AI生成'`
    - `isAiGenerated = true`
  - `run_()` 在内部捕获大部分错误并返回阶段结果，因此调用方不能只依赖 `catch`；必须检查 `COMPILE` 阶段是否为 `done`。

### 3.6 数据库和版本更新

- `entry/src/main/ets/data/database/BookSourceTable.ts`
  - `getSourceByUrl()` 当前对 `source_url` 使用精确匹配。
  - `insertSource()` 新增书源。
  - 同一个逻辑站点可能出现尾斜杠或 `www.` 差异，因此本功能必须在服务层先规范化比较。

- `entry/src/main/ets/service/SourceRevisionService.ts`
  - `applyRepair()` 支持更新已有书源并记录可回滚版本。
  - 更新时会保留已有分组、启用状态、排序等用户管理字段。

- `entry/src/main/ets/service/BookSourceChangeNotifier.ts`
  - 新增或批量完成后应通知书源列表刷新。

### 3.7 单本网页 AI 导入

- `entry/src/main/ets/engine/ai/AiBookImporter.ts`
  - `isSafeAiImportUrl()` 已用于排除本机、内网和非 HTTP(S) URL。
  - 本功能应复用该安全检查。
  - 不要调用 `AiBookImporter.import()`，因为本功能的产物是全局书源，不是书架中的单本书。

---

## 4. 核心产品决策

### 4.1 入口与页面结构

普通用户路径：

```text
书源管理
  └─ 点击顶部 AI
       └─ AI 书源
            ├─ 网址建源
            └─ 搜书发现
```

修复路径：

```text
书源管理/书源调试
  └─ AI 修复
       └─ AI 修复书源（不显示创建标签）
```

不要新增 `AiSourceDiscoverPage` 路由。直接在现有 `AiSourceGeneratePage` 中增加普通模式的两个标签，可以保持入口统一，也不会破坏已有跳转参数。

### 4.2 标签文案

正式文案：

- `网址建源`
- `搜书发现`

不要使用“书名搜索”作为唯一标签文案，因为用户可能误以为最终结果是把书加入书架。“搜书发现”强调目标是通过书名发现网站。

### 4.3 默认标签

- 首次进入默认 `网址建源`，保持现有用户习惯。
- 可以使用 `SettingsStore` 记住上次普通创建模式选择的标签。
- 修复模式强制使用网址/修复面板，不读取记忆值。

### 4.4 批量保存策略

- 每个站点完整生成成功后立即写入 `book_sources`。
- 新增书源保持 `enabled = false`。
- 新增书源使用 Agent 已设置的 `group = 'AI生成'`。
- 批量结束后由用户决定是否启用本次成功项。
- 这样即使用户离开页面或应用随后被系统终止，已经成功的结果也不会丢失，同时未经用户最终确认的批量来源不会立刻参与搜书。

### 4.5 已有书源策略

- 精确或规范化 URL 已存在：默认不选中，并显示“已有书源”。
- 同主机但 URL 不完全一致：显示“疑似重复”，允许用户检查和编辑首页。
- 默认操作为“跳过已有”。
- 只有用户打开“允许更新已有书源”并主动选中该项时，才执行更新。
- 更新必须通过 `SourceRevisionService.applyRepair()`，不得直接调用 `updateSource()` 覆盖用户配置。

### 4.6 并发策略

- 候选站点必须串行处理，并发度固定为 1。
- 原因：
  - `WebViewFetcher` 是单例全局 WebView。
  - `AiSourceAgent` 具有实例可变状态。
  - 验证码和 Cloudflare 交互无法并发展示。
  - AI API 经常存在并发和频率限制。
  - 多站并发容易触发网站反爬。

### 4.7 停止策略

第一版不强制改造所有底层网络请求以支持立即取消。

- 提供按钮：`完成当前网站后停止`。
- 点击后设置 `stopRequested = true`。
- 当前 Agent 返回后不再启动下一个候选项。
- 尚未开始的候选项状态改为 `cancelled` 或保持 `pending`，结果汇总中计入“未执行”。
- 不要宣称当前正在执行的 LLM 请求会立即中断。

---

## 5. 用户界面详细规格

## 5.1 页面头部

普通模式：

```text
┌──────────────────────────────────┐
│ ←              AI 书源      AI 设置 │
├──────────────────────────────────┤
│          网址建源    搜书发现        │
└──────────────────────────────────┘
```

修复模式：

```text
┌──────────────────────────────────┐
│ ←           AI 修复书源     AI 设置 │
└──────────────────────────────────┘
```

要求：

- 标签放在页面标题栏下方。
- 使用项目现有语义化主题颜色。
- 不得硬编码文字色、背景色、边框色或主色。
- 标签需要清晰的选中态、未选中态和无障碍说明。
- AI 正在执行时禁止切换标签；可禁用标签并展示提示“请先停止当前任务”。

## 5.2 网址建源标签

该标签完整保留现有 UI 和行为：

- 网站首页或小说站 URL。
- 真实测试关键词。
- 开始生成。
- 八阶段进度。
- 完整过程日志。
- 重新运行。
- 保存书源。

除公共保存服务抽取外，不应改变现有功能语义。

## 5.3 搜书发现：初始状态

布局：

```text
书名
[ 斗罗大陆                         ]

搜索引擎
[ 必应                         ▼ ]

[ 打开搜索结果并发现网站 ]

说明：这里只发现并生成书源，不会把搜索到的书加入书架。
```

字段规则：

- 书名必填，去除首尾空白和末尾常见标点。
- 不自动添加引号、`小说`、`免费阅读`、排除词等额外关键词。
- 搜索引擎默认读取现有在线搜书偏好 `online_search_engine`。
- 搜索引擎选择变化时同步更新同一个偏好值，使在线搜书和搜书发现保持一致。

## 5.4 搜索结果浏览器

打开已有 `AiImportPreviewDialog`，参数建议：

- `initialUrl`：公共搜索引擎服务构造的搜索地址。
- `titleText`：`必应 · 斗罗大陆` 等。
- `confirmText`：`提取当前页网站`。
- `helperText`：`停留在搜索结果页，无需进入具体小说。加载完成后提取当前页中的网站。`
- `dismissBeforeConfirm = false`，由上层校验结果后再关闭。
- 新增 `collectLinks = true`。

确认时校验：

- 当前页必须仍是支持的搜索引擎结果页。
- 如果用户已经进入具体网页，提示：`请返回搜索结果页后再提取网站`。
- DOM 未加载或提取结果为空时不关闭浏览器，展示错误并允许重试。

## 5.5 候选网站列表

顶部摘要：

```text
发现 18 条网页结果，归并为 7 个网站 · 已选择 5 个
[选择全部新网站] [清空选择] [重新搜索]
```

每个候选项展示：

- 复选框。
- 网站显示名；无法识别时显示主机名。
- 规范化首页地址。
- 命中的网页数量，例如 `搜索结果中命中 3 个页面`。
- 最多 2 条样本标题。
- 状态标签之一：
  - `新网站`
  - `已有书源`
  - `疑似重复`
  - `地址待确认`
  - `不安全地址`
- `编辑首页`操作。

选择默认值：

- 新网站：默认选中。
- 已有书源：默认不选中。
- 疑似重复：默认不选中。
- 地址待确认：默认不选中。
- 不安全地址：禁止选中。

候选列表底部：

- Toggle：`允许重新生成并更新已有书源`，默认关闭。
- 主按钮：`批量生成选中的 N 个书源`。
- 当 N 为 0 时按钮禁用。
- 建议限制一次最多选择 10 个网站；超过时提示用户分批执行。

开始前确认对话框：

```text
即将依次分析 5 个网站。每个网站都会真实执行搜索、详情、目录和正文验证，可能耗时较长并消耗多次 AI 请求。

生成成功的书源会立即保存为“未启用”，批量完成后可统一启用。
```

按钮：`取消`、`开始生成`。

## 5.6 批量执行状态

顶部显示：

- 总进度：`2 / 5`。
- 当前网站：主机名或网站名称。
- 当前阶段：例如 `搜索规则 · 抓取搜索结果并验证选择器`。
- 按钮：`完成当前网站后停止`。

列表中每个候选项显示状态：

- `等待中`
- `生成中`
- `等待人工验证`
- `已新增（未启用）`
- `已更新`
- `配置无变化`
- `已跳过`
- `生成失败`
- `未执行`

当前项可展开显示：

- 八个 Agent 阶段状态。
- 阶段 summary。
- 精简日志。
- 失败原因。

日志保存规则：

- UI 内每个候选保留最近 200 条日志，避免无限增长。
- 完整日志仍可以写系统日志。
- 不得记录 AI API Key、Cookie、密码、验证码或整页 HTML。

## 5.7 人工验证

复用现有 `CloudflareDialog`、`CaptchaDialog` 和 `onRequestWebView` 回调。

批量模式下：

- 当前候选状态改为 `waiting_user`。
- 页面显示“当前网站需要人工验证”。
- 用户完成验证后继续当前 Agent。
- 用户取消验证时返回空 HTML，让当前站点按失败处理，然后继续下一个站点。
- 不得因为某个站点需要验证而丢弃已经成功保存的其他站点。

## 5.8 完成状态

汇总：

```text
批量生成完成
新增 4 · 更新 1 · 无变化 1 · 失败 2 · 跳过 1
```

操作：

- `查看失败项`
- `复制结果摘要`
- `启用本次新增书源`
- `返回书源管理`

`启用本次新增书源`只作用于本次成功新增且当前仍未启用的 ID，不要批量启用以前的 `AI生成` 分组。

---

## 6. 数据模型设计

新增文件建议：

`entry/src/main/ets/model/AiSourceDiscovery.ts`

建议定义如下。字段名称可以小幅调整，但语义必须保留。

```typescript
export interface AiSearchPageLink {
  href: string;
  text: string;
  title: string;
  context: string;
  dataUrl: string;
}

export interface AiSourceCandidateSample {
  title: string;
  url: string;
  context: string;
}

export type AiSourceCandidateDuplicate = 'none' | 'exact' | 'same_host';

export type AiSourceCandidateStatus =
  'candidate' |
  'queued' |
  'running' |
  'waiting_user' |
  'created' |
  'updated' |
  'unchanged' |
  'failed' |
  'skipped' |
  'cancelled';

export interface AiSourceCandidate {
  id: string;
  engineId: string;
  keyword: string;
  resultPageUrl: string;
  displayName: string;
  landingUrl: string;
  homepageUrl: string;
  normalizedSiteKey: string;
  host: string;
  hitCount: number;
  samples: AiSourceCandidateSample[];
  confidence: number;
  selected: boolean;
  safe: boolean;
  duplicate: AiSourceCandidateDuplicate;
  existingSourceId: number;
  existingSourceName: string;
  status: AiSourceCandidateStatus;
  currentStep: number;
  stepSummary: string;
  logs: string[];
  savedSourceId: number;
  error: string;
}

export interface AiSourceBatchSummary {
  created: number;
  updated: number;
  unchanged: number;
  failed: number;
  skipped: number;
  cancelled: number;
  createdSourceIds: number[];
}
```

ArkTS 注意事项：

- 不要使用 `any`。
- 不要依赖动态新增对象属性。
- 所有进入 `@State` 的数组更新必须创建新数组。
- 更新候选项时使用 `map` 或复制对象，不要直接 `this.candidates[index].status = ...` 后期待 UI 自动刷新。
- 对日志使用新数组，例如 `logs: [...item.logs, message].slice(-200)`。

---

## 7. 公共在线搜索引擎配置

新增文件建议：

`entry/src/main/ets/service/OnlineSearchEngineService.ts`

从 `SearchPage.ets` 提取并复用以下能力：

```typescript
export interface OnlineSearchEngine {
  id: string;
  name: string;
}

export const ONLINE_SEARCH_ENGINES: OnlineSearchEngine[] = [
  { id: 'bing', name: '必应' },
  { id: 'baidu', name: '百度' },
  { id: 'sogou', name: '搜狗' },
  { id: 'shenma', name: '神马' },
  { id: 'google', name: 'Google' },
];

export function normalizeOnlineSearchEngine(value: string): string;
export function getOnlineSearchEngineName(value: string): string;
export function buildOnlineSearchUrl(engineId: string, keyword: string): string;
export function isOnlineSearchResultPage(url: string): boolean;
export function isOnlineSearchEngineHost(url: string): boolean;
```

URL 规则必须与当前 `SearchPage.onlineSearchUrl_()` 一致：

```text
baidu  -> https://www.baidu.com/s?wd={encoded}
sogou  -> https://www.sogou.com/web?query={encoded}
shenma -> https://m.sm.cn/s?q={encoded}
google -> https://www.google.com/search?q={encoded}
bing   -> https://cn.bing.com/search?q={encoded}
```

同时修改 `SearchPage.ets` 使用公共服务，确保在线搜书行为没有回归。

---

## 8. WebView 链接提取设计

## 8.1 兼容扩展 AiImportPreviewDialog

修改：

`entry/src/main/ets/components/AiImportPreviewDialog.ets`

新增可选参数：

```typescript
collectLinks: boolean = false;
```

扩展结果：

```typescript
export interface AiImportPreviewResult {
  url: string;
  html: string;
  links?: AiSearchPageLink[];
}
```

要求：

- `collectLinks === false` 时保持原行为，不能影响 `SearchPage` 和 `AiImportBookPage` 的单本导入。
- `collectLinks === true` 时，在读取 outerHTML 后额外执行一次固定 JavaScript，返回结构化链接 JSON。
- 链接最多返回 300 条。
- 每条 `text`、`title` 最多 200 字符，`context` 最多 500 字符。
- JavaScript 必须是固定字符串，不拼接用户输入，避免脚本注入。

## 8.2 建议的页面脚本语义

脚本需要遍历 `document.querySelectorAll('a[href]')`，为每个链接收集：

- `anchor.href`：浏览器解析后的绝对 URL。
- `anchor.innerText` 或 `textContent`。
- `anchor.title`。
- 搜索结果容器上下文。
- 可能包含真实落地地址的属性。

搜索结果容器优先寻找：

```text
li
article
.result
.c-container
.g
[data-sokoban-container]
```

真实地址属性候选：

```text
data-url
data-landurl
data-href
data-mu
mu
```

不仅检查 `<a>` 自身，也检查最近结果容器上的这些属性。

脚本返回 JSON 字符串。ArkWeb 会再次把字符串编码为 JSON，必须先复用现有 `decodeJsString_()`，再 `JSON.parse()` 为 `AiSearchPageLink[]`。

解析失败时返回空数组并显示可重试错误，不得导致应用崩溃。

---

## 9. 候选站点发现服务

新增文件建议：

`entry/src/main/ets/service/AiSourceDiscoveryService.ts`

该服务必须尽量由纯函数组成，方便单元测试。

建议公开方法：

```typescript
export class AiSourceDiscoveryService {
  static buildCandidates(
    engineId: string,
    keyword: string,
    resultPageUrl: string,
    links: AiSearchPageLink[],
    existingSources: BookSource[]
  ): AiSourceCandidate[];

  static normalizeHomepageUrl(url: string): string;
  static normalizedSiteKey(url: string): string;
  static decodeKnownSearchRedirect(engineId: string, link: AiSearchPageLink): string;
  static isCandidateUrl(url: string): boolean;
}
```

## 9.1 处理顺序

对每个 `AiSearchPageLink` 依次处理：

1. 选择最可能的落地地址。
2. 解码搜索引擎可直接识别的跳转参数。
3. 拒绝非 HTTP(S) 地址。
4. 拒绝搜索引擎自身域名和搜索导航链接。
5. 使用 `isSafeAiImportUrl()` 拒绝本机、内网、带账号密码的 URL。
6. 去除 fragment。
7. 从落地 URL 推导站点首页。
8. 生成站点归一化 key。
9. 按 key 合并，累计命中数并保留样本。
10. 与本地全部书源对比，标记 `exact` 或 `same_host`。
11. 计算置信度和默认选中状态。
12. 排序后最多返回 50 个站点。

## 9.2 落地地址优先级

优先级从高到低：

1. `dataUrl` 中明确的外站 HTTP(S) URL。
2. 搜索跳转 URL 参数中可以直接解码出的外站 URL。
3. `<a>` 的 `href` 是直接外站地址。
4. 无法解析的搜索引擎 opaque 跳转链接。

对于第 4 类：

- 候选暂时标记为“地址待确认”，默认不选择。
- 可以在关闭搜索结果浏览器后，通过隐藏 `WebViewFetcher.fetch()` 串行打开有限数量的跳转链接并读取 `finalUrl`。
- 解析跳转时必须限制数量和超时，建议最多 20 条、每条 15 秒。
- 跳转解析失败不应阻塞其他直接地址。
- 不要并发调用 `WebViewFetcher.fetch()`。

## 9.3 搜索跳转参数解码

仅当参数解码后是安全的外站 HTTP(S) URL 时采用。

常见参数名：

```text
q
url
target
u
dest
destination
```

不要把搜索引擎自身 `/search`、账户、设置、图片、视频、新闻等链接作为候选。

## 9.4 首页地址推导

第一版规则：

```text
landingUrl = https://m.example.com/book/123.html
homepageUrl = https://m.example.com
```

规范化：

- scheme 和 host 转小写。
- 去除用户名密码。
- 去除 fragment 和 query。
- 去除默认端口 `:80`、`:443`。
- 首页不保留尾斜杠。
- 保留非默认端口。
- 默认只把 `www.example.com` 和 `example.com` 视为同一 key。
- 不要直接合并 `m.example.com`、`api.example.com`、`wap.example.com` 等子域名。
- 同一 key 同时出现 HTTP 和 HTTPS 时优先 HTTPS。

有些小说站位于子目录而根域名是门户。第一版不自动猜测子目录首页，必须允许用户编辑 `homepageUrl`。`AiSourceAgent` 后续会验证首页是否真的存在站内搜索入口；无法验证则该站生成失败，不得用样本详情页硬凑规则。

## 9.5 候选合并

同一个 `normalizedSiteKey`：

- 只生成一个候选站点。
- `hitCount + 1`。
- `samples` 最多保留 3 条不同 URL。
- 显示名优先采用结果标题中较短、非空且不像 URL 的站点部分；无法可靠判断时直接使用 host。
- 不要用 AI 决定合并结果。

## 9.6 置信度

置信度只用于排序和状态提示，不得替代用户选择。

建议评分：

- 链接文本包含完整书名：+35。
- 上下文包含完整书名：+20。
- 同一站点出现 2 条及以上结果：+15。
- URL 路径包含 `book`、`novel`、`read`、`chapter`、`info` 等常见小说结构：+10。
- 链接有明确外站直达地址：+10。
- 只能得到 opaque 搜索跳转：-30。
- 链接文字为空：-10。
- 已有精确书源：不改变置信度，但默认不选。

不要硬编码大批“非小说网站黑名单”。搜索结果可能包含有效的小众书站，最终由用户选择。只排除搜索引擎自身及明确无效协议。

## 9.7 已有书源判断

加载 `BookSourceTable.getAllSources()`，包括已禁用书源。

判断：

- `normalizeHomepageUrl(existing.sourceUrl) === normalizeHomepageUrl(candidate.homepageUrl)`：`exact`。
- normalized host 相同但完整规范化 URL 不同：`same_host`。
- 否则：`none`。

注意：数据库原方法是精确 URL 查询，本服务的规范化比较只用于候选标记和保存前冲突判断，不要在本次功能中修改数据库全局唯一语义。

---

## 10. 批量生成服务

新增文件建议：

`entry/src/main/ets/service/AiSourceBatchGenerateService.ts`

建议回调：

```typescript
export interface AiSourceBatchCallbacks {
  onCandidateChanged?: (candidate: AiSourceCandidate) => void;
  onSummaryChanged?: (summary: AiSourceBatchSummary) => void;
  onRequestWebView?: (url: string, reason: string) => Promise<string>;
}
```

建议服务骨架：

```typescript
export class AiSourceBatchGenerateService {
  private stopRequested_: boolean = false;

  requestStop(): void;

  async run(
    context: Context,
    keyword: string,
    candidates: AiSourceCandidate[],
    allowUpdateExisting: boolean,
    callbacks: AiSourceBatchCallbacks
  ): Promise<AiSourceBatchSummary>;
}
```

## 10.1 串行伪代码

```typescript
for (const candidate of selectedCandidates) {
  if (stopRequested) {
    markCancelled(candidate);
    continue;
  }

  if (candidate.duplicate === 'exact' && !allowUpdateExisting) {
    markSkipped(candidate, '已有书源，未允许更新');
    continue;
  }

  const agent = new AiSourceAgent({
    onStepUpdate: (step) => updateCandidateStep(candidate.id, step),
    onLog: (message) => appendCandidateLog(candidate.id, message),
    onRequestWebView: callbacks.onRequestWebView,
  });

  await agent.init(context);
  if (!agent.isConfigured()) {
    throw new Error('请先配置 AI API 和模型');
  }

  const results = await agent.analyze(candidate.homepageUrl, keyword);
  const compile = results[AiStep.COMPILE];
  const source = agent.getCompiledBookSource();

  if (!compile || compile.status !== 'done' || !source) {
    markFailed(candidate, compile?.summary || '书源未通过全链路验证');
    continue;
  }

  const saveResult = await saveService.saveBatchGeneratedSource(
    source, candidate, allowUpdateExisting);
  markFromSaveResult(candidate, saveResult);
}
```

## 10.2 关键要求

- 每个候选新建一个 `AiSourceAgent`。
- `keyword` 必须使用用户本次输入的书名。
- 不得把候选样本的 `landingUrl` 直接注入 Agent 草稿，或者让 Agent 跳过站内搜索阶段。
- 候选 `homepageUrl` 是 Agent 唯一入口地址。
- 当前站失败后继续下一站。
- Agent 初始化未配置属于批次级错误：停止批次并提示去 AI 设置。
- 某个站的网络错误、规则错误、验证码取消属于单项错误。
- 执行期间候选数组更新必须不可变，确保 ArkUI 刷新。

---

## 11. 共享保存服务

当前 `AiSourceGeneratePage.saveGeneratedSource_()` 是页面私有实现。为了保证单个生成和批量生成的冲突语义一致，必须抽取共享服务。

新增文件建议：

`entry/src/main/ets/service/AiGeneratedSourceSaveService.ts`

建议结果：

```typescript
export type AiGeneratedSourceSaveStatus =
  'created' | 'updated' | 'unchanged' | 'skipped';

export interface AiGeneratedSourceSaveResult {
  status: AiGeneratedSourceSaveStatus;
  sourceId: number;
  changedFields: string[];
  message: string;
}
```

建议方法：

```typescript
export class AiGeneratedSourceSaveService {
  static async findExistingByNormalizedUrl(sourceUrl: string): Promise<BookSource | null>;

  static async createGeneratedSource(
    candidate: BookSource,
    enabled: boolean
  ): Promise<AiGeneratedSourceSaveResult>;

  static async updateGeneratedSource(
    existing: BookSource,
    candidate: BookSource,
    reason: string,
    preserveSourceName: boolean
  ): Promise<AiGeneratedSourceSaveResult>;
}
```

## 11.1 单个网址建源

保持现有语义：

- 用户点击“保存书源”后填写名称。
- 新增书源保存并启用。
- URL 已存在时显示更新确认。
- 更新通过 `SourceRevisionService.applyRepair()`。
- 保存成功后通知书源列表并返回。

只是把具体数据库写入移动到共享服务，不能改变现有文案和行为。

## 11.2 批量搜书发现

新增书源：

- 保留 Agent 生成的名称。
- `enabled = false`。
- `group` 为空时设为 `AI生成`；已有 `AI生成` 时不重复追加。
- 设置正确的 `createTime`、`updateTime`。
- 调用 `insertSource()`。
- 返回新 ID，记录到 `summary.createdSourceIds`。

已有书源且允许更新：

- 保存前把候选 `sourceUrl` 设置为现有书源的原始 `sourceUrl`，满足 `SourceRevisionService` 的身份约束。
- 默认保留现有书源名称，即 `preserveSourceName = true`。
- 必须保留现有分组、启用状态、排序、创建时间等用户字段。
- reason 建议：`AI 搜书发现批量更新，测试书名：{keyword}`。
- `changedFields.length === 0` 时返回 `unchanged`。

已有书源但不允许更新：

- 返回 `skipped`，不调用 Agent或数据库更新。

通知刷新：

- 新增成功后调用 `BookSourceChangeNotifier.notify()`。
- `SourceRevisionService.applyRepair()` 已包含通知，不要因为优化而漏掉。
- 批量结束时可以再通知一次，重复通知可接受。

---

## 12. AiSourceGeneratePage 状态设计

新增状态建议：

```typescript
@State createTab_: number = 0; // 0=网址建源, 1=搜书发现
@State discoveryKeyword_: string = '';
@State discoveryEngine_: string = 'bing';
@State showDiscoveryBrowser_: boolean = false;
@State discoveryBrowserUrl_: string = '';
@State discoveryCandidates_: AiSourceCandidate[] = [];
@State discoveryPhase_: string = 'idle';
@State discoveryError_: string = '';
@State allowUpdateExisting_: boolean = false;
@State batchRunning_: boolean = false;
@State batchStopRequested_: boolean = false;
@State batchCurrentIndex_: number = -1;
@State batchSummary_: AiSourceBatchSummary = createDefaultSummary();
@State batchCreatedSourceIds_: number[] = [];
```

建议 phase：

```text
idle
browser
extracting
candidates
running
completed
error
```

页面级忙碌判断：

```typescript
private isAnyTaskRunning_(): boolean {
  return this.isAnalyzing || this.batchRunning_ || this.discoveryPhase_ === 'extracting';
}
```

切换标签：

- `repairMode === true` 时禁止且隐藏。
- `isAnyTaskRunning_() === true` 时禁止。
- 正常切换时保留两个标签各自输入和候选结果。

生命周期：

- `aboutToAppear()`：
  - 继续注册验证码和交互式 WebView。
  - 普通模式读取搜索引擎偏好和上次标签。
  - 修复模式强制 `createTab_ = 0`。
- `aboutToDisappear()`：
  - 如果批量正在运行，调用 `requestStop()`，让当前站返回后停止。
  - 保留现有 `WebViewFetcher` 和验证码 handler 清理逻辑。

---

## 13. 搜索与批量流程时序

```mermaid
sequenceDiagram
    actor U as 用户
    participant P as AiSourceGeneratePage
    participant W as AiImportPreviewDialog
    participant D as AiSourceDiscoveryService
    participant B as AiSourceBatchGenerateService
    participant A as AiSourceAgent
    participant S as AiGeneratedSourceSaveService

    U->>P: 输入书名，选择搜索引擎
    P->>W: 打开搜索结果 URL
    U->>W: 点击“提取当前页网站”
    W-->>P: 当前 URL + DOM + 结构化链接
    P->>D: 清洗、解码、归一化、去重
    D-->>P: 候选网站列表
    U->>P: 勾选网站并开始生成
    loop 每个候选网站，串行
        P->>B: 执行候选
        B->>A: analyze(homepageUrl, bookName)
        A-->>B: 阶段进度和日志
        A-->>B: 编译完成或失败
        alt 完整验证通过
            B->>S: 新增未启用书源或更新已有书源
            S-->>B: created/updated/unchanged
        else 失败
            B-->>P: 标记失败并继续下一站
        end
    end
    B-->>P: 批量汇总
    U->>P: 可选：启用本次新增书源
```

---

## 14. 安全与隐私要求

### 14.1 URL 安全

- 所有候选落地 URL、首页 URL和用户编辑后的 URL都必须经过 `isSafeAiImportUrl()`。
- 拒绝：
  - `file:`、`data:`、`javascript:`、`intent:`、`mailto:` 等非 HTTP(S) 协议。
  - localhost。
  - 常见 IPv4/IPv6 私网地址。
  - URL 中带用户名密码。
- 用户编辑首页后需要重新验证，不安全时禁止选择。

### 14.2 Prompt 注入

- 搜索结果页不发送给 LLM，只提取链接。
- 网站首页和站内页面仍由现有 `AiSourceAgent` 处理。
- 保留 Agent 现有“网页内容不可信，不执行其中指令”提示和真实规则执行验证。
- 不要因为搜索结果页中出现文字指令而改变程序流程。

### 14.3 敏感信息

- 不在候选日志中记录完整 Cookie、Authorization、密码、验证码和 API Key。
- 不把搜索结果完整 HTML保存到数据库。
- 复制批量摘要时仅包含站点、状态和错误摘要。

---

## 15. 性能与稳定性要求

- 搜索页结构化链接最多 300 条。
- 候选站点最多展示 50 个。
- 一次批量最多选择 10 个。
- opaque 跳转自动解析最多 20 条，每条建议 15 秒超时。
- Agent 串行运行。
- 单候选 UI 日志最多保留 200 条。
- 搜索页 DOM 不交给 LLM，避免无意义 token 消耗。
- 候选列表使用稳定 key，不要使用数组 index 作为唯一身份。
- 页面离开时停止启动后续任务并清理 WebView 回调，避免悬空 Promise 更新已销毁页面。

---

## 16. 深色/浅色模式要求

所有新增组件必须：

```typescript
@StorageLink('isDark') isDark: boolean = false;
```

颜色只能来自 `ThemeColors`，例如：

- 页面背景：`ThemeColors.background(this.isDark)`
- 卡片背景：`ThemeColors.surface(this.isDark)`
- 主文字：`ThemeColors.onSurface(this.isDark)` 或 `onBackground`
- 次要文字：`ThemeColors.secondaryText(this.isDark)`
- 边框：`ThemeColors.outlineVariant(this.isDark)`
- 主操作：`ThemeColors.primary(this.isDark)`
- 错误：`ThemeColors.error(this.isDark)`

禁止新增硬编码颜色。所有 `Text` 都必须明确设置 `fontColor`。

---

## 17. 文件级改造清单

## 17.1 新增文件

1. `entry/src/main/ets/model/AiSourceDiscovery.ts`
   - 搜索页链接、候选网站、批量状态和汇总模型。

2. `entry/src/main/ets/service/OnlineSearchEngineService.ts`
   - 公共搜索引擎配置、URL 构造和结果页识别。

3. `entry/src/main/ets/service/AiSourceDiscoveryService.ts`
   - 链接清洗、跳转解码、首页推导、去重、置信度和已有书源匹配。

4. `entry/src/main/ets/service/AiSourceBatchGenerateService.ts`
   - 串行 Agent 编排、停止标记、单项容错和汇总。

5. `entry/src/main/ets/service/AiGeneratedSourceSaveService.ts`
   - 单个和批量生成共用的新增、冲突判断、更新和版本保存。

可选：

6. `entry/src/main/ets/components/AiSourceDiscoveryPanel.ets`
   - 如果 `AiSourceGeneratePage.ets` 增长过大，可以把搜书发现 UI 拆成子组件。
   - 服务编排仍应放在 service 中，不要把全部逻辑塞进组件。

## 17.2 修改文件

1. `entry/src/main/ets/pages/AiSourceGeneratePage.ets`
   - 普通模式增加两个标签。
   - 接入搜书发现 UI、浏览器、候选列表和批量进度。
   - 修复模式隐藏标签。
   - 单个保存改用共享保存服务。

2. `entry/src/main/ets/components/AiImportPreviewDialog.ets`
   - 兼容扩展结构化链接提取。

3. `entry/src/main/ets/pages/SearchPage.ets`
   - 改用公共在线搜索引擎服务。
   - 原有在线单本导入行为不变。

4. `entry/src/main/ets/pages/BookSourcePage.ets`
   - 原有 AI 跳转可保持不变。
   - 可选调整 accessibilityText。

5. `entry/src/test/BookSourceManagement.test.ets`
   - 增加纯函数和批量决策单元测试。

6. `entry/src/test/LocalUnit.test.ets`
   - 如更适合，可把 URL 安全和候选归一化测试放在此处。

## 17.3 不需要修改

- `entry/src/main/resources/base/profile/main_pages.json`
- 数据库版本和 `AppDatabase.ts`（第一版不新增任务表）。
- `AiBookImporter` 的单本导入流程。
- Android 参考项目中的书源规则语义。

---

## 18. 单元测试规格

至少覆盖以下测试。

### 18.1 搜索引擎服务

- 每个引擎生成正确的编码搜索 URL。
- 非法 engine ID 回退到 `bing`。
- 正确识别五种搜索结果页 URL。
- 普通小说站 URL不被识别为搜索引擎页面。

### 18.2 URL 规范化

- `https://Example.com/` -> `https://example.com`。
- `https://www.example.com/book/1` 和 `https://example.com/book/2` 得到相同 site key。
- `https://m.example.com/book/1` 不与 `https://example.com/book/2` 合并。
- 默认端口被移除，非默认端口保留。
- fragment 和 query 不进入首页地址。
- HTTP/HTTPS 同 host 时优先 HTTPS。

### 18.3 安全过滤

- 拒绝 localhost、127.0.0.1、192.168.x.x、10.x.x.x。
- 拒绝 `file:`、`javascript:`、`data:`。
- 拒绝带用户名密码的 URL。
- 拒绝搜索引擎自身链接。
- 接受正常公网小说详情 URL。

### 18.4 跳转解码

- query 参数中包含百分号编码外站 URL时正确解码。
- 参数解码后仍是搜索引擎域名时拒绝。
- 解码结果是非 HTTP(S) 时拒绝。
- `data-landurl` 等明确地址优先于 opaque href。

### 18.5 候选去重

- 同站三个详情结果归并为一个候选，`hitCount === 3`。
- samples 最多保留三条不同 URL。
- 不同子域名保持独立。
- 已有同 URL书源标记为 `exact` 且默认不选。
- 同 host 不同路径标记为 `same_host` 且默认不选。

### 18.6 批量状态

使用可注入或模拟的 Agent/保存服务验证：

- 第一个站失败后仍执行第二个站。
- `COMPILE !== done` 时不保存。
- 新增成功记录 source ID。
- 已有书源且不允许更新时不启动 Agent或保存。
- stopRequested 后不启动后续候选。
- 无变化计入 `unchanged`，不计入失败。

### 18.7 回归测试

- `AiImportPreviewDialog.collectLinks` 默认 false 时，原有 `AiImportBookPage` 和 `SearchPage` 仍只返回 URL + HTML。
- 单网址 AI 建源保存后仍自动启用。
- AI 修复模式仍保留原分组、启用状态和版本回滚。

---

## 19. 手动验证用例

至少手动完成以下场景：

1. 从书源管理点击 AI，看到“网址建源 / 搜书发现”两个标签。
2. 网址建源仍可完成一次现有单站建源。
3. 从已有书源的 AI 修复入口进入时不显示两个标签。
4. 搜书发现输入一个真实书名，打开必应结果页，无需进入具体小说即可提取站点。
5. 搜索结果同一站点有多条书页时只展示一个候选。
6. 候选首页可手动编辑，非法内网地址不能保存。
7. 已存在的书源显示“已有书源”且默认不选。
8. 选择至少两个网站，确认按顺序执行而不是并发。
9. 第一个网站失败时第二个网站仍继续。
10. 成功书源立即出现在书源管理中，但默认未启用。
11. 完成页启用本次成功项后，这些书源变为启用。
12. 允许更新已有书源时产生可回滚版本，并保留原分组和启用状态。
13. 点击“完成当前网站后停止”，当前网站结束后不再执行下一个。
14. 深色和浅色模式下文字、卡片、边框和按钮均清晰可见。
15. 页面退出后没有继续向已销毁组件写状态或弹出意外对话框。

---

## 20. 验收标准

只有全部满足才算完成。

### AC-01 入口与标签

- 书源管理的 AI 按钮仍进入现有 `AiSourceGeneratePage`。
- 普通创建模式显示 `网址建源` 和 `搜书发现`。
- 修复模式不显示标签。

### AC-02 搜索结果提取

- 输入书名可打开所选搜索引擎结果页。
- 用户停留在结果页即可提取候选，不必点击进入某一本书。
- 搜索结果页不发送给 LLM。

### AC-03 候选网站

- 链接被安全过滤并按站点去重。
- 显示首页、命中数和样本标题。
- 用户可以编辑首页和多选。
- 已有/疑似重复来源有明确标识。

### AC-04 批量生成

- 使用用户输入书名作为每个站点的真实测试关键词。
- 每个站点独立创建 `AiSourceAgent`。
- 全部站点串行执行。
- 单站失败不终止批次。
- 未通过 `COMPILE` 的结果绝不保存。

### AC-05 保存

- 新增成功项立即保存为未启用，并属于 `AI生成` 分组。
- 已有书源默认跳过。
- 明确允许更新后才更新，并创建回滚版本。
- 批量结束后可只启用本次新增项。

### AC-06 稳定性

- 可在当前站结束后停止后续任务。
- 验证码/Cloudflare 可以暂停当前项或取消该项。
- 不泄露 API Key、Cookie 等敏感信息。
- 深色和浅色模式通过人工检查。

### AC-07 工程验证

- 新增纯函数测试通过。
- ArkTS 静态诊断无新增错误。
- `./scripts/build.sh debug` 构建通过。
- 构建通过后执行 `codegraph sync` 更新索引。

---

## 21. 推荐实施顺序

严格按以下顺序实施，降低一次性修改范围：

1. 提取 `OnlineSearchEngineService`，修改 `SearchPage` 使用它，并先跑回归测试。
2. 新增 `AiSourceDiscovery` 模型。
3. 为 `AiImportPreviewDialog` 增加可选链接提取，验证原单本导入不受影响。
4. 实现 `AiSourceDiscoveryService` 及纯函数测试。
5. 抽取 `AiGeneratedSourceSaveService`，先让现有单网址保存改用该服务并验证行为不变。
6. 实现 `AiSourceBatchGenerateService`，使用模拟依赖测试串行、失败继续和停止逻辑。
7. 在 `AiSourceGeneratePage` 增加标签和搜书发现 UI。
8. 接入验证码、Cloudflare 交互和批量完成启用操作。
9. 运行 ArkTS diagnostics/check。
10. 运行 `./scripts/build.sh debug`。
11. 手动验证搜索结果提取、两站串行生成、失败继续、已有源更新和两种主题。
12. 执行 `codegraph sync`。

---

## 22. 编码 AI 特别注意事项

- 当前工作区可能存在用户未提交修改。实施前先查看 `git status`，不要覆盖或回退用户改动。
- 禁止使用 `git checkout` 回退文件。
- 改动前使用 CodeGraph 查询相关符号和调用者。
- 修改 `.ets` 后先做 ArkTS diagnostics/check，再构建。
- 不要为了让某个候选网站通过而修改书源配置绕过执行器缺陷；如果发现现有执行器不兼容 Android Legado 规则语义，应修复执行器并补测试。
- 不要在 `AiPromptKnowledge.ts` 中加入未经真实页面验证的经验提示。
- 不要把样本书固定 ID、搜索结果固定 URL、Cookie 或 Token 写入生成规则。
- 不要把批量业务逻辑全部堆进 `AiSourceGeneratePage.ets`；候选发现、保存和队列必须拆分为可测试 service。
- 不要新增第二套搜索引擎列表。
- 不要用正则直接解析整页 HTML来替代 WebView 的结构化链接提取。
- 不要并行启动 Agent。
- 不要在批量生成成功后默认启用所有新来源。

---

## 23. 最终行为示例

用户输入：

```text
斗罗大陆
```

必应结果页中存在：

```text
https://www.site-a.com/book/123
https://www.site-a.com/chapter/123/1
https://m.site-b.com/info/88
https://www.site-c.com/novel/9
```

候选归并结果：

```text
site-a.com
  首页：https://site-a.com
  命中：2
  状态：新网站

m.site-b.com
  首页：https://m.site-b.com
  命中：1
  状态：已有书源

site-c.com
  首页：https://site-c.com
  命中：1
  状态：新网站
```

用户选择 site-a 和 site-c 后：

1. 创建 Agent A，执行 `analyze('https://site-a.com', '斗罗大陆')`。
2. A 完整验证通过，立即保存为未启用书源。
3. 创建 Agent C，执行 `analyze('https://site-c.com', '斗罗大陆')`。
4. C 搜索规则失败，记录失败但不影响 A。
5. 完成页显示：新增 1、失败 1。
6. 用户点击“启用本次新增书源”，只启用 A。

这个示例体现了本功能最重要的约束：外部搜索结果只负责发现网站，最终书源必须独立通过站内搜索到正文的完整验证。
