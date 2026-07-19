# LegadoHOS — 需求说明书（v2.0）

> 鸿蒙原生开源阅读 App，基于 ArkTS（ArkUI）开发，兼容 Legado（阅读）书源生态。
> 目标：提供与 Android 版 Legado 功能对等的鸿蒙阅读体验。
>
> **编写目的**：便于 AI / 后续开发者快速理解已实现的功能范围、设计取舍和待完善项。
> **更新日期**：2026-07-19（补充发现书→在线搜索/URL→AI 单书导入→阅读/缓存/刷新的端到端闭环）

---

## 1. 应用总览

| 条目 | 内容 |
|------|------|
| 应用名称 | LegadoHOS（鸿蒙版 Legado 阅读器） |
| 开发框架 | HarmonyOS ArkTS + ArkUI |
| 目标设备 | Phone / Tablet |
| 最低 API | API 9+（兼容 API 12 推荐方式；真机需 API 12+ 启动 WebView 兜底） |
| 包名 / module | `entry` |
| 数据库 | RDB（`@ohos.data.relationalStore`，18 张核心表，含 AI 单书解析档案） |
| JS 引擎 | QuickJS（通过 NAPI 桥接，支持降级 Mock） |
| 书源格式 | 兼容 Legado 书源 JSON（规则式 + JS 脚本式） |

---

## 2. 已实现功能清单

### 2.1 书架（BookshelfPage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-001 | 书架列表展示 | ✅ 完成 | 展示书名、作者、封面色块、阅读进度条、最近阅读时间 |
| R-002 | 按最后阅读时间排序 | ✅ 完成 | 最近阅读的书籍排在前面 |
| R-003 | 空书架状态 | ✅ 完成 | 显示"书架是空的"占位提示 |
| R-004 | 点击继续阅读 | ✅ 完成 | 跳转到 ReadPage，传入当前阅读进度 |
| R-005 | 移除书籍 | ✅ 完成 | 长按弹出对话框确认后移除 |
| R-006 | 封面颜色映射 | ✅ 完成 | 书名首字哈希映射到 12 种预设颜色 |
| R-007 | 书籍数量统计 | ✅ 完成 | 顶部显示"N本" |
| R-008 | 分组标签切换 | ✅ 完成 | 系统分组（全部/未分组/本地）+自定义分组标签 |
| R-009 | 书架配置 | ✅ 完成 | 封面/进度/时间等显示开关（BookshelfConfigDialog） |

### 2.2 发现 / 搜索（ExplorePage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-010 | 关键词搜索 | ✅ 完成 | TextInput 输入 + 搜索按钮 |
| R-011 | 多书源并发搜索 | ✅ 完成 | 可配置并发数（默认 16），每搜完一个源实时增量合并结果 |
| R-012 | 搜索结果去重合并 | ✅ 完成 | 同名+同作者视为同一本书，多源结果合并，显示来源计数 |
| R-013 | 搜索结果来源徽标 | ✅ 完成 | 显示"N个源"标签，点击 Toast 展示具体来源列表 |
| R-014 | 搜索结果默认兜底 | ✅ 完成 | SourceExecutor 无结果时降级到旧版 SearchEngine |
| R-015 | Cloudflare 检测与 WebView | ✅ 完成 | 403 检测后提供"浏览器模式"兜底（WebViewFetchDialog） |
| R-016 | 搜索结果点击 | ✅ 完成 | 跳转到 BookInfoPage 查看详情 |
| R-017 | 搜索进度提示 | ✅ 完成 | 显示"搜索中... | 已合并 N 条" |
| R-018 | 搜索无结果状态 | ✅ 完成 | 显示"没有找到结果"占位 |
| R-019 | 书源加载计数 | ✅ 完成 | 底部显示"已加载 N 个书源" |
| R-019a | 搜索历史 | ✅ 完成 | 搜索关键词记录（SearchKeywordTable） |
| R-019b | 发现书单 | ✅ 完成 | ExploreBookPage 按分类/排行榜浏览 |
| R-019c | 搜索模式整合 | ✅ 完成 | 书架统一搜索页提供“书源/在线”两个标签，不为在线导入设置独立主入口 |
| R-019d | 发现书搜索方式选择 | ✅ 完成 | 优书、龙空点击发现书后选择书源搜索或在线搜索，跳转对应标签并带入书名/作者 |
| R-019e | 在线搜索引擎 | ✅ 完成 | 必应（默认）、百度、搜狗、神马、Google 下拉选择，记住最后选择 |
| R-019f | 在线搜索 WebView | ✅ 完成 | 通过 WebView 展示搜索结果，用户进入具体书页后确认导入当前页 |
| R-019g | 直接 URL 导入入口 | ✅ 完成 | 在线标签保留公网 HTTP(S) URL 输入，与搜索结果复用相同预览和导入流程 |
| R-019h | 搜索历史交互 | ✅ 完成 | 最近 30 条；仅输入聚焦时展开，预览/分析时收起并清焦点，避免遮挡导入结果 |
| R-019i | WebView 导航与页面模式 | ✅ 完成 | 后退/前进/刷新/桌面或移动切换，默认桌面模式并持久化 |
| R-019j | 人工确认门禁 | ✅ 完成 | 取消不写入；搜索结果页不可直接导入；确认时提交当前 URL 与渲染后 HTML |

