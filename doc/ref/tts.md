    你这个需求，最适合做成“双引擎架构”：

```text
系统 TTS
  └─ 兜底、低功耗、无需下载

应用内离线神经 TTS
  └─ 更自然、多音色、用户自行下载模型
```

综合鸿蒙适配成熟度、自然度和可控性，**首选 sherpa-onnx + Kokoro 中文模型**。

## 推荐顺序

### 方案一：sherpa-onnx + Kokoro，多音色离线方案

这是目前最值得投入的路线。

`sherpa-onnx` 已正式支持 HarmonyOS，并提供：

* HarmonyOS 本地 TTS 示例工程；
* 可直接通过 OHPM 安装的 `sherpa_onnx.har`；
* ArkTS 接口；
* 异步合成；
* 流式回调音频数据；
* C++/NAPI 底层推理；
* 完全离线运行。([K2 FSA][1])

可以直接添加依赖：

```json
{
  "dependencies": {
    "sherpa_onnx": "1.12.1"
  }
}
```

或者：

```bash
ohpm install sherpa_onnx
```

目前比较适合中文阅读的是：

#### Kokoro 中文+英文模型

官方模型列表中有：

* `kokoro-multi-lang-v1_1`

    * 中文、英文；
    * 103 个 speaker；
* `kokoro-multi-lang-v1_0`

    * 中文、英文；
    * 53 个 speaker。([K2 FSA][2])

优点：

* 音色明显多于系统 TTS；
* 自然度通常优于传统 VITS/Piper；
* 中文和英文混读；
* 模型统一，不需要每个音色下载一套完整模型；
* 完全离线；
* 已被 sherpa-onnx 原生支持。

缺点：

* 103 个 speaker 不代表 103 个都适合中文；
* 中文语气、停顿和多音字仍需要文本预处理；
* 模型比传统 VITS 大；
* 低端设备首句延迟和耗电会比较明显。

**这是我最推荐你先做的 MVP。**

### 方案二：sherpa-onnx + VITS/MeloTTS，作为轻量中文音色

sherpa-onnx 还支持多种中文 VITS 模型，包括：

* `vits-melo-tts-zh_en`
* AISHELL3 多说话人模型；
* 中文单说话人 VITS；
* MatchaTTS 中文模型。([K2 FSA][3])

其中 `vits-melo-tts-zh_en` 支持中英文，但只有一个 speaker，英文词汇也受词典覆盖限制。([K2 FSA][3])

优点：

* 模型通常更小；
* CPU 推理压力较低；
* 首句延迟容易控制；
* 比较适合中低端设备。

缺点：

* 自然度通常不如 Kokoro；
* 多数模型音色较少；
* 长篇小说容易出现机械感；
* 中文标点、儿化音、多音字问题比较明显。

适合作为：

```text
高品质模式：Kokoro
省电模式：VITS/MeloTTS
```

### 方案三：华为 Core Speech Kit，继续作为系统增强方案

华为的 Core Speech Kit 提供 `TextToSpeech` 能力，属于鸿蒙原生系统能力。([华为开发者][4])

它的优势是：

* 系统适配最好；
* 后台播放和音频焦点处理相对省事；
* 功耗低；
* 安装包不需要包含大模型；
* 不同设备可能自动获得更好的系统音色。

但问题是：

* 音色数量和设备、系统版本有关；
* 用户无法自由导入模型；
* 对是否完全离线、哪些音色离线，开发者控制有限；
* 朗读自然度上限受系统实现限制。

因此不建议替换掉它，而是保留为：

```text
默认引擎：鸿蒙系统 TTS
高级离线引擎：应用内神经 TTS
```

### 方案四：科大讯飞离线 TTS 商业 SDK

讯飞的高品质离线合成 XTTS 已经用于 Android、iOS、Linux，其官方说明明确称高品质版比传统离线合成效果更好，但资源占用也更高。([讯飞开放平台][5])

不过目前讯飞公开的 HarmonyOS SDK 更新记录，明确列出的语音合成主要是在线能力；我没有找到公开文档确认高品质离线 XTTS 已经面向普通 HarmonyOS NEXT 开发者自助开放。([讯飞开放平台][6])

这条路线的特点：

* 中文发音和数字、日期、单位处理成熟；
* 商业技术支持较好；
* 音色自然度可能优于普通开源模型；
* 有机会获得定制音色或专业词典。

但需要面对：

* 商业授权费用；
* 可能按设备数、装机量或调用量授权；
* SDK 和音库可能绑定应用签名；
* 能否提供多个离线音色，要和讯飞商务确认；
* 不能随意把音库做成用户共享资源。

适合正式商业产品，不适合先做原型。

## 我建议的最终产品结构

### 引擎选择界面

```text
朗读引擎

● 系统语音
  无需下载，功耗低

○ 自然语音·标准
  完全离线，约 150～300 MB

○ 自然语音·高品质
  完全离线，约 300～600 MB
```

实际对应：

```text
系统语音
  └─ HarmonyOS TTS

自然语音·标准
  └─ VITS / MeloTTS

自然语音·高品质
  └─ Kokoro
```

不要把模型全部内置到 HAP 中。建议做成可下载资源包：

```text
files/tts/
├── kokoro-zh-en/
│   ├── model.onnx
│   ├── voices.bin
│   ├── tokens.txt
│   ├── lexicon.txt
│   ├── espeak-ng-data/
│   └── manifest.json
├── vits-zh/
└── temp/
```

每个模型包配一个描述文件：

```json
{
  "id": "kokoro-zh-en-v1.1",
  "name": "自然语音",
  "engine": "kokoro",
  "version": 1,
  "languages": ["zh-CN", "en-US"],
  "speakers": 103,
  "sampleRate": 24000,
  "size": 386000000,
  "sha256": "...",
  "minAppVersion": "1.5.0"
}
```

## 阅读器场景必须额外做的处理

模型本身只解决“发声”，小说朗读体验主要由下面几个环节决定。

### 1. 分句不要直接按固定字数切

推荐顺序：

```text
章节
 → 段落
 → 句号/问号/感叹号
 → 分号
 → 逗号
 → 最长字数保护
```

每段建议控制在大约：

```text
20～80 个汉字
```

太短会导致语气断裂，太长则首句等待明显，取消朗读也不灵敏。

### 2. 提前合成后续句子

使用生产者—消费者队列：

```text
当前播放：第 N 句
后台合成：第 N+1、N+2 句
缓存待播：最多 2～4 句
```

这样可以把模型首句延迟隐藏掉。

不要一次性把整章全部合成，否则会：

* 占用大量内存；
* 用户跳页后产生大量无效计算；
* 手机持续发热；
* 取消响应迟缓。

### 3. 音频缓存

建议缓存合成结果：

```text
cacheKey =
  modelId
  + speakerId
  + speed
  + normalizedText
```

音频格式可以考虑：

* 内存中：PCM Float32 或 PCM16；
* 临时磁盘：PCM/WAV；
* 长期缓存：Opus 或 AAC。

阅读器通常不需要长期缓存整本书，保留当前章节和下一章节即可。

### 4. 文本规范化

中文小说必须处理：

* `2026-07-11`
* `3.14`
* `20%`
* `1.5 GB`
* `第12章`
* `100 km/h`
* 英文字母和缩写；
* 省略号；
* 破折号；
* 引号内对白；
* 多音字。

例如：

```text
原文：CPU 占用达到 80%，持续了 3.5 秒。

规范化：
C P U 占用达到百分之八十，持续了三点五秒。
```

技术书和小说最好使用不同规范化策略。

### 5. 对话语气

可以根据引号自动添加轻微停顿：

```text
他说：“你终于来了。”
```

拆成类似：

```text
他说，<短停顿>
你终于来了。<中停顿>
```

但不要默认根据角色切换不同 speaker。多 speaker 切换会：

* 破坏声音一致性；
* 增加模型状态切换开销；
* 对角色识别错误非常敏感。

后续可以把“多人有声书模式”作为实验功能。

## 建议你第一阶段就这样做

```text
1. 保留现有 HarmonyOS 系统 TTS
2. 引入 sherpa_onnx HAR
3. 先只支持一个 Kokoro 中英模型
4. 从 103 个 speaker 中人工筛选 6～12 个
5. 实现句子级合成队列
6. 提前缓存后两句
7. 支持暂停、恢复、跳句和调速
8. 再增加一个轻量 VITS 模型
```

不要一开始就开放全部 103 个音色。最好筛选为：

```text
温和女声
沉稳男声
青年女声
青年男声
新闻女声
小说男声
```

因为大量 speaker 之间差异很小，有些中文效果也可能不稳定。把所有音色扔给用户，选择界面会像在调打印机驱动——自由是自由了，但不快乐。

## 结论

最适合你的组合是：

