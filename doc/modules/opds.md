# OPDS 在线书库

## 能力范围

- 支持 OPDS 1.x Atom XML 的 navigation、subsection、acquisition 与 next 分页关系。
- 支持 OPDS 2.0 JSON 的 navigation、publications、acquisition 与 next 分页关系。
- 支持从 `rel="search"` 发现 OPDS 远程搜索；兼容 OpenSearch Description 的
  `{searchTerms}` 模板。
- OPDS 是只读来源，不支持上传、删除或创建目录。
- acquisition 会映射为现有 `CloudFile`，继续复用云端书库的下载、导入、书架绑定与更新状态。
- 支持 EPUB、PDF、TXT、MOBI、AZW/AZW3 等本地导入引擎已支持的格式。
- 私有 OPDS 可选用 HTTP Basic 认证；公开来源不保存或发送认证信息。

## 内置来源

应用首次进入在线书库或来源管理页时会创建：

- 名称：Project Gutenberg
- 协议：OPDS
- 地址：`https://www.gutenberg.org/ebooks.opds/`

该来源可以停用，但不能编辑或删除。根目录展示 Gutenberg 提供的热门、最新等分类；
搜索框提交后执行全库书名/作者搜索。请求使用包含联系地址的明确 User-Agent，分页仅由
用户点击“下一页”触发，避免自动批量抓取。

若官方 OPDS 按出口 IP 返回 403，应用会改用
[Gutendex](https://gutendex.com/) 提供备用分类、搜索和书目元数据，并将 EPUB 下载地址切换到
Project Gutenberg 官方镜像列表中的 `gutenberg.pglaf.org`，避免主站封禁导致内置书库完全不可用。
官方根目录能够访问、但热门/最新/随机分类 feed 返回 403 时，也会分别映射到 Gutendex 的
热门、最新和每日随机分页，不再停留在错误页。

## 实现结构

- `OpdsParser.ts`：无网络依赖的 OPDS 1.x / 2.0 解析与相对 URL 解析。
- `OpdsCloudProvider.ts`：网络访问、虚拟路径映射、Basic Auth 与书籍下载。
- `CloudSourceRepository.ensureBuiltInSources()`：幂等创建内置 Project Gutenberg 来源。
- `CloudBookRepository`：允许公开 OPDS 使用空凭证，并采用 Provider 返回的面包屑名称。

OPDS 虚拟路径将完整 feed/acquisition URL 编码为安全相对路径段。目录的“下一页”作为显式虚拟目录展示，不会在后台自动拉取后续页面。
