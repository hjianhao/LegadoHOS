# Legado 书源规则详解

> 参考: https://celeter.github.io/ (JSOUP 规则文档)
> 实现: LegadoHOS — HarmonyOS ArkTS 阅读 App

---

## 目录

1. [规则体系概述](#1-规则体系概述)
2. [Default 规则（核心）](#2-default-规则核心)
3. [CSS 规则](#3-css-规则)
4. [JSONPath 规则](#4-jsonpath-规则)
5. [XPath 规则](#5-xpath-规则)
6. [JavaScript / JS 表达式](#6-javascript--js-表达式)
7. [正则规则](#7-正则规则)
8. [URL 模板与构建规则](#8-url-模板与构建规则)
9. [连接操作符](#9-连接操作符)
10. [LegadoHOS 实现差异](#10-legadohos-实现差异)
11. [常见问题与修复记录](#11-常见问题与修复记录)

---

## 1. 规则体系概述

Legado 书源规则共有 **6 种规则类型**，按优先级排列：

| 规则类型 | 标识前缀 | 用途 |
|---------|---------|------|
| Default 规则 | 无前缀（默认） | 元素选择、属性提取 |
| CSS 规则 | `@css:` | 标准 CSS 选择器 |
| JSONPath | `$.` 或 `@json:` | JSON 数据提取 |
| XPath | `//` 或 `@XPath:` | XPath 选择器 |
| JavaScript | `@js:` 或 `<js>` | JS 表达式求值 |
| 正则规则 | `:` (AllInOne) 或 `##` (净化) | 正则匹配提取 |

**优先级说明**：
- 在 `{{}}` 中，默认为 JS，其他规则需带标识前缀
- 在规则字段中（如 `ruleSearchName`），默认为 Default 规则，CSS 需带 `@css:` 前缀
- 正则替换 `##` 只能跟在其他规则后面使用

---

## 2. Default 规则（核心）

### 2.1 基本格式

```
类型.名称.位置@类型.名称.位置@...@获取内容
```

每段规则用 `@` 分隔，逐层深入 DOM。最后一段为提取内容。

### 2.2 三段式结构

每段规则分为三段，用 `.` 分隔：

```
类型 . 名称 . 位置
```

| 段 | 必填 | 说明 |
|----|------|------|
| **类型** | 部分 | 如 `class`、`id`、`tag`、`text`、`children` |
| **名称** | 大部分 | 类型对应的值（类名、标签名、id值、文本内容） |
| **位置** | 可选 | 数字索引，0=第一个，负数=倒数。省略=全部 |

类型可省略，通过前缀推断：
- 以 `.` 开头 → type=class（如 `.novelslist2` = class=novelslist2）
- 以 `#` 开头 → type=id（如 `#content` = id=content）
- 直接写标签名 → type=tag（如 `div` = tag=div）

### 2.3 类型对照表

| 类型 | 写法示例 | 含义 |
|------|---------|------|
| tag | `div`、`a`、`li` | HTML 标签名 |
| class | `.title`、`.item` | CSS 类名 |
| id | `id.content`、`#content` | HTML ID |
| text | `text.关键字` | 包含特定文本的元素 |
| children | `children` | 获取所有直接子元素（不需要名称和位置） |

### 2.4 位置索引

位置为纯数字，支持正数和负数：

| 写法 | 含义 |
|------|------|
| `a.0` | 第 1 个 `a` 元素 |
| `a.1` | 第 2 个 `a` 元素 |
| `td.2` | 第 3 个 `td` 元素 |
| `p.-1` | 最后 1 个 `p` 元素 |
| `p.-2` | 倒数第 2 个 `p` 元素 |
| `div.0` | 第 1 个 `div` 元素 |
| `.item.0` | 第 1 个 class="item" 的元素 |
| `li` | 全部 `li` 元素（不指定位置） |

### 2.5 排除索引 `!`

排除指定索引的元素，类似于"跳过"：

| 写法 | 含义 |
|------|------|
| `a!0` | 排除第 1 个 `a`（从第 2 个开始） |
| `a!0:2` | 排除第 1 到第 3 个（区间） |
| `a!-1` | 排除最后 1 个 |
| `.item!0:2:-1` | 排除前 3 个和最后 1 个 |

### 2.6 `@` 分隔符

`@` 在 Default 规则中既是分段符又是后代组合器：

| 写法 | 含义 |
|------|------|
| `a.0@text` | 第 1 个 `a` 元素的 → 提取文本 |
| `.novelslist2@li` | class="novelslist2" 内 → 找 `li` 元素 |
| `id.content@a` | id="content" 内 → 找 `a` 元素 |
| `.table@tbody@tr` | class="table" 内 → 找 `tbody` → 再找 `tr` |
| `h3@a@text` | `h3` 内 → 找 `a` → 提取文本 |

> **注意**：在 Legado 中，`@` 连接两个选择器始终表示**后代关系**（空格），不是 CSS 的 `tag.class` 同元素关系。例如 `.novelslist2@li` = `.novelslist2 li`（找内部的 li），不是 `li.novelslist2`。

### 2.7 获取内容（最后一段）

`@` 最后一段指定提取内容：

| 获取内容 | 说明 |
|---------|------|
| `@text` | 所有后代文本（压缩空白） |
| `@textNodes` | 仅直接文本节点（不含子元素文本） |
| `@ownText` | 仅元素自身的直接文本 |
| `@href` | href 属性值 |
| `@src` | src 属性值 |
| `@html` | 内部 HTML |
| `@all` | 整个外部 HTML |

### 2.8 简写形态速查

| 完整写 | 简写 | 含义 |
|--------|------|------|
| `tag.div.0@text` | `div.0@text` | 第 1 个 div 的文本 |
| `class.title.0@text` | `.title.0@text` | 第 1 个 .title 的文本 |
| `tag.a.0@href` | `a.0@href` | 第 1 个 a 的 href |
| `id.content.0@text` | `#content@text` 或 `id.content@text` | id=content 的文本 |

### 2.9 正则替换后缀

在规则后加 `##正则##替换` 进行文本处理：

```
a.0@text##\s+||
td.2@text##全文阅读.*$$
```

- 替换内容为空时第二个 `##` 可省略
- 支持多级替换：`##正则1##替换1##正则2##替换2`

### 2.10 @put 与 @get 变量

```
@put:{bid:"//*[@bid-data]/@bid-data"}
@get:bid
```

- `@put` 将提取的值存为变量（可在后续规则中引用）
- `@get` 引用之前 put 的变量
- 仅能用于非 JS 规则中
- JS 中使用 `java.put()` / `java.get()`

### 2.11 @@ 前缀

在 `{{}}` 中，Default 规则要以 `@@` 开头（因为 `{{}}` 默认是 JS）：

```
{{@@a.0@text}}
```

---

## 3. CSS 规则

### 3.1 基本格式

必须以 `@css:` 开头：

```
@css:选择器
@css:选择器@text
```

### 3.2 示例

```
@css:.bookbox a@href
@css:#content@html
@css:ul.list > li@text
```

### 3.3 支持的选择器

基于 Jsoup/HTML Parser 实现：

| 选择器 | 示例 | 说明 |
|--------|------|------|
| tag | `div` | 标签选择器 |
| .class | `.title` | 类选择器 |
| #id | `#content` | ID 选择器 |
| tag.class | `div.book` | 标签+类 |
| tag#id | `div#main` | 标签+ID |
| 后代 | `div p` | 空格分隔 |
| 子元素 | `div > p` | `>` 分隔 |
| 属性 | `[href]` | 有属性 |
| 属性=值 | `[href=xxx]` | 属性等于 |
| 属性^= | `[href^=https]` | 属性开头匹配 |
| 属性$= | `[href$=.jpg]` | 属性结尾匹配 |
| 属性*= | `[href*=book]` | 属性包含匹配 |
| 属性~= | `[class~=item]` | 属性空格分隔匹配 |
| 属性\|= | `[lang\|=zh]` | 属性等于或 `value-` 前缀 |

### 3.4 获取内容

同 Default 规则：`@text`、`@href`、`@src`、`@html`、`@ownText`

---

## 4. JSONPath 规则

### 4.1 基本格式

以 `$.` 或 `@json:` 开头：

```
$.data.books[*].name
@json:$.data.list
```

### 4.2 语法

| 表达式 | 含义 |
|--------|------|
| `$` | 根对象 |
| `.field` | 字段访问 |
| `[n]` | 数组索引 |
| `[*]` | 数组遍历（返回全部） |
| `..` | 递归搜索 |

### 4.3 示例

```
$.data.novel_list||$.data
$.booklist[*].title
$.bid
```

### 4.4 在 {{}} 中使用

```
{{$.book_id}}
{{@json:$.data.url}}
```

---

## 5. XPath 规则

### 5.1 基本格式

以 `//` 或 `@XPath:` 开头：

```
//div[@class='book']
@XPath://a/@href
```

### 5.2 注意

- LegadoHOS 未实现 XPath 引擎，遇到 `//` 开头的规则会转换为 CSS
- 转换规则：`tag[n]` → `:nth-of-type(n)`（但 CSS 引擎未实现该伪类，可能不生效）

---

## 6. JavaScript / JS 表达式

### 6.1 基本格式

```
@js:表达式
<js>代码</js>
```

### 6.2 在规则字段中使用

```
searchName: @js:JSON.parse(result).title
searchName: a.0@text@js:result.replace(/^《|》$/g,'')
```

`@js:` 只能放在规则最后执行。

### 6.3 在 URL 模板中使用

```
searchUrl: @js:..."https://api.example.com/search?keyword="+key
searchUrl: https://example.com/search?q={{key}}&page={{page}}
```

### 6.4 可用变量

| 变量 | 说明 |
|------|------|
| `key` / `keyword` | 搜索关键字 |
| `page` | 当前页码（从 0 开始） |
| `pageNum` | 当前页码（从 1 开始） |
| `baseUrl` | 书源基础 URL |
| `result` | 当前规则的提取结果 |
| `source` | 书源对象（`source.getKey()` 获取 URL） |
| `cookie` | Cookie 操作 |
| `java` | Java 桥接对象（详见下） |

### 6.5 Java 桥接 API

| 方法 | 说明 |
|------|------|
| `java.ajax(url)` | HTTP 请求，返回字符串 |
| `java.md5Encode(str)` | MD5 编码 |
| `java.md5Encode16(str)` | MD5 16 位编码 |
| `java.base64Decode(str)` | Base64 解码 |
| `java.base64Encode(str)` | Base64 编码 |
| `java.timeFormat(timestamp)` | 时间戳格式化 |
| `java.get(rule)` | 获取文本 |
| `java.put(key, value)` | 存储变量 |
| `java.get(key)` | 读取变量 |
| `java.setContent(content, baseUrl)` | 设置解析内容和 baseUrl |

---

## 7. 正则规则

### 7.1 AllInOne（列表规则）

以 `:` 开头，用于搜索列表、发现列表等：

```
:正则表达式
:（完整正则，含多组捕获）
```

捕获组依次对应：书名、作者、链接、封面等。

### 7.2 OnlyOne（单字段）

```
##正则表达式##替换内容###
```

只能用于非列表字段，只取第一个匹配。

### 7.3 净化（文本处理）

```
##正则表达式##替换内容
```

跟在其他规则后面使用，循环替换。

---

## 8. URL 模板与构建规则

### 8.1 URL 模板变量

```
{{key}}      → encodeURIComponent(搜索关键字)
{{keyword}}  → encodeURIComponent(搜索关键字)
{{page}}     → 页码（从 0 开始）
{{pageNum}}  → 页码（从 1 开始）
```

### 8.2 @js: 表达式

```
searchUrl: @js:构建完整的搜索 URL
```

内部可用 `key`、`page`、`baseUrl`、`source` 等变量。

### 8.3 JSON 选项

在 URL 末尾附加 JSON 选项，用 `,` 分隔：

```
url,{"method":"POST","body":"keyword={{key}}"}
url,{"method":"POST","body":"{\"keyword\":\"{{key}}\"}","headers":{"Content-Type":"application/json"}}
url,{'method':'POST','body':'keyword={{key}}'}
url,{'webView': true}
```

支持格式：
| 参数 | 说明 |
|------|------|
| `method` | GET / POST |
| `body` | 请求体（支持 `{{key}}` 模板） |
| `headers` | 自定义请求头 |
| `charset` | 字符编码 |
| `webView` | 是否用 WebView 加载 |

### 8.4 cookie 处理

```
{{cookie.removeCookie(source.getKey())}}
```

用于清除书源域名的 cookie，避免缓存影响。

---

## 9. 连接操作符

只能用于同种规则之间（不包括 JS 和正则）：

| 操作符 | 行为 | 说明 |
|--------|------|------|
| `||` | 优先 | 以第一个取到值的为准 |
| `&&` | 合并 | 合并所有取到的值 |
| `%%` | 交错 | 依次取数（类似 zip） |

### 示例

```
searchList: .novelslist2@li!0||.l@li
  → 优先用 .novelslist2 li，失败则用 .l li

searchName: name||title||bookName
  → 优先用 name，失败用 title，再失败用 bookName

searchAuthor: td.1@text%%td.2@text
  → 如果作者分两列显示，交错合并
```

---

## 10. LegadoHOS 实现差异

### 10.1 支持的规则

| 规则类型 | LegadoHOS | Android Legado | 说明 |
|---------|-----------|---------------|------|
| Default 规则 | ✅ 完整 | ✅ | 核心规则 |
| CSS 规则 | ✅ 基础 | ✅ | 标准 CSS 选择器 |
| JSONPath | ✅ | ✅ | `$.` 和 `@json:` |
| XPath | ⚠️ 有限 | ✅ | 遇到 `//` 转 CSS |
| JavaScript | ✅ | ✅ | QuickJS 引擎 |
| 正则 AllInOne | ✅ | ✅ | `:` 开头 |
| 正则替换 `##` | ✅ | ✅ | 文本净化 |

### 10.2 已修复的解析缺陷

#### 修复 1：normalizeCssRule（SourceExecutor.ts:2333-2368）

**功能**：将 Legado Default 规则语法转换为 HtmlParser 能识别的标准 CSS。

| 转换 | 说明 |
|------|------|
| `@@class` → `.class` | Legado CSS 类选择器简写 |
| `id.XXX` → `#XXX` | Legado ID 选择器 |
| `.class@tag` → `.class tag` | `@` 展开为后代空格 |
| `tag1@tag2` → `tag1 tag2` | 同上 |
| `@text/@href/@src` | 保留（非 HTML 标签） |
| `@js:/@put:/@data-*` | 保留（非标签引用） |

**HTML 标签白名单**：仅当 `@` 后为已知 HTML 标签名时转换，避免错误转换 `@js:`、`@data-src`、`@onclick` 等。

#### 修复 2：位置索引解析（HtmlParser.ts:407-439）

**功能**：Default 规则 `tag.N`（如 `a.0`、`td.2`、`p.-1`）不再被错误地当作 CSS 类选择器，而是按位置返回第 N 个匹配元素。

**拦截点**：
- `matchSimple()` — 简单选择器
- `findAllDescendants()` — 后代组合器链
- `findElementsInChildren()` — 子元素组合器链

#### 修复 3：排除索引兼容（HtmlParser.ts:186）

**功能**：`!0` 排除语法在规则标准化后不再要求必须处于选择器结尾。正则从 `$` 改为 `(?=\s|$|>)`，支持 `.author!0 a` 这种标准化后 `!0` 后跟空格的场景。

#### 修复 4：JSON 选项提取（SourceExecutor.ts:289-376）

**功能**：URL 末尾的 JSON 选项（`url,{"method":"POST","body":"..."}`）正确提取。

**关键修复**：
- `url.substring(startIdx + 1, endIdx)` — 保留完整 `{}`
- 删除 QuickJS executeScript 步骤（多线程下返回空 `{}`）
- `content[i - 1]` — 修复引用 `jsonStr` 而非 `content` 的 bug
- 手动解析器支持单引号、body 值含逗号的情况

### 10.3 未实现的功能

| 功能 | 状态 | 说明 |
|------|------|------|
| `:nth-of-type()` | ❌ | CSS 伪类未实现 |
| `:eq()` | ❌ | jQuery 式位置选择器 |
| `:first` / `:last` | ❌ | CSS 伪类 |
| CSS 逗号分组 | ❌ | `.s1,.s7` 不支持 |
| XPath 引擎 | ❌ | `//` 转 CSS 可能失败 |
| `@textNodes` | ❌ | 非标准属性后缀未识别 |
| `@put` / `@get` 变量 | ❌ | 跨段变量引用 |

---

## 11. 常见问题与修复记录

### 11.1 搜索结果少（只有 5 个源）

**根因**：两处解析缺陷

| 缺陷 | 影响源数 | 修复 |
|------|---------|------|
| JSON 选项提取完全损坏 | 34 个 | 修复 endIdx、删除 QuickJS 步骤、修复引用 |
| CSS 规则不支持 `id.`/`@`/位置索引 | 14+ 个 | normalizeCssRule + resolvePositional |

### 11.2 CSS list rule found 0 items

**常见原因**：
1. 规则使用了 `id.xxx` → 需要 normalizeCssRule 转换 `#xxx`
2. 规则使用了 `.class@tag` → `@` 需要展开为空格
3. 规则使用了位置索引 `a.0` → 需要 resolvePositional 解析
4. 服务器返回了非内容页（404、Cloudflare、跳转页等）

### 11.3 搜索 "冲出四合院" 只返回 5 个源

修复后期望更多源参与合并。最终结果还取决于：
- 服务器响应（Cloudflare 403、超时、SSL 错误等）
- 该源数据库是否真有这本书
- Cookie 和请求头设置

### 11.4 Author not found

字段选择器使用了位置索引如 `a.2@text`，但页面 HTML 结构中没有第 3 个 `a` 标签，或位置索引解析未生效。

### 11.5 buildUrl evalJs 错误

```
ReferenceError: cookie is not defined
```

`cookie` 对象在 QuickJS 作用域中未定义，不影响搜索结果（只是无法清除 cookie）。

---

## 附录：LegadoCSS vs CSS 对照表

| Legado Default | 标准 CSS 等价 | 说明 |
|---------------|---------------|------|
| `div` | `div` | 标签选择器 |
| `.class` | `.class` | 类选择器 |
| `id.name` | `#name` | ID 选择器 |
| `.class@tag` | `.class tag` | 后代 |
| `tag1@tag2` | `tag1 tag2` | 后代 |
| `id.name@tag` | `#name tag` | 后代 |
| `a.0` | (位置索引) | 第 1 个 a |
| `td.2` | (位置索引) | 第 3 个 td |
| `li!0` | (排除索引) | 跳过第 1 个 li |
| `a.0@text` | (属性提取) | a 的第 1 个文本 |
| `@@class` | `.class` | 简写 |
