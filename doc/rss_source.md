# 订阅源规则：从入门到再入门

> 来源：https://mgz0227.github.io/The-tutorial-of-Legado/Rule/rss.html
> 更新时间：2024-02-27

---

## Legado 订阅源规则说明

### 概况

1. 语法说明
2. Legado 的特殊规则
3. 解析流程
4. 规则概述
5. 附录

---

### 1、语法说明

详见[书源规则](https://alanskycn.gitee.io/teachme/)（已 404）

---

### 2、Legado 的特殊规则

详见[书源规则](https://alanskycn.gitee.io/teachme/)（已 404）

---

### 3、解析流程

订阅源的解析：

1. 访问源 URL（sourceUrl）
2. 检查是否存在列表规则（ruleArticles）  
   若为空，则认为是标准 RSS 源，采用默认规则解析。否则，请看第 3 点。
3. 解析列表规则（ruleArticles）  
   返回一个列表，列表下一页规则（ruleArticles）只在上拉时触发，且不存在页数 `{{page}}`
4. 解析标题规则（ruleTitle）、时间规则（rulePubDate）、图片 url 规则（ruleImage）、链接规则（ruleLink）和链接规则（ruleLink）
5. 检查是否存在描述规则（ruleDescription）  
   若存在，则解析描述规则（ruleDescription），到这里就解析结束。否则，请看第 6 点。
6. 检查是否存在内容规则（ruleContent）  
   若存在，则解析内容规则（ruleContent），然后结束解析。否则，直接结束解析。

根据订阅源的解析，可以发现订阅源有三种：标准 RSS 源、有列表规则和描述规则的源以及有列表规则无描述规则的源。

#### ▲ 标准 RSS 源

- 特征：只填写了源名称（sourceName）、源 URL（sourceUrl）。
- 图标（sourceIcon）和源分组（sourceGroup）可有可无，不影响解析。

#### ▲ 有列表规则和描述规则的源

- 特征：一定填写了源名称（sourceName）、源 URL（sourceUrl）、列表规则（ruleArticles）、标题规则（ruleTitle）、描述规则（ruleDescription）和链接规则（ruleLink）。
- 列表下一页规则（ruleArticles）根据实际需求来填写，不填也可以。图标（sourceIcon）和源分组（sourceGroup）可有可无，不影响解析。

#### ▲ 有列表规则无描述规则的源

- 特征：一定填写了源名称（sourceName）、源 URL（sourceUrl）、列表规则（ruleArticles）、标题规则（ruleTitle）和链接规则（ruleLink）。
- 列表下一页规则（ruleArticles）和内容规则（ruleContent）根据实际需求来填写，不填也可以。图标（sourceIcon）和源分组（sourceGroup）可有可无，不影响解析。

---

### 4、规则概述

#### sourceUrl（源 URL）

- 必填
- 唯一标识，不可重复
- 与其他源相同会覆盖

#### sourceName（源名称）

- 必填
- 名字可重复

#### sourceIcon（图标）

- 可不填

#### sourceGroup（源分组）

- 可不填

#### ruleArticles（列表规则）

- 根据实际需求填写
- 判断是否是标准 RSS 的标志

#### ruleArticles（列表下一页规则）

- 根据实际需求填写，一般和列表规则（ruleArticles）一起搭配使用
- 规则解析的结果必须是字符串
- 无页数 `{{page}}`，想实现页数加一请使用 JS

#### ruleTitle（标题规则）

- 填写列表规则（ruleArticles）后，为必填项

#### rulePubDate（时间规则）

- 可不填，根据实际需求填写

#### ruleDescription（描述规则）

- 根据实际需求填写
- 区分有列表规则和描述规则的源和有列表规则无描述规则的源的标志

#### ruleImage（图片 url 规则）

- 可不填，根据实际需求填写

#### ruleLink（链接规则）

- 填写列表规则（ruleArticles）后，为必填项
- 文章的唯一标识

#### ruleContent（内容规则）

- 根据实际需求填写，不填打开网页，填写可修改样式

#### header（请求头）

- 根据实际需求填写

---

### 5、附录

订阅源示例：

```json
{
  "articleStyle": 0,
  "customOrder": -24967,
  "enableJs": true,
  "enabled": true,
  "enabledCookieJar": false,
  "header": "{\n\"User-Agent\": \"Mozilla/5.0 (Linux; U; Android 8.1.0; zh-CN; MI 8 Lite Build/OPM1.171019.019) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/78.0.3904.108 UCBrowser/13.2.0.1100 Mobile Safari/537.36\"\n}",
  "lastUpdateTime": 1675946926480,
  "loadWithBaseUrl": true,
  "ruleArticles": "id.content@h3",
  "ruleLink": "a@href",
  "ruleTitle": "a@textNodes",
  "singleUrl": true,
  "sortUrl": "首页::http://yuedu.miaogongzi.net/gx.html",
  "sourceGroup": "书源",
  "sourceIcon": "https://i.loli.net/2021/06/23/S7rvWRZtPIq34MJ.png",
  "sourceName": "喵公子书源管理",
  "sourceUrl": "http://yuedu.miaogongzi.net/gx.html"
}
```
