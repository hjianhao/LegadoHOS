鸿蒙系统（HarmonyOS）确实支持 EPUB 格式，但原生组件库中**没有专门的 EPUB 阅读控件**，需要通过以下方式实现：

## 1. 官方提供的方案

**Web 组件（`Web` 组件）**
- HarmonyOS 的 `Web` 组件可以加载 HTML 内容
- 可以结合 JavaScript 库（如 EPUB.js）来渲染 EPUB 文件
- 这是目前官方文档中推荐的通用文档渲染方式

**文件处理**
- 系统级支持 EPUB 文件的解析和元数据读取
- 可以通过 `file.fs` 或 `resourceManager` 读取 EPUB 文件内容

## 2. 第三方开源方案

社区中已有开发者基于 ArkUI 封装了 EPUB 阅读组件，常见实现思路：

- **基于 WebView + EPUB.js**：将 EPUB 解包后通过 Web 组件渲染
- **原生解析渲染**：使用 JavaScript/TypeScript 解析 EPUB 的 XML/HTML 内容，通过 ArkUI 的 `Text`、`Image`、`List` 等基础组件逐页渲染
- **分页引擎**：自行实现 CSS 分页、字体渲染、目录解析等功能

## 3. 实现建议

如果你要开发 EPUB 阅读功能：

1. **简单需求**：直接用 `Web` 组件加载 EPUB.js，实现快但自定义程度低
2. **复杂需求**：需要自行解析 EPUB（本质上是 ZIP 包 + HTML/XML），用 ArkUI 组件搭建阅读器，涉及：
    - ZIP 解压（`zlib` 或第三方库）
    - XML 解析（目录、元数据）
    - HTML 内容渲染（`RichText` 或自定义排版）
    - 分页与翻页动画

## 参考资源

- **HarmonyOS 官方文档**：搜索 "Web 组件" 和 "文件管理" 相关 API
- **OpenHarmony 开源社区**：Gitee 上有多个 EPUB 阅读器的开源实现可供参考

如果你需要具体的代码示例或实现思路，可以告诉我你的具体场景（ArkTS / ArkUI-X / 是否需要复杂排版），我可以进一步帮你梳理。


通过 Web 组件显示 EPUB 时，**字体、字号、间距、边距等格式设置完全支持**，**文本选择功能也支持**，但实现方式和控制粒度取决于你采用的具体方案：

---

## 一、格式设置支持情况

| 设置项 | 支持情况 | 实现方式 |
|--------|---------|---------|
| **字体** | ✅ 支持 | CSS `font-family`，可加载本地或网络字体 |
| **字号** | ✅ 支持 | CSS `font-size`，可动态调整 |
| **行间距** | ✅ 支持 | CSS `line-height` |
| **段间距** | ✅ 支持 | CSS `margin` / `padding` |
| **页边距** | ✅ 支持 | CSS `padding` 或容器布局 |
| **背景色/主题** | ✅ 支持 | CSS `background-color`、深色模式切换 |
| **文字颜色** | ✅ 支持 | CSS `color` |
| **首行缩进** | ✅ 支持 | CSS `text-indent` |
| **对齐方式** | ✅ 支持 | CSS `text-align` |

### 实现示例（通过 EPUB.js + CSS 注入）

```typescript
// ArkTS 侧：加载 Web 组件并传递配置
Web({ src: 'epub-reader.html', controller: this.controller })
  .javaScriptAccess(true)
  .domStorageAccess(true)
```

```javascript
// HTML 侧：通过 EPUB.js 渲染并注入自定义样式
var book = ePub("file://path/to/book.epub");
var rendition = book.renderTo("viewer", {
    width: "100%",
    height: "100%",
    stylesheet: {
        "font-family": "'PingFang SC', serif",
        "font-size": "18px",
        "line-height": "1.8",
        "padding": "20px",
        "color": "#333333"
    }
});
```

---

## 二、文本选择功能

| 功能 | 支持情况 | 说明 |
|------|---------|------|
| **文本选择** | ✅ 支持 | Web 组件默认支持长按/拖动选中文本 |
| **复制** | ✅ 支持 | 浏览器内核默认能力 |
| **高亮/标注** | ⚠️ 需自行实现 | 需配合 JavaScript 库（如 EPUB.js 的 annotations 插件） |
| **词典查询** | ⚠️ 需自行实现 | 监听 `selectionchange` 事件，调用 ArkTS 接口 |

### 文本选择的限制与注意事项

1. **跨章节选择**：EPUB 通常分页加载，跨章节的连续选择可能中断
2. **自定义菜单**：系统默认弹出复制菜单，如需自定义（如"划线""笔记"），需通过 CSS 隐藏默认菜单 + JavaScript 拦截
3. **与 ArkTS 通信**：选中文本后如需调用原生功能（如翻译、分享），需通过 `WebMessagePort` 或 `runJavaScript` 进行双向通信

```typescript
// ArkTS 侧：接收 Web 组件中的选中文本
this.controller.runJavaScript('window.getSelection().toString()', (result) => {
    console.log('选中的文本：', result);
});
```

---

## 三、关键结论

| 需求 | 可行性 |
|------|--------|
| 基础排版（字体、字号、间距等） | ✅ 完全支持，通过 CSS 灵活控制 |
| 文本选择 | ✅ 支持，但体验不如原生组件精细 |
| 复杂交互（批注、笔记、词典） | ⚠️ 需要额外开发，Web 组件与 ArkTS 的通信有一定复杂度 |
| 极致阅读体验（平滑翻页、精确排版） | ❌ Web 方案有局限，原生解析渲染更优 |

---

## 四、建议

- **如果追求快速实现、功能完整**：Web 组件 + EPUB.js 是最佳方案，格式设置和文本选择都能满足大部分需求
- **如果追求原生体验、复杂交互**：建议自行解析 EPUB，用 ArkUI 的 `Text`、`List` 等组件搭建阅读器，控制更精细但开发成本高

需要我提供 EPUB.js 在鸿蒙 Web 组件中的完整集成示例，或者原生解析 EPUB 的思路吗？


通过 Web 组件可以实现**类似翻书的分页效果**，但需要自行实现分页逻辑，不是开箱即用的功能。以下是具体方案和关键实现要点：

---

## 一、核心思路

EPUB/PDF 在 Web 组件中的分页翻页，本质上是**将连续滚动内容切分为固定尺寸的"页"，通过 CSS/JS 控制显示区域**。

```
内容流（连续HTML） → 计算分页断点 → 裁剪可视区域 → 手势/点击切换
```

---

## 二、具体实现方案

### 方案 1：CSS 列分页（最简单，适合 EPUB）

利用 CSS `columns` 属性将内容分为视口宽度的列，通过滚动位置切换"页"。

```css
/* 将内容分为多列，每列 = 一屏宽度 */
#book-content {
    columns: 100vw;           /* 每列宽度 = 视口宽度 */
    column-gap: 40px;         /* 列间距（翻页边距） */
    height: 100vh;            /* 高度固定 */
    overflow: hidden;         /* 隐藏滚动条 */
    font-size: 18px;
    line-height: 1.8;
}
```

```javascript
// 点击翻页：滚动一屏宽度
function nextPage() {
    const container = document.getElementById('book-content');
    container.scrollBy({ left: window.innerWidth, behavior: 'smooth' });
}

function prevPage() {
    container.scrollBy({ left: -window.innerWidth, behavior: 'smooth' });
}
```

**优点**：实现简单，天然支持文字重排  
**缺点**：分页断点可能切断图片/段落，精确控制难

---

### 方案 2：JS 计算分页（更精确，适合 PDF/EPUB）

预计算内容高度，按视口尺寸强制分页，避免切断文字。

```javascript
// 核心分页逻辑
function paginateContent() {
    const container = document.getElementById('content');
    const pageHeight = window.innerHeight - 40; // 减去边距
    const allContent = container.innerHTML;
    
    // 清空后逐段填充，检测高度
    container.innerHTML = '';
    let currentPage = document.createElement('div');
    currentPage.className = 'page';
    container.appendChild(currentPage);
    
    // 遍历所有段落/元素
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = allContent;
    const elements = Array.from(tempDiv.children);
    
    elements.forEach(el => {
        currentPage.appendChild(el.cloneNode(true));
        if (currentPage.scrollHeight > pageHeight) {
            // 超出一页，回退并新建页
            currentPage.removeChild(currentPage.lastChild);
            currentPage = document.createElement('div');
            currentPage.className = 'page';
            container.appendChild(currentPage);
            currentPage.appendChild(el.cloneNode(true));
        }
    });
}
```

```css
.page {
    width: 100%;
    height: 100vh;
    overflow: hidden;
    position: absolute;
    top: 0;
    left: 0;
    opacity: 0;
    transition: opacity 0.3s, transform 0.3s;
}

.page.active {
    opacity: 1;
    transform: translateX(0);
}

.page.prev {
    transform: translateX(-100%);
}

.page.next {
    transform: translateX(100%);
}
```

**优点**：分页精确，不会切断内容  
**缺点**：计算量大，大文档初始化慢，动态字号/屏幕旋转需重新计算

---