| 方案                    | 自然度 |    音色 |  完全离线 |   鸿蒙适配 | 成本 |
| --------------------- | --: | ----: | ----: | -----: | -: |
| 系统 TTS                |   中 |   少～中 | 不完全可控 |     最好 |  低 |
| Kokoro + sherpa-onnx  |   高 |    很多 |     是 | 已有官方示例 | 开源 |
| VITS/MeloTTS + sherpa |   中 |   少～中 |     是 |    已支持 | 开源 |
| 讯飞 XTTS               |   高 | 取决于授权 |     是 |  需商务确认 | 商业 |

**首选：系统 TTS 继续兜底，应用内增加 sherpa-onnx + Kokoro。**

这条路线不需要自己移植 ONNX Runtime，sherpa-onnx 已经提供 HarmonyOS HAR、示例工程和异步 TTS 接口，工程风险最低。([K2 FSA][1])

[1]: https://k2-fsa.github.io/sherpa/onnx/harmony-os/how-to-build-har.html?utm_source=chatgpt.com "How to build sherpa_onnx.har — sherpa 1.3 documentation"
[2]: https://k2-fsa.github.io/sherpa/onnx/tts/index.html?utm_source=chatgpt.com "Text-to-speech (TTS) — sherpa 1.3 documentation"
[3]: https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html?utm_source=chatgpt.com "vits — sherpa 1.3 documentation"
[4]: https://developer.huawei.com/consumer/en/doc/harmonyos-guides/core-speech-introduction?utm_source=chatgpt.com "Only Essential Cookies"
[5]: https://www.xfyun.cn/doc/tts/offline_tts/Linux-SDK.html?utm_source=chatgpt.com "离线语音合成Linux SDK 文档"
[6]: https://www.xfyun.cn/doc/total_sdk_compliance/SDK_History.html?utm_source=chatgpt.com "SDK更新日志"




官方项目是：

```text
k2-fsa/sherpa-onnx
```

GitHub 仓库就是 `k2-fsa/sherpa-onnx`。鸿蒙相关代码在：

```text
harmony-os/
├── SherpaOnnxHar/   # 生成 sherpa_onnx.har 的库工程
├── SherpaOnnxTts/   # 鸿蒙离线 TTS 示例
└── 其他 ASR/VAD 示例
```

官方已经把 `sherpa_onnx` 发布到 **OHPM 三方库中心仓**，通常不需要手工下载 `.har`。在鸿蒙工程的 `oh-package.json5` 中加入：

```json
{
  "dependencies": {
    "sherpa_onnx": "1.12.1"
  }
}
```

然后在工程目录执行：

```bash
ohpm install
```

也可以直接执行：

```bash
ohpm install sherpa_onnx
```

官方文档目前明确推荐“始终使用最新版本”，文档示例暂时写的是 `1.12.1`。安装时最好先在 OHPM 搜索 `sherpa_onnx`，确认当前最新可用版本，而不是固定照抄旧版本号。([K2 FSA][1])

## GitHub 上对应的项目位置

主仓库：

```text
https://github.com/k2-fsa/sherpa-onnx
```

HAR 工程：

```text
https://github.com/k2-fsa/sherpa-onnx/tree/master/harmony-os/SherpaOnnxHar
```

鸿蒙 TTS 示例：

```text
https://github.com/k2-fsa/sherpa-onnx/tree/master/harmony-os/SherpaOnnxTts
```

官方 TTS 示例文档也是直接让开发者 clone 主仓库，然后用 DevEco Studio 打开：

```text
harmony-os/SherpaOnnxTts
```

([K2 FSA][2])

## 需要单独拿到 `.har` 文件时

官方 GitHub Release 页面主要发布各平台二进制、模型及安装包，目前没有看到稳定地把 `sherpa_onnx.har` 单独作为每个 Release 的固定附件。因此更可靠的方式是：

1. **通过 OHPM 安装**，推荐；
2. 从 GitHub 源码自行构建 HAR。

自行构建后文件位置是：

```text
harmony-os/SherpaOnnxHar/
└── sherpa_onnx/build/default/outputs/default/sherpa_onnx.har
```

官方构建命令：

```bash
git clone https://github.com/k2-fsa/sherpa-onnx
cd sherpa-onnx

export OHOS_SDK_NATIVE_DIR=/你的路径/openharmony/native

./build-ohos-arm64-v8a.sh
./build-ohos-x86-64.sh

cd harmony-os/SherpaOnnxHar

hvigorw clean --no-daemon

hvigorw \
  --mode module \
  -p product=default \
  -p module=sherpa_onnx@default \
  assembleHar \
  --analyze=normal \
  --parallel \
  --incremental \
  --no-daemon
```

构建完成后执行：

```bash
find . -name "*.har"
```

应该能看到：

```text
./sherpa_onnx/build/default/outputs/default/sherpa_onnx.har
```

([K2 FSA][1])

## 建议你怎么用

你的阅读器项目优先这样引入：

```json
{
  "dependencies": {
    "sherpa_onnx": "最新可用版本"
  }
}
```

先不要手工复制 HAR。OHPM 能处理依赖版本和工程结构，后续升级也方便。

只有这几种情况才建议自己编译：

* 要修改 sherpa-onnx 的 C++ 代码；
* 要裁剪掉 ASR、VAD 等不用的功能以减小库体积；
* OHPM 版本不支持你当前使用的 HarmonyOS API 版本；
* 需要调整 ONNX Runtime 编译选项；
* 只想保留 `arm64-v8a`，不需要模拟器的 `x86_64` 库。

另外，`sherpa_onnx.har` **只包含推理引擎和 ArkTS/NAPI 接口，不包含具体 TTS 音色模型**。Kokoro、VITS 等模型仍要单独下载并放入 `resources/rawfile`，或由应用运行后下载到沙箱目录。

[1]: https://k2-fsa.github.io/sherpa/onnx/harmony-os/how-to-build-har.html "How to build sherpa_onnx.har — sherpa 1.3 documentation"
[2]: https://k2-fsa.github.io/sherpa/onnx/harmony-os/tts.html?utm_source=chatgpt.com "On-device text-to-speech (TTS, 本地语音合成)"


对，**鸿蒙应用最终安装包是 HAP**；`sherpa_onnx.har` 不是应用安装包，而是供鸿蒙工程引用的**静态共享库包**。

可以把它类比成：

| 鸿蒙格式   | 类似于                           |
| ------ | ----------------------------- |
| `.hap` | Android 的 APK，一个可安装运行的应用或模块   |
| `.har` | Android 的 AAR/JAR，一个被其他应用依赖的库 |
| `.hsp` | 动态共享包，类似可被多个模块共享的动态组件         |
| `.app` | 应用发布包，内部可以包含一个或多个 HAP         |

## HAR 是什么

HAR 全称通常理解为 **Harmony Archive**。它用于封装鸿蒙应用开发中的可复用代码和资源，例如：

* ArkTS/TypeScript 接口；
* UI 组件；
* 图片、配置等资源；
* C/C++ 编译产生的 `.so`；
* NAPI 接口；
* 类型声明文件；
* 依赖信息。

`sherpa_onnx.har` 大致会包含这种结构：

```text
sherpa_onnx.har
├── ets/
│   ├── Index.ets
│   └── 类型声明和 ArkTS 封装
├── libs/
│   └── arm64-v8a/
│       ├── libsherpa-onnx.so
│       ├── libonnxruntime.so
│       └── 其他 native 库
├── resources/
├── module.json
├── oh-package.json5
└── typings/
```

具体目录会随版本不同，但核心思路是：

```text
ArkTS API
   ↓ NAPI
C/C++ sherpa-onnx
   ↓
ONNX Runtime
```

## HAP 是什么

HAP 是可以安装和运行的模块包，里面包含：

* 页面和 Ability；
* ArkTS 代码；
* 应用资源；
* 权限声明；
* native 库；
* 被依赖的 HAR 代码；
* 模块配置。

构建你的阅读器时，大致过程是：

```text
你的阅读器源码
    +
sherpa_onnx.har
    +
TTS 模型资源
    ↓
DevEco Studio 编译
    ↓
entry-default-signed.hap
```

最终用户安装的是：

```text
reader.hap
```

而不是单独安装：

```text
sherpa_onnx.har
```

HAR 本身通常不能点击安装，也没有独立应用入口。

## 为什么 sherpa-onnx 提供 HAR

因为它是一个开发库，不是一个完整 TTS 应用。

它提供的通常是类似这样的 ArkTS 接口：

```ts
import { OfflineTts } from 'sherpa_onnx'
```

然后你的阅读器代码调用它：

```ts
const tts = new OfflineTts(config)

const audio = tts.generate('这是一段测试文字', 0, 1.0)
```

最终生成 PCM 音频，再交给鸿蒙的 `AudioRenderer` 播放。

因此层次关系是：

```text
阅读器 HAP
├── 阅读器页面
├── 分页和文本选择
├── 朗读控制
├── sherpa_onnx HAR
│   ├── ArkTS 封装
│   └── native .so
└── TTS 模型
    ├── model.onnx
    ├── tokens.txt
    ├── voices.bin
    └── 词典等资源
```