### 2.3 书籍详情（BookInfoPage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-020 | 书籍信息展示 | ✅ 完成 | 书名、作者、封面、分类、字数、简介 |
| R-021 | 加入/移出书架 | ✅ 完成 | 按钮切换，同步更新数据库 |
| R-022 | 开始阅读 | ✅ 完成 | 跳转 ReadPage，自动获取目录和正文 |
| R-023 | 查看目录 | ✅ 完成 | 展开目录列表，点击跳转章节 |
| R-024 | 书源切换 | ✅ 完成 | 查看其他可用的书源（ChangeSourceSheet） |

### 2.4 阅读（ReadPage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-030 | 正文加载 | ✅ 完成 | 基于书源规则或直连获取正文 |
| R-031 | 目录获取 | ✅ 完成 | 支持 CSS/XPath/正则/JSON 规则解析目录 |
| R-032 | 目录反转自动检测 | ✅ 完成 | 检测最新章在前的情况，自动反转列表 |
| R-033 | 定位第一章 | ✅ 完成 | 自动跳过引言/公告定位首个真实章节 |
| R-034 | 上一章/下一章 | ✅ 完成 | 底部翻页按钮 / 滑动手势 |
| R-035 | 目录弹窗 | ✅ 完成 | 侧滑目录列表，高亮当前章节，点击跳转 |
| R-036 | 阅读设置面板 | ✅ 完成 | 字体大小（14-32）、行高（24-52）、背景色切换（StylePanel） |
| R-037 | 深色阅读背景 | ✅ 完成 | 提供暗色背景切换 |
| R-038 | 阅读进度自动保存 | ✅ 完成 | 换章时保存到数据库（章节索引、标题、最新章节） |
| R-039 | 正文内容兜底清理 | ✅ 完成 | 无规则时使用 HtmlUtil.stripHtml 清理 HTML 标签 |
| R-039a | 分页翻页（PageView） | ✅ 完成 | 文本分页排版、翻页动画（滑动/覆盖/无） |
| R-039b | 点击区域配置 | ✅ 完成 | 上/中/下三区自定义动作（菜单/翻页前/翻页后/无） |
| R-039c | 底部阅读菜单 | ✅ 完成 | 目录/夜间模式/设置/朗读/缓存/换源 |
| R-039d | 章节缓存管理 | ✅ 完成 | 查看/预缓存章节（CacheDialog） |
| R-039e | 繁简转换 | ✅ 完成 | 阅读内容简繁体转换（ChineseConverter） |
| R-039f | 阅读换源 | ✅ 完成 | 阅读中切换其他书源查看同一章节 |
| R-039g | 滚动阅读模式 | ✅ 完成 | 全文连续滚动，onReachStart/End 自动加载章节 |
| R-039h | 内容替换规则实时应用 | ✅ 完成 | 阅读时应用 ReplaceRule 替换正则 |
| R-039i | 绑定选择菜单 | ✅ 完成 | 阅读页文字选中弹出自定义菜单（复制/问Kimi/问小艺） |

