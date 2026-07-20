# 打开方式/分享 导入（ShareImport）

## 背景

部分设备（如某些平板 ROM）缺少系统文件选择器组件（`sysPicker/filePicker`），
`DocumentViewPicker` 拉起失败（errorCode=1011 start_ability_fail）。
「打开方式/分享」是无需特殊权限的替代文件获取通道。

## 机制

- `entry/src/main/module.json5`：MainAbility 使用两组独立 skills：
  - 文件打开：`ohos.want.action.viewData`，`file`/`content` URI 均声明
    `linkFeature: "FileOpen"`，供系统文件管理器识别为文件处理应用。
  - 系统分享：`ohos.want.action.sendData` / `sendMultipleData`，支持单文件和多文件分享。
  `uris[].type` 同时覆盖 UTD 标识（`general.json`、`general.plain-text`、
  `com.adobe.pdf`、`general.epub`、`general.ebook`、`com.amazon.azw/azw3/mobi`）
  和常用 MIME 类型。
- `MainAbility.onCreate / onNewWant` → `ShareImportService.handleWant()`：
  解析 want 中的文件 URI（`want.uri`、`ability.params.stream`、
  `ohos.ability.params.stream`、`uri` 参数位），
  URI 不带后缀时根据 `want.type` 补全类型，
  按后缀分类后写入 `AppStorage('pendingShareImport')`（含递增 id，保证重复分享也触发 @Watch）。
- 分发：
  - `.json` → 书源导入：MainPage 监听 payload，读取 URI 文本后弹出
    `ImportSourceDialog`（`initialJson` 预置，跳过菜单直接进预览）。
  - `.txt/.epub/.mobi/.azw/.azw3/.pdf` → 本地书导入：MainPage 切到书架 Tab，
    `BookshelfPage` 复用 `importLocalBookUris()`（与文件选择器导入共用管线）。
  - 其他类型 → toast 提示不支持。

## 关键经验（真机验证记录）

- skills `uris[].type` 优先填写 **UTD**，同时保留常用 MIME 兼容项；文件打开项必须设置
  `linkFeature: "FileOpen"`，否则 BMS 的普通隐式启动可以命中，但文件管理器的“打开方式”可能不会展示。
- 验证方式：`aa start -A ohos.want.action.viewData -U file://... -t general.json`
  可命中本应用（BMS 会按 URI 后缀推导类型）。
- aa 直接发的 URI 不带读授权，应用内 openSync 会 ENOENT——属正常现象；
  真实「打开方式」由系统授予 URI 读权限（已用系统"文件预览"验证可读）。
- 若分享方把支持文件统一标记为 `application/octet-stream`，文件打开 skill 通过后缀
  `pathRegex` 兜底，只匹配 json/txt/epub/mobi/azw/azw3/pdf，避免应用出现在所有二进制文件候选中。

## 相关文件

- `entry/src/main/module.json5`
- `entry/src/main/ets/MainAbility/MainAbility.ets`
- `entry/src/main/ets/service/ShareImportService.ets`
- `entry/src/main/ets/pages/MainPage.ets`
- `entry/src/main/ets/pages/BookshelfPage.ets`（`importLocalBookUris`）
- `entry/src/main/ets/pages/ImportSourceDialog.ets`（`initialJson`）