## HAR 会不会被原样放进 HAP

通常不会简单地把整个 `.har` 原封不动塞进去。

构建时，DevEco Studio 会把 HAR 展开并合并：

* ArkTS 代码参与编译；
* 资源合并到模块；
* `.so` 放进 HAP 对应 ABI 目录；
* 依赖关系一起处理。

最终 HAP 内可能类似：

```text
reader.hap
├── libs/
│   └── arm64-v8a/
│       ├── libsherpa-onnx.so
│       └── libonnxruntime.so
├── ets/
├── resources/
└── module.json
```

## HAR 和 HSP 的区别

HAR 是**静态依赖**：

```text
应用 A + HAR → 编译进应用 A
应用 B + HAR → 又编译一份进应用 B
```

优点是部署简单，应用自己带齐依赖；缺点是多个应用使用同一个库时，会各自占一份空间。

HSP 是**动态共享包**：

```text
应用模块
   ↓
运行时加载 HSP
```

它更适合大型鸿蒙应用内部多个 HAP 模块共享代码和资源。对 sherpa-onnx 这种第三方 SDK，HAR 更常见、更方便。

## 在工程里怎么使用

一般通过 `oh-package.json5` 引用，例如本地 HAR：

```json
{
  "dependencies": {
    "sherpa_onnx": "file:../libs/sherpa_onnx.har"
  }
}
```

或者通过 OHPM 仓库：

```json
{
  "dependencies": {
    "sherpa_onnx": "1.12.1"
  }
}
```

然后执行：

```bash
ohpm install
```

代码中再导入：

```ts
import { OfflineTts } from 'sherpa_onnx'
```

## 还要注意模型不一定在 HAR 里面

`sherpa_onnx.har` 主要是**推理引擎**。语音模型通常需要你另外提供，例如：

```text
model.onnx
voices.bin
tokens.txt
lexicon.txt
espeak-ng-data/
```

通常不建议把几百 MB 的模型直接塞进 HAR，也不一定适合塞入 HAP。更实用的是：

```text
首次安装阅读器
    ↓
用户选择音色
    ↓
下载对应模型包
    ↓
保存到应用沙箱
    ↓
sherpa-onnx 从文件路径加载
```

这样 HAP 本身不会膨胀得离谱，也能按需增加音色。

一句话概括：

> **HAP 是可以安装运行的鸿蒙应用包；HAR 是编译进 HAP、供应用调用的鸿蒙库包。**
> `sherpa_onnx.har` 相当于 TTS 引擎 SDK，你的阅读器最终仍然打包和安装为 HAP。


`kokoro-int8-multi-lang-v1_1` **解压后的完整模型目录约 215 MB**，其中主要文件是：

* `model.int8.onnx`：约 **114 MB**
* `voices.bin`：约 **53.8 MB**
* 英文词典：约 **12.3 MB**
* 中文词典：约 **2.1 MB**
* `dict/`、`espeak-ng-data/` 以及 FST 规则等：其余约数十 MB

Hugging Face 当前显示整个仓库为 215 MB。压缩后的 `.tar.bz2` 会更小，但实际下载大小可能随发布包压缩方式变化，部署时应按 **至少 220～250 MB 存储空间**估算。([Hugging Face][1])

## 两种导入方式

### 方式一：直接打包进 HAP

把解压后的整个目录放到：

```text
entry/src/main/resources/rawfile/
└── kokoro-int8-multi-lang-v1_1/
    ├── model.int8.onnx
    ├── voices.bin
    ├── tokens.txt
    ├── lexicon-zh.txt
    ├── lexicon-us-en.txt
    ├── lexicon-gb-en.txt
    ├── date-zh.fst
    ├── number-zh.fst
    ├── phone-zh.fst
    ├── dict/
    └── espeak-ng-data/
```

官方 HarmonyOS TTS 示例也是要求把模型放进 `entry/src/main/resources/rawfile`，然后随应用一起构建。([K2 FSA][2])

构建关系是：

```text
模型目录
   ↓
resources/rawfile
   ↓
编译打包
   ↓
reader.hap
```

#### 优点

* 安装后马上能用；
* 不需要模型下载逻辑；
* 模型版本和 App 版本完全一致；
* 首次启动实现最简单；
* 不依赖用户网络。

#### 缺点

* HAP 体积会直接增加约 215 MB；
* 加上 `sherpa_onnx.har` 和 native `.so`，最终增加量还会更高；
* 每次升级 App 可能需要重新下载安装整个大包；
* 以后增加第二个模型时，安装包会迅速膨胀；
* 用户不能选择只下载需要的音色包。

因此，这种方式适合：

```text
开发验证
内部测试
第一个 Demo
只打算长期提供一个模型
```

不太适合正式阅读器长期发布。

---

## 方式二：运行时下载到应用沙箱

正式产品更建议这么做：

```text
阅读器 HAP
├── sherpa_onnx 推理引擎
├── TTS 管理代码
└── 不包含大模型

首次选择“自然语音”
        ↓
下载压缩模型包
        ↓
校验 SHA-256
        ↓
解压到应用沙箱
        ↓
把绝对路径传给 sherpa-onnx
```

建议目录：

```text
context.filesDir/
└── tts/
    └── kokoro-int8-multi-lang-v1_1/
        ├── model.int8.onnx
        ├── voices.bin
        ├── tokens.txt
        ├── lexicon-zh.txt
        ├── lexicon-us-en.txt
        ├── lexicon-gb-en.txt
        ├── date-zh.fst
        ├── number-zh.fst
        ├── phone-zh.fst
        ├── dict/
        ├── espeak-ng-data/
        └── manifest.json
```

例如：

```ts
const modelRoot =
  `${context.filesDir}/tts/kokoro-int8-multi-lang-v1_1`;

const modelPath = `${modelRoot}/model.int8.onnx`;
const voicesPath = `${modelRoot}/voices.bin`;
const tokensPath = `${modelRoot}/tokens.txt`;
```

然后把这些路径传给 Kokoro 配置。

概念代码可能类似：

```ts
const config = {
  model: `${modelRoot}/model.int8.onnx`,
  voices: `${modelRoot}/voices.bin`,
  tokens: `${modelRoot}/tokens.txt`,
  lexicon: [
    `${modelRoot}/lexicon-zh.txt`,
    `${modelRoot}/lexicon-us-en.txt`,
    `${modelRoot}/lexicon-gb-en.txt`
  ],
  dataDir: `${modelRoot}/espeak-ng-data`,
  dictDir: `${modelRoot}/dict`
};
```

具体字段名要以你使用的 `sherpa_onnx` HAR 版本和 Kokoro ArkTS 配置类型为准。

## 不建议放在普通公共手机目录

不建议让用户把模型放到类似：

```text
Download/
Documents/
共享存储目录/
```

然后长期直接从那里加载。

原因包括：

* HarmonyOS NEXT 的跨目录访问受沙箱和 URI 权限约束；
* 用户可能删除、移动或改名；
* 文件选择器返回的往往是 URI，不一定是 native 层可直接使用的普通路径；
* 模型包含大量小文件和子目录，不只是单个 ONNX；
* 每次启动都需要确认授权是否仍有效；
* C++ native 层加载普通文件路径更稳定。

更可靠的做法是：

```text
用户选择下载包或导入文件
        ↓
App 读取文件
        ↓
复制并解压到 context.filesDir
        ↓
以后只从应用沙箱加载
```

## 推荐的最终方案

你的阅读器已有系统 TTS，建议这样分发：

```text
安装包
├── 系统 TTS 支持
├── sherpa_onnx 引擎
└── 一个很小的试听资源或无模型

语音中心
├── 系统语音：无需下载
└── 自然语音 Kokoro：约 200 MB，按需下载
```

用户点击下载后显示：

```text
自然语音 · 多音色
下载大小：约 180～220 MB
安装后占用：约 215 MB
包含：中英文朗读、103 个基础音色
```

下载完成后保存：

```text
context.filesDir/tts/<model-id>
```

而临时压缩包放在：

```text
context.cacheDir/tts-download/
```

解压成功并校验完后删除压缩包，避免同时占用两份空间。

## 模型更新目录设计

建议不要直接写死为一个目录，增加版本层：

```text
filesDir/tts/
├── kokoro-int8-multi-lang-v1_1/
│   ├── 1.0.0/
│   │   └── 模型文件
│   └── current.json
└── model-registry.json
```

或者简化为：

```text
filesDir/tts/
├── kokoro-int8-multi-lang-v1_1-202607/
└── active-model.json
```

下载更新时先放到临时目录：

```text
filesDir/tts/.installing/
```

校验完成后再原子切换，避免下载中断导致原模型损坏。

## 是否可以只下载部分音色

这个模型不太适合按单个音色拆包，因为全部音色集中在同一个：

```text
voices.bin
```

`voices.bin` 约 53.8 MB。即使你只向用户展示 8 个音色，通常仍然需要完整文件。([Hugging Face][1])