### 方案 3：EPUB.js 内置分页（推荐 EPUB）

EPUB.js 库自带分页引擎，支持直接配置：

```javascript
var book = ePub("book.epub");
var rendition = book.renderTo("viewer", {
    width: "100%",
    height: "100%",
    spread: "none",           // 单页模式
    flow: "paginated"         // 分页模式（默认是 scroll）
});

// 翻页
rendition.next();             // 下一页
rendition.prev();             // 上一页

// 获取当前页码信息
rendition.on("relocated", function(location) {
    console.log("当前页：", location.start.cfi);
    console.log("总页数：", location.end.displayed.page);
});
```

**优点**：专为 EPUB 设计，分页智能，支持目录跳转、进度保存  
**缺点**：仅支持 EPUB，PDF 需另寻方案

---

### 方案 4：PDF.js + 单页渲染（适合 PDF）

PDF.js 原生支持单页模式，配合手势实现翻页：

```javascript
const pdf = await pdfjsLib.getDocument(url).promise;
let currentPage = 1;

async function renderPage(num) {
    const page = await pdf.getPage(num);
    const viewport = page.getViewport({ scale: 1.5 });
    const canvas = document.getElementById('pdf-canvas');
    const context = canvas.getContext('2d');
    
    canvas.height = viewport.height;
    canvas.width = viewport.width;
    
    await page.render({ canvasContext: context, viewport }).promise;
}

// 翻页
function nextPage() {
    if (currentPage < pdf.numPages) {
        currentPage++;
        renderPage(currentPage);
    }
}
```

**优点**：PDF 官方方案，渲染准确  
**缺点**：每页是独立图片/Canvas，文字选择体验差，重排困难

---

## 三、鸿蒙 Web 组件中的手势交互

在 ArkTS 中监听 Web 组件的手势，传递至 JS 侧：

```typescript
Web({ src: 'reader.html', controller: this.controller })
  .javaScriptAccess(true)
  .onTouch((event) => {
      // 检测点击区域：左侧1/3上一页，右侧1/3下一页，中间呼出菜单
      const x = event.touches[0].x;
      const width = display.getDefaultDisplaySync().width;
      
      if (x < width / 3) {
          this.controller.runJavaScript('window.prevPage()');
      } else if (x > width * 2 / 3) {
          this.controller.runJavaScript('window.nextPage()');
      } else {
          this.controller.runJavaScript('window.toggleMenu()');
      }
  })
```

**JS 侧暴露全局函数**：

```javascript
window.nextPage = function() { /* 翻页逻辑 */ };
window.prevPage = function() { /* 翻页逻辑 */ };
window.toggleMenu = function() { /* 显示设置面板 */ };
```

---

## 四、翻页动画效果

| 效果 | 实现方式 |
|------|---------|
| **平滑滑动** | CSS `transform: translateX()` + `transition` |
| **仿真翻页（3D 卷曲）** | CSS `transform: rotateY()` + `perspective`，或 WebGL 库（如 `Turn.js`） |
| **淡入淡出** | CSS `opacity` 过渡 |
| **覆盖滑动** | 新页从右侧滑入覆盖旧页 |

**仿真翻页示例**：

```css
.page-flip {
    transform-origin: left center;
    transition: transform 0.6s cubic-bezier(0.25, 1, 0.5, 1);
}

.page-flip.turning {
    transform: rotateY(-90deg);
}
```

---

## 五、方案选择建议

| 格式 | 推荐方案 | 翻页效果 |
|------|---------|---------|
| **EPUB** | EPUB.js `flow: "paginated"` | 内置分页，支持进度记忆 |
| **PDF（简单）** | PDF.js 单页渲染 + 点击翻页 | 类似图片浏览 |
| **PDF（重排后）** | 提取文本 → JS 分页 → ArkUI 渲染 | 可做到 EPUB 级体验 |
| **极致仿真翻书** | WebGL（如 `Turn.js`）或原生 ArkUI 动画 | 3D 卷曲效果，但开发复杂 |

---

## 六、关键结论

- **Web 组件本身不提供翻书控件**，但可以通过 JS/CSS 完全实现
- **EPUB 推荐 EPUB.js**，分页最成熟
- **PDF 推荐单页渲染或服务端转 EPUB**
- **仿真翻页动画**可用 CSS 3D 或 WebGL，但性能在 Web 组件中可能受限

需要我提供 EPUB.js 分页的完整集成代码，或者 PDF 提取文本后重排分页的详细实现思路吗？


EPUB.js 的内置分页**支持图片**，但有一些关键特性和限制需要注意：

---

## 一、图片支持情况

| 特性 | 支持情况 | 说明 |
|------|---------|------|
| **内嵌图片显示** | ✅ 支持 | EPUB 中的 `<img>` 标签正常渲染 |
| **SVG 图形** | ✅ 支持 | 矢量图缩放清晰 |
| **CSS 背景图** | ✅ 支持 | 通过样式引用 |
| **跨页图片** | ⚠️ 部分支持 | 大图可能被分页切断 |
| **图片自适应** | ⚠️ 需配置 | 默认可能溢出或变形 |

---

## 二、图片分页的常见问题

### 1. 图片被分页切断

当图片高度超过剩余页空间时，EPUB.js 默认可能将图片拆分到两页：

```
[页1底部] 图片上半部分
[页2顶部] 图片下半部分  ← 不理想
```

### 2. 解决方案：CSS 控制图片不跨页

```css
/* 强制图片完整显示在一页内，避免切断 */
img {
    max-width: 100%;
    max-height: 90vh;        /* 限制最大高度，留边距 */
    object-fit: contain;      /* 保持比例缩放 */
    page-break-inside: avoid; /* 避免图片内部分页 */
    break-inside: avoid;      /* CSS3 标准 */
}

/* 图片前后加空白，推动图片到新页 */
img {
    margin: 1em 0;
}
```

### 3. 在 EPUB.js 中配置分页行为

```javascript
var rendition = book.renderTo("viewer", {
    width: "100%",
    height: "100%",
    flow: "paginated",
    spread: "none",           // 单页
    minSpreadWidth: 800,      // 屏幕宽度大于此值时双页
    stylesheet: {
        "img": "max-height: 85vh; page-break-inside: avoid;"
    }
});

// 监听分页完成，调整图片
rendition.on("rendered", function(section) {
    // 可在此执行自定义图片处理
    let images = document.querySelectorAll('img');
    images.forEach(img => {
        // 确保图片加载后重新计算分页
        img.onload = () => rendition.resize();
    });
});
```

---

## 三、大图/跨页图的特殊处理

### 方案 A：图片自适应缩放（推荐）

```css
/* 大图自动缩放适应单页 */
.full-page-image {
    display: block;
    width: 100%;
    height: auto;
    max-height: calc(100vh - 40px);  /* 减去页边距 */
    margin: 0 auto;
    object-fit: contain;
}
```

### 方案 B：图片独占一页

```css
/* 图片前后强制分页，独占整页 */
.image-page {
    page-break-before: always;
    page-break-after: always;
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
}
```

### 方案 C：双页跨页图（杂志/画册）

```javascript
// 检测屏幕宽度，宽屏时启用双页模式
var rendition = book.renderTo("viewer", {
    width: "100%",
    height: "100%",
    flow: "paginated",
    spread: "auto",           // 自动判断单双页
    minSpreadWidth: 1000      // 宽屏展开双页
});
```

```css
/* 跨页图片在双页模式下完整显示 */
.spread-image {
    width: 200%;              /* 横跨两页宽度 */
    margin-left: -50%;       /* 居中跨页 */
}
```

---

## 四、EPUB.js 图片渲染的底层行为

EPUB.js 的分页机制基于 **CSS Columns** 或 **JavaScript 计算**，图片处理逻辑：

```
1. 加载章节 HTML
2. 解析 CSS 样式
3. 按视口宽度分栏（CSS columns）
4. 图片按 HTML 顺序流入各栏
5. 如图片高度 > 栏剩余空间：
   - 默认：图片顶部对齐，底部切断（下一栏继续）
   - 配置 break-inside: avoid：整图推至下一栏
```

---

## 五、关键结论

| 场景 | 建议 |
|------|------|
| **普通图文混排** | 直接用 EPUB.js 内置分页，`img` 加 `max-height` 和 `break-inside: avoid` |
| **图片密集（画册/漫画）** | 考虑单页模式（`spread: "none"`），或每图独占一页 |
| **跨页大图** | 双页模式（`spread: "auto"`）+ 自定义 CSS |
| **图片被切断** | 检查 EPUB 源文件 CSS，确保 `page-break-inside: avoid` |
| **图片加载慢导致分页错位** | 监听 `img.onload` 后调用 `rendition.resize()` 重新计算 |

---

## 六、鸿蒙 Web 组件中的额外注意

```typescript
Web({ src: 'epub-reader.html', controller: this.controller })
  .javaScriptAccess(true)
  .domStorageAccess(true)
  .cacheMode(WebCacheMode.Default)  // 缓存图片，避免重复加载
```

- 鸿蒙 Web 组件的缓存策略会影响图片加载速度
- 大 EPUB 文件建议解压后本地加载，避免内存问题