### 2.5 书源管理（BookSourcePage / ImportSourceDialog）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-040 | 书源列表展示 | ✅ 完成 | 显示书源名称、网址、启用状态、权重 |
| R-041 | 书源导入 | ✅ 完成 | 支持 URL 导入和 JSON 文本导入 |
| R-042 | 书源启用/禁用 | ✅ 完成 | 开关控制 |
| R-043 | 书源 JSON 解析 | ✅ 完成 | 兼容 Legado 书源 JSON 格式的多种字段命名 |
| R-044 | 规则字段序列化 | ✅ 完成 | 支持字符串/JSON 对象/JSON 数组三种规则格式 |
| R-045 | 书源编辑 | ✅ 完成 | BookSourceEditPage 编辑搜索/详情/目录/正文规则 |
| R-046 | 书源校验 | ✅ 完成 | SourceChecker 搜索/发现/详情/目录/正文多步校验 |

### 2.6 我的 / 设置（MyPage / SettingsPage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-050 | 个人信息页面 | ✅ 完成 | "我的"Tab 页 |
| R-051 | 应用设置 | ✅ 完成 | 基本设置入口 |
| R-052 | 书源管理入口 | ✅ 完成 | 跳转到书源管理页 |
| R-053 | Web 服务入口 | ✅ 完成 | 启动/关闭 HTTP 服务 |
| R-054 | 深色主题切换 | ✅ 完成 | 跟随系统或手动切换 |
| R-055 | 关于页面 | ✅ 完成 | 版本信息等 |
| R-055a | 备份与恢复页面 | ✅ 完成 | BackupSettingsPage 支持本地/WebDAV 备份恢复 |
| R-055b | 字体管理 | ✅ 完成 | FontManagerPage 导入/预览/删除自定义字体 |

### 2.7 本地书籍解析

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-060 | TXT 解析（TxtParser） | ✅ 完成 | 支持章节分割、编码检测、大文件分页读取 |
| R-061 | EPUB 解析（DirEpubParser + EpubJsParser） | ✅ 完成 | 双引擎：DirEpubParser 解析 OPF/NCX + EpubJsParser/EpubParserWebView 调用 EPUB.js |
| R-062 | MOBI/AZW/AZW3 图文阅读（MobiParser + MobiProbeParser） | ✅ 完成 | 轻量 PDB/MOBI/EXTH 导入探测；foliate-js 解析 KF6/KF8、HUFF/CDIC；Range 随机读取；拒绝 DRM/KFX |
| R-063 | PDF 解析与阅读（PdfParser + 原生 WebView） | ✅ 完成 | 元数据提取、目录结构、横竖屏切换、裁边显示、双页模式（WebView 加载 PDF） |
| R-064 | 本地书籍导入引擎 | ✅ 完成 | LocalBookEngine 统一导入 TXT/EPUB/MOBI/PDF，TaskPool 并发解压 EPUB |

### 2.8 书源引擎（SourceExecutor / ScriptEngine）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-070 | HTTP 网络请求 | ✅ 完成 | 封装 `@ohos.net.http`，支持 GET/POST/PUT |
| R-071 | 规则解析（RuleParser） | ✅ 完成 | 支持 JSONPath / CSS 选择器 / XPath / 正则 |
| R-072 | QuickJS 引擎集成 | ✅ 完成 | NAPI 桥接，支持 JS 书源脚本执行 |
| R-073 | JS polyfill 注入 | ✅ 完成 | ScriptApi.ts 1073 行 polyfill（MD5/Base64/AES/时间格式化） |
| R-074 | HTTP 请求委托 | ✅ 完成 | JS 侧请求由 ArkTS 侧实际发起，避免 NAPI 死锁 |
| R-075 | 引擎降级 | ✅ 完成 | 原生 QuickJS 不可用时降级为 Mock（直接解析） |
| R-076 | 模板 URL 构建 | ✅ 完成 | 支持 {{key}}、{{page}}、{{bookUrl}} 等占位符替换 |
| R-077 | 自定义请求头 | ✅ 完成 | 书源 JSON 中的 header 字段支持 |
| R-078 | JSON 搜索结果解析 | ✅ 完成 | 直接 JSON 解析 + 字段映射 |
| R-079 | HTML 搜索结果解析 | ✅ 完成 | 规则解析 + 兜底文本提取 |
| R-080 | HTML 目录提取安全兜底 | ✅ 完成 | 多层模式匹配 + 导航链接过滤 + "最近更新"分段过滤 |
| R-081 | 正文内容规则提取 | ✅ 完成 | ruleBookContent 支持 |
| R-082 | 书源脚本标准接口 | ✅ 完成 | search() / getBookInfo() / getToc() / getContent() |
| R-083 | 并发搜索池 | ✅ 完成 | 固定并发数，逐个启动，每完成一个触发回调 |
| R-084 | JSONPath 简化实现 | ✅ 完成 | $.list[*].name 路径导航 |

### 2.9 引擎子模块

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-090 | 发现页引擎（ExploreEngine） | ✅ 完成 | 发现页模块 / 规则项管理 |
| R-091 | 书源切换器（SourceSwitcher） | ✅ 完成 | 源间章节比较、切换选择（SourceSwitchStore 持久化） |
| R-092 | 缓存管理（CacheManager） | ✅ 完成 | 章节缓存读写、过期清理 |
| R-093 | 内容替换引擎（ContentReplace） | ✅ 完成 | 正则替换规则，支持作用域和排序 |
| R-094 | 章节管理器（ChapterManager） | ✅ 完成 | 预加载、并发下载、排序 |
| R-095 | 文字排版引擎（TextLayout） | ✅ 完成 | 分页/分行布局计算（基于 MeasureText） |
| R-096 | 翻译引擎（TranslationEngine） | ✅ 完成 | 多翻译提供商接口（Google/DeepL/Baidu 等） |
| R-097 | WebView 取内容（WebViewFetcher） | ✅ 完成 | Cloudflare 保护站点 WebView 兜底，支持 cookie 注入 |
| R-098 | JS 表达式求值（JsExpressionEvaluator） | ✅ 完成 | 规则 URL 中 @js: 表达式独立计算 |
| R-099 | Worker JS 执行（JsEvalWorker） | ✅ 完成 | 独立线程执行 JS 规则（RSS 排序等） |

### 2.10 音频 / TTS

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-100 | TTS 朗读（TTSPlayer） | ✅ 完成 | 章节朗读、暂停、继续、停止 |
| R-101 | 音频播放器（AudioPlayer） | ✅ 完成 | 有声书播放，支持暂停/继续/seek |
| R-102 | 播放列表管理（PlaylistManager） | ✅ 完成 | 顺序/循环/随机/单曲循环 |
| R-103 | 阅读定时器（ReadTimer） | ✅ 完成 | 定时关闭（15/30/45/60/90 分钟） |
| R-104 | 朗读面板（ReadAloudPanel） | ✅ 完成 | 阅读页朗读控制面板（511 行），暂停/继续/语速/音色 |
| R-105 | 朗读引擎（ReadAloudEngine） | ✅ 完成 | 后台朗读引擎（352 行），状态管理（播放/暂停/停止/完成） |
| R-106 | TTS 控制面板（TtsControlPanel） | ✅ 完成 | 语速/音色配置浮层 |
| R-107 | TTS 双后端架构 | ✅ 完成 | ITtsBackend 接口，系统 TTS + sherpa-onnx + Azure TTS 三种后端 |
| R-108 | sherpa-onnx 离线 TTS | ✅ 完成 | SherpaOnnxTtsBackend，Kokoro 多音色，102 种音色，模型需下载 ~215MB |
| R-109 | 文本规范化（TextNormalizer） | ✅ 完成 | 数字/日期/标点的中文朗读优化 |
| R-110 | TTS 模型管理（TtsModelManager） | ✅ 完成 | 模型下载/校验/解压/版本管理 |