理论上可以研究拆分 speaker embedding，但需要确认 sherpa-onnx 对 `voices.bin` 的文件结构和索引要求，且后续升级容易失配。第一版不值得做这种裁剪。

## 我的明确建议

开发阶段：

```text
模型放 resources/rawfile
```

先把推理、播放队列、暂停恢复和音色切换跑通。

正式发布：

```text
HAP 只带 sherpa_onnx
模型按需下载到 context.filesDir
App 保存并指定模型绝对路径
```

这能把阅读器初始安装包控制住，也方便以后增加 Kokoro、VITS 或其他模型。215 MB 的模型硬塞进安装包，能用，但多少有点像为了带把伞，给汽车焊了个雨棚。

[1]: https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/tree/main "csukuangfj/kokoro-int8-multi-lang-v1_1 at main"
[2]: https://k2-fsa.github.io/sherpa/onnx/harmony-os/tts.html "On-device text-to-speech (TTS, 本地语音合成) — sherpa 1.3 documentation"


# Kokoro加载性能优化
**3 分多钟明显不正常。**Kokoro INT8 在现代鸿蒙手机上，即使冷启动，也不应该需要几分钟。最可能的问题不是模型本身，而是启动时反复执行了：

1. 遍历 `rawfile` 中的大量资源；
2. 把每个文件完整读入 `Uint8Array`；
3. 再复制到应用沙箱；
4. 创建 ONNX Runtime Session；
5. 甚至每次开始朗读都重新创建引擎。

官方 HarmonyOS 示例里的资源复制实现确实存在一个很容易踩中的性能点：`copyRawFileToSandbox()` 会先调用 `getRawFileContentSync(src)`，之后才检查沙箱中的目标文件大小。也就是说，**即使文件已经复制过，仍然会先把源文件完整读取一遍**。对于 Kokoro 的大量词典和 `espeak-ng-data` 文件，这可能造成非常慢的启动。([GitHub][1])

## 第一优先级：确认慢在哪里

先在初始化代码中加分段计时，不要只测整个 `new OfflineTts()`：

```ts
const now = (): number => Date.now();

let t = now();
console.info(`[TTS] init start`);

const t1 = now();
console.info(`[TTS] prepare path: ${t1 - t} ms`);

copyModelResourcesIfNeeded();
const t2 = now();
console.info(`[TTS] copy resources: ${t2 - t1} ms`);

const config = buildTtsConfig();
const t3 = now();
console.info(`[TTS] build config: ${t3 - t2} ms`);

const tts = new OfflineTts(config, context.resourceManager);
const t4 = now();
console.info(`[TTS] create OfflineTts: ${t4 - t3} ms`);

console.info(`[TTS] total: ${t4 - t} ms`);
```

另外记录：

```ts
console.info(`[TTS] model=${modelPath}`);
console.info(`[TTS] voices=${voicesPath}`);
console.info(`[TTS] dataDir=${dataDir}`);
console.info(`[TTS] lexicon=${lexicon}`);
```

判断标准：

| 耗时位置                      | 主要原因                        |
| ------------------------- | --------------------------- |
| 资源复制 2～3 分钟               | `rawfile` 遍历、读取和复制          |
| `new OfflineTts()` 2～3 分钟 | ONNX Session、模型路径、存储介质或版本问题 |
| 第一次 `generate()` 很慢       | 首次推理、线程配置、CPU性能             |
| 每次朗读都慢                    | 重复创建 OfflineTts             |

---

# 最有效的优化：不要每次从 rawfile 读取模型

## 正式版把模型放应用沙箱

你的模型本来就准备按需下载，那么应直接放到：

```text
context.filesDir/tts/kokoro-int8-multi-lang-v1_1/
```

例如：

```text
/data/storage/el2/base/haps/entry/files/tts/kokoro-int8-multi-lang-v1_1/
├── model.int8.onnx
├── voices.bin
├── tokens.txt
├── lexicon-zh.txt
├── lexicon-us-en.txt
├── date-zh.fst
├── number-zh.fst
├── phone-zh.fst
├── dict/
└── espeak-ng-data/
```

初始化时全部使用绝对路径：

```ts
const root =
  `${context.filesDir}/tts/kokoro-int8-multi-lang-v1_1`;

config.model.kokoro.model =
  `${root}/model.int8.onnx`;

config.model.kokoro.voices =
  `${root}/voices.bin`;

config.model.kokoro.tokens =
  `${root}/tokens.txt`;

config.model.kokoro.lexicon = [
  `${root}/lexicon-zh.txt`,
  `${root}/lexicon-us-en.txt`,
  `${root}/lexicon-gb-en.txt`
].join(',');

config.model.kokoro.dataDir =
  `${root}/espeak-ng-data`;

config.ruleFsts = [
  `${root}/date-zh.fst`,
  `${root}/phone-zh.fst`,
  `${root}/number-zh.fst`
].join(',');
```

关键是：

```text
不要调用 copyRawFileDirToSandbox()
不要调用 getRawFileContentSync()
不要每次遍历 rawfile
```

官方示例本质上是为了方便演示，把模型打包到应用资源中；它并不一定是正式产品的大模型加载最佳方案。官方代码会复制 `dataDir`，并在创建 `OfflineTts` 前设置模型、voices、tokens、lexicon 等路径。([GitHub][1])

---

# 如果暂时必须把模型放在 rawfile

至少改成**先检查目标文件，再读取源文件**。

官方示例当前逻辑大致是：

```ts
const data = resourceManager.getRawFileContentSync(src);

// 到这里才检查目标文件
if (fs.accessSync(filepath)) {
  const stat = fs.statSync(filepath);
  if (stat.size === data.length) {
    return;
  }
}
```

问题是，为了知道 `data.length`，已经把整个文件读进内存了。官方源码就是这个顺序。([GitHub][1])

更好的做法是建立一个模型清单：

```json
{
  "version": "1.1-int8",
  "files": {
    "model.int8.onnx": {
      "size": 114000000,
      "sha256": "..."
    },
    "voices.bin": {
      "size": 53800000,
      "sha256": "..."
    }
  }
}
```

启动时先读取一个很小的安装标记：

```ts
const marker =
  `${context.filesDir}/tts/kokoro-int8-multi-lang-v1_1/.installed`;

if (fs.accessSync(marker)) {
  // 直接初始化，不遍历 rawfile
  return;
}
```

只在首次安装时复制：

```ts
async function installModelOnce(): Promise<void> {
  if (fs.accessSync(marker)) {
    return;
  }

  await copyAllModelFiles();

  // 校验关键文件
  validateModelFiles();

  const fd = fs.openSync(
    marker,
    fs.OpenMode.CREATE |
    fs.OpenMode.WRITE_ONLY |
    fs.OpenMode.TRUNC
  );
  fs.writeSync(fd.fd, '1.1-int8');
  fs.closeSync(fd.fd);
}
```

不要在每次初始化时逐个判断几百个资源文件。

## 更进一步：安装完成后只记录模型版本

例如：

```text
filesDir/tts/model-registry.json
```

内容：

```json
{
  "kokoro-int8-multi-lang-v1_1": {
    "installed": true,
    "version": "1.1",
    "root": "/data/storage/.../files/tts/kokoro-int8-multi-lang-v1_1",
    "verified": true
  }
}
```

只有以下情况才重新校验：

* 首次安装；
* 模型版本升级；
* App 检测到关键文件不存在；
* 上次安装异常中断。

---

# 第二优先级：OfflineTts 必须做成单例

官方示例已经通过：

```ts
if (msgType == 'init-tts' && !tts) {
  tts = initTts(context);
}
```

确保 Worker 生命周期内只初始化一次。([GitHub][1])

你的阅读器也应该采用类似结构：

```ts
class KokoroTtsManager {
  private static instance: KokoroTtsManager;
  private tts?: OfflineTts;
  private initPromise?: Promise<OfflineTts>;

  static getInstance(): KokoroTtsManager {
    if (!KokoroTtsManager.instance) {
      KokoroTtsManager.instance = new KokoroTtsManager();
    }
    return KokoroTtsManager.instance;
  }

  async ensureInitialized(): Promise<OfflineTts> {
    if (this.tts) {
      return this.tts;
    }

    if (this.initPromise) {
      return this.initPromise;
    }

    this.initPromise = this.initialize();

    try {
      this.tts = await this.initPromise;
      return this.tts;
    } finally {
      this.initPromise = undefined;
    }
  }

  private async initialize(): Promise<OfflineTts> {
    // 在 Worker 中执行实际初始化
    return createOfflineTts();
  }
}
```

不要在以下动作中重新创建引擎：

```text
每次点击朗读
每次翻页
每次切换章节
每次暂停后恢复
每次切换音色
```

Kokoro 的所有 speaker 都在同一个 `voices.bin` 中，切换音色只改 `sid`，不需要重新加载模型：

```ts
input.sid = selectedSpeakerId;
```

只有切换到另一套模型时，才需要释放和重建引擎。

---

# 第三优先级：提前异步初始化

