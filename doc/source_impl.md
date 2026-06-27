# LegadoHOS 书源规则实现对照

> 对比 `source.md`（规则标准）与代码实际实现
> 生成日期: 2026-06-27

---

## 目录

1. [Default 规则实现](#1-default-规则实现)
2. [CSS 规则实现](#2-css-规则实现)
3. [JSONPath 规则实现](#3-jsonpath-规则实现)
4. [XPath 规则实现](#4-xpath-规则实现)
5. [JavaScript 表达式实现](#5-javascript-表达式实现)
6. [正则规则实现](#6-正则规则实现)
7. [URL 模板与 JSON 选项实现](#7-url-模板与-json-选项实现)
8. [LegadoHOS 特有扩展](#8-legadohos-特有扩展)
9. [实现差距总表](#9-实现差距总表)

---

## 1. Default 规则实现

### 1.1 核心实现文件

| 文件 | 职责 | 关键方法 |
|------|------|---------|
| `entry/src/main/ets/util/HtmlParser.ts` (951行) | HTML 解析 + CSS 选择器 | `evaluateLegado()`, `extractAttr()`, `matchSimple()` |
| `entry/src/main/ets/engine/source/RuleParser.ts` | 规则连接符解析 | `parseRuleList()`, `parse()` |
| `entry/src/main/ets/engine/source/RuleAnalyzer.ts` | 规则编排 | `evaluateRule()` |

### 1.2 选择器类型实现对照

| 选择器类型 | 标准格式 | 实现状态 | 实现位置 | 说明 |
|-----------|---------|---------|---------|------|
| tag | `div` | ✅ | `HtmlParser.ts:806` | `matchSimple()` 正则匹配标签名 |
| class | `.title` | ✅ | `HtmlParser.ts:812` | `classMatches` 提取所有类名匹配 |
| id | `#content` / `id.content` | ✅ | `HtmlParser.ts:818` | ID 匹配 + `normalizeCssRule` 转换 `id.`→`#` |
| text | `text.关键字` | ✅ | `HtmlParser.ts:773` | 通过 `:contains()` 实现 |
| children | `children` | ✅ | `HtmlParser.ts` | 直接返回所有子元素 |

### 1.3 位置索引实现

| 语法 | 状态 | 实现 |
|------|------|------|
| `tag.N` (正数) | ✅ | `HtmlParser.ts:658` — `stripSuffix()` 提取数字位置 |
| `tag.-N` (负数) | ✅ | 同上 — `realIdx = els.length + position` |
| `tag.0:3` (范围) | ❌ | 未实现 — `stripSuffix()` 仅支持单个位置 |
| `tag!N` (排除) | ✅ | `HtmlParser.ts:536` — `stripSuffix()` 排除索引逻辑 |
| `tag!N:M` (排除范围) | ✅ | 同上 — `for (let i = firstIdx; i <= endIdx; i++)` |

### 1.4 @ 分隔符实现

| 规则 | 实现 |
|------|------|
| `@` 作为后代组合器 | `HtmlParser.ts:513` — `normalizeCssRule()` 将 `@` 展开为空格 |
| HTML 标签白名单 | `HtmlParser.ts` — 仅白名单标签才展开 `@`，避免误转 `@js:`、`@data-*` |
| 裸属性名回退 | `HtmlParser.ts:316` — `text/href/src/html/ownText/textNodes/value` 直接作为属性提取 |

### 1.5 属性后缀实现 (`extractAttr`)

| 后缀 | 状态 | 实现位置 | 说明 |
|------|------|---------|------|
| `@text` | ✅ | `HtmlParser.ts:337` | `cleanText(el.text)` — 合并空白 |
| `@ownText` | ✅ | `HtmlParser.ts:340` | `cleanText(el.ownText)` — 仅直接文本 |
| `@textNodes` | ⚠️ | `HtmlParser.ts:314` | 被降级为 `text` (`if (suffix==='textnodes') suffix='text'`) |
| `@href` | ✅ | `HtmlParser.ts:343` | `el.attributes['href']` |
| `@src` | ✅ | `HtmlParser.ts:344` | `el.attributes['src']` |
| `@html` | ✅ | `HtmlParser.ts:348` | `el.innerHtml` |
| `@value` | ✅ | `HtmlParser.ts:345` | `el.attributes['value']` (2026-06-27 新增) |
| `@all` | ✅ | `HtmlParser.ts` | `el.outerHtml` |

### 1.6 `##` 正则链替换

| 功能 | 状态 | 实现位置 |
|------|------|---------|
| 单级替换 `##regex##replacement` | ✅ | `HtmlParser.ts:356-367` |
| 多级替换 `##r1##s1##r2##s2` | ✅ | 同上 — `for` 循环偶数步进 |
| 空替换 (删除) | ✅ | `replacement = (i+1 < parts.length) ? parts[i+1] : ''` |

### 1.7 @put / @get 变量

| 功能 | 状态 | 实现位置 | 说明 |
|------|------|---------|------|
| `@get:{key}` 读取 | ✅ | `RuleParser.ts:107-110` | 正则提取 key，由调用方替换 |
| `@put:{key:value}` 存储 | ❌ | — | **未实现**。`grep parsePutDirective` 无结果 |
| JS 端 `java.put()` | ✅ | `ScriptApi.ts:94` | Polyfill 内 `_javaStore` 闭包存储 |
| JS 端 `java.get()` | ✅ | `ScriptApi.ts:86` | Polyfill 内 `_javaStore[key]` 读取 |

---

## 2. CSS 规则实现

### 2.1 基本支持

| 选择器类型 | 标准 | 状态 | 实现位置 |
|-----------|------|------|---------|
| tag `div` | ✅ | ✅ | `HtmlParser.ts:806` |
| `.class` | ✅ | ✅ | `HtmlParser.ts:812` |
| `#id` | ✅ | ✅ | `HtmlParser.ts:818` |
| `tag.class` / `tag#id` | ✅ | ✅ | 组合匹配 |
| 后代 `div p` | ✅ | ✅ | `HtmlParser.ts:591` |
| 子元素 `div > p` | ✅ | ✅ | `HtmlParser.ts:595` |
| 相邻兄弟 `div + p` | ✅ | ✅ | `HtmlParser.ts:612-620` |
| 后续兄弟 `div ~ p` | ✅ | ✅ | `HtmlParser.ts:622-628` |
| 多类 `.c1.c2` | ✅ | ✅ | `HtmlParser.ts:812` |

### 2.2 属性选择器

| 操作符 | 示例 | 状态 | 实现位置 |
|--------|------|------|---------|
| `[attr]` | `[href]` | ✅ | `HtmlParser.ts:824-830` |
| `[attr=val]` | `[href=xxx]` | ✅ | 同上 |
| `[attr^=val]` | `[href^=https]` | ✅ | 同上 + `HtmlParser.ts:890` |
| `[attr$=val]` | `[href$=.jpg]` | ✅ | 同上 + `HtmlParser.ts:891` |
| `[attr*=val]` | `[href*=book]` | ✅ | 同上 + `HtmlParser.ts:892` |
| `[attr~=val]` | `[class~=item]` | ✅ | `HtmlParser.ts:898` |
| `[attr|=val]` | `[lang|=zh]` | ✅ | `HtmlParser.ts:899` |

### 2.3 CSS 伪类

| 伪类 | 状态 | 实现位置 | 说明 |
|------|------|---------|------|
| `:contains(text)` | ✅ | `HtmlParser.ts:773-775` | 支持有引号/无引号双模式 |
| `:not(selector)` | ✅ | `HtmlParser.ts:779-782` | 否定选择器 |
| `:has(selector)` | ✅ | `HtmlParser.ts:785-788` | 子元素存在性筛选 |
| `:nth-child(n)` | ✅ | `HtmlParser.ts:791-794, 915` | 第 N 个子元素 |
| `:nth-of-type(n)` | ✅ | `HtmlParser.ts:797-800, 920` | 第 N 个同类型元素 |
| `:first` / `:last` | ❌ | — | 可被 `:nth-child(1)` / `:nth-child(-1)` 替代 |
| `:eq()` | ❌ | — | 可被 `:nth-child()` 替代 |
| CSS 逗号分组 `.s1,.s7` | ❌ | — | 不支持一次选择多个独立路径 |

### 2.4 CSS 规则执行路径

```
@css:.bookbox a@href
  → RuleAnalyzer.evaluateRule()
    → 检测 @css: 前缀 → stripPrefix('@css:')
    → HtmlParser.querySelectorAll(doc, '.bookbox a')
      → 返回匹配元素列表
    → HtmlParser.extractAttr(doc, '@css:.bookbox a@href')
      → 提取第一个匹配元素的 href 属性
```

---

## 3. JSONPath 规则实现

### 3.1 基本支持

| 语法 | 状态 | 实现位置 |
|------|------|---------|
| `$.field` 点路径 | ✅ | `RuleParser.ts` — `parse()` 中检测 `$.` 前缀 |
| `[n]` 数组索引 | ✅ | 同上 — 下标访问 |
| `[*]` 数组遍历 | ✅ | 同上 — `flatMap` |
| `..` 递归搜索 | ✅ | 同上 — 深度遍历 |
| `@json:` 前缀 | ✅ | `RuleAnalyzer.ts` — 检测 `@json:` 前缀 |

### 3.2 注意事项

- 实现为简易路径遍历，非完整 JSONPath 规范（不支持 `[?()]` 过滤表达式、`[::]` 切片）
- 使用 `JSON.parse()` 解析响应体后进行遍历
- 与 CSS 规则的区分逻辑：`isJsonRule()` 检测 `$.` / `@json:` 开头

---

## 4. XPath 规则实现

| 功能 | 状态 | 说明 |
|------|------|------|
| 独立 XPath 引擎 | ❌ | 未实现 |
| `//` 到 CSS 的转换 | ⚠️ | `RuleParser.ts` 检测 `//` 前缀后移除，直接传递给 CSS 选择器 |
| `tag[n]` → `:nth-of-type(n)` | ⚠️ | 理论上可工作（`:nth-of-type` 已实现），但需代码确认转换逻辑存在 |

---

## 5. JavaScript 表达式实现

### 5.1 引擎架构

```
JS 代码 → 预处理 (无 with-block 提升) → QuickJS NAPI (C++ 桥) → ArkTS 回调
```

| 组件 | 文件 | 行数 | 说明 |
|------|------|------|------|
| QuickJS 桥接 | `napi/quickjs_bridge.ts` | — | NAPI 调用 `libquickjs_bridge.so` |
| 引擎封装 | `engine/source/ScriptEngine.ts` | 176 | 引擎生命周期 + HTTP 回调注册 |
| Polyfill | `engine/source/ScriptApi.ts` | 1073 | Java 兼容层、MD5、Base64、AES |
| 规则执行 | `engine/source/SourceExecutor.ts` | 2369 | 搜索/详情/目录/正文各阶段的 JS 调用 |
| Worker 执行 | `workers/JsEvalWorker.ts` | — | 独立线程场景（RSS sortUrl） |

### 5.2 Java 桥接 API 实现

| API | 规则标准 | 实现状态 | 实现位置 | 说明 |
|-----|---------|---------|---------|------|
| `java.ajax(url)` | HTTP 请求 | ⚠️ | `ScriptApi.ts:113` | Polyfill 空实现（返回 `''`）。实际通过 ArkTS `NetUtil` 处理，buildUrl 中有预取机制 |
| `java.md5Encode(str)` | MD5 | ✅ | `ScriptApi.ts:156` | 纯 JS MD5 实现 (~104 行) |
| `java.md5Encode16(str)` | 16位MD5 | ✅ | `ScriptApi.ts:397` | 取 MD5 中间 16 位 |
| `java.base64Decode(str)` | Base64解码 | ✅ | `ScriptApi.ts:127` | 优先 `Base64.decode()` → `atob()` 兜底 |
| `java.base64Encode(str)` | Base64编码 | ✅ | `ScriptApi.ts:135` | 优先 `Base64.encode()` → `btoa()` 兜底 |
| `java.timeFormat(ts)` | 时间格式化 | ✅ | `ScriptApi.ts:145` | Polyfill `SimpleDateFormat` 兼容 |
| `java.put(key, val)` | 变量存储 | ✅ | `ScriptApi.ts:94` | `_javaStore` 闭包 |
| `java.get(key)` | 变量读取 | ✅ | `ScriptApi.ts:86` | `_javaStore[key]` |
| `java.setContent(html, url)` | 内容设置 | ❌ | — | 未在 polyfill 中找到 |
| `java.ajaxAll(urls)` | 并发请求 | ⚠️ | `ScriptApi.ts:351` | Polyfill 存根，使用模拟 `http.get()`，QuickJS 内可能死锁 |
| `java.connect(url)` | HTTP响应 | ⚠️ | `ScriptApi.ts:320` | Polyfill 存根，同上问题 |
| `java.webView(url)` | WebView渲染 | ⚠️ | `ScriptApi.ts:120` | 返回 `[[WEBVIEW_RESULT:URL]]` 标记，由 ArkTS 侧检测处理 |
| `java.aesBase64DecodeToString()` | AES解密 | ✅ | `ScriptApi.ts:401` | 纯 JS Rijndael AES-CBC + PKCS7 |
| `java.importScript(path)` | 远程加载JS | ⚠️ | `ScriptApi.ts:381` | 使用模拟 `http.get()` |

### 5.3 with-block 函数提升

| 项目 | 状态 | 说明 |
|------|------|------|
| 标准要求 | QuickJS 需将 `with(scope) { function f(){} }` 中的 `f` 提升到外部 | |
| 实现状态 | ❌ **未实现** | 代码审查确认不存在预处理逻辑 |
| 影响 | 七猫等书源的 AES 解密 `decode()` 函数不可访问，抛出 `TypeError: not a function` |
| 替代方案 | 需实现基于括号计数的解析器提取声明，或手动修改书源 JS |

### 5.4 jsLib 缓存

| 项目 | 状态 | 说明 |
|------|------|------|
| `jsLib` 字段 | ✅ 存在 | `BookSource.ts` 中定义，存储 JS 库 URL |
| 缓存机制 | ❌ 未实现 | 每次重新执行 jsLib 脚本，无编译缓存 |

### 5.5 NAPI 返回值编码

| 问题 | 说明 | 状态 |
|------|------|------|
| 双 JSON 编码 | NAPI `executeScript()` 返回 `JSON.stringify(jsResult)`，字符串结果被额外引号包裹 | ⚠️ 多处已修复（`evalJsForNoteUrl`、`executeTocUrlJs`），但仍无统一解码封装 |
| 统一封装 | `executeScriptWithDecode()` | ❌ 未实现 |

---

## 6. 正则规则实现

### 6.1 AllInOne（列表规则）

| 功能 | 状态 | 实现位置 |
|------|------|---------|
| `:` 前缀检测 | ✅ | `RuleAnalyzer.ts` |
| 多组捕获 → 字段映射 | ✅ | `AnalyzeByRegex.ts` |

### 6.2 OnlyOne（单字段）

| 功能 | 状态 | 实现位置 |
|------|------|---------|
| `##regex##replacement###` | ✅ | `HtmlParser.ts:306` — extractAttr 中 `##` 分离 |

### 6.3 连接操作符

| 操作符 | 标准 | 实现状态 | 实现位置 |
|--------|------|---------|---------|
| `\|\|` 优先 | ✅ | ✅ | `RuleParser.ts` — `parseRuleList('||')` |
| `&&` 合并 | ✅ | ✅ | `RuleParser.ts` — `parseRuleList('&&')` |
| `%%` 交错 | ✅ | ✅ | `RuleParser.ts` — `parseRuleList('%%')` |

---

## 7. URL 模板与 JSON 选项实现

### 7.1 URL 模板变量

| 变量 | 状态 | 实现位置 |
|------|------|---------|
| `{{key}}` / `{{keyword}}` | ✅ | `SourceExecutor.ts` — `buildUrl()` 中 URL 模板替换 |
| `{{page}}` / `{{pageNum}}` | ✅ | 同上 |
| `{{baseUrl}}` | ✅ | 同上 |
| `{{source.xxx}}` | ✅ | 同上 |

### 7.2 JSON 选项

| 选项 | 状态 | 实现位置 | 说明 |
|------|------|---------|------|
| `method` | ✅ | `SourceExecutor.ts` — `collapseUrlJson()` + `buildUrl()` | GET/POST 切换 |
| `body` | ✅ | 同上 | 支持 `{{key}}` 模板 |
| `headers` | ✅ | 同上 | 自定义请求头 |
| `charset` | ✅ | 同上 | 编码检测覆盖 |
| `webView` | ✅ | `SourceExecutor.ts` | WebView 渲染兜底 |
| 多行 JSON | ✅ | `SourceExecutor.ts:27` — `collapseUrlJson()` | 归一化换行为空格（2026-06-27 修复） |

---

## 8. LegadoHOS 特有扩展

### 8.1 与 Android Rhino 的关键差异

| 差异点 | Android (Rhino) | LegadoHOS (QuickJS) | 影响 |
|--------|----------------|---------------------|------|
| `with(scope) { function f(){} }` | 函数提升到外部 | 不提升 | 七猫 AES 解密失败 |
| `JavaImporter` | 原生支持 | 需手写垫片 | polyfill 中 |
| `Packages.java.*` | 原生支持 | ❌ 未实现 | 某些书源可能依赖 |
| `java.ajax()` | 同步阻塞 HTTP | 需两阶段桥接 | content 规则已实现 |
| 脚本编译缓存 | 支持 `CompiledScript` | 不支持 | 每次重新执行 |

### 8.2 扩展的 CSS 能力

相比 Android Legado 的 Jsoup，LegadoHOS HtmlParser 额外实现了：

| 能力 | Jsoup | HtmlParser |
|------|-------|-----------|
| `:has(selector)` | ❌ | ✅ |
| 位置索引 `tag.N` | ❌ (需 JS) | ✅ |
| 排除索引 `tag!N` | ❌ | ✅ |
| 裸属性名回退 | ❌ | ✅ |
| `@value` 后缀 | ❌ | ✅ |
| `:contains()` 无引号 | ❌ | ✅ |

---

## 9. 实现差距总表

### 9.1 ❌ 未实现（需开发）

| 功能 | 优先级 | 涉及文件 | 影响 |
|------|--------|---------|------|
| `@put:{key:value}` 存储指令 | P1 | `RuleParser.ts` | `@get` 读取已实现但 `@put` 无存储 |
| with-block 函数提升预处理 | P0 | `SourceExecutor.ts` | 七猫等书源 AES 解密失败 |
| `java.ajax()` 通用桥接（非仅 content） | P0 | `SourceExecutor.ts` | explore/search 规则中的 ajax 调用 |
| `Packages.java.*` 全局定义 | P2 | `ScriptApi.ts` / napi | 部分书源可能依赖 |
| jsLib 脚本缓存 | P1 | `ScriptEngine.ts` | 重复执行性能浪费 |
| `executeScriptWithDecode()` 统一封装 | P1 | `ScriptEngine.ts` | NAPI 双 JSON 编码需统一 |
| `getStoredHeaders()` 统一封装 | P1 | `SourceExecutor.ts` | headers 读取代码重复 |
| CSS 逗号分组 `.s1,.s7` | P2 | `HtmlParser.ts` | 少部分书源使用 |
| `:first` / `:last` / `:eq()` | P2 | `HtmlParser.ts` | 可被 `:nth-child()` 替代 |
| XPath 引擎 | P2 | — | 需新实现 |
| `@textNodes` 独立实现（非降级） | P3 | `HtmlParser.ts` | 目前与 `@text` 相同 |
| `java.ajaxAll()` / `java.connect()` 真正实现 | P3 | `ScriptApi.ts` | 目前仅存根 |
| `cookie.removeCookie()` | P3 | `ScriptApi.ts` | QuickJS 中未定义 |

### 9.2 ⚠️ 部分实现

| 功能 | 当前状态 | 缺失部分 |
|------|---------|---------|
| Default 规则范围索引 `tag.0:3` | 仅单索引 | 范围语法 |
| `extractAttr` @textNodes | 被降级为 text | 独立实现 |
| java.ajax content 预取 | content 规则可工作 | 其他规则未桥接 |
| java.ajaxAll / java.connect | Polyfill 存根 | QuickJS 内 HTTP 可能死锁 |
| java.webView | 标记字符串 | WebView 渲染后注入需完善 |

### 9.3 ✅ 完整实现

| 功能 | 关键文件 |
|------|---------|
| Default 规则基础解析（tag/class/id/text/children） | `HtmlParser.ts` |
| 位置索引（正数/负数/排除） | `HtmlParser.ts` |
| `##` 正则链替换 | `HtmlParser.ts` |
| CSS 标签/类/ID/后代/子/兄弟选择器 | `HtmlParser.ts` |
| CSS 属性选择器（= / ^= / $= / *= / ~= / \|=） | `HtmlParser.ts` |
| CSS 伪类（:contains / :not / :has / :nth-child / :nth-of-type） | `HtmlParser.ts` |
| 属性后缀（@text / @href / @src / @html / @ownText / @value） | `HtmlParser.ts:336-350` |
| 裸属性名回退 | `HtmlParser.ts:316-318` |
| JSONPath 简单路径遍历 | `RuleParser.ts` |
| @get:{key} 变量读取 | `RuleParser.ts:107-110` |
| java.put / java.get | `ScriptApi.ts:86-97` |
| java.md5Encode / md5Encode16 | `ScriptApi.ts:156-397` |
| java.base64Decode / base64Encode | `ScriptApi.ts:127-138` |
| java.aesBase64DecodeToString | `ScriptApi.ts:401` (纯 JS Rijndael) |
| java.timeFormat | `ScriptApi.ts:145` |
| URL 模板 {{key}} / {{page}} / {{baseUrl}} | `SourceExecutor.ts buildUrl()` |
| JSON 选项 (method/body/headers/charset/webView) | `SourceExecutor.ts collapseUrlJson()` |
| 多行 JSON 归一化 | `SourceExecutor.ts:27` |
| 连接操作符 \|\| / && / %% | `RuleParser.ts` |
| 正则 AllInOne / OnlyOne / 净化 | `AnalyzeByRegex.ts` + `HtmlParser.ts` |