### 2.11 服务

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-111 | 备份/恢复（BackupService） | ✅ 完成 | 导出/导入书架、书源、替换规则、RSS、设置 |
| R-112 | WebDAV 同步（WebDavService） | ✅ 完成 | 远程备份/同步到 WebDAV 服务器 |
| R-113 | 下载管理（DownloadService） | ✅ 完成 | 章节批量下载，断点续传，队列管理 |
| R-114 | 朗读服务（ReadAloudService） | ✅ 完成 | 后台朗读服务（RemoteObject，支持跨 Ability 通信） |
| R-115 | Web 服务（WebService） | ✅ 完成 | HTTP 服务器，提供阅读内容远程访问 |
| R-116 | 控制器服务（ControllerService） | ✅ 完成 | 全局播放控制、通知管理 |
| R-117 | 书架传输服务（BookshelfTransferService） | ✅ 完成 | 导入时自动匹配书源、下载目录、upsert 书籍 |

### 2.12 书架管理（BookshelfManagePage）

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-120 | 批量选择 | ✅ 完成 | 多选模式，全选/取消全选 |
| R-121 | 分组筛选 | ✅ 完成 | 系统分组 + 自定义分组下拉筛选 |
| R-122 | 搜索过滤 | ✅ 完成 | 书名/作者关键字过滤 |
| R-123 | 导出书架 | ✅ 完成 | 导出为 JSON 文件 |
| R-124 | 导入书架 | ✅ 完成 | 从 JSON 文件导入，自动匹配书源 |
| R-125 | 批量移动分组 | ✅ 完成 | 选中书籍移动到指定分组 |
| R-126 | 批量删除 | ✅ 完成 | 选中书籍从书架移除 |
| R-127 | 分组管理 | ✅ 完成 | GroupManageDialog 新建/编辑/删除自定义分组 |
| R-128 | URL 添加书籍 | ✅ 完成 | AddBookUrlDialog 输入书源 URL 或详情页 URL |

### 2.13 主题

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-130 | 主题管理（AppTheme） | ✅ 完成 | 全局单例，亮/暗主题切换 |
| R-131 | 色彩方案（ColorScheme） | ✅ 完成 | MD3 配色体系，支持自定义 |
| R-132 | 主题模式（ThemeMode） | ✅ 完成 | 亮色/暗色/跟随系统，预设色板 |
| R-133 | 设置持久化 | ✅ 完成 | 主题选择保存到 Preferences |

### 2.14 工具类

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-140 | HTML 解析（HtmlParser） | ✅ 完成 | 951 行自研解析器，支持 CSS/Default 规则、位置索引、排除索引、属性选择器、伪类 |
| R-141 | HTML 清理（HtmlUtil） | ✅ 完成 | 标签剥离、实体解码、纯文本提取 |
| R-142 | 网络请求（NetUtil） | ✅ 完成 | HTTP(S) GET/POST/PUT，超时控制、UA/编码检测 |
| R-143 | 文件操作（FileUtil） | ✅ 完成 | 文件读写、目录管理、路径工具 |
| R-144 | 字符串处理（StrUtil） | ✅ 完成 | 相似度计算（Levenshtein/Cosine）、格式校验 |
| R-145 | 加密工具（CryptoUtil） | ✅ 完成 | MD5/SHA1/SHA256/Base64 |
| R-146 | ZIP 解压（@ohos.zlib） | ✅ 完成 | EPUB 导入、备份恢复均使用系统 zlib 解压 |
| R-147 | 封面生成（BookCoverUtil） | ✅ 完成 | 文字封面 Canvas 生成，颜色映射 |
| R-148 | 繁简转换（ChineseConverter） | ✅ 完成 | 简繁双向转换（OpenCC 兼容词表，260 行） |
| R-149 | 内容缓存（ContentCache） | ✅ 完成 | 章节内容内存缓存 |
| R-150 | 内容清理（ContentCleaner） | ✅ 完成 | 广告/脚本/空行清理（248 行） |
| R-151 | 章节缓存（ChapterCache） | ✅ 完成 | 章节内容缓存助手 |
| R-152 | 源切换存储（SourceSwitchStore） | ✅ 完成 | 换源结果持久化 |
| R-153 | 应用上下文（AppContext） | ✅ 完成 | 全局 Context 单例 |