不要等用户点击朗读后才加载。

比较好的时机：

```text
用户打开书籍
    ↓
页面渲染完成
    ↓
后台 Worker 初始化 Kokoro
    ↓
用户点击朗读时已经就绪
```

例如在书籍页面进入后：

```ts
aboutToAppear(): void {
  this.scheduleTtsWarmup();
}

private scheduleTtsWarmup(): void {
  setTimeout(() => {
    KokoroTtsManager
      .getInstance()
      .ensureInitialized()
      .catch((err: Error) => {
        console.error(`[TTS] warmup failed: ${err.message}`);
      });
  }, 500);
}
```

实际初始化应放在 `TaskPool` 或 `Worker`，不要阻塞 UI 线程。官方 HarmonyOS 示例也是把 `OfflineTts` 初始化和 `generateAsync()` 放在 Worker 中处理。([GitHub][1])

---

# 第四优先级：关闭 debug

官方示例配置是：

```ts
config.model.debug = true;
```

([GitHub][1])

正式版改成：

```ts
config.model.debug = false;
```

这通常不会把 3 分钟直接变成 3 秒，但可以减少日志输出和额外检查，尤其是大量日志被 DevEco Studio 捕获时。

---

# 第五优先级：线程数调优，但主要影响推理

官方示例默认：

```ts
config.model.numThreads = 2;
```

([GitHub][1])

可以测试：

```ts
config.model.numThreads = 4;
```

或者根据设备核心数：

```ts
const recommendedThreads = 4;
config.model.numThreads = recommendedThreads;
```

建议测试：

```text
2 线程
4 线程
6 线程
```

不要简单设成 CPU 全部核心数。手机大小核架构下，线程过多可能导致：

* 抢占 UI；
* 功耗和温度上升；
* 系统降频；
* 实际速度反而下降。

更重要的是：`numThreads` 主要优化**语音生成速度**，对模型文件读取和资源复制帮助不大。因此，在没有确定耗时发生在 `new OfflineTts()` 之前，不要把线程数当成首要解法。

---

# 第六优先级：不要重复校验 200 MB 文件的 SHA-256

模型下载完成时校验一次是对的，但每次启动时重新计算：

```text
model.int8.onnx SHA-256
voices.bin SHA-256
全部词典 SHA-256
```

也可能耗时很久。

合理策略：

```text
下载完成
  → 完整 SHA-256 校验
  → 写入 .installed / registry

普通启动
  → 只检查标记、版本和关键文件是否存在
  → 不重新计算完整哈希
```

可以快速检查：

```ts
interface ExpectedFile {
  path: string;
  size: number;
}

function quickValidate(files: ExpectedFile[]): boolean {
  for (const item of files) {
    if (!fs.accessSync(item.path)) {
      return false;
    }

    if (fs.statSync(item.path).size !== item.size) {
      return false;
    }
  }

  return true;
}
```

完整 SHA-256 只在：

* 下载后；
* 用户主动执行“验证语音包”；
* 文件大小不符；
* 应用异常退出后发现安装未完成。

---

# 第七优先级：确认模型没有放在慢速外部存储

模型应该放在应用内部沙箱：

```text
context.filesDir
```

不建议直接从这些位置加载：

```text
Download/
Documents/
用户选择的公共目录 URI
NAS 或分布式目录
压缩包内部
```

尤其不要每次从压缩包动态读取 `model.int8.onnx`。正确流程是：

```text
下载压缩包
  → 解压到临时目录
  → 校验
  → 移动到 filesDir/tts/
  → 删除压缩包
  → 直接从普通文件加载
```

---

# 第八优先级：做一次短文本预热

模型初始化完成后，第一次推理有时仍会比后续慢。可以后台生成一个极短文本：

```ts
const warmupInput = new TtsInput();
warmupInput.text = '你好。';
warmupInput.sid = defaultSid;
warmupInput.speed = 1.0;

await tts.generateAsync(warmupInput);
```

生成结果丢弃。

注意：

* 预热放 Worker；
* 页面稳定后执行；
* 不要在 App 启动首屏同步执行；
* 低电量或省电模式可以跳过。

---

# 推荐的加载流程

```text
App 安装
  └─ 不带 Kokoro 大模型

用户下载自然语音
  ├─ 下载到 cacheDir
  ├─ 解压到 .installing
  ├─ SHA-256 校验一次
  ├─ 原子移动到 filesDir/tts/model-id
  └─ 写入 .installed

打开阅读页面
  ├─ 检查 .installed
  ├─ 直接使用绝对路径
  ├─ Worker 中 new OfflineTts
  ├─ 保持单例
  └─ 可选短文本预热

开始朗读
  ├─ 不重新初始化
  ├─ 只提交文本和 sid
  └─ 预生成后续 2～3 句
```

## 我对你这个问题的判断

按概率排序：

1. **每次启动都在遍历并读取 `rawfile/espeak-ng-data`**；
2. **模型或词典反复从 rawfile 复制到沙箱**；
3. **每次朗读重新创建 `OfflineTts`**；
4. 每次启动重新计算整个模型包 SHA-256；
5. 模型仍在压缩包或公共存储 URI 中；
6. 真正的 ONNX Session 初始化异常缓慢。

先把模型完整放到 `context.filesDir`，使用绝对路径，并彻底绕过 `copyRawFileDirToSandbox()`。这一项最可能把 3 分钟降到合理范围。随后保持 `OfflineTts` 单例、后台预加载、关闭 debug。线程数则放到最后调整——它更像油门，不是搬掉堵在路中央的冰箱。

[1]: https://github.com/k2-fsa/sherpa-onnx/blob/master/harmony-os/SherpaOnnxTts/entry/src/main/ets/workers/NonStreamingTtsWorker.ets "sherpa-onnx/harmony-os/SherpaOnnxTts/entry/src/main/ets/workers/NonStreamingTtsWorker.ets at master · k2-fsa/sherpa-onnx · GitHub"


# 转语音性能优化

可以优化，但先给结论：**277 字耗时 174 秒，Kokoro 在这台设备/当前鸿蒙构建上很可能达不到“整段生成完再播放”的实时朗读要求。**

最有效的办法不是期待把 174 秒优化到 5 秒，而是同时做两件事：

1. 把推理速度尽量提高；
2. 改成“短句生成一段、立即播放一段”，隐藏总生成时间。

## 先计算真正的性能：RTF

不能只看“277 字用了 174 秒”，要记录生成音频的时长。

```text
RTF = 合成耗时 ÷ 生成音频时长
```

例如这 277 字最终生成 75 秒音频：

```text
RTF = 174 ÷ 75 = 2.32
```

含义是生成 1 秒语音需要 2.32 秒，无法实时追上播放。

朗读器大致要求：

|       RTF | 使用体验       |
| --------: | ---------- |
|   `< 0.5` | 很理想，能轻松预生成 |
| `0.5～0.9` | 可以连续朗读     |
| `0.9～1.2` | 勉强，需较大缓冲   |
|   `> 1.5` | 很难连续播放     |
|     `> 2` | 建议换轻量模型    |

sherpa-onnx 的一些 VITS 模型即使在树莓派 4 上，官方测试也可能出现 RTF 大于 1；增加线程可明显改善，但提升并非线性。例如某中文 VITS 模型从 1 线程的 RTF 4.275 降到 4 线程的 1.593。([K2 FSA][1])

---

# 第一项：确认没有只使用一个 CPU 线程

Kokoro 在鸿蒙上通常通过 ONNX Runtime CPU provider 运行，不会自然使用华为手机的 NPU。sherpa-onnx 配置里一般能看到：

```text
provider = cpu
num_threads = ...
```

官方案例也提醒，单线程 CPU 运行 Kokoro 会非常慢。([GitHub][2])

检查初始化配置：

```ts
config.model.numThreads = 4;
config.model.provider = 'cpu';
config.model.debug = false;
```

依次实测：

```text
1、2、4、6 线程
```

不要直接认为 8 线程最快。手机是大小核架构，过多线程可能让任务跑到小核、引发发热降频，反而变慢。

建议测试同一段 50 字文本：

| 线程数 | 合成耗时 | 音频时长 | RTF |
| --: | ---: | ---: | --: |
|   1 |      |      |     |
|   2 |      |      |     |
|   4 |      |      |     |
|   6 |      |      |     |

如果 1、2、4、6 线程耗时几乎一样，重点检查：

* `numThreads` 是否确实传入 native 层；
* HAR 版本是否实际采用该配置；
* 是否每次测试都重建引擎；
* CPU 使用率是不是始终只有约一个核心；
* 是否使用 Debug 构建。

## 一定使用 Release 构建测试

DevEco 的 Debug 版本、native 调试符号和大量日志可能显著影响性能。

至少测试：

```text
Release HAP
debug = false
关闭高频 console 日志
断开 DevEco 调试器后测试
```

尤其不要在音频回调中逐帧打印日志。

---

# 第二项：不要一次输入 277 字

Kokoro 对长文本通常会分句处理，但把一大段文本一次交进去，会产生两个问题：

* 必须等整段全部完成才拿到结果；
* 长句的 token 序列会加大单次推理成本和内存压力。

把文本切成 **15～35 个汉字一段**，每段一至两个自然句。

例如原文：

```text
张明推开房门，看见桌上放着一封信。他犹豫了一会儿，
最终还是拆开了信封。窗外的雨越来越大，房间里只剩下钟表的声音。
```

拆成：

```text
张明推开房门，看见桌上放着一封信。
他犹豫了一会儿，最终还是拆开了信封。
窗外的雨越来越大。
房间里只剩下钟表的声音。
```

推荐规则：

```text
优先按：。！？；
其次按：，：
最低长度：10～15 字
目标长度：20～35 字
最大长度：45～60 字
```

不要切成每个逗号一段，否则语气会碎得像导航播报。

### 这不会一定降低总耗时，但会大幅改善首句等待

假设：

```text
277 字总生成时间：174 秒
切成 10 段
第一段生成时间：10～18 秒
```

用户无需等 174 秒才听到声音，可以第一段生成完就开始播放，同时后台生成第二段。

不过，如果单个 25 字句子仍然需要 15～20 秒，而它只能播放约 6～8 秒，后台生成仍然追不上，最终还是会断音。因此切句只是隐藏延迟，**RTF 仍必须接近或低于 1**。

---

# 第三项：采用生产者—消费者流水线

阅读器不要这样做：

```text
277 字 → 全部生成 → 播放
```

应改为：

```text
文本分句
   ↓
生成第 1 句
   ↓
立即播放第 1 句
   ├─ 同时生成第 2 句
   └─ 后续保持 2～4 句缓存
```

基本结构：

```ts
interface TtsSegment {
  id: number;
  text: string;
  pcm?: ArrayBuffer;
  state: 'pending' | 'generating' | 'ready' | 'playing' | 'done';
}

class TtsPipeline {
  private segments: TtsSegment[] = [];
  private nextGenerateIndex: number = 0;
  private nextPlayIndex: number = 0;
  private readonly targetReadyCount: number = 3;

  async start(text: string): Promise<void> {
    this.segments = splitForTts(text).map((item, index) => ({
      id: index,
      text: item,
      state: 'pending'
    }));

    await this.fillBuffer();
    await this.playLoop();
  }

  private async fillBuffer(): Promise<void> {
    while (
      this.nextGenerateIndex < this.segments.length &&
      this.readyCount() < this.targetReadyCount
    ) {
      const segment = this.segments[this.nextGenerateIndex++];
      segment.state = 'generating';

      const audio = await this.generate(segment.text);
      segment.pcm = audio;
      segment.state = 'ready';
    }
  }

  private readyCount(): number {
    return this.segments.filter(item => item.state === 'ready').length;
  }

  private async playLoop(): Promise<void> {
    while (this.nextPlayIndex < this.segments.length) {
      const segment = this.segments[this.nextPlayIndex];

      while (segment.state !== 'ready') {
        await new Promise<void>(resolve => setTimeout(resolve, 20));
      }

      segment.state = 'playing';

      // 播放期间继续补充后续句子
      const filling = this.fillBuffer();
      await this.playPcm(segment.pcm!);
      await filling;

      segment.state = 'done';
      segment.pcm = undefined;
      this.nextPlayIndex++;
    }
  }

  private async generate(text: string): Promise<ArrayBuffer> {
    // 调用 Worker 中的 sherpa-onnx
    throw new Error('Not implemented');
  }

  private async playPcm(data: ArrayBuffer): Promise<void> {
    // 写入 AudioRenderer
    throw new Error('Not implemented');
  }
}
```

实际实现中，生成和播放必须处于不同执行通道，不能让 `generate()` 阻塞 AudioRenderer。

---

# 第四项：检查是否真的用了 INT8 模型

确认路径指向：

```text
model.int8.onnx
```

而不是：

```text
model.onnx
```

同时在 sherpa-onnx debug 日志中确认实际加载的文件。验证完后再关闭 debug。

但有个现实问题：**INT8 不保证在所有 ARM CPU 上都比 FP32 快很多。**

速度取决于：

* ONNX Runtime 是否启用了 ARM 优化；
* 算子是否具有有效的 INT8 kernel；
* 模型中多少算子真正被量化；
* 线程调度和内存带宽；
* SoC CPU 架构。

因此可以在同一设备上用 30 字短句比较：

```text
model.int8.onnx
model.onnx
```

不要只根据文件名断定 INT8 一定更快。通常 INT8 更省内存，但某些算子发生量化/反量化时，速度收益可能有限。

---

# 第五项：检查 CPU 使用情况

合成期间观察：

```text
CPU 总占用
各核心占用
CPU 频率
设备温度
内存
```

典型判断：

### 只有一个核心接近 100%

说明多线程没有生效，或者主要瓶颈是单线程算子。

处理方向：

```ts
config.model.numThreads = 4;
```

并检查 native 配置日志。

### 多个核心较高，但速度仍慢

说明模型对该 CPU 就比较重，继续调线程只能小幅改善。

### 开始快，后面越来越慢

很可能是发热降频。应：

* 控制线程数在 2～4；
* 不一次生成整章；
* 维持小缓冲，不无限预生成；
* 屏幕关闭时仍需观察系统功耗策略。

### CPU 占用不高但非常慢

可能包括：

* Worker/TaskPool 调度问题；
* 频繁复制巨大 PCM 数组；
* ArkTS 与 native 间反复转换；
* 每次句子重新创建 TTS 实例；
* 同步写 WAV 文件；
* 音频数据经过多次序列化。

---

# 第六项：避免 PCM 数据的巨大复制

277 字可能生成一分钟以上的 24 kHz 音频。以单声道 Float32 计算：

```text
24000 × 4 字节 × 60 秒 ≈ 5.5 MB
```

如果经历：

```text
native vector
→ NAPI Array
→ Worker 消息
→ ArkTS Array
→ AudioRenderer
```

可能发生多次完整复制。

优化方向：

* 优先使用 `ArrayBuffer`；
* 避免转换成普通 `number[]`；
* 避免拼接多个大数组；
* 分句后逐段传输；
* 尽量使用可转移对象；
* 不要先写 WAV 再重新读出播放；
* 直接把 PCM 分块交给 AudioRenderer。

不过，277 字耗时 174 秒，**主要瓶颈大概率仍是模型推理**，而不是几 MB 数据复制。数据复制一般是第二级优化。

---

# 第七项：不要并发创建多个 Kokoro 实例

看起来可以同时生成第 2、3 句，但不建议一开始这么做：

```text
OfflineTts 实例 1 → 第 1 句
OfflineTts 实例 2 → 第 2 句
OfflineTts 实例 3 → 第 3 句
```

Kokoro 实例可能各自持有完整 ONNX Session 和模型内存。这会导致：

* 内存大幅增加；
* 多个实例争抢 CPU；
* 发热更严重；
* 线程过度订阅；
* 最终吞吐反而下降。

先用：

```text
1 个 TTS 实例
4 个推理线程
1 条串行生成队列
播放与生成并行
```

只有在确认单实例没有吃满 CPU 后，才测试两个实例；通常手机端不值得。

---

# 第八项：调高语速只能有限改善

Kokoro 的 `speed` 或 `lengthScale` 会影响输出音频长度，但不意味着推理耗时按同样比例下降。

例如：

```ts
input.speed = 1.1;
```

可能稍微减少生成样本数量，但用户能接受的范围通常只有：

```text
0.9～1.25
```

无法靠把语速调快解决 2～3 倍的性能差距。

---

# 第九项：换更轻的模型，往往才是根本方案

如果优化线程、Release、分句后，RTF 仍然大于 1.2，建议不要把 Kokoro 作为默认朗读引擎。

可以采用：

```text
高品质模式：Kokoro
流畅模式：轻量 VITS
系统模式：鸿蒙系统 TTS
```

sherpa-onnx 官方提供多种中文 VITS 模型，包括：

* `vits-melo-tts-zh_en`
* 中文单说话人 VITS
* AISHELL3 多说话人模型
* 其他中文 VITS 模型

官方文档也给出了 VITS 在不同线程数下的 RTF 测试，说明这类模型虽音质通常低于 Kokoro，但更适合资源有限的 CPU 设备。([K2 FSA][1])

需要注意：`vits-melo-tts-zh_en` 本身并不算特别小，官方页面列出的模型约 163 MB；选择模型时要实际比较 RTF，而不是只比较包体积。([K2 FSA][1])

## 更现实的产品定位

| 引擎       | 用途                 |
| -------- | ------------------ |
| 鸿蒙系统 TTS | 默认流畅、低功耗           |
| 轻量 VITS  | 离线增强、能连续朗读         |
| Kokoro   | 高品质短段落、导出音频，或高性能设备 |

Kokoro 很自然，但自然往往是拿算力换来的。手机 CPU 没有魔法口袋。

