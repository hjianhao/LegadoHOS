# 漫画阅读模块

> 漫画书源规则解析与漫画阅读器功能设计文档。
> 对标安卓 Legado 的 `ReadMangaActivity` + `ReadManga` + `MangaAdapter` 等模块。

## 1. 功能概述

LegadoHOS 漫画阅读模块支持图片型书源（`bookSourceType=2`）的漫画阅读，包括：
- 漫画书源类型识别与路由分流
- 漫画正文图片 URL 提取
- 带防盗链请求头的图片下载与本地缓存
- 三种阅读方向 + 单页全屏模式
- 双指缩放、拖动平移、双击定位缩放
- 9 宫格触控区域配置
- 章节导航、进度保存、换源
- 自动阅读、长按保存图片、沉浸式阅读

## 2. 书源类型识别

### 2.1 BookSourceType 枚举

定义于 `model/BookSource.ts`：

```typescript
export enum BookSourceType {
  TEXT = 0,    // 文本
  AUDIO = 1,   // 音频
  IMAGE = 2,   // 图片/漫画
  FILE = 3,    // 文件
}
```

### 2.2 parseBookSource 修复

Legado 书源 JSON 使用 `bookSourceType` 字段标识书源类型。`parseBookSource` 函数优先读取 `json.bookSourceType`：

```typescript
sourceType: json.bookSourceType ?? json.sourceType ?? 0,
```

同时修复了 `ruleBookContentImageStyle` 和 `ruleBookContentImageDecode` 的嵌套格式解析（兼容 `ruleContent.imageStyle` / `ruleContent.imageDecode`）。

### 2.3 路由分流

| 入口 | 判断条件 | 目标页面 |
|------|----------|----------|
| `BookshelfPage.continueRead` | `book.isManga` | `pages/ComicReadPage` |
| `BookInfoPage.startRead` | `sourceType === 2`（异步 `ensureMangaFlag_`） | `pages/ComicReadPage` |
| `BookInfoPage.startReadAt` | `sourceType === 2` | `pages/ComicReadPage` |
| `SearchPage.addPreviewToShelf` | 查询书源 `sourceType === 2` | 设置 `isManga: true` |

### 2.4 书籍类型传播

- `BookInfoPage.saveBookImplicitly` / `addToShelf`：根据书源 `sourceType === 2` 设置 `type: BookType.MANGA` / `isManga: true`
- `SearchPage.addPreviewToShelf`：查询书源类型，漫画源设置 `isManga: true`

## 3. 漫画正文解析

### 3.1 getContent preserveImages 参数

`SourceExecutor.getContent(source, contentUrl, bookUrl?, preserveImages?)` 新增第 4 个参数：

- `preserveImages = false`（默认）：走 `stripHtml`，去除所有 HTML 标签（含 `<img>`），返回纯文本
- `preserveImages = true`：走 `ContentCleaner.formatKeepImg`，保留 `<img>` 标签并标准化为绝对 URL

### 3.2 formatKeepImg 图片 URL 补全

`ContentCleaner.formatKeepImg(html, baseUrl)` 支持三种相对路径补全：

| URL 格式 | 补全方式 | 示例 |
|----------|----------|------|
| `http://` / `https://` | 不处理 | `https://cdn.com/1.jpg` |
| `//cdn.com/1.jpg` | 补协议 | `https://cdn.com/1.jpg` |
| `/images/1.jpg` | 补 origin | `https://a.com/images/1.jpg` |
| `images/1.jpg` | 补 origin + 目录 | `https://a.com/b/c/images/1.jpg` |

支持的图片属性：`data-original` / `data-lazy-src` / `data-cfsrc` / `data-src` / `src`

### 3.3 extractImageUrls 图片 URL 提取

`SourceExecutor.extractImageUrls(content, baseUrl)` 从正文中提取图片 URL 列表，支持三种格式：

1. **HTML `<img>` 标签**：`formatKeepImg` 标准化 + 正则提取 `src`
2. **JSON 数组/对象**：`["url1","url2"]` 或 `{"images":["url1"]}` 等
3. **纯文本 URL**：按行分割过滤 `http://` / `https://` 开头

所有 URL 经 `resolvePageUrl` 转为绝对路径，去重后返回。

## 4. 图片下载与缓存

### 4.1 MangaImageLoader

定义于 `util/MangaImageLoader.ts`，负责带自定义请求头的图片下载与本地缓存。

**核心方法**：

| 方法 | 说明 |
|------|------|
| `load(url, source, onProgress?)` | 加载图片：缓存命中直接返回，否则排队下载 |
| `preload(url, source)` | 预下载到缓存（不阻塞调用方） |
| `getLocalPath(url)` | 获取本地缓存路径 |
| `isCached(url)` | 检查是否已缓存 |
| `clearAllCache()` | 清空全部缓存 |
| `clearCacheExcept(urls)` | 清理指定图片外的缓存 |
| `getCacheSize()` | 获取缓存大小 |

**请求头注入**：
- `Referer`：设为书源 `sourceUrl`（防盗链关键）
- `User-Agent`：Chrome 120 桌面 UA
- 书源自定义 `header` JSON 中的所有字段

**缓存机制**：
- 缓存目录：`/data/storage/el2/base/haps/entry/files/manga_cache/`
- 文件命名：`v2_{hash16(url)}.{suffix}`（含缓存版本号，变更算法时自动失效）
- 原子写入：临时文件 `.tmp` + `rename`
- 并发控制：最大 3 个并发下载，同一 URL 的 Promise 复用
- 缓存校验：读取前检查魔数（JPEG/PNG/GIF/WebP），无效则删除重下

### 4.2 图片解密

| 解密方式 | 说明 |
|----------|------|
| AES-256-CBC（硬编码） | 漫蛙等源，IV=前16字节，固定密钥 |
| 竖条重组（硬编码） | 禁漫天堂，按 bookId 区间计算条数，反向重排像素 |
| 书源 imageDecode 规则 | 正则匹配 `java.aesBase64DecodeToString` / `java.base64Decode` / XOR，原生执行 |

### 4.3 下载进度回调

`downloadImage` 通过 rcp 的 `callbacks.onDownloadProgress` 回调获取下载进度，透传到 `ComicReadPage.loadImage_`，更新 `imageProgress` Map，在加载占位区显示 `xx%`。

## 5. 阅读器功能

### 5.1 阅读模式

| 模式 | 常量 | 说明 |
|------|------|------|
| 条漫 | `READ_MODE_WEBTOON = 0` | List 连续滚动，onReachStart/onReachEnd 自动切章 |
| 左->右翻页 | `READ_MODE_LEFT_TO_RIGHT = 1` | Swiper 水平翻页 |
| 右->左翻页 | `READ_MODE_RIGHT_TO_LEFT = 2` | Swiper 图片列表反转（日漫） |
| 单页全屏 | `READ_MODE_SINGLE_PAGE = 3` | 独立开关，`ImageFit.Contain` 每屏一张图 |

阅读模式持久化到 `SettingsStore`（`comic_read_mode`），单页全屏独立持久化（`comic_single_page`）。

### 5.2 手势操作

| 手势 | 实现 | 说明 |
|------|------|------|
| 双指缩放 | `PinchGesture({fingers:2})` | 0.5x ~ 3x，`onActionStart` 记录基准 |
| 双击缩放 | `TapGesture({count:2})` | 切换 1x/2x，以触点为中心计算偏移 |
| 缩放后拖动 | `PanGesture()` | 仅 `imageScale > 1` 时生效，clamp 边界 |
| 长按保存 | `LongPressGesture()` | 保存图片到系统相册 |
| 9 宫格点击 | `handleComicClick_(x,y)` | 3x3 区域命中检测 + 动作分发 |

### 5.3 9 宫格触控区域

- 屏幕 3x3 等分为 9 个区域（TL/TC/TR/ML/MC/MR/BL/BC/BR）
- 每个区域可配置动作：无操作 / 显示菜单 / 下一页 / 上一页 / 下一章 / 上一章
- 配置持久化到 `SettingsStore`（`comic_click_tl~br`）
- 默认值：`[4,2,3, 2,0,1, 2,1,1]`（与安卓 MangaClickAction 一致）
- 菜单中可打开触控设置面板，3x3 网格点击循环切换动作

### 5.4 章节管理

| 功能 | 说明 |
|------|------|
| 章节加载 | 优先 ChapterCache 内存缓存 -> DB 缓存 -> 网络获取 |
| 三章预加载 | 预加载前后各 1 章正文文本 + 图片预下载 |
| 多章预下载 | 前后各 2 章图片静默预下载到本地缓存 |
| 无缝翻章 | `tryUsePreloadedChapter_` 优先使用预加载内容，避免加载占位闪烁 |
| 章节边界页 | 章首"下一章 xxx" / 章尾"已读完 xxx" |
| 进度保存 | 章节 index + 页内位置（`durChapterPos`） |
| 进度恢复 | 重进章节恢复到之前浏览的图片位置 |

### 5.5 菜单系统

菜单从上到下：

1. **顶部栏**：返回 + 书名 + 章节标题（点击打开章节 URL）+ 模式选择
2. **章节进度条**：Slider 拖动跳转章节，显示 `章节 3/45`
3. **亮度调节**：Slider 0-100（50=默认），显示 `亮度 50`
4. **页内进度条**：Slider 拖动跳转图片，显示 `页码 7/10`
5. **底部按钮栏第一行**：上一章 / 目录 / 下一章 / 自动
6. **底部按钮栏第二行**：刷新 / 换源 / 单页 / 触控

子面板：
- **模式选择面板**：条漫 / 左->右 / 右->左 三选一
- **触控设置面板**：3x3 网格 + 保存按钮
- **换源面板**：复用 `ChangeSourceSheet` 组件

### 5.6 页脚信息条

固定在底部（`hitTestBehavior(None)` 不阻挡点击）：
```
章节标题              14:30  7/10  3/45 (6%)
```
- 章节标题
- 当前时间
- 当前章节图片页码（`currentPageIndex+1/imageUrls.length`）
- 章节进度（`currentIndex+1/totalChapters (百分比%)`）

进度百分比采用加权计算：`chapterIndex/total + 1/total * (pageIndex+1)/imageCount`，未读完不超过 99%。

### 5.7 自动阅读

- `setInterval` 定时调用 `nextPage()`
- 速度可配（`comic_auto_read_speed`，默认 3 秒/页）
- 菜单底部"自动"按钮开关，开启时显示 `自动✓` 高亮
- 菜单显示时暂停，`aboutToDisappear` 清理定时器

### 5.8 沉浸式阅读

- `aboutToAppear`：`setWindowSystemBarEnable([])` 隐藏状态栏和导航栏
- `aboutToDisappear`：`setWindowSystemBarEnable(['status','navigation'])` 恢复
- 菜单显隐联动：菜单显示恢复状态栏，隐藏时进入沉浸式

### 5.9 其他功能

| 功能 | 说明 |
|------|------|
| 图片加载进度 | 占位区显示下载百分比 `xx%` |
| 交叉淡入动画 | Image `.opacity(1)` + `.animation({duration:300})` |
| 长按保存图片 | `photoAccessHelper.createAsset` 保存到相册 |
| 打开章节 URL | 菜单顶部栏章节标题点击 -> 系统浏览器 |
| 换源 | 复用 `ChangeSourceSheet`，更新书源/书URL/清缓存/重新加载 |
| 强制刷新 | 清除当前章节缓存并重新拉取 |
| 条漫侧边留白 | List padding 百分比（0-20%），持久化 |
| 亮度调节 | Slider 0-100（50=默认），持久化 |

## 6. 配置项

### 6.1 SettingsStore 漫画配置

| 方法 | key | 默认值 | 说明 |
|------|-----|--------|------|
| `getComicReadMode/setComicReadMode` | `comic_read_mode` | 0 | 阅读方向：0=条漫,1=左->右,2=右->左 |
| `getComicSinglePageMode/setComicSinglePageMode` | `comic_single_page` | false | 单页全屏开关 |
| `getComicPreloadNum/setComicPreloadNum` | `comic_preload_num` | 3 | 图片预加载数量 |
| `getComicClickAction/setComicClickAction` | `comic_click_tl~br` | `[4,2,3,2,0,1,2,1,1]` | 9 宫格触控动作 |
| `getComicAutoReadSpeed/setComicAutoReadSpeed` | `comic_auto_read_speed` | 3 | 自动阅读速度（秒/页） |
| `getComicBrightness/setComicBrightness` | `comic_brightness` | 50 | 亮度（0-100，50=默认） |
| `getComicSidePadding/setComicSidePadding` | `comic_side_padding` | 0 | 条漫侧边留白百分比 |

### 6.2 设置页漫画分区

`SettingsPage.ets` 的 `buildComicSettings` 提供：
- 阅读方向选择（条漫/左->右/右->左）
- 图片预加载数量 Slider（1-20）
- 图片缓存管理（显示大小 + 清理按钮）

## 7. 文件清单

| 文件 | 职责 |
|------|------|
| `model/BookSource.ts` | `BookSourceType` 枚举、`isImageSource` 函数、`parseBookSource` 修复 |
| `engine/source/SourceExecutor.ts` | `getContent(preserveImages)` / `extractImageUrls` |
| `util/ContentCleaner.ts` | `formatKeepImg` 图片标签保留与 URL 补全 |
| `util/MangaImageLoader.ts` | 图片下载、缓存、解密、进度回调 |
| `pages/ComicReadPage.ets` | 漫画阅读页（UI + 交互 + 手势 + 菜单） |
| `pages/BookInfoPage.ets` | 路由分流、`ensureMangaFlag_`、`saveBookImplicitly` |
| `pages/BookshelfPage.ets` | `continueRead` 按 `isManga` 分流 |
| `pages/SearchPage.ets` | `addPreviewToShelf` 传播 `isManga` |
| `pages/SettingsPage.ets` | 漫画设置分区 |
| `data/preferences/SettingsStore.ts` | 漫画配置持久化 |

## 8. 待实现功能

以下功能在安卓版 Legado 中存在，鸿蒙版尚未实现：

### 8.1 P2 体验增强

| # | 功能 | 安卓实现 | 说明 |
|---|------|----------|------|
| 1 | 阅读时长统计 | `ReadRecordSession`，每 120s 自动保存 | 记录用户阅读时长 |
| 2 | WebDav 进度同步 | `syncProgress` / `uploadProgress` | 漫画阅读进度云端同步 |
| 3 | 章节购买 | 执行书源 `ContentRule.payAction` JS | 付费章节购买 |
| 4 | 禁用源 / 编辑源 | 菜单快捷操作 | 从阅读器直接禁用或编辑书源 |
| 5 | 书籍详情页入口 | `openBookInfoActivity()` | 从阅读器跳转书籍详情页 |
| 6 | 自动换源 | `autoChangeSource` 并发搜索取首个命中 | 当前源加载失败时自动切换 |
| 7 | 网络变化监听 | `NetworkChangedListener` | 网络恢复时同步进度 |
| 8 | 护眼覆盖层 | `EyeProtectionHelper` 色矩阵叠加 | 护眼模式 |
| 9 | 页脚可配置 | `MangaFooterConfig` 各项隐藏/对齐方式 | 自定义页脚显示内容 |
| 10 | 滚动动画开关 | `disableMangaScrollAnimation` | 控制平滑滚动 vs 即时跳转 |
| 11 | 点击翻页开关 | `disableClickScroll` | 控制点击区域是否触发翻页 |
| 12 | 缩放禁用开关 | `disableMangaScale` | 完全禁用缩放手势 |
| 13 | 隐藏章节标题页 | `hideMangaTitle` | 不显示章首/章尾边界页 |
| 14 | 图片背景色配置 | `mangaBackground` 默认纯黑 | 自定义图片区域背景色 |
| 15 | 双页横屏模式 | `enableDoublePageInLandscape` | 横屏时两页并排显示 |
| 16 | 上->下翻页模式 | `PAGE_TOP_TO_BOTTOM` | 单页竖向翻页 |
| 17 | 条漫带间隙模式 | `WEBTOON_WITH_GAP` | 图片之间有间距的条漫 |
| 18 | 每书独立配置 | `book.readConfig.mangaScrollMode` | 每本书记忆各自的阅读模式 |
| 19 | 触觉反馈 | `performHapticFeedback` | 翻页/拖动时震动反馈 |
| 20 | 灰度模式 | `GrayscaleTransformation` | 图片转灰度显示 |
| 21 | 墨水屏模式 | `EpaperTransformation` 阈值二值化 | 适合墨水屏的黑白显示 |
| 22 | ARGB 色彩滤镜 | `MangaColorFilterConfig` R/G/B/A 滑块 | 自定义颜色滤镜矩阵 |
| 23 | 自动亮度 | `autoBrightness` 跟随系统 | 亮度自动调节 |
| 24 | 预下载数量 UI 调整 | 菜单 `menu_pre_manga_number` NumberPicker | 在阅读页调整预加载数量 |
| 25 | 缩放后 fling 惯性 | `zoomFling` + `DecelerateInterpolator` | 缩放状态下的惯性滑动 |
| 26 | 快速缩放 | `isQuickScaling` 双击后滑动 | 双击后滑动快速缩放 |
| 27 | 音量键翻页 | `onKeyDown` VOLUME_UP/DOWN | 鸿蒙普通应用无法拦截系统音量键（需系统级权限 `INPUT_MONITORING`），技术限制不可实现 |