### 2.15 数据库

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-160 | RDB 初始化（AppDatabase） | ✅ 完成 | 懒加载单例，核心表幂等建表 + 迁移（现有 18 张） |
| R-161 | BookTable | ✅ 完成 | 书籍 CRUD + 书架查询 + 进度保存 + 分组字段 |
| R-162 | ChapterTable | ✅ 完成 | 章节 CRUD |
| R-163 | BookSourceTable | ✅ 完成 | 书源 CRUD + 启用查询 + 权重排序 |
| R-164 | BookSourcesCacheTable | ✅ 完成 | 书源搜索结果缓存 |
| R-165 | BookmarkTable | ✅ 完成 | 书签 CRUD |
| R-166 | ReadRecordTable | ✅ 完成 | 阅读记录 + 详情（2 张表：read_records + read_record_details） |
| R-167 | ReplaceRuleTable | ✅ 完成 | 替换规则 CRUD |
| R-168 | RSSSourceTable | ✅ 完成 | RSS 源 + 文章 + 星标 + 阅读记录（4 张表） |
| R-169 | CacheTable | ✅ 完成 | 章节缓存 + TXT 目录规则（2 张表：caches + txt_toc_rules） |
| R-170 | SearchResultTable | ✅ 完成 | 搜索结果缓存 |
| R-171 | BookGroupTable | ✅ 完成 | 书架分组 CRUD |
| R-172 | SearchKeywordTable | ✅ 完成 | 搜索历史记录 |
| R-173 | 数据库迁移 | ✅ 完成 | ALTER TABLE 添加列 + 新表创建（幂等处理） |
| R-174 | AiBookProfileTable | ✅ 完成 | AI 单书解析档案；保存详情/目录 URL、规则快照、刷新状态和规则版本 |

### 2.16 窗口小部件

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-180 | 最近阅读 Widget | ✅ 完成 | 桌面小部件显示最近阅读 |
| R-181 | 搜索 Widget | ✅ 完成 | 桌面快捷搜索 |

### 2.17 RSS 订阅

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-190 | RSS 主页（RssMainPage） | ✅ 完成 | 显示已订阅源列表，下拉刷新，管理入口 |
| R-191 | RSS 文章列表（RssArticlesPage） | ✅ 完成 | 文章列表，按源/收藏/搜索过滤 |
| R-192 | RSS 文章阅读（RssReadPage） | ✅ 完成 | 文章内容展示（309 行），WebView 渲染 |
| R-193 | RSS 收藏（RssFavoritesPage） | ✅ 完成 | 星标文章列表（285 行），取消收藏 |
| R-194 | RSS 排序规则（RssSortPage） | ✅ 完成 | 自定义排序 URL 管理（442 行），JS 规则执行 |
| R-195 | RSS 源管理（RssSourceManagePage） | ✅ 完成 | 启用/禁用/编辑/删除 RSS 源 |
| R-196 | RSS 源编辑（RssSourceEditPage） | ✅ 完成 | 编辑源名称/URL/分组/规则（229 行） |
| R-197 | RSS 导入（RssImportDialog） | ✅ 完成 | URL/JSON 导入 RSS 源 |
| R-198 | RSS 解析引擎（RssService） | ✅ 完成 | 默认 RSS 解析 + 规则式解析（270 行） |
| R-199 | 规则式 RSS 解析（RssParserByRule） | ✅ 完成 | 基于 Legado 规则的 RSS 文章提取（399 行） |
| R-199a | 默认 RSS 解析（RssParserDefault） | ✅ 完成 | 标准 RSS/Atom feed 解析 |
| R-199b | RSS 导入模型（RSSImport） | ✅ 完成 | Legado 备份格式 RSS 数据解析 |