---

# 建议你马上做的测试

用同一个已经初始化的 TTS 实例，分别测试以下文本长度：

```text
15 字
30 字
60 字
120 字
277 字
```

每项记录：

```text
文本字数
预处理耗时
generate 耗时
音频样本数
音频时长
RTF
numThreads
```

示例：

```ts
const start = Date.now();

const audio = await tts.generateAsync(input);

const elapsedMs = Date.now() - start;
const audioSeconds = audio.samples.length / audio.sampleRate;
const rtf = elapsedMs / 1000 / audioSeconds;

console.info(
  `[TTS] chars=${input.text.length}, ` +
  `elapsed=${elapsedMs}ms, ` +
  `audio=${audioSeconds.toFixed(2)}s, ` +
  `RTF=${rtf.toFixed(3)}, ` +
  `threads=${numThreads}`
);
```

这组结果能判断：

* 耗时是否基本随字数线性增加；
* 长文本是否出现额外恶化；
* 切句是否能降低单位成本；
* 多线程是否有效；
* 是否足以边生成边播放。

## 最终判断标准

优化后如果达到：

```text
RTF ≤ 0.8
```

Kokoro 可以作为连续朗读引擎。

如果是：

```text
0.8 < RTF ≤ 1.2
```

使用 3～5 句预缓冲，有机会稳定朗读。

如果仍是：

```text
RTF > 1.5
```

不要继续花大量时间微调。保留 Kokoro 作为“高品质模式”，默认改用轻量 VITS 或系统 TTS，会更靠谱。

**针对你当前的 174 秒结果，优先顺序是：Release 构建 → `numThreads` 测试 2/4/6 → 20～35 字分句 → 计算 RTF → 播放与下一句生成流水线。若 RTF 仍大于 1.2，直接换轻量模型。**

[1]: https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html?utm_source=chatgpt.com "vits — sherpa 1.3 documentation"
[2]: https://github.com/k2-fsa/sherpa-onnx/issues/2236?utm_source=chatgpt.com "Can't get kokoro 1.0 with wasm onnx to run · Issue #2236"

# 如何后台播放

可以解决。你现在虽然创建了 `AVSession`，但 **AVSession 主要负责播控中心、锁屏控制和媒体状态管理，本身不等于后台保活**。

要实现熄屏后继续：

```text
VITS/ONNX 后台生成 PCM
        +
AudioRenderer 持续播放
        +
AVSession 激活
        +
audioPlayback 长时任务
```

缺少长时任务时，应用进入后台或锁屏后，系统可能暂停 AudioRenderer，或者挂起负责 ONNX 推理、PCM 供给的 Worker，最终表现为播放停止。华为官方明确要求：后台或熄屏播放需要同时接入 AVSession，并申请音频播放长时任务。([华为开发者][1])

## 1. 配置后台播放权限

在 `entry/src/main/module.json5` 中加入：

```json
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING"
      }
    ],

    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "backgroundModes": [
          "audioPlayback"
        ]
      }
    ]
  }
}
```

关键是两处都需要：

```text
ohos.permission.KEEP_BACKGROUND_RUNNING
backgroundModes: ["audioPlayback"]
```

`KEEP_BACKGROUND_RUNNING` 是系统授权的普通权限，音频播放对应的长时任务类型是 `audioPlayback`。([华为开发者][2])

注意 `backgroundModes` 应当配置在真正发起长时任务的 Ability 上。

## 2. 开始朗读时启动音频长时任务

导入模块：

```ts
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
```

建立管理类：

```ts
export class AudioBackgroundTask {
  private context: common.UIAbilityContext;
  private running: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }

    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      wantAgentFlags: [
        wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG
      ]
    };

    const agent = await wantAgent.getWantAgent(wantAgentInfo);

    await backgroundTaskManager.startBackgroundRunning(
      this.context,
      backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
      agent
    );

    this.running = true;
    console.info('[TTS] audio background task started');
  }

  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }

    await backgroundTaskManager.stopBackgroundRunning(this.context);

    this.running = false;
    console.info('[TTS] audio background task stopped');
  }
}
```

调用顺序建议是：

```ts
await backgroundTask.start();
await avSession.activate();
await audioRenderer.start();
```

停止朗读时：

```ts
await audioRenderer.stop();
await avSession.deactivate();
await backgroundTask.stop();
```

官方 AudioRenderer PCM 播放实践同样采用 `BackgroundMode.AUDIO_PLAYBACK` 启动长时任务。([华为开发者][3])

## 3. AVSession 必须保持激活

创建后还要调用：

```ts
await avSession.activate();
```

不要只创建而未激活：

```ts
const avSession = await avSessionManager.createAVSession(
  context,
  'ReaderTtsSession',
  'audio'
);

await avSession.activate();
```

播放状态也要同步更新：

```ts
await avSession.setAVPlaybackState({
  state: avSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
  speed: 1.0,
  position: {
    elapsedTime: currentPositionMs,
    updateTime: Date.now()
  }
});
```

暂停时：

```ts
await avSession.setAVPlaybackState({
  state: avSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE,
  speed: 1.0,
  position: {
    elapsedTime: currentPositionMs,
    updateTime: Date.now()
  }
});
```

停止时：

```ts
await avSession.setAVPlaybackState({
  state: avSessionManager.PlaybackState.PLAYBACK_STATE_STOP,
  speed: 1.0,
  position: {
    elapsedTime: 0,
    updateTime: Date.now()
  }
});
```

AVSession 应当覆盖完整朗读周期，而不是每播放一句就创建、激活、销毁一次。官方要求音视频应用作为媒体会话提供方，维持媒体信息和播放状态，并响应系统播控命令。([华为开发者][4])

## 4. AudioRenderer 的用途和内容类型要配置正确

阅读器 TTS 应使用语音类型：

```ts
import audio from '@ohos.multimedia.audio';

const rendererOptions: audio.AudioRendererOptions = {
  streamInfo: {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
    channels: audio.AudioChannel.CHANNEL_1,
    sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
    encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
  },
  rendererInfo: {
    content: audio.ContentType.CONTENT_TYPE_SPEECH,
    usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    rendererFlags: 0
  }
};
```

如果你当前 SDK 没有 `STREAM_USAGE_AUDIOBOOK`，可以根据 API 版本使用：

```ts
usage: audio.StreamUsage.STREAM_USAGE_MEDIA
```

尽量不要使用：

```ts
STREAM_USAGE_UNKNOWN
STREAM_USAGE_NOTIFICATION
STREAM_USAGE_VOICE_COMMUNICATION
```

错误的 usage 可能让系统按通知音、通话音频或临时音频处理，而不是持续媒体播放。

## 5. ONNX 推理 Worker 也必须处于长时任务生命周期内

你的链路不是单纯播放固定音频文件，而是：

```text
Worker 运行 VITS
  → 产生 PCM
  → 发送到主线程
  → AudioRenderer 播放
```

熄屏以后可能出现两种情况：

### 情况 A：AudioRenderer 被系统停止

长时任务加 AVSession 通常可以解决。

### 情况 B：AudioRenderer 仍在运行，但 Worker 不再生成 PCM

这会导致 AudioRenderer 因没有数据而停播或静音。此时要确保：

* 长时任务在开始 ONNX 推理前已经启动；
* Worker 不依附于页面对象；
* 页面 `onPageHide()` 中没有停止 Worker；
* `UIAbility.onBackground()` 中没有释放 TTS；
* 熄屏事件中没有暂停生成队列；
* 不要因为 UI 页面销毁而销毁 AudioRenderer。

错误模式：

```ts
onPageHide(): void {
  this.ttsWorker.terminate();
  this.audioRenderer.stop();
}
```

阅读器进入锁屏或后台时，页面生命周期可能变化，这样会主动中断播放。

更好的设计是把朗读服务放到应用级管理器：

```text
UI 页面
   ↓ 发出开始/暂停/跳转命令

ReaderAudioService
├── AVSession
├── 长时任务
├── AudioRenderer
├── VITS Worker
├── PCM 队列
└── 当前章节及句子位置
```

不要让它跟某个具体页面的生命周期绑定。

## 6. 保证 AudioRenderer 始终有 PCM 可读

VITS 是边生成边播放时，熄屏后 CPU 调度可能变慢。即使没有被完全挂起，推理速度下降也可能造成 PCM 队列断供。

建议播放前缓存至少：

```text
10～20 秒 PCM
```

而不是只缓存下一句。

结构建议：

```text
低水位：剩余 8 秒音频
目标水位：剩余 20 秒
高水位：剩余 30 秒
```

当队列低于低水位时，加快生成：

```ts
if (bufferedDurationMs < 8000) {
  requestNextSegments();
}
```

达到高水位时暂停预生成：

```ts
if (bufferedDurationMs > 30000) {
  pauseGeneration();
}
```

对于熄屏朗读，缓存 2～3 句未必足够，因为短句可能只有三四秒。

## 7. 不要在句子间 stop/start AudioRenderer

有些实现会这样：

```text
生成一句
→ AudioRenderer.start()
→ 播放一句
→ AudioRenderer.stop()
→ 生成下一句
→ 再 start()
```

这很容易在熄屏状态下被系统认定为播放已经结束，后台任务也可能失去持续音频活动。

正确方式是：

```text
一次创建 AudioRenderer
一次 start()
持续向 renderer 写入 PCM
最后才 stop()
```

句子之间可以插入短暂静音 PCM：

```ts
function createSilence(
  durationMs: number,
  sampleRate: number = 24000
): ArrayBuffer {
  const sampleCount = Math.floor(sampleRate * durationMs / 1000);
  return new Int16Array(sampleCount).buffer;
}
```

例如句尾插入 150～300 ms 静音，但不要停止 renderer。

## 8. 检查 AudioRenderer 的回调模式

推荐使用数据请求回调持续供给 PCM，而不是在多个异步任务中随意调用 `write()`。

核心原则：

```text
AudioRenderer 请求数据
  → 从 PCM 环形缓冲区取数据
  → 不足则补静音
  → 后台继续生成
```

当缓存暂时为空时，不要直接结束 AudioRenderer。可以暂时返回静音，给 VITS 几百毫秒补充数据。

但是不能长时间无限补静音，否则用户会听到明显停顿。应同时触发缓冲不足状态。

## 9. 处理音频焦点中断

即使后台播放配置正确，来电、导航、其他播放器也可能导致音频焦点中断。

监听 AudioRenderer 中断事件：

```ts
audioRenderer.on('audioInterrupt', async (interruptEvent) => {
  console.info(
    `[TTS] interrupt force=${interruptEvent.forceType}, ` +
    `hint=${interruptEvent.hintType}`
  );

  switch (interruptEvent.hintType) {
    case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
      await pauseReading();
      break;

    case audio.InterruptHint.INTERRUPT_HINT_STOP:
      await stopReading();
      break;

    case audio.InterruptHint.INTERRUPT_HINT_RESUME:
      await resumeReading();
      break;

    case audio.InterruptHint.INTERRUPT_HINT_DUCK:
      await audioRenderer.setVolume(0.2);
      break;

    case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
      await audioRenderer.setVolume(1.0);
      break;
  }
});
```

不要把所有 `audioInterrupt` 都当成停止。系统允许恢复时应继续播放。

## 10. 建议的完整启动顺序

```ts
async function startReading(): Promise<void> {
  // 1. 先取得后台运行资格
  await backgroundAudioTask.start();

  // 2. 激活媒体会话
  await readerAvSession.activate();

  // 3. 初始化并启动持续运行的 AudioRenderer
  await pcmPlayer.prepare();
  await pcmPlayer.start();

  // 4. 启动 VITS Worker 和预生成队列
  await ttsPipeline.start();

  // 5. 更新播控中心状态
  await readerAvSession.updatePlayingState();
}
```

结束顺序反过来：

```ts
async function stopReading(): Promise<void> {
  await ttsPipeline.stop();
  await pcmPlayer.stop();

  await readerAvSession.updateStoppedState();
  await readerAvSession.deactivate();

  await backgroundAudioTask.stop();
}
```

不要过早调用：

```ts
stopBackgroundRunning()
avSession.deactivate()
```

它们应该在整次朗读真正结束时调用，而不是一句话播放完成时调用。

## 最可能的问题排序

根据你的实现方式，最可能是：

1. 只接入了 AVSession，没有调用 `startBackgroundRunning()`；
2. `module.json5` 未声明 `backgroundModes: ["audioPlayback"]`；
3. 熄屏后 VITS Worker 被暂停，PCM 队列耗尽；
4. 朗读逻辑绑定页面生命周期，`onPageHide()` 主动释放；
5. 每句话之间停止并重启 AudioRenderer；
6. PCM 预缓存太少，熄屏降频后生成追不上播放；
7. AudioRenderer 的 `usage/content` 配置不适合媒体朗读。

**优先补齐 `KEEP_BACKGROUND_RUNNING + audioPlayback + startBackgroundRunning()`，同时保证 AVSession 激活、AudioRenderer 全程不停止，并把 VITS/PCM 队列从页面生命周期中移到应用级服务。**这通常就是熄屏继续朗读所缺的关键部分。

[1]: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-background-scene?utm_source=chatgpt.com "后台播放-本地媒体会话-AVSession Kit（音视频播控服务）"
[2]: https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/continuous-task?utm_source=chatgpt.com "长时任务(ArkTS)"
[3]: https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-playing-pcm-audio-based-audiorenderer?utm_source=chatgpt.com "基于AudioRender播放PCM音频-音频播放系列开发实践"
[4]: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/using-avsession-developer?utm_source=chatgpt.com "华为HarmonyOS开发者- 媒体会话提供方(ArkTS)"


**Debug 版本也可以使用 `ohos.permission.KEEP_BACKGROUND_RUNNING`，不要求必须是 Release 包。**

它属于面向普通应用开放的 `system_grant` 权限。应用在 `module.json5` 中声明后，由系统在安装时授予，不需要像用户授权权限那样弹窗申请；`backgroundTaskManager.startBackgroundRunning()` 在 Debug HAP 中同样可以调用。([华为开发者][1])

配置示例：

```json
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING"
      }
    ],
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "backgroundModes": [
          "audioPlayback"
        ]
      }
    ]
  }
}
```

但有几个容易造成“Debug 版好像申请不了”的问题。

## 1. 修改 `module.json5` 后需要重新安装

权限和 `backgroundModes` 是安装时读取的。只做热重载或增量部署，配置不一定完全刷新。

建议：

```text
卸载旧应用
→ Clean Project
→ 重新编译 Debug HAP
→ 重新安装
```

至少需要停止应用后完整重新安装一次。

## 2. `backgroundModes` 必须配置在对应 Ability

调用：

```ts
backgroundTaskManager.startBackgroundRunning(
  context,
  backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
  wantAgent
);
```

所使用的 `context` 对应哪个 `UIAbility`，哪个 Ability 就必须声明：

```json
"backgroundModes": [
  "audioPlayback"
]
```

仅仅声明权限、不声明后台模式，仍然会调用失败。

## 3. 必须使用 `UIAbilityContext`

建议从 `EntryAbility` 或页面的 UIContext 获取：

```ts
import { common } from '@kit.AbilityKit';

const context =
  getContext(this) as common.UIAbilityContext;
```

不要传普通 `Context`、Worker 上下文或已经失效的页面上下文。

## 4. Debug 模式可能因调试器表现不同

连接 DevEco 调试器时，系统对进程调度、日志和生命周期的表现可能与脱离调试器运行不同。因此后台播放至少测试两次：

```text
Debug HAP + 连接调试器
Debug HAP + 断开调试器后独立运行
```

如果第二种能熄屏播放，说明不是权限问题，而可能是调试会话、断点或大量日志影响了 Worker/AudioRenderer。

## 5. 检查调用错误码

不要吞掉 `startBackgroundRunning()` 的异常：

```ts
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';

try {
  await backgroundTaskManager.startBackgroundRunning(
    context,
    backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
    wantAgent
  );

  console.info('[TTS] startBackgroundRunning success');
} catch (error) {
  const err = error as BusinessError;
  console.error(
    `[TTS] startBackgroundRunning failed: ` +
    `code=${err.code}, message=${err.message}`
  );
}
```

官方接口明确要求 `KEEP_BACKGROUND_RUNNING` 权限。([华为开发者][2])

## 6. 开始长时任务不等于一定能持续播放

Debug 版本即使成功调用，也仍要满足音频播放的实际条件：

* `AVSession` 已激活；
* `AudioRenderer` 处于运行状态；
* `AudioRenderer` 使用媒体或有声读物 usage；
* PCM 持续供给，而不是长时间没有数据；
* 没有在 `onBackground()` 或 `onPageHide()` 中停止 Worker；
* 没有每播放一句就调用 `AudioRenderer.stop()`；
* 长时任务没有被提前停止。

建议输出状态日志：

```ts
console.info('[TTS] background task started');
console.info(`[TTS] renderer state=${audioRenderer.state}`);
console.info(`[TTS] avSession active=${sessionActive}`);
```

## 结论

`KEEP_BACKGROUND_RUNNING`：

* **Debug HAP：可以使用**
* **Release HAP：可以使用**
* 不需要运行时弹窗授权
* 必须在 `module.json5` 声明
* 必须配置对应的 `backgroundModes`
* 修改配置后最好卸载重装
* 调用失败时重点查看 `BusinessError.code`

所以你可以直接用 Debug 版本调试熄屏朗读，不必先生成 Release 包。

[1]: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/permissions-for-all?utm_source=chatgpt.com "应用权限管控-程序访问控制-安全-系统- 华为HarmonyOS ..."
[2]: https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-backgroundtaskmanager?utm_source=chatgpt.com "ohos.backgroundTaskManager (Background Task Management)"