---

需要我提供一个完整的 EPUB.js 配置示例，包含图片自适应、分页防切断、以及鸿蒙 Web 组件的集成代码吗？

   # webview+epub.js如何加载epub文件

是的，完全正确。

---

## 流程确认

```
┌─────────────┐     解压      ┌─────────────┐     HTTP 暴露    ┌─────────────┐
│  EPUB 文件   │ ───────────→ │  目录结构    │ ───────────────→ │  Web 组件   │
│  (ZIP 格式)  │   鸿蒙代码    │  HTML/CSS/   │   本地服务器      │  + EPUB.js  │
│             │              │  图片/字体等  │  (127.0.0.1)   │             │
└─────────────┘              └─────────────┘                └─────────────┘
```

---

## 为什么这样做最优

| 原因 | 说明 |
|------|------|
| **EPUB 本质是 ZIP** | 解压后就是普通文件，EPUB.js 可以直接按 URL 读取 |
| **HTTP 按需加载** | 打开书籍只加载当前章节，翻页再加载下一章，内存占用低 |
| **无大对象传递** | 不走 JSBridge，500MB 文件也不会内存爆炸 |
| **浏览器原生支持** | Web 组件通过 `http://` 访问资源无安全限制 |
| **资源缓存** | 浏览器自动缓存图片/CSS，重复访问不重新加载 |

---

## 解压后的目录结构

```
/data/storage/.../epub_unzipped/    ← HTTP 服务器根目录
├── mimetype
├── META-INF/
│   └── container.xml
└── OEBPS/ 或 OPS/
    ├── package.opf          ← EPUB.js 入口
    ├── toc.ncx
    ├── chapter1.xhtml
    ├── chapter2.xhtml
    ├── style.css
    └── images/
        └── cover.jpg        ← 所有资源直接通过 URL 访问
```

---

## EPUB.js 加载方式

```javascript
// 直接加载解压后的目录（通过 HTTP）
var book = ePub("http://127.0.0.1:49231/OEBPS/package.opf");

// 或让 EPUB.js 自动发现（传入目录）
var book = ePub("http://127.0.0.1:49231/");
```

EPUB.js 内部会自动读取 `META-INF/container.xml` 找到 `package.opf`，然后按 `spine` 顺序加载章节。

---

## 鸿蒙侧完整流程