### 2.18 AI 书源生成与在线单书导入

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-200 | AI 配置（AiConfigPage） | ✅ 完成 | API 端点/密钥/模型配置 |
| R-201 | AI 源生成（AiSourceGeneratePage） | ✅ 完成 | 多步 UI 引导生成书源（221 行） |
| R-202 | AI 生成引擎（AiSourceAgent） | ✅ 完成 | 6 步 LLM 驱动分析（382 行）：首页→搜索→详情→目录→正文→汇总 |
| R-203 | WebView 兜底 | ✅ 完成 | AI 生成时 Cloudflare 站点走 WebView 渲染 |
| R-204 | AI 智能导入交互 | ✅ 完成 | 主入口整合在 SearchPage：在线搜索/直接 URL→WebView 预览确认→分析→缓存选择 |
| R-205 | AI 书籍导入引擎（AiBookImporter） | ✅ 完成 | 抓取/渲染→元数据→完整目录→正文规则实测→原子保存书籍、目录和单书档案 |
| R-206 | 单书档案而非全局书源 | ✅ 完成 | 导入一本书不新增 BookSource；临时解析器序列化到 AiBookProfile，由 BookSourceResolver 统一解析 |
| R-207 | 书籍元数据提取 | ✅ 完成 | 确定性规则优先、AI 补充，提取书名/作者/封面/简介/字数/分类/更新时间 |
| R-208 | 完整目录发现 | ✅ 完成 | 识别“全部章节”二级入口、显式下一页和 option 页码，最多跟进 60 页 |
| R-209 | 目录归一化 | ✅ 完成 | 剔除页首最近章节摘要、按章节 URL 去重、纠正明显倒序、重建连续索引 |
| R-209a | 正文规则验证 | ✅ 完成 | 最多用 3 个真实章节样本分析并调用 SourceExecutor 实测，失败不落库 |
| R-209b | 导入后缓存选择 | ✅ 完成 | 默认只落目录；可稍后按需缓存，或确认后立即创建整书后台缓存任务 |
| R-209c | 连载刷新 | ✅ 完成 | 保存详情/目录/章节 URL 与规则快照；书架刷新保留已有正文、已读和缓存状态 |
| R-209d | 安全与误跳防护 | ✅ 完成 | 拒绝内网 URL，忽略网页提示注入，校验广告/异书跳转并通过 HTTP/WebView 有限重试 |

端到端详细需求、数据语义、异常恢复和验收标准见 [`doc/modules/online_book.md`](modules/online_book.md)。

### 2.19 Web 取内容

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-210 | Web 取内容页（WebFetchPage） | ✅ 完成 | 手动 WebView 获取页面内容 |
| R-211 | WebView 取内容对话框 | ✅ 完成 | Cloudflare 检测后弹出 WebView 获取内容（WebViewFetchDialog） |
| R-212 | WebView 引擎组件 | ✅ 完成 | 可复用 WebView 组件（WebViewEngine） |

### 2.20 辅助页面

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-220 | 搜索主页（SearchPage） | ✅ 完成 | 全局搜索入口 |
| R-221 | 错误页面（ErrorPage） | ✅ 完成 | 错误提示页 |
| R-222 | 简版阅读页（SimplePage） | ✅ 完成 | 纯文本阅读视图 |
| R-223 | 书签页面（BookmarkPage） | ✅ 完成 | 书签列表管理 |
| R-224 | 阅读记录（ReadRecordPage） | ✅ 完成 | 阅读历史记录 |
| R-225 | 换源页（ChangeSourcePage） | ✅ 完成 | 搜索其他书源 |
| R-226 | 章节列表（ChapterListPage） | ✅ 完成 | 全章节目录列表 |
| R-227 | 规则订阅页（RuleSubPage） | ✅ 完成 | 书源规则远程订阅管理 |
| R-228 | 书内搜索（SearchContentPage） | ✅ 完成 | 阅读页内搜索关键词，支持正则/替换/历史范围 |
| R-229 | 备份设置页（BackupSettingsPage） | ✅ 完成 | 本地/WebDAV 备份恢复配置 |
| R-230 | 字体管理页（FontManagerPage） | ✅ 完成 | 导入/预览/删除自定义 .ttf/.otf 字体 |

