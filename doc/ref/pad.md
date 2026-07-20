当前工程已经声明支持平板，也做了最基础的宽屏侧栏切换，但整体仍是“手机界面横向拉伸”。平板适配需要围绕响应式断点、分栏导航、内容最大宽度、阅读器横屏、弹窗形态五方面系统整改，而不是逐页增加横屏判断。

鸿蒙建议根据“当前可用窗口”响应布局，而不是只判断设备类型或横竖屏，这样才能同时适配平板全屏、分屏和自由窗口。[HarmonyOS 多设备开发最佳实践](https://developer.huawei.com/consumer/cn/best-practices/multidevice/)


## 当前基础和主要问题

已有基础：

- [module.json5](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/module.json5:9) 已声明 `phone`、`tablet`。
- [MainPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/MainPage.ets:88) 已在宽度达到 `840vp` 时，把底部页签切换为左侧栏。
- 深浅色语义色已经基本统一。
- 列表多数使用 `LazyForEach`，具备大屏增加内容量的性能基础。
- 工程目标 API 26、最低兼容 API 23。

主要问题：

1. 只有主框架识别宽度，子页面没有统一断点。
2. 大量页面全宽显示，横屏时列表一行过长、表单输入框过宽。
3. 书架宫格列数来自固定用户配置，没有根据实际宽度计算。
4. 设置、书源、RSS、规则管理等仍是手机式“列表→整页详情”。
5. 全项目约有 92 处旧 `router` 跳转，不利于平板列表详情分栏和各页签独立导航栈。
6. 搜索、详情和部分 AI 页面用 `top: 36/42/44vp` 模拟状态栏，例如 [SearchPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/SearchPage.ets:1484)，横屏、多窗口下容易错位。
7. 很多底部弹层在平板上仍铺满屏幕宽度。
8. 阅读正文横屏时直接占满整行，阅读行长过大。
9. WebView 页面若直接根据断点切换组件分支，容易重新创建 WebView，可能重新引入之前的 Controller 关联问题。
10. 平板鼠标、触控板、键盘焦点及快捷键基本没有专门适配。

## 统一响应式方案

建议建立四级窗口规格：

| 窗口宽度 | 模式 | 基本布局 |
|---|---|---|
| `< 600vp` | Compact | 手机单列、底部页签、底部半模态 |
| `600–839vp` | Medium | 紧凑侧边栏、内容限宽、部分双列 |
| `840–1199vp` | Expanded | 左侧导航、列表详情分栏、多列内容 |
| `≥ 1200vp` | Large | 扩展分栏、更多网格列、阅读双页模式 |

同时增加低高度规则：窗口高度小于约 `480vp` 时压缩标题栏、避免固定高度面板，保证平板横屏和上下分屏可用。

由于最低兼容 API 是 23，不建议直接把最新 API 26 的 `ContainerReader` 作为唯一实现。第一阶段可以使用：

- 根容器 `onAreaChange` 统一生成窗口规格。
- 通过 `@Provide/@Consume` 或 AppStorage 向子页面传递。
- 页面内部使用 `GridRow/GridCol`、约束宽度和响应式 Builder。
- 后续若最低兼容版本提升到 API 26，再迁移到 `ContainerReader`。

建议新增公共设施：

- `WindowSizeClass`：统一断点、窗口宽高和低高度状态。
- `ResponsiveScaffold`：统一标题栏、安全区、内容边距和最大宽度。
- `ListDetailLayout`：列表/详情单栏与双栏切换。
- `AdaptiveGrid`：按最小卡片宽度自动计算列数。
- `AdaptiveOverlay`：手机底部面板、平板居中弹窗或侧边面板。
- 统一内容宽度 Token：表单约 `720vp`，普通正文约 `840vp`，列表页约 `1000–1200vp`。

## 各界面改造方案

### 1. 主框架和导航

涉及 [MainPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/MainPage.ets:88)。

- Compact 保留底部四页签。
- Medium/Expanded 改为左侧导航栏。
- Large 可将侧栏从图标栏扩展为带完整标题的导航区。
- 四个一级页签分别维护自己的导航栈，切换页签时保留滚动和子页面状态。
- 分阶段将 `@ohos.router` 迁移到 `Navigation + NavPathStack`；官方当前已将 `Navigation` 作为推荐导航方案。
- 阅读页可继续作为独立全屏目的页，避免嵌在主侧栏里。

### 2. 书架

涉及 [BookshelfPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/BookshelfPage.ets:775)。

- 顶部标题、搜索、排序操作重新排布；宽屏将搜索框放入标题栏中央区域。
- 宫格不再直接使用固定 `gridColumns`，改成按最小卡片宽度自动计算：
    - Compact：2–3 列
    - Medium：4–5 列
    - Expanded：5–7 列
    - Large：7–9 列
- 用户的“列数”配置改为每种窗口规格分别保存，或解释为卡片密度。
- 列表模式在宽屏下采用两列书籍卡片，避免单行横跨整个屏幕。
- 书架菜单改用锚点菜单，不继续用手写的全屏遮罩和绝对定位。
- 导入进度提示由 `left:10%/width:80%` 改为居中、最大宽度约 `420vp` 的标准进度弹窗。
- 长按继续适用于触屏；鼠标右键弹出相同上下文菜单。

### 3. 搜索、在线导入和 AI 导入

涉及：

- [SearchPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/SearchPage.ets:1236)
- [AiImportBookPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/AiImportBookPage.ets:287)
- [AiImportPreviewDialog.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/components/AiImportPreviewDialog.ets:346)

建议宽屏采用主从结构：

```text
搜索条件/结果列表  |  书籍详情或网页预览
      40%          |       60%
```

- 搜索结果点击后在右侧显示书籍详情，Compact 才整页跳转。
- 在线搜索结果点击后，右侧打开 WebView；确认导入按钮固定在右侧面板标题栏。
- 直接输入 URL 与在线搜索继续保留同一页面的两个标签。
- AI 分析状态、缓存选择提示固定在详情面板内，不被搜索历史遮挡。
- WebView 在断点变化时只调整父容器宽度，不销毁和重建 Controller。
- 过滤、书源范围等手机底部 Sheet，在宽屏改为右侧筛选面板或锚点弹窗。
- 搜索框支持 `Enter` 搜索、`Esc` 收起历史、上下键选择历史。

### 4. 发现页

涉及：

- [DiscoverPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/DiscoverPage.ets:12)
- `ExplorePage`
- `YoushuExplorePage`
- `LkongExplorePage`
- `YoushuBooklistPage`
- `YoushuBooklistDetailPage`

方案：

- 顶部二级页签保留，不建议再加第二条侧边栏。
- 书源发现、书单、推书结果使用 2–4 列卡片或宽屏双列列表。
- 优书、龙空的帖子/书单列表与详情改成左右分栏。
- “转在线搜索/书源搜索”结果在右侧打开，不丢失发现页原有位置。
- 登录 WebView 使用宽屏居中模态窗口，控制区保持固定，网页区域自适应。

### 5. 书籍详情、目录和换源

涉及：

- [BookInfoPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/BookInfoPage.ets:1188)
- [ChapterListPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/ChapterListPage.ets:489)
- [ChangeSourcePage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/ChangeSourcePage.ets:313)

书籍详情：

- Compact 保持当前纵向布局。
- Expanded 采用封面与基础信息左栏、简介/最新章节/操作右栏。
- 当前固定 `500vp` 的封面背景高度改为窗口相关约束。
- 操作按钮不要横跨整屏，组成紧凑操作区。
- 简介正文限制最大宽度，避免超长行。

目录与换源：

- 从详情页进入时，在宽屏作为右侧详情面板。
- 阅读器中打开目录时，使用左侧 `360–420vp` 面板，正文仍然可见。
- 换源列表左侧显示来源，右侧显示章节和检测信息。

### 6. 阅读器

涉及：

- [ReadPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/ReadPage.ets:2154)
- [ReaderPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/ReaderPage.ets:1471)
- [ComicReadPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/ComicReadPage.ets:1010)

这是平板适配优先级最高的部分。

文本阅读：

- 滚动模式：正文居中，设置合理最大宽度，不让一行文字横跨整个横屏。
- 翻页模式：
    - Compact/Medium 单页。
    - Expanded 可配置单页居中或双页。
    - Large 默认支持双页书本式排版，中间保留页缝。
- 横竖屏切换后重新分页，但保持当前字符偏移，而不是只保持旧页码。
- 阅读设置中的左右边距按“单页内容宽度”计算，不能按整个窗口计算。

EPUB/MOBI/PDF：

- EPUB 支持横屏双栏/双页 spread。
- PDF 默认按高度或整页适配，保留手动横竖屏设置。
- 目录、样式、朗读和设置面板在宽屏改为侧边面板。
- 顶部和底部菜单不应因为横屏高度较小遮住大部分内容。

漫画：

- 条漫模式限制图片最大宽度并居中。
- 单页漫画横屏按可视区 contain。
- 可选双页漫画模式，并支持从右到左顺序。
- 设置面板在右侧显示，避免横屏底部面板过高。

### 7. RSS

涉及 `RssMainPage`、`RssSortPage`、`RssArticlesPage`、`RssReadPage`、`RssSourceManagePage`。

- RSS 源主页使用 2–3 列来源卡片。
- 文章列表和文章阅读采用左右分栏。
- RSS 源管理与编辑采用列表/编辑器双栏。
- RSS 正文限制最大阅读宽度。
- 导入和分组管理使用自适应弹窗。

### 8. 我的、设置和管理类页面

涉及：

- [MyPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/MyPage.ets:22)
- [SettingsPage.ets](/Users/hjianhao/Code/ai/LegadoHOS/entry/src/main/ets/pages/SettingsPage.ets:150)
- `BookSourcePage/EditPage`
- `ReplaceRulePage/EditPage`
- `BookshelfManagePage`
- `BookmarkPage`
- `FontManagerPage`
- `BackupSettingsPage`

方案：

- “我的”菜单在宽屏改为两列卡片，主体最大宽度约 `960vp`。
- 设置页采用左侧分类、右侧配置的永久双栏；手机仍为逐级进入。
- 书源管理：左侧书源列表，右侧编辑/调试。
- 替换规则：左侧规则列表，右侧规则编辑。
- 书架管理、缓存管理：宽屏增加列信息并支持多选工具栏。
- 备份、AI 配置、网络、TTS 等表单统一限制到 `640–720vp`，不全屏拉伸。
- 关于页居中限宽即可，不需要复杂分栏。

### 9. 对话框、半模态和 WebView 弹窗

当前多数弹窗已设置 `maxWidth`，方向是正确的，但调用位置仍经常固定为 `DialogAlignment.Bottom`。

统一规则：

- 确认、警告：居中，最大宽度约 `400–480vp`。
- 普通表单：居中，最大宽度约 `520–640vp`。
- 分组、导入、批量操作：手机底部半模态；平板居中或侧边半模态。
- WebView 登录、网页确认：平板使用约 80% 窗口或最大 `1200×900vp`。
- 高度不再固定为 `70%/92%`，使用最大高度和内部滚动。
- 云端进度确认等手写百分比定位弹窗，替换为标准居中弹窗。
- WebView 弹窗禁止因断点切换创建第二套 Controller。

## 平板交互补充

除了布局，还应补齐：

- 鼠标悬浮态、按压态和右键菜单。
- Tab 键焦点顺序和可见焦点样式。
- `Esc` 返回/关闭弹层。
- `Ctrl+F` 搜索、方向键翻页、PageUp/PageDown 阅读。
- 滚动条在鼠标设备上可见，触屏时保持弱化。
- 图标视觉尺寸可以是 24–40vp，但交互热区建议保持至少约 48vp。
- 旋转、分屏和拖动窗口时保留搜索条件、列表位置、WebView 页面和阅读位置。

## 建议实施顺序

1. 建立断点、响应式容器、安全区和自适应弹层基础设施。
2. 改造 MainPage 导航栏和各页签导航栈。
3. 优先完成文本/EPUB/PDF/漫画阅读器横屏。
4. 改造书架、搜索、在线导入、书籍详情。
5. 改造设置、书源、RSS、发现等列表详情页面。
6. 统一全部对话框、菜单、鼠标和键盘交互。
7. 最后逐步将旧 router 迁移到 Navigation。

验收至少覆盖 `360、600、840、1024、1280vp` 等窗口宽度，以及平板横竖屏、左右分屏、自由窗口、深浅色、字体放大、鼠标键盘和窗口动态拖动。整个过程中尤其要回归阅读位置恢复和 WebView Controller 生命周期。


是的，应该由阅读设置控制，而不应仅根据横屏宽度强制双页。

建议增加“横屏排版”设置：

- 自动：默认选项。根据窗口可用宽度和内容类型决定单页或双页。
- 单页：正文居中显示并限制最大宽度，两侧留白。
- 双页：左右两页并排，中间保留页缝。

生效规则建议如下：

| 阅读模式 | 单页 | 双页 |
|---|---:|---:|
| 文本翻页 | 支持 | 支持 |
| 文本滚动 | 支持 | 不支持，保持单列滚动 |
| EPUB 翻页 | 支持 | 支持 |
| MOBI 翻页 | 支持 | 支持 |
| PDF | 支持 | 可后续实现 |
| 条漫滚动 | 支持 | 不支持 |
| 漫画单页 | 支持 | 支持，可结合左右阅读方向 |

“自动”模式可以采用：

- 可用宽度小于 `840vp`：单页。
- 宽度达到 `840vp`，但高度较小或字号较大：仍使用单页。
- 可用宽度达到约 `1000vp`：优先双页。
- 分屏或自由窗口缩小后自动回到单页。

还需要注意：

- 横竖屏或单双页切换时，应按当前文字字符偏移重新分页，保证用户仍停留在原来的阅读位置。
- 双页下“下一页”应一次翻动一个跨页，即左、右两页一起更新。
- 从右向左阅读的漫画，页面顺序应为右页在前。
- 设置建议保存为全局默认，同时允许在单本书中临时覆盖。
- 竖屏固定按单页处理，不必显示双页。

设置入口可以放在阅读界面的“样式/排版”面板中：

```text
横屏排版
○ 自动
○ 单页
○ 双页
```

此外可以提供“记住本书设置”，避免为了某本适合双页的 EPUB 改变所有书籍。