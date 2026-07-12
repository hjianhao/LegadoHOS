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