### 2.22 QuickJS NAPI 桥接

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-231 | 多方式加载 | ✅ 完成 | `import('libquickjs_bridge.so')` / `requireNapi('quickjs_bridge')` / Mock 降级 |
| R-232 | 引擎生命周期管理 | ✅ 完成 | createEngine / destroyEngine |
| R-233 | JS 脚本执行 | ✅ 完成 | executeScript |
| R-234 | JS 函数调用 | ✅ 完成 | callFunction（传参/返回 JSON 字符串） |
| R-235 | HTTP 请求委托 | ✅ 完成 | registerHttpHandler / onHttpResponse |
| R-236 | 原生 C++ 实现 | ✅ 完成 | libraries/quickjs/src/napi_bridge.cpp |

---

## 3. 未实现 / 部分实现功能

| # | 需求 | 状态 | 说明 |
|---|------|------|------|
| R-300 | 漫画阅读完整实现 | ✅ 完成 | ComicReadPage 支持四种阅读模式、缩放手势、图片缓存、自动阅读 |
| R-301 | PDF 渲染 | ✅ 完成 | WebView 加载 PDF，支持横竖屏/裁边/双页/翻页 |
| R-302 | MOBI 图文混排阅读 | ✅ 完成 | foliate-js 集成，支持 KF6/KF8 格式 |
| R-303 | 有声书完整支持 | ⚠️ 部分 | AudioPlayer 引擎就绪，UI 层待接入 |
| R-304 | 多设备阅读进度同步 | 📋 规划 | WebDAV 已有，设备间自动同步待完成 |
| R-305 | Web 远程管理完善 | ⚠️ 部分 | WebServer 路由就绪，监听功能需启用 |
| R-306 | 漫画本地文件导入 | 📋 规划 | 本地 CBZ/CBR 文件导入 UI 未实现 |

---

## 4. 兼容性要求

- 书源格式：完全兼容 Legado 书源 JSON（字段名双兼容 `ruleSearchUrl` / `searchUrl` 等）
- JS 书源脚本：兼容 `search()` / `getBookInfo()` / `getToc()` / `getContent()` 标准接口
- 备份格式：兼容 Legado 备份 JSON 格式
- 规则语法：支持 JSONPath / CSS 选择器 / XPath / 正则表达式四种规则类型
- HarmonyOS API：兼容 API 9+，推荐 API 12（NAPI 原生模块加载方式）
- RSS 源格式：兼容标准 RSS 2.0 / Atom feed，兼容 Legado RSS 源 JSON 格式

---

## 5. 性能需求

| # | 需求 | 说明 |
|---|------|------|
| P-001 | 并发搜索控制 | 默认 16 并发，可配置 |
| P-002 | 数据库懒加载 | AppDatabase 使用 Promise 懒初始化，页面在 aboutToAppear 中 await |
| P-003 | 大文件分页读取 | TXTParser 支持大文件分段读取 |
| P-004 | 搜索结果增量更新 | 每完成一个书源即触发 UI 更新（setInterval 轮询），避免全部完成才显示 |
| P-005 | HTTP 超时配置 | 默认 30 秒，可配置 |
| P-006 | WebView 资源管理 | WebViewFetcher 使用后自动清理，防内存泄漏 |
| P-007 | 在线导入目录边界 | 目录最多 60 页；已知页码最多 5 路并发，按页面顺序合并 |
| P-008 | AI 上下文控制 | 目录 HTML 最多约 40,000 字符，正文 HTML 最多约 30,000 字符；正文最多尝试 3 章样本 |

---

## 6. 约束

- 不使用第三方依赖库（HarmonyOS 纯原生开发）
- 纯 ArkTS + C++（QuickJS 原生模块）
- API 9 最低兼容，API 12 新特性（NAPI 动态加载）可选
- HTML 解析为自研 HtmlParser（951 行），不依赖 Jsoup 等库
- 书源规则标准化模块 `normalizeCssRule` 处理 Legado → 标准 CSS 转换