```typescript
import { fileIo, zlib } from '@kit.CoreFileKit';

// 1. 解压 EPUB
async function unzipEpub(epubPath: string, outputDir: string): Promise<void> {
    // 鸿蒙提供 ZIP 解压能力
    await zlib.decompressFile(epubPath, outputDir, zlib.ZipIoType.ZIP);
}

// 2. 启动服务器
let server = new EpubServer();
let port = await server.start(outputDir, 0);

// 3. Web 组件加载
// Web({ src: `http://127.0.0.1:${port}/reader.html` })
```

---

## 对比不走解压的方案

| 方案 | 内存 | 速度 | 复杂度 |
|------|------|------|--------|
| **解压 + HTTP** | 低（按需） | 快 | 中 |
| JSBridge 传 ArrayBuffer | 高（完整在内存） | 慢 | 低 |
| 服务器直接读 ZIP | 中（需解压缓存） | 中 | 高 |

**解压 + HTTP 是最平衡的方案**，特别是对于大文件。

---

需要我提供**鸿蒙解压 ZIP 的完整代码**，或者**处理 EPUB 解压后特殊路径（如加密字体、XML 命名空间）的注意事项**吗？


鸿蒙生态中没有官方提供的现成 HTTP 服务器组件，推荐以下几种实现方式：

---

## 一、推荐方案对比

| 方案 | 实现方式 | 复杂度 | 性能 | 推荐度 |
|------|---------|--------|------|--------|
| **自研 TCP Socket 服务器** | 基于 `@kit.NetworkKit` 的 socket API | 中 | 高 | ⭐⭐⭐ 最推荐 |
| **NAPI 接入 C 库** | 接入 `mongoose`、` civetweb` 等轻量 C 库 | 中高 | 极高 | 大文件/高并发 |
| **Worker 线程 + 简化 HTTP** | 在 Worker 中处理请求 | 中 | 中 | 避免阻塞主线程 |

---

## 二、自研 TCP Socket 服务器（推荐）

基于鸿蒙内置的 `socket` 模块实现，足够轻量：

```typescript
// EpubServer.ets
import { socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

export class EpubServer {
    private server: socket.TCPSocket | null = null;
    private port: number = 0;
    private rootDir: string = '';
    private running: boolean = false;

    async start(rootDir: string, preferredPort: number = 0): Promise<number> {
        this.rootDir = rootDir;
        this.server = socket.constructTCPSocketInstance();

        // 动态端口：0 表示系统分配
        this.server.bind({ address: '127.0.0.1', port: preferredPort });
        this.server.listen(10);

        let localAddr = this.server.getLocalAddress();
        this.port = localAddr.port;
        this.running = true;

        // 异步处理连接
        this.acceptLoop();

        return this.port;
    }

    private async acceptLoop() {
        while (this.running) {
            try {
                let client = await this.server!.accept();
                this.handleClient(client);
            } catch (e) {
                if (this.running) console.error('Accept error:', e);
            }
        }
    }

    private async handleClient(client: socket.TCPSocketConnection) {
        // 读取 HTTP 请求
        let buffer = new ArrayBuffer(4096);
        let readLen = await client.receive(buffer);
        let request = this.bufferToString(buffer, readLen.bytesRead);

        // 解析 GET 路径
        let match = request.match(/GET\s+(.+?)\s+HTTP/);
        let path = match ? decodeURIComponent(match[1]) : '/';
        let filePath = this.rootDir + path;

        // 读取文件
        try {
            let content = fileIo.readSync(filePath);
            let mimeType = this.getMimeType(filePath);
            let response = this.buildResponse(200, mimeType, content);
            await client.send(response);
        } catch (e) {
            let response = this.buildResponse(404, 'text/plain', 'Not Found');
            await client.send(response);
        }

        client.close();
    }

    private buildResponse(status: number, mimeType: string, content: ArrayBuffer): ArrayBuffer {
        let header = `HTTP/1.1 ${status} OK\r\n` +
                     `Content-Type: ${mimeType}\r\n` +
                     `Access-Control-Allow-Origin: *\r\n` +
                     `Content-Length: ${content.byteLength}\r\n` +
                     `Connection: close\r\n\r\n`;
        let headerBuf = this.stringToBuffer(header);
        return this.concatBuffer(headerBuf, content);
    }

    private getMimeType(path: string): string {
        if (path.endsWith('.html') || path.endsWith('.xhtml')) return 'application/xhtml+xml';
        if (path.endsWith('.css')) return 'text/css';
        if (path.endsWith('.js')) return 'application/javascript';
        if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
        if (path.endsWith('.png')) return 'image/png';
        if (path.endsWith('.gif')) return 'image/gif';
        if (path.endsWith('.svg')) return 'image/svg+xml';
        if (path.endsWith('.woff2')) return 'font/woff2';
        if (path.endsWith('.opf')) return 'application/oebps-package+xml';
        if (path.endsWith('.ncx')) return 'application/x-dtbncx+xml';
        return 'application/octet-stream';
    }

    stop() {
        this.running = false;
        this.server?.close();
    }

    getPort(): number { return this.port; }

    // 工具函数
    private bufferToString(buf: ArrayBuffer, len: number): string {
        let bytes = new Uint8Array(buf, 0, len);
        let decoder = new TextDecoder('utf-8');
        return decoder.decode(bytes);
    }

    private stringToBuffer(str: string): ArrayBuffer {
        let encoder = new TextEncoder();
        return encoder.encode(str);
    }

    private concatBuffer(a: ArrayBuffer, b: ArrayBuffer): ArrayBuffer {
        let result = new Uint8Array(a.byteLength + b.byteLength);
        result.set(new Uint8Array(a), 0);
        result.set(new Uint8Array(b), a.byteLength);
        return result.buffer;
    }
}
```

**使用**：
```typescript
// 解压 EPUB 到目录
let server = new EpubServer();
let port = await server.start('/data/storage/.../epub_unzipped/', 0);
// Web 组件加载：http://127.0.0.1:${port}/
```

---

## 三、NAPI 接入 C 库（高性能）

如果需要更高性能，通过 NAPI 接入成熟的 C 语言 HTTP 库：

| 库 | 特点 | 体积 |
|----|------|------|
| **mongoose** | 单文件、轻量、功能全 | ~200KB |
| **civetweb** | 兼容 mongoose API，维护活跃 | ~300KB |
| **lighthttpd** | 高性能，但较复杂 | 较大 |

**NAPI 封装思路**：
```
C 库编译为 .so → NAPI 暴露 startServer(rootDir, port) → ArkTS 调用
```

---

## 四、Worker 线程优化（避免阻塞）

HTTP 服务器放在 Worker 中，不占用主线程：

```typescript
// server_worker.ets
import { worker } from '@kit.ArkTS';

// 在 Worker 中启动服务器
const parentPort = worker.workerPort;
parentPort.onmessage = (e) => {
    if (e.data.type === 'start') {
        let server = new EpubServer();
        server.start(e.data.rootDir, e.data.port).then(port => {
            parentPort.postMessage({ type: 'started', port: port });
        });
    }
};
```

```typescript
// 主线程
let workerInstance = new worker.ThreadWorker('entry/ets/workers/server_worker.ets');
workerInstance.postMessage({ type: 'start', rootDir: epubDir, port: 0 });
workerInstance.onmessage = (e) => {
    let port = e.data.port;  // 获取动态端口
    // 加载 Web 组件
};
```

---

## 五、推荐选择

| 场景 | 推荐方案 |
|------|---------|
| **快速实现、EPUB < 100MB** | 自研 TCP Socket 服务器（方案一） |
| **EPUB > 100MB、高并发** | NAPI + mongoose/civetweb |
| **UI 不能卡顿** | Worker 线程 + 任一种服务器 |
| **极简需求** | 自研 TCP Socket，代码可控 |

---

## 六、关键注意点

| 问题 | 解决 |
|------|------|
| **端口冲突** | 绑定 `port: 0` 让系统分配 |
| **CORS 限制** | 响应头加 `Access-Control-Allow-Origin: *` |
| **中文路径** | URL 编码/解码处理 |
| **大文件传输** | 分块读取，避免一次性加载到内存 |
| **并发连接** | `listen(backlog)` 设置队列长度 |

---

需要我提供**完整的 Worker + TCP 服务器集成示例**，或者**NAPI 封装 mongoose 的简化代码框架**吗？


是的，**解压到应用沙箱目录**。

---

## 鸿蒙沙箱目录结构

```
/data/storage/el2/base/haps/entry/files/        ← 应用文件目录（推荐）
/data/storage/el2/base/haps/entry/cache/        ← 缓存目录（临时文件）
```

| 目录 | 用途 | 持久性 |
|------|------|--------|
| `files/` | 用户数据、书籍、配置 | ✅ 持久保存 |
| `cache/` | 临时解压、缓存 | ⚠️ 系统可能清理 |

---

## 推荐解压路径

```
/data/storage/el2/base/haps/entry/files/epub/
├── book_001/          ← 某本书的解压目录
│   ├── mimetype
│   ├── META-INF/
│   └── OEBPS/
├── book_002/
└── ...
```

---

## 完整解压代码

```typescript
import { fileIo, zlib } from '@kit.CoreFileKit';
import { context } from '@kit.UIAbilityKit';

class EpubManager {
    private epubDir: string = '';

    constructor() {
        // 获取应用沙箱 files 目录
        let appContext = context.getApplicationContext();
        this.epubDir = appContext.filesDir + '/epub/';
        
        // 确保目录存在
        if (!fileIo.accessSync(this.epubDir)) {
            fileIo.mkdirSync(this.epubDir);
        }
    }

    // 解压 EPUB 到沙箱
    async unzipEpub(epubUri: string, bookId: string): Promise<string> {
        let outputDir = this.epubDir + bookId + '/';
        
        // 清理旧目录（如有）
        if (fileIo.accessSync(outputDir)) {
            fileIo.rmdirSync(outputDir, true);  // 递归删除
        }
        fileIo.mkdirSync(outputDir);

        // 复制到临时 ZIP 路径（zlib 需要本地路径）
        let tempZip = this.epubDir + bookId + '.zip';
        await this.copyFile(epubUri, tempZip);

        // 解压
        await zlib.decompressFile(tempZip, outputDir, zlib.ZipIoType.ZIP);

        // 删除临时 ZIP
        fileIo.unlinkSync(tempZip);

        return outputDir;
    }

    // 复制文件（从 URI 到沙箱路径）
    private async copyFile(srcUri: string, destPath: string): Promise<void> {
        // 根据来源处理：用户选择、网络下载、应用内置等
        // 使用 fileIo.copyFileSync 或流式复制
        let srcFile = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
        let destFile = fileIo.openSync(destPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
        
        let buf = new ArrayBuffer(1024 * 1024);  // 1MB 缓冲区
        let offset = 0;
        while (true) {
            let readLen = fileIo.readSync(srcFile.fd, buf, { offset: offset });
            if (readLen.bytesRead <= 0) break;
            fileIo.writeSync(destFile.fd, buf.slice(0, readLen.bytesRead));
            offset += readLen.bytesRead;
        }
        
        fileIo.closeSync(srcFile);
        fileIo.closeSync(destFile);
    }

    // 获取已解压书籍路径
    getBookPath(bookId: string): string {
        return this.epubDir + bookId + '/';
    }

    // 清理单本书
    deleteBook(bookId: string): void {
        let path = this.epubDir + bookId;
        if (fileIo.accessSync(path)) {
            fileIo.rmdirSync(path, true);
        }
    }
}
```

---

## 使用流程

```typescript
let epubManager = new EpubManager();

// 用户选择 EPUB 文件后
let outputDir = await epubManager.unzipEpub('file://.../book.epub', 'book_001');
// outputDir = /data/storage/.../files/epub/book_001/

// 启动服务器
let server = new EpubServer();
let port = await server.start(outputDir, 0);

// Web 组件加载
// http://127.0.0.1:49231/OEBPS/package.opf
```

---

## 关键注意点

| 问题 | 处理 |
|------|------|
| **沙箱路径权限** | 应用只能访问自己的沙箱目录，不能随意写其他路径 |
| **解压后路径** | 确保 EPUB 内部路径正确，有些 EPUB 多一层嵌套目录 |
| **磁盘空间** | 500MB EPUB 解压后可能 1GB+，需检查剩余空间 |
| **并发解压** | 大文件解压耗时，建议放 Worker 线程避免卡 UI |
| **重复解压** | 已解压的书籍直接复用，避免重复操作 |

---

## 检查 EPUB 解压结构

```typescript
// 有些 EPUB 解压后多一层目录，需要找到真正的内容根
function findContentRoot(dir: string): string {
    // 检查是否直接包含 mimetype
    if (fileIo.accessSync(dir + 'mimetype')) {
        return dir;
    }
    
    // 检查子目录
    let files = fileIo.listFileSync(dir);
    for (let f of files) {
        let subPath = dir + f.name + '/';
        if (fileIo.accessSync(subPath + 'mimetype')) {
            return subPath;
        }
    }
    return dir;
}
```

---

需要我提供**Worker 线程中解压大 EPUB 的代码**，或者**解压后启动服务器并加载到 Web 组件的完整串联示例**吗？

以下是完整的 Worker 线程解压 + 服务器启动 + Web 组件加载的串联示例：

---

## 一、Worker 线程解压大文件

```typescript
// entry/src/main/ets/workers/epub_worker.ets
import { worker } from '@kit.ArkTS';
import { fileIo, zlib } from '@kit.CoreFileKit';

const parentPort = worker.workerPort;

parentPort.onmessage = async (e) => {
    let { type, epubPath, bookId, outputDir } = e.data;

    if (type === 'unzip') {
        try {
            // 清理旧目录
            if (fileIo.accessSync(outputDir)) {
                fileIo.rmdirSync(outputDir, true);
            }
            fileIo.mkdirSync(outputDir);

            // 复制到临时 ZIP
            let tempZip = outputDir + '.zip';
            await copyFile(epubPath, tempZip);

            // 报告进度
            parentPort.postMessage({ type: 'progress', stage: '解压中...', percent: 30 });

            // 解压
            await zlib.decompressFile(tempZip, outputDir, zlib.ZipIoType.ZIP);

            // 删除临时 ZIP
            fileIo.unlinkSync(tempZip);

            parentPort.postMessage({ type: 'done', outputDir: outputDir });

        } catch (err) {
            parentPort.postMessage({ type: 'error', message: err.message });
        }
    }
};

async function copyFile(src: string, dest: string): Promise<void> {
    let srcFile = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
    let destFile = fileIo.openSync(dest, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);

    let buf = new ArrayBuffer(1024 * 1024);
    let offset = 0;
    while (true) {
        let read = fileIo.readSync(srcFile.fd, buf, { offset: offset });
        if (read.bytesRead <= 0) break;
        fileIo.writeSync(destFile.fd, buf.slice(0, read.bytesRead));
        offset += read.bytesRead;
        parentPort.postMessage({ type: 'progress', stage: '复制中...', percent: Math.floor(offset / 10000) });
    }

    fileIo.closeSync(srcFile);
    fileIo.closeSync(destFile);
}
```

---

## 二、主页面完整代码

```typescript
// entry/src/main/ets/pages/ReaderPage.ets
import { router } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { context } from '@kit.UIAbilityKit';
import { worker } from '@kit.ArkTS';
import { EpubServer } from '../utils/EpubServer';

@Entry
@Component
struct ReaderPage {
    @State bookId: string = '';
    @State epubPath: string = '';
    @State serverPort: number = 0;
    @State loading: boolean = true;
    @State progressText: string = '';
    @State progressPercent: number = 0;

    private webController: WebviewController = new WebviewController();
    private server: EpubServer = new EpubServer();
    private workerInstance: worker.ThreadWorker | null = null;

    aboutToAppear() {
        // 获取路由参数
        let params = router.getParams() as Record<string, string>;
        this.bookId = params['bookId'] || 'default';
        this.epubPath = params['epubPath'] || '';

        this.startLoadProcess();
    }

    aboutToDisappear() {
        this.server.stop();
        this.workerInstance?.terminate();
    }

    async startLoadProcess() {
        let filesDir = context.getApplicationContext().filesDir;
        let outputDir = filesDir + '/epub/' + this.bookId + '/';

        // 已解压？直接启动服务器
        if (fileIo.accessSync(outputDir + 'mimetype')) {
            await this.startServer(outputDir);
            return;
        }

        // 未解压，启动 Worker
        this.loading = true;
        this.progressText = '准备解压...';

        this.workerInstance = new worker.ThreadWorker('entry/ets/workers/epub_worker.ets');

        this.workerInstance.onmessage = async (e) => {
            let data = e.data;

            if (data.type === 'progress') {
                this.progressText = data.stage;
                this.progressPercent = data.percent;
            }

            if (data.type === 'done') {
                this.progressText = '解压完成，启动服务器...';
                await this.startServer(data.outputDir);
            }

            if (data.type === 'error') {
                this.progressText = '错误: ' + data.message;
                this.loading = false;
            }
        };

        this.workerInstance.postMessage({
            type: 'unzip',
            epubPath: this.epubPath,
            bookId: this.bookId,
            outputDir: outputDir
        });
    }

    async startServer(rootDir: string) {
        // 找到内容根目录（处理嵌套）
        let contentRoot = this.findContentRoot(rootDir);
        this.serverPort = await this.server.start(contentRoot, 0);

        this.loading = false;
        this.progressText = '加载完成';

        // 加载 Web 组件
        let webUrl = `http://127.0.0.1:${this.serverPort}/reader.html`;
        this.webController.loadUrl(webUrl);
    }

    findContentRoot(dir: string): string {
        if (fileIo.accessSync(dir + 'mimetype')) {
            return dir;
        }
        let files = fileIo.listFileSync(dir);
        for (let f of files) {
            if (f.isDirectory) {
                let sub = dir + f.name + '/';
                if (fileIo.accessSync(sub + 'mimetype')) {
                    return sub;
                }
            }
        }
        return dir;
    }

    // 与 Web 组件通信
    sendToWeb(action: string, data?: any) {
        let js = `window.onArkUIAction && window.onArkUIAction('${action}', ${JSON.stringify(data || {})})`;
        this.webController.runJavaScript(js);
    }

    build() {
        Stack() {
            // 加载中遮罩
            if (this.loading) {
                Column() {
                    LoadingProgress()
                        .width(50)
                        .height(50)
                        .color('#FF6600')

                    Text(this.progressText)
                        .fontSize(14)
                        .margin({ top: 16 })

                    Progress({ value: this.progressPercent, total: 100 })
                        .width(200)
                        .margin({ top: 8 })
                }
                .width('100%')
                .height('100%')
                .backgroundColor('#FFFFFF')
                .zIndex(100)
            }

            // Web 阅读器
            Web({ src: '', controller: this.webController })
                .width('100%')
                .height('100%')
                .javaScriptAccess(true)
                .domStorageAccess(true)
                .fileAccess(true)
                .onPageBegin(() => {
                    // 页面加载后注入配置
                    this.webController.runJavaScript(`
                        window.__EPUB_CONFIG__ = {
                            bookPath: '/OEBPS/package.opf',
                            theme: 'light',
                            fontSize: 18,
                            lineHeight: 1.8
                        };
                    `);
                })
                .onTouch((event) => {
                    if (this.loading) return;
                    let x = event.touches[0].x;
                    let width = display.getDefaultDisplaySync().width;

                    // 点击区域：左1/3上一页，右1/3下一页，中间菜单
                    if (x < width / 3) {
                        this.sendToWeb('prevPage');
                    } else if (x > width * 2 / 3) {
                        this.sendToWeb('nextPage');
                    } else {
                        this.sendToWeb('toggleMenu');
                    }
                })

            // 底部控制栏（可展开）
            Row() {
                Button('上一章')
                    .onClick(() => this.sendToWeb('prevChapter'))

                Button('目录')
                    .onClick(() => this.sendToWeb('showToc'))

                Button('设置')
                    .onClick(() => this.sendToWeb('showSettings'))

                Button('下一章')
                    .onClick(() => this.sendToWeb('nextChapter'))
            }
            .width('100%')
            .height(60)
            .position({ x: 0, y: '100%' })
            .translate({ y: -60 })
            .backgroundColor('#F5F5F5')
            .justifyContent(FlexAlign.SpaceAround)
        }
        .width('100%')
        .height('100%')
    }
}
```

---

## 三、Web 侧 reader.html

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>EPUB Reader</title>
    <script src="epub.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body, #viewer {
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: #fff;
        }
        .loading {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 16px;
            color: #999;
        }
    </style>
</head>
<body>
    <div id="viewer"></div>
    <div class="loading" id="loading">加载中...</div>

    <script>
        let book = null;
        let rendition = null;
        let config = window.__EPUB_CONFIG__ || {};

        function init() {
            let bookPath = config.bookPath || '/OEBPS/package.opf';
            let baseUrl = location.origin;  // http://127.0.0.1:49231

            book = ePub(baseUrl + bookPath);

            rendition = book.renderTo('viewer', {
                width: '100%',
                height: '100%',
                flow: 'paginated',
                spread: 'none',
                minSpreadWidth: 800,
                stylesheet: {
                    'font-size': (config.fontSize || 18) + 'px',
                    'line-height': config.lineHeight || 1.8,
                    'font-family': 'serif',
                    'padding': '20px'
                }
            });

            // 监听分页完成
            rendition.on('relocated', (location) => {
                // 向 ArkUI 上报进度
                if (window.onEpubProgress) {
                    window.onEpubProgress({
                        cfi: location.start.cfi,
                        percentage: book.locations.percentageFromCfi(location.start.cfi)
                    });
                }
            });

            // 显示第一页
            rendition.display().then(() => {
                document.getElementById('loading').style.display = 'none';
            });

            // 目录
            book.ready.then(() => {
                console.log('书籍就绪:', book.package.metadata.title);
            });
        }

        // 接收 ArkUI 指令
        window.onArkUIAction = function(action, data) {
            switch(action) {
                case 'nextPage':
                    rendition.next();
                    break;
                case 'prevPage':
                    rendition.prev();
                    break;
                case 'nextChapter':
                    book.package.spine.get(rendition.location?.end?.index + 1)
                        ?.then(section => rendition.display(section.href));
                    break;
                case 'prevChapter':
                    book.package.spine.get(rendition.location?.start?.index - 1)
                        ?.then(section => rendition.display(section.href));
                    break;
                case 'showToc':
                    book.loaded.navigation.then(nav => {
                        // 向 ArkUI 发送目录数据
                        if (window.onEpubToc) {
                            window.onEpubToc(JSON.stringify(nav.toc));
                        }
                    });
                    break;
                case 'showSettings':
                    // 呼出设置面板
                    break;
                case 'setFontSize':
                    rendition.themes.fontSize(data.size + 'px');
                    break;
                case 'setTheme':
                    if (data.theme === 'dark') {
                        rendition.themes.override('background-color', '#1a1a1a');
                        rendition.themes.override('color', '#e0e0e0');
                    } else {
                        rendition.themes.override('background-color', '#ffffff');
                        rendition.themes.override('color', '#333333');
                    }
                    break;
            }
        };

        // 初始化
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    </script>
</body>
</html>
```

---

## 四、关键文件放置

```
entry/src/main/resources/rawfile/
├── epub.min.js          ← EPUB.js 库
├── reader.html          ← 阅读器页面
└── ...
```

服务器启动后，Web 组件访问 `http://127.0.0.1:port/reader.html`，EPUB.js 从同源的 `/OEBPS/package.opf` 加载书籍。

---

## 五、流程总结

```
用户选择 EPUB
    ↓
ArkUI 检查是否已解压
    ↓
未解压 → 启动 Worker 线程解压（不卡 UI）
    ↓
解压完成 → 启动 EpubServer（动态端口）
    ↓
Web 组件加载 reader.html
    ↓
EPUB.js 从 http://127.0.0.1:port/OEBPS/package.opf 加载
    ↓
分页渲染，ArkUI ↔ Web 双向通信
```

---

需要我补充**目录弹窗组件**、**阅读进度保存到数据库**、或者**字体/主题设置面板**的代码吗？


以下是目录弹窗、阅读进度保存、字体/主题设置面板的完整代码：

---

## 一、目录弹窗组件

```typescript
// entry/src/main/ets/components/TocDialog.ets
@Component
export struct TocDialog {
    @Prop tocList: Array<{ label: string, href: string, subitems?: Array<any> }> = [];
    @State expandIndex: number = -1;
    onSelect: (href: string) => void = () => {};
    onClose: () => void = () => {};

    @Builder
    TocItem(item: any, level: number = 0) {
        Column() {
            Row() {
                Text(item.label)
                    .fontSize(16 - level * 2)
                    .fontColor('#333')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                if (item.subitems && item.subitems.length > 0) {
                    Image(this.expandIndex === item.index ? $r('app.media.ic_expand') : $r('app.media.ic_collapse'))
                        .width(20)
                        .height(20)
                }
            }
            .width('100%')
            .height(48)
            .padding({ left: 16 + level * 20, right: 16 })
            .backgroundColor(this.expandIndex === item.index ? '#FFF3E0' : '#FFFFFF')
            .onClick(() => {
                if (item.subitems && item.subitems.length > 0) {
                    this.expandIndex = this.expandIndex === item.index ? -1 : item.index;
                } else {
                    this.onSelect(item.href);
                    this.onClose();
                }
            })

            // 子目录
            if (this.expandIndex === item.index && item.subitems) {
                ForEach(item.subitems, (sub: any) => {
                    this.TocItem({ ...sub, index: -1 }, level + 1)
                })
            }
        }
        .width('100%')
    }

    build() {
        Column() {
            // 标题栏
            Row() {
                Text('目录')
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)

                Button('关闭')
                    .fontSize(14)
                    .backgroundColor('transparent')
                    .fontColor('#666')
                    .onClick(this.onClose)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .border({ width: { bottom: 1 }, color: '#EEE' })

            // 目录列表
            List() {
                ForEach(this.tocList, (item: any, index: number) => {
                    ListItem() {
                        this.TocItem({ ...item, index: index })
                    }
                })
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 0.5, color: '#EEE' })

            // 快速跳转
            Row() {
                TextInput({ placeholder: '输入页码或章节...' })
                    .width('70%')
                    .height(40)
                    .onSubmit((value) => {
                        // 搜索匹配
                        let found = this.tocList.find(t => t.label.includes(value));
                        if (found) {
                            this.onSelect(found.href);
                            this.onClose();
                        }
                    })

                Button('跳转')
                    .width('25%')
                    .height(40)
                    .onClick(() => {})
            }
            .width('100%')
            .height(60)
            .padding(12)
            .border({ width: { top: 1 }, color: '#EEE' })
        }
        .width('80%')
        .height('100%')
        .backgroundColor('#FFFFFF')
    }
}
```

---

## 二、阅读进度数据库

```typescript
// entry/src/main/ets/database/BookDatabase.ets
import { relationalStore } from '@kit.ArkData';

const STORE_NAME = 'epub_reader.db';
const TABLE_BOOKS = 'books';

interface BookProgress {
    bookId: string;
    title: string;
    coverPath: string;
    currentCfi: string;
    currentChapter: string;
    progressPercent: number;
    lastReadTime: number;
    fontSize: number;
    lineHeight: number;
    theme: string;
    createTime: number;
}

class BookDatabase {
    private store: relationalStore.RdbStore | null = null;

    async init() {
        this.store = await relationalStore.getRdbStore(context.getApplicationContext(), {
            name: STORE_NAME,
            securityLevel: relationalStore.SecurityLevel.S1
        });

        // 创建表
        await this.store.executeSql(`
            CREATE TABLE IF NOT EXISTS ${TABLE_BOOKS} (
                bookId TEXT PRIMARY KEY,
                title TEXT,
                coverPath TEXT,
                currentCfi TEXT,
                currentChapter TEXT,
                progressPercent REAL,
                lastReadTime INTEGER,
                fontSize INTEGER,
                lineHeight REAL,
                theme TEXT,
                createTime INTEGER
            )
        `);
    }

    async saveProgress(progress: BookProgress): Promise<void> {
        if (!this.store) await this.init();

        let values = new relationalStore.ValuesBucket();
        values.put('bookId', progress.bookId);
        values.put('title', progress.title);
        values.put('coverPath', progress.coverPath);
        values.put('currentCfi', progress.currentCfi);
        values.put('currentChapter', progress.currentChapter);
        values.put('progressPercent', progress.progressPercent);
        values.put('lastReadTime', Date.now());
        values.put('fontSize', progress.fontSize);
        values.put('lineHeight', progress.lineHeight);
        values.put('theme', progress.theme);

        // UPSERT
        try {
            await this.store!.insert(TABLE_BOOKS, values);
        } catch (e) {
            await this.store!.update(values, TABLE_BOOKS, 'bookId = ?', [progress.bookId]);
        }
    }

    async getProgress(bookId: string): Promise<BookProgress | null> {
        if (!this.store) await this.init();

        let result = await this.store!.query(
            relationalStore.Predicate.create()
                .equalTo('bookId', bookId),
            TABLE_BOOKS
        );

        if (result.goToFirstRow()) {
            return {
                bookId: result.getString(result.getColumnIndex('bookId')),
                title: result.getString(result.getColumnIndex('title')),
                coverPath: result.getString(result.getColumnIndex('coverPath')),
                currentCfi: result.getString(result.getColumnIndex('currentCfi')),
                currentChapter: result.getString(result.getColumnIndex('currentChapter')),
                progressPercent: result.getDouble(result.getColumnIndex('progressPercent')),
                lastReadTime: result.getLong(result.getColumnIndex('lastReadTime')),
                fontSize: result.getInt(result.getColumnIndex('fontSize')),
                lineHeight: result.getDouble(result.getColumnIndex('lineHeight')),
                theme: result.getString(result.getColumnIndex('theme')),
                createTime: result.getLong(result.getColumnIndex('createTime'))
            };
        }
        return null;
    }

    async getAllBooks(): Promise<BookProgress[]> {
        if (!this.store) await this.init();

        let result = await this.store!.query(
            relationalStore.Predicate.create(),
            TABLE_BOOKS
        );

        let books: BookProgress[] = [];
        while (result.goToNextRow()) {
            books.push({
                bookId: result.getString(result.getColumnIndex('bookId')),
                title: result.getString(result.getColumnIndex('title')),
                coverPath: result.getString(result.getColumnIndex('coverPath')),
                currentCfi: result.getString(result.getColumnIndex('currentCfi')),
                currentChapter: result.getString(result.getColumnIndex('currentChapter')),
                progressPercent: result.getDouble(result.getColumnIndex('progressPercent')),
                lastReadTime: result.getLong(result.getColumnIndex('lastReadTime')),
                fontSize: result.getInt(result.getColumnIndex('fontSize')),
                lineHeight: result.getDouble(result.getColumnIndex('lineHeight')),
                theme: result.getString(result.getColumnIndex('theme')),
                createTime: result.getLong(result.getColumnIndex('createTime'))
            });
        }
        return books;
    }

    async deleteBook(bookId: string): Promise<void> {
        if (!this.store) await this.init();
        await this.store!.delete(
            relationalStore.Predicate.create().equalTo('bookId', bookId),
            TABLE_BOOKS
        );
    }
}

export const bookDB = new BookDatabase();
```

---

## 三、字体/主题设置面板

```typescript
// entry/src/main/ets/components/SettingsPanel.ets
@Component
export struct SettingsPanel {
    @State fontSize: number = 18;
    @State lineHeight: number = 1.8;
    @State theme: string = 'light';
    @State fontFamily: string = 'serif';

    onFontSizeChange: (size: number) => void = () => {};
    onLineHeightChange: (height: number) => void = () => {};
    onThemeChange: (theme: string) => void = () => {};
    onFontFamilyChange: (family: string) => void = () => {};
    onClose: () => void = () => {};

    private fontSizes: number[] = [12, 14, 16, 18, 20, 22, 24, 26, 28];
    private lineHeights: number[] = [1.2, 1.4, 1.6, 1.8, 2.0, 2.2];
    private themes: Array<{ name: string, label: string, bg: string, fg: string }> = [
        { name: 'light', label: '白天', bg: '#FFFFFF', fg: '#333333' },
        { name: 'dark', label: '夜间', bg: '#1A1A1A', fg: '#E0E0E0' },
        { name: 'sepia', label: '护眼', bg: '#F5E6D3', fg: '#5B4636' },
        { name: 'green', label: '绿纸', bg: '#E8F5E9', fg: '#2E7D32' }
    ];
    private fonts: Array<{ name: string, label: string }> = [
        { name: 'serif', label: '宋体' },
        { name: 'sans-serif', label: '黑体' },
        { name: 'cursive', label: '楷体' },
        { name: 'monospace', label: '等宽' }
    ];

    build() {
        Column() {
            // 标题
            Row() {
                Text('阅读设置')
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)

                Button('完成')
                    .fontSize(14)
                    .backgroundColor('transparent')
                    .fontColor('#666')
                    .onClick(this.onClose)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .border({ width: { bottom: 1 }, color: '#EEE' })

            Scroll() {
                Column({ space: 24 }) {
                    // 字号
                    Column({ space: 12 }) {
                        Row() {
                            Text('A')
                                .fontSize(12)
                                .fontColor('#999')

                            Text(`${this.fontSize}px`)
                                .fontSize(16)
                                .layoutWeight(1)
                                .textAlign(TextAlign.Center)

                            Text('A')
                                .fontSize(24)
                                .fontColor('#999')
                        }
                        .width('100%')

                        Slider({
                            value: this.fontSize,
                            min: 12,
                            max: 28,
                            step: 2
                        })
                            .width('100%')
                            .onChange((value) => {
                                this.fontSize = value;
                                this.onFontSizeChange(value);
                            })
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // 行间距
                    Column({ space: 12 }) {
                        Text(`行间距: ${this.lineHeight.toFixed(1)}`)
                            .fontSize(14)
                            .fontColor('#666')

                        Row() {
                            ForEach(this.lineHeights, (h: number) => {
                                Button(`${h.toFixed(1)}`)
                                    .width(60)
                                    .height(36)
                                    .fontSize(12)
                                    .backgroundColor(this.lineHeight === h ? '#FF6600' : '#F5F5F5')
                                    .fontColor(this.lineHeight === h ? '#FFFFFF' : '#666')
                                    .onClick(() => {
                                        this.lineHeight = h;
                                        this.onLineHeightChange(h);
                                    })
                            })
                        }
                        .width('100%')
                        .justifyContent(FlexAlign.SpaceBetween)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // 主题
                    Column({ space: 12 }) {
                        Text('主题')
                            .fontSize(14)
                            .fontColor('#666')

                        Row() {
                            ForEach(this.themes, (t: any) => {
                                Column() {
                                    Text(t.label)
                                        .fontSize(12)
                                        .fontColor(t.fg)
                                }
                                .width(70)
                                .height(50)
                                .backgroundColor(t.bg)
                                .border({
                                    width: this.theme === t.name ? 2 : 0,
                                    color: '#FF6600'
                                })
                                .borderRadius(8)
                                .justifyContent(FlexAlign.Center)
                                .onClick(() => {
                                    this.theme = t.name;
                                    this.onThemeChange(t.name);
                                })
                            })
                        }
                        .width('100%')
                        .justifyContent(FlexAlign.SpaceBetween)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // 字体
                    Column({ space: 12 }) {
                        Text('字体')
                            .fontSize(14)
                            .fontColor('#666')

                        Row() {
                            ForEach(this.fonts, (f: any) => {
                                Button(f.label)
                                    .width(70)
                                    .height(36)
                                    .fontSize(12)
                                    .fontFamily(f.name)
                                    .backgroundColor(this.fontFamily === f.name ? '#FF6600' : '#F5F5F5')
                                    .fontColor(this.fontFamily === f.name ? '#FFFFFF' : '#666')
                                    .onClick(() => {
                                        this.fontFamily = f.name;
                                        this.onFontFamilyChange(f.name);
                                    })
                            })
                        }
                        .width('100%')
                        .justifyContent(FlexAlign.SpaceBetween)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // 预览
                    Column() {
                        Text('预览文本')
                            .fontSize(this.fontSize)
                            .fontFamily(this.fontFamily)
                            .lineHeight(this.lineHeight)
                            .fontColor(this.themes.find(t => t.name === this.theme)?.fg || '#333')
                            .width('100%')
                            .padding(16)
                            .backgroundColor(this.themes.find(t => t.name === this.theme)?.bg || '#FFF')
                            .borderRadius(8)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })
                }
                .width('100%')
                .padding({ top: 16, bottom: 32 })
            }
            .layoutWeight(1)
        }
        .width('100%')
        .height('50%')
        .backgroundColor('#FFFFFF')
        .borderRadius({ topLeft: 16, topRight: 16 })
    }
}
```

---

## 四、更新后的 ReaderPage（整合所有功能）

```typescript
// entry/src/main/ets/pages/ReaderPage.ets
import { router } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { context } from '@kit.UIAbilityKit';
import { worker } from '@kit.ArkTS';
import { EpubServer } from '../utils/EpubServer';
import { bookDB } from '../database/BookDatabase';
import { TocDialog } from '../components/TocDialog';
import { SettingsPanel } from '../components/SettingsPanel';

@Entry
@Component
struct ReaderPage {
    @State bookId: string = '';
    @State epubPath: string = '';
    @State bookTitle: string = '';
    @State serverPort: number = 0;
    @State loading: boolean = true;
    @State progressText: string = '';
    @State progressPercent: number = 0;
    @State showToc: boolean = false;
    @State showSettings: boolean = false;
    @State tocList: Array<any> = [];
    @State currentProgress: number = 0;

    // 阅读设置
    @State fontSize: number = 18;
    @State lineHeight: number = 1.8;
    @State theme: string = 'light';

    private webController: WebviewController = new WebviewController();
    private server: EpubServer = new EpubServer();
    private workerInstance: worker.ThreadWorker | null = null;
    private currentCfi: string = '';

    async aboutToAppear() {
        let params = router.getParams() as Record<string, any>;
        this.bookId = params['bookId'] || 'default';
        this.epubPath = params['epubPath'] || '';
        this.bookTitle = params['title'] || '未知书籍';

        // 加载历史进度
        let saved = await bookDB.getProgress(this.bookId);
        if (saved) {
            this.fontSize = saved.fontSize || 18;
            this.lineHeight = saved.lineHeight || 1.8;
            this.theme = saved.theme || 'light';
            this.currentCfi = saved.currentCfi || '';
        }

        this.startLoadProcess();
    }

    aboutToDisappear() {
        // 保存进度
        this.saveCurrentProgress();
        this.server.stop();
        this.workerInstance?.terminate();
    }

    async saveCurrentProgress() {
        if (this.currentCfi) {
            await bookDB.saveProgress({
                bookId: this.bookId,
                title: this.bookTitle,
                coverPath: '',
                currentCfi: this.currentCfi,
                currentChapter: '',
                progressPercent: this.currentProgress,
                lastReadTime: Date.now(),
                fontSize: this.fontSize,
                lineHeight: this.lineHeight,
                theme: this.theme,
                createTime: Date.now()
            });
        }
    }

    // ... startLoadProcess, startServer, findContentRoot 同上 ...

    // 接收 Web 组件消息
    setupWebMessage() {
        let ports = this.webController.createWebMessagePorts();
        this.webController.postMessage('init', '*', [ports[0]]);

        ports[1].onMessageEvent((event) => {
            let data = JSON.parse(event.data);
            switch (data.type) {
                case 'progress':
                    this.currentCfi = data.cfi;
                    this.currentProgress = data.percent;
                    break;
                case 'toc':
                    this.tocList = JSON.parse(data.toc);
                    break;
                case 'chapterChanged':
                    this.bookTitle = data.title;
                    break;
            }
        });
    }

    // 发送指令到 Web
    sendToWeb(action: string, data?: any) {
        let js = `window.onArkUIAction('${action}', ${JSON.stringify(data || {})})`;
        this.webController.runJavaScript(js);
    }

    build() {
        Stack() {
            // Web 阅读器
            Web({ src: '', controller: this.webController })
                .width('100%')
                .height('100%')
                .javaScriptAccess(true)
                .domStorageAccess(true)
                .fileAccess(true)
                .onPageBegin(() => {
                    this.setupWebMessage();
                    // 注入配置
                    this.webController.runJavaScript(`
                        window.__EPUB_CONFIG__ = {
                            bookPath: '/OEBPS/package.opf',
                            fontSize: ${this.fontSize},
                            lineHeight: ${this.lineHeight},
                            theme: '${this.theme}',
                            savedCfi: '${this.currentCfi}'
                        };
                    `);
                })
                .onTouch((event) => {
                    if (this.loading || this.showToc || this.showSettings) return;
                    let x = event.touches[0].x;
                    let width = display.getDefaultDisplaySync().width;

                    if (x < width / 3) {
                        this.sendToWeb('prevPage');
                    } else if (x > width * 2 / 3) {
                        this.sendToWeb('nextPage');
                    } else {
                        // 中间区域：显示底部控制栏或设置
                        this.showSettings = true;
                    }
                })

            // 加载遮罩
            if (this.loading) {
                Column() {
                    LoadingProgress().width(50).height(50).color('#FF6600')
                    Text(this.progressText).fontSize(14).margin({ top: 16 })
                    Progress({ value: this.progressPercent, total: 100 }).width(200).margin({ top: 8 })
                }
                .width('100%').height('100%')
                .backgroundColor('#FFFFFF')
                .zIndex(100)
            }

            // 顶部标题栏（点击显示）
            Row() {
                Text(this.bookTitle)
                    .fontSize(16)
                    .fontColor('#FFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)

                Button('目录')
                    .fontSize(14)
                    .backgroundColor('transparent')
                    .fontColor('#FFF')
                    .onClick(() => {
                        this.sendToWeb('getToc');
                        this.showToc = true;
                    })

                Button('设置')
                    .fontSize(14)
                    .backgroundColor('transparent')
                    .fontColor('#FFF')
                    .onClick(() => this.showSettings = true)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .backgroundColor('rgba(0,0,0,0.7)')
            .position({ x: 0, y: 0 })

            // 目录弹窗
            if (this.showToc) {
                Row() {
                    TocDialog({
                        tocList: this.tocList,
                        onSelect: (href: string) => {
                            this.sendToWeb('goto', { href: href });
                        },
                        onClose: () => this.showToc = false
                    })
                    .width('80%')
                    .height('100%')

                    Blank()
                        .width('20%')
                        .height('100%')
                        .backgroundColor('rgba(0,0,0,0.5)')
                        .onClick(() => this.showToc = false)
                }
                .width('100%')
                .height('100%')
                .zIndex(200)
            }

            // 设置面板
            if (this.showSettings) {
                Column() {
                    Blank()
                        .height('50%')
                        .backgroundColor('rgba(0,0,0,0.5)')
                        .onClick(() => this.showSettings = false)

                    SettingsPanel({
                        fontSize: this.fontSize,
                        lineHeight: this.lineHeight,
                        theme: this.theme,
                        onFontSizeChange: (v) => {
                            this.fontSize = v;
                            this.sendToWeb('setFontSize', { size: v });
                        },
                        onLineHeightChange: (v) => {
                            this.lineHeight = v;
                            this.sendToWeb('setLineHeight', { height: v });
                        },
                        onThemeChange: (v) => {
                            this.theme = v;
                            this.sendToWeb('setTheme', { theme: v });
                        },
                        onClose: () => this.showSettings = false
                    })
                }
                .width('100%')
                .height('100%')
                .zIndex(200)
            }

            // 进度条
            if (!this.loading) {
                Row() {
                    Progress({ value: this.currentProgress * 100, total: 100 })
                        .width('100%')
                        .height(2)
                        .color('#FF6600')
                }
                .width('100%')
                .position({ x: 0, y: '100%' })
                .translate({ y: -2 })
            }
        }
        .width('100%')
        .height('100%')
    }
}
```

---

## 五、更新后的 reader.html（支持保存的 CFI 恢复）

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>EPUB Reader</title>
    <script src="epub.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body, #viewer { width: 100%; height: 100%; overflow: hidden; }
        .loading {
            position: absolute; top: 50%; left: 50%;
            transform: translate(-50%, -50%);
            font-size: 16px; color: #999;
        }
    </style>
</head>
<body>
    <div id="viewer"></div>
    <div class="loading" id="loading">加载中...</div>

    <script>
        let book = null;
        let rendition = null;
        let config = window.__EPUB_CONFIG__ || {};

        function init() {
            let bookPath = config.bookPath || '/OEBPS/package.opf';
            let baseUrl = location.origin;

            book = ePub(baseUrl + bookPath);

            rendition = book.renderTo('viewer', {
                width: '100%',
                height: '100%',
                flow: 'paginated',
                spread: 'none',
                minSpreadWidth: 800,
                stylesheet: {
                    'font-size': (config.fontSize || 18) + 'px',
                    'line-height': config.lineHeight || 1.8,
                    'font-family': 'serif',
                    'padding': '20px'
                }
            });

            // 应用主题
            applyTheme(config.theme || 'light');

            // 定位到保存的位置
            let displayTarget = config.savedCfi || undefined;

            rendition.display(displayTarget).then(() => {
                document.getElementById('loading').style.display = 'none';
            });

            // 监听位置变化
            rendition.on('relocated', (location) => {
                book.locations.percentageFromCfi(location.start.cfi).then(percent => {
                    sendToArkUI('progress', {
                        cfi: location.start.cfi,
                        percent: percent,
                        href: location.start.href
                    });
                });
            });

            // 获取目录
            book.loaded.navigation.then(nav => {
                window.__TOC_DATA__ = nav.toc;
            });
        }

        function applyTheme(theme) {
            let themes = {
                light: { bg: '#FFFFFF', fg: '#333333' },
                dark: { bg: '#1A1A1A', fg: '#E0E0E0' },
                sepia: { bg: '#F5E6D3', fg: '#5B4636' },
                green: { bg: '#E8F5E9', fg: '#2E7D32' }
            };
            let t = themes[theme] || themes.light;
            document.body.style.backgroundColor = t.bg;
            if (rendition) {
                rendition.themes.override('background-color', t.bg);
                rendition.themes.override('color', t.fg);
            }
        }

        function sendToArkUI(type, data) {
            if (window.__WEB_MESSAGE_PORT__) {
                window.__WEB_MESSAGE_PORT__.postMessage(JSON.stringify({ type, ...data }));
            }
        }

        // 接收 ArkUI 指令
        window.onArkUIAction = function(action, data) {
            switch(action) {
                case 'nextPage': rendition.next(); break;
                case 'prevPage': rendition.prev(); break;
                case 'getToc':
                    sendToArkUI('toc', { toc: JSON.stringify(window.__TOC_DATA__ || []) });
                    break;
                case 'goto':
                    rendition.display(data.href);
                    break;
                case 'setFontSize':
                    rendition.themes.fontSize(data.size + 'px');
                    break;
                case 'setLineHeight':
                    rendition.themes.override('line-height', data.height);
                    break;
                case 'setTheme':
                    applyTheme(data.theme);
                    break;
                case 'prevChapter':
                    let prev = book.package.spine.get(rendition.location?.start?.index - 1);
                    if (prev) rendition.display(prev.href);
                    break;
                case 'nextChapter':
                    let next = book.package.spine.get(rendition.location?.end?.index + 1);
                    if (next) rendition.display(next.href);
                    break;
            }
        };

        // 初始化消息通道
        window.addEventListener('message', (e) => {
            if (e.data === 'init') {
                window.__WEB_MESSAGE_PORT__ = e.ports[0];
            }
        });

        init();
    </script>
</body>
</html>
```

---

## 六、书架页面（入口）

```typescript
// entry/src/main/ets/pages/BookshelfPage.ets
import { router } from '@kit.UIAbilityKit';
import { bookDB } from '../database/BookDatabase';
import { picker } from '@kit.CoreFileKit';

@Entry
@Component
struct BookshelfPage {
    @State books: Array<any> = [];
    @State isLoading: boolean = true;

    async aboutToAppear() {
        this.books = await bookDB.getAllBooks();
        this.isLoading = false;
    }

    async pickEpub() {
        let documentPicker = new picker.DocumentSelectOptions();
        let result = await picker.select(documentPicker);
        if (result && result.length > 0) {
            let uri = result[0];
            // 提取文件名作为 bookId
            let bookId = uri.split('/').pop()?.replace('.epub', '') || 'unknown';

            router.pushUrl({
                url: 'pages/ReaderPage',
                params: {
                    bookId: bookId,
                    epubPath: uri,
                    title: bookId
                }
            });
        }
    }

    @Builder
    BookCard(book: any) {
        Row({ space: 12 }) {
            Image(book.coverPath || $r('app.media.default_cover'))
                .width(80)
                .height(110)
                .objectFit(ImageFit.Cover)
                .borderRadius(4)

            Column({ space: 8 }) {
                Text(book.title)
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(`进度: ${(book.progressPercent * 100).toFixed(1)}%`)
                    .fontSize(12)
                    .fontColor('#999')

                Text(`上次阅读: ${new Date(book.lastReadTime).toLocaleDateString()}`)
                    .fontSize(12)
                    .fontColor('#999')

                Progress({ value: book.progressPercent * 100, total: 100 })
                    .width('100%')
                    .height(3)
                    .color('#FF6600')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height(130)
        .padding(12)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .onClick(() => {
            router.pushUrl({
                url: 'pages/ReaderPage',
                params: {
                    bookId: book.bookId,
                    epubPath: '',  // 已解压，从数据库读取
                    title: book.title
                }
            });
        })
    }

    build() {
        Column() {
            // 标题栏
            Row() {
                Text('书架')
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)

                Button('+')
                    .fontSize(24)
                    .width(48)
                    .height(48)
                    .backgroundColor('#FF6600')
                    .fontColor('#FFFFFF')
                    .borderRadius(24)
                    .onClick(() => this.pickEpub())
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })

            if (this.isLoading) {
                LoadingProgress().width(40).height(40).margin({ top: 100 })
            } else if (this.books.length === 0) {
                Column() {
                    Text('暂无书籍')
                        .fontSize(16)
                        .fontColor('#999')
                        .margin({ top: 100 })

                    Button('导入 EPUB')
                        .margin({ top: 20 })
                        .onClick(() => this.pickEpub())
                }
            } else {
                List() {
                    ForEach(this.books, (book: any) => {
                        ListItem() {
                            this.BookCard(book)
                        }
                        .margin({ bottom: 12 })
                    })
                }
                .width('100%')
                .layoutWeight(1)
                .padding({ left: 16, right: 16, top: 12 })
            }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F5F5F5')
    }
}
```

---

## 七、模块依赖关系

```
pages/
├── BookshelfPage.ets      ← 书架入口
└── ReaderPage.ets         ← 阅读器（整合所有组件）

components/
├── TocDialog.ets          ← 目录弹窗
└── SettingsPanel.ets     ← 设置面板

database/
└── BookDatabase.ets       ← 进度数据库

utils/
└── EpubServer.ets         ← 本地 HTTP 服务器

workers/
└── epub_worker.ets        ← 解压 Worker

resources/rawfile/
├── epub.min.js            ← EPUB.js 库
└── reader.html            ← Web 阅读器
```

---

需要我补充**封面提取**（从 EPUB 中读取封面图片显示在书架）、**全文搜索**、或者**阅读时间统计**的功能吗？