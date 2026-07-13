# TTS 朗读模块设计

> 离线神经 TTS（sherpa-onnx + Kokoro）集成方案设计文档。
> 参考资料见 `doc/ref/tts.md`。
> 更新日期：2026-07-12

---

## 1. 背景与目标

### 1.1 现状

当前 LegadoHOS 已有一套基于鸿蒙系统 TTS 的朗读引擎：

| 文件 | 职责 |
|------|------|
| `service/ReadAloudEngine.ets` | 核心引擎：分句队列 + 双缓冲 PCM 播放 + 跨章节续读 |
| `components/reader/ReadAloudPanel.ets` | 朗读控制面板 UI（引擎/音色/语速/播放控制） |
| `pages/ReadPage.ets` | ReadPage 集成：章节提供器 + 位置同步 |
| `data/preferences/SettingsStore.ts` | TTS 偏好持久化（音色/语速） |
| `engine/audio/TTSPlayer.ts` | 旧版 TTS 播放器（已废弃，未使用） |
| `service/ReadAloudService.ts` | 旧版朗读服务（已废弃，未使用） |
| `components/reader/TtsControlPanel.ets` | 旧版控制面板（已废弃，未使用） |

系统 TTS 的局限性：

- 音色数量受设备和系统版本限制，用户无法自由导入模型；
- 朗读自然度上限受系统实现限制；
- 是否完全离线不可控。

### 1.2 目标

引入 **sherpa-onnx + Kokoro** 多音色离线神经 TTS，作为系统 TTS 的高品质替代：

```
双引擎架构
├── 系统 TTS（兜底）
│   └─ 低功耗、无需下载、设备内置
└── 离线神经 TTS（sherpa-onnx + Kokoro）
    └─ 更自然、多音色、用户自行下载模型
```

### 1.3 技术选型依据

| 方案 | 自然度 | 音色 | 完全离线 | 鸿蒙适配 | 成本 |
|------|--------|------|----------|----------|------|
| 系统 TTS | 中 | 少~中 | 不完全可控 | 最好 | 低 |
| Kokoro + sherpa-onnx | 高 | 很多（103） | 是 | 已有官方 HAR + 示例 | 开源 |
| VITS/MeloTTS + sherpa | 中 | 少~中 | 是 | 已支持 | 开源 |
| 讯飞 XTTS | 高 | 取决于授权 | 是 | 需商务确认 | 商业 |

**首选：系统 TTS 继续兜底，应用内增加 sherpa-onnx + Kokoro。**

sherpa-onnx 已正式支持 HarmonyOS：
- OHPM 包 `sherpa_onnx`（最新版 1.13.3+），提供 ArkTS API + native NAPI 推理；
- 官方鸿蒙 TTS 示例工程 `harmony-os/SherpaOnnxTts`；
- 异步合成 `generateAsync()`，进度回调，完全离线运行；
- Apache-2.0 许可证，开源可商用。

---

## 2. sherpa-onnx ArkTS API 摘要

### 2.1 核心类

```typescript
import { OfflineTts, OfflineTtsConfig, OfflineTtsKokoroModelConfig,
         TtsInput, TtsOutput } from 'sherpa_onnx';

// 配置
const config = new OfflineTtsConfig();
config.model.kokoro.model    = '/path/to/model.onnx';
config.model.kokoro.voices   = '/path/to/voices.bin';
config.model.kokoro.tokens   = '/path/to/tokens.txt';
config.model.kokoro.dataDir  = '/path/to/espeak-ng-data';
config.model.kokoro.lexicon  = '/path/to/lexicon-us-en.txt,/path/to/lexicon-zh.txt';
config.model.numThreads      = 2;
config.ruleFsts              = '/path/to/date-zh.fst,/path/to/phone-zh.fst,/path/to/number-zh.fst';
config.maxNumSentences       = 1;
config.silenceScale          = 0.2;

// 创建引擎（第二个参数可选 ResourceManager，传入则从 rawfile 加载）
const tts = new OfflineTts(config);
// tts.sampleRate  -> 24000 (Kokoro 固定)
// tts.numSpeakers -> 103

// 异步合成
const input = new TtsInput();
input.text   = '你好世界';
input.sid    = 50;    // speaker ID
input.speed  = 1.0;
input.callback = (data) => 1;  // 返回 0=取消, 1=继续

const output: TtsOutput = await tts.generateAsync(input);
// output.samples    -> Float32Array ([-1.0, 1.0])
// output.sampleRate -> 24000
```

### 2.2 关键类型

| 类型 | 说明 |
|------|------|
| `OfflineTtsConfig` | 顶层配置（model + ruleFsts + maxNumSentences + silenceScale） |
| `OfflineTtsKokoroModelConfig` | Kokoro 模型配置（model/voices/tokens/dataDir/lexicon/lengthScale） |
| `TtsInput` | 合成输入（text/sid/speed/callback） |
| `TtsOutput` | 合成输出（samples: Float32Array, sampleRate: number） |

### 2.3 与系统 TTS 的差异

| 维度 | 系统 TTS（CoreSpeechKit） | sherpa-onnx + Kokoro |
|------|--------------------------|---------------------|
| 采样率 | 16000 Hz | **24000 Hz**（固定） |
| PCM 格式 | S16LE Int16 | **Float32**（需转 Int16） |
| 合成方式 | `speak()` 回调 `onData` 流式 | `generateAsync()` 一次性返回整句 |
| 音色选择 | `person` int + `style` string | **`sid` int**（0-102） |
| 模型管理 | 系统内置/系统下载 | **需应用自行下载管理** |
| 线程 | 系统调度 | NAPI AsyncWorker（`generateAsync` 内部异步） |

---

## 3. Kokoro 模型规格

### 3.1 模型选型

| 模型 | 压缩后 | 解压后 | Speaker 数 | 说明 |
|------|--------|--------|-----------|------|
| `kokoro-int8-multi-lang-v1_1` | ~180 MB | ~215 MB | 103 | **推荐**（int8 量化，体积小） |
| `kokoro-multi-lang-v1_0` | ~280 MB | ~345 MB | 53 | 旧版，53 speakers |
| `kokoro-multi-lang-v1_1` | ~330 MB | ~400 MB | 103 | 全精度，体积大 |

### 3.2 模型文件结构

```
kokoro-int8-multi-lang-v1_1/
├── model.int8.onnx     ~114 MB   主模型
├── voices.bin          ~53.8 MB  103 个 speaker embedding
├── tokens.txt                    分词表
├── lexicon-zh.txt      ~2.1 MB   中文词典
├── lexicon-us-en.txt   ~5.6 MB   美式英文词典
├── lexicon-gb-en.txt   ~6.0 MB   英式英文词典
├── date-zh.fst                   日期规范化规则
├── number-zh.fst                 数字规范化规则
├── phone-zh.fst                  电话号码规则
├── dict/                         词典目录
└── espeak-ng-data/               音素数据目录（122 个文件）
```

### 3.3 筛选音色

v1_1 的 103 个 speaker 中，适合中文的 speaker ID 为 45-52（v1_0 编号）。本项目从中筛选 8 个作为预设音色：

| sid | 名称 | 性别 |
|-----|------|------|
| 45 | 温和女声·小贝 | 女 |
| 46 | 亲切女声·小妮 | 女 |
| 47 | 甜美女声·小晓 | 女 |
| 48 | 活力女声·小艺 | 女 |
| 49 | 沉稳男声·云健 | 男 |
| 50 | 青年男声·云希 | 男（默认） |
| 51 | 阳光男声·云夏 | 男 |
| 52 | 磁性男声·云阳 | 男 |

> 注意：v1_1 的 speaker 编号可能与 v1_0 不同，集成时需实际测试确认。

### 3.4 音色拆包

不建议按单个音色拆包。全部音色集中在同一个 `voices.bin`（~53.8 MB），即使只展示 8 个音色仍需完整文件。拆分 speaker embedding 需要确认 sherpa-onnx 对文件结构的要求，且后续升级容易失配，第一版不做。

---

## 4. 库导入方式

`sherpa_onnx` 库有两种导入方式，详见 `doc/ref/tts.md` "sherpa_onnx 库的两种导入方式" 章节。

### 4.1 方式一：OHPM 安装预编译 HAR

```json5
// entry/oh-package.json5
{
  "dependencies": {
    "sherpa_onnx": "^1.13.3"
  }
}
```

- 零编译复杂度，`ohpm install` 即用；
- 包含全功能（TTS + ASR + VAD + 说话人分离）+ 双 ABI（arm64-v8a + x86_64）；
- 无法裁剪、无法定制。

### 4.2 方式二：源码编译自定义 HAR

```bash
git clone https://github.com/k2-fsa/sherpa-onnx
cd sherpa-onnx
export OHOS_SDK_NATIVE_DIR=/path/to/sdk/native
export SHERPA_ONNX_ENABLE_TTS=ON
export SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF
./build-ohos-arm64-v8a.sh
cd harmony-os/SherpaOnnxHar/
hvigorw --mode module -p module=sherpa_onnx@default assembleHar --no-daemon
```

```json5
// entry/oh-package.json5
{
  "dependencies": {
    "sherpa_onnx": "file:./libs/sherpa_onnx.har"
  }
}
```

- 可裁剪不需要的功能（关闭 ASR/VAD/说话人分离）；
- 可只保留 arm64-v8a，去掉 x86_64；
- 需要鸿蒙 commandline-tools + CMake 编译。

### 4.3 对本项目的策略

```
Phase 1（开发验证）→ 方式一：OHPM 安装，快速跑通端到端
Phase 2（正式发布前）→ 方式二：源码编译裁剪版，减小 .so 体积
```

体积对比：

```
方式一 OHPM 包：
  libsherpa-onnx-c-api.so (arm64)  ← TTS + ASR + VAD + 说话人分离 + ...
  libsherpa-onnx-c-api.so (x86_64) ← 同上，真机完全不用
  libonnxruntime.so (arm64)
  libonnxruntime.so (x86_64)       ← 真机完全不用

方式二 自编译（裁剪后）：
  libsherpa-onnx-c-api.so (arm64)  ← 只保留 TTS
  libonnxruntime.so (arm64)
  （无 x86_64）
```

---

## 5. 模型分发策略

### 5.1 模型不入 HAP

215 MB 的模型不内置到安装包。HAP 只携带 `sherpa_onnx` 引擎 + TTS 管理代码，用户首次选择"自然语音"时按需下载。

### 5.2 沙箱目录结构

```
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

`manifest.json` 描述模型元信息：

```json
{
  "id": "kokoro-int8-multi-lang-v1_1",
  "name": "自然语音",
  "engine": "kokoro",
  "version": 1,
  "languages": ["zh-CN", "en-US"],
  "speakers": 103,
  "sampleRate": 24000,
  "size": 215000000,
  "sha256": "...",
  "minAppVersion": "1.5.0"
}
```

### 5.3 下载流程

```
用户选择"自然语音"
    ↓
检查沙箱是否已有模型（manifest.json + 文件校验）
    ↓ 无
下载 .tar.bz2 到 context.cacheDir/tts-download/
    ↓
校验 SHA-256
    ↓
解压到 context.filesDir/tts/.installing/
    ↓
原子重命名为 kokoro-int8-multi-lang-v1_1/
    ↓
删除临时压缩包
    ↓
写入 manifest.json
```

临时压缩包放 `context.cacheDir/tts-download/`，解压成功并校验后删除，避免同时占用两份空间。

### 5.4 模型更新

```
filesDir/tts/
├── kokoro-int8-multi-lang-v1_1/
│   ├── 1.0.0/
│   │   └── 模型文件
│   └── current.json    ← 指向当前激活版本
└── model-registry.json ← 已安装模型注册表
```

下载更新时先放到 `.installing/` 临时目录，校验完成后原子切换，避免下载中断导致原模型损坏。

---

## 6. 架构设计

### 6.1 整体架构

```
┌──────────────────────────────────────────────────┐
│              ReadAloudPanel (UI)                  │
│    引擎切换 │ 音色选择 │ 调速 │ 播放控制          │
├──────────────────────────────────────────────────┤
│           ReadAloudEngine (调度层)                │
│  ┌──────────────────────────────────────┐        │
│  │  分句队列 + 双缓冲 + 跨章节续读       │        │
│  │  (splitText_, pendingQueue_, etc.)   │        │
│  └──────────────┬───────────────────────┘        │
│                 │ ITtsBackend 接口                 │
│        ┌────────┴────────┐                        │
│        ▼                 ▼                        │
│  ┌──────────┐     ┌──────────────┐               │
│  │ SystemTts │     │ SherpaOnnxTts│               │
│  │ Backend   │     │ Backend      │               │
│  │ (现有)    │     │ (新增)       │               │
│  └──────────┘     └──────┬───────┘               │
│                           │                       │
│                   NAPI AsyncWorker                 │
│                   OfflineTts.generateAsync         │
├───────────────────────────────────────────────────┤
│              AudioRenderer                         │
│         (PCM writeData 驱动播放)                   │
└──────────────────────────────────────────────────┘
```

### 6.2 核心设计：后端接口抽象

新增 `ITtsBackend` 接口，将合成能力与调度逻辑解耦。现有系统 TTS 和新增 sherpa-onnx 各实现一个后端，`ReadAloudEngine` 通过接口调度，不关心具体合成方式。

```typescript
// service/tts/ITtsBackend.ets
export interface TtsBackendConfig {
  sampleRate: number;
  channels: number;  // 1 = mono
}

export interface TtsSynthRequest {
  text: string;
  speed: number;
  speakerId?: number;  // sherpa-onnx 用，系统 TTS 忽略
}

export interface TtsSynthResult {
  pcm: ArrayBuffer;    // Int16 PCM, ready for AudioRenderer
  sampleRate: number;
}

export interface TtsVoiceInfo {
  id: string;
  name: string;
  gender: string;
  language: string;
  description: string;
  downloaded: boolean;
  engine: 'system' | 'sherpa-onnx';
}

export interface ITtsBackend {
  readonly name: string;           // 'system' | 'sherpa-onnx'
  readonly sampleRate: number;     // 16000 | 24000
  readonly ready: boolean;

  init(): Promise<void>;
  synthesize(req: TtsSynthRequest): Promise<TtsSynthResult>;
  listVoices(): Promise<TtsVoiceInfo[]>;
  setVoice(voiceId: string): void;
  release(): Promise<void>;
}
```

### 6.3 与现有代码的兼容性

现有 `ReadAloudEngine` 核心架构：

```
textToSpeech.speak() → onData(ArrayBuffer PCM) → chunkPcm_ 拼接
  → pendingQueue_ → AudioRenderer writeData 播放
```

sherpa-onnx 输出路径：

```
OfflineTts.generateAsync() → TtsOutput.samples(Float32Array)
  → 转 Int16 PCM → pendingQueue_ → AudioRenderer writeData 播放
```

**关键契合点**：两者都输出原始 PCM，都通过 AudioRenderer writeData 驱动播放。现有的分句队列、双缓冲、跨章节续读逻辑可完全复用，只需替换"合成"环节。

### 6.4 ReadAloudEngine 改造要点

| 改动点 | 说明 |
|--------|------|
| 新增 `backend_` 字段 | 持有 `ITtsBackend` 实例 |
| `setBackend(backend)` | 切换引擎时释放旧后端 + 重建 AudioRenderer（采样率不同） |
| `speakNext_()` | 从 `ttsEngine_.speak()` + 回调改为 `await backend.synthesize()` |
| `recreateAudioRenderer_()` | 根据后端 sampleRate 动态选择 16000 或 24000 |
| 移除 `chunkPcm_` | `synthesize` 返回完整 PCM，不需要拼接 onData 小块 |

AudioRenderer 采样率映射：

```typescript
private sampleRateToEnum_(rate: number): audio.AudioSamplingRate {
  switch (rate) {
    case 16000: return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    case 24000: return audio.AudioSamplingRate.SAMPLE_RATE_24000;
    default:    return audio.AudioSamplingRate.SAMPLE_RATE_24000;
  }
}
```

### 6.5 SherpaOnnxTtsBackend 实现

```typescript
// service/tts/SherpaOnnxTtsBackend.ets
export class SherpaOnnxTtsBackend implements ITtsBackend {
  readonly name = 'sherpa-onnx';
  private tts_: OfflineTts | null = null;
  private context_: common.UIAbilityContext;
  private modelPath_: string;
  private currentSid_: number = 50;

  get sampleRate(): number { return this.tts_?.sampleRate ?? 24000; }
  get ready(): boolean { return this.tts_ !== null; }

  async init(): Promise<void> {
    if (!await this.isModelReady_()) {
      throw new Error('模型未下载');
    }
    const config = new OfflineTtsConfig();
    config.model.kokoro.model   = `${this.modelPath_}/model.int8.onnx`;
    config.model.kokoro.voices  = `${this.modelPath_}/voices.bin`;
    config.model.kokoro.tokens  = `${this.modelPath_}/tokens.txt`;
    config.model.kokoro.dataDir = `${this.modelPath_}/espeak-ng-data`;
    config.model.kokoro.lexicon =
      `${this.modelPath_}/lexicon-us-en.txt,${this.modelPath_}/lexicon-zh.txt`;
    config.model.numThreads = 2;
    config.ruleFsts =
      `${this.modelPath_}/date-zh.fst,${this.modelPath_}/phone-zh.fst,${this.modelPath_}/number-zh.fst`;
    config.maxNumSentences = 1;
    config.silenceScale = 0.2;
    this.tts_ = new OfflineTts(config);
  }

  async synthesize(req: TtsSynthRequest): Promise<TtsSynthResult> {
    const input = new TtsInput();
    input.text = req.text;
    input.sid = req.speakerId ?? this.currentSid_;
    input.speed = req.speed;
    input.callback = () => 1;
    const output = await this.tts_!.generateAsync(input);
    return { pcm: this.float32ToInt16_(output.samples), sampleRate: output.sampleRate };
  }

  /** Float32 [-1.0, 1.0] → Int16 PCM */
  private float32ToInt16_(samples: Float32Array): ArrayBuffer {
    const buf = new ArrayBuffer(samples.length * 2);
    const view = new DataView(buf);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
    return buf;
  }
}
```

---

## 7. 阅读器场景增强

模型本身只解决"发声"，小说朗读体验还需以下处理。

### 7.1 分句策略

当前 `splitText_` 按固定 300 字切分 + 句号回溯。需要改为更精细的分句：

```
章节 → 段落 → 句号/问号/感叹号 → 分号 → 逗号 → 最长字数保护
```

每段控制 20-80 个汉字。太短导致语气断裂，太长则首句等待明显、取消不灵敏。

### 7.2 预合成队列

当前 `pendingQueue_` 已支持预合成。优化点：

- 队列深度限制 3-4 句，避免内存过大；
- 用户跳转/切章时清空队列，取消进行中的合成。

```
当前播放：第 N 句
后台合成：第 N+1、N+2 句
缓存待播：最多 2-4 句
```

### 7.3 文本规范化

新增 `TextNormalizer`，处理中文小说常见模式：

| 原文 | 规范化 |
|------|--------|
| `2026-07-11` | `2026年7月11日` |
| `3.14` | `三点一四` |
| `80%` | `百分之八十` |
| `第12章` | `第十二章` |
| `1.5 GB` | `一点五吉字节` |
| `CPU` | `C P U` |
| `——` | `，` |
| `……` | `。` |

### 7.4 对话语气

根据引号自动添加轻微停顿，不切换 speaker：

```
他说："你终于来了。"
→ 他说，<短停顿> 你终于来了。<中停顿>
```

不默认根据角色切换不同 speaker，多 speaker 切换会破坏声音一致性、增加状态切换开销、对角色识别错误敏感。后续可把"多人有声书模式"作为实验功能。

### 7.5 音频缓存（可选）

```
cacheKey = modelId + sid + speed + hash(normalizedText)
```

缓存当前章节 + 下一章节的 PCM，避免重复合成。内存中保持 PCM Float32 或 PCM16，长期缓存可转 Opus/AAC。阅读器通常不需要缓存整本书。

---

## 8. UI 设计

### 8.1 引擎选择界面

```
┌─────────────────────────────────────┐
│  朗读设置                            │
├─────────────────────────────────────┤
│  引擎                                │
│  ● 系统语音（无需下载）               │
│  ○ 自然语音（离线·高品质）  [下载模型] │
├─────────────────────────────────────┤
│  音色选择                            │
│  ○ 沉稳男声·云健                     │
│  ● 青年男声·云希                     │
│  ○ 甜美女声·小晓                     │
│  ...                                 │
├─────────────────────────────────────┤
│  语速 ━━━━━●━━━━ 1.0x               │
│  ⏮ ⏯ ⏭   第3章/第10章               │
└─────────────────────────────────────┘
```

### 8.2 模型下载状态

```
未下载：
  自然语音（离线·高品质）  [下载模型]
  下载大小：约 180-220 MB

下载中：
  自然语音  ████░░░░░░  45%
  [取消]

已就绪：
  ● 自然语音（离线·高品质）  ✓ 已就绪
```

---

## 9. 文件清单

### 9.1 新增文件

| 文件 | 职责 |
|------|------|
| `service/tts/ITtsBackend.ets` | TTS 后端接口定义 |
| `service/tts/SherpaOnnxTtsBackend.ets` | sherpa-onnx 后端实现 |
| `service/tts/SystemTtsBackend.ets` | 现有系统 TTS 封装为后端 |
| `service/tts/TtsModelManager.ets` | 模型下载/校验/解压/管理 |
| `service/tts/TextNormalizer.ets` | 中文文本规范化 |

### 9.2 修改文件

| 文件 | 改动 |
|------|------|
| `service/ReadAloudEngine.ets` | 引入 `ITtsBackend`，`speakNext_` 改为 `backend.synthesize`，动态采样率 |
| `components/reader/ReadAloudPanel.ets` | 新增引擎切换、模型下载、离线音色列表 |
| `data/preferences/SettingsStore.ts` | 新增 `tts_engine`、`tts_sherpa_sid` 等偏好 |
| `entry/oh-package.json5` | 添加 `sherpa_onnx` 依赖 |

### 9.3 废弃文件（可清理）

| 文件 | 说明 |
|------|------|
| `engine/audio/TTSPlayer.ts` | 旧版 TTS 播放器，已被 ReadAloudEngine 取代 |
| `service/ReadAloudService.ts` | 旧版朗读服务，从未被实例化 |
| `components/reader/TtsControlPanel.ets` | 旧版控制面板，零引用 |
| `service/ReadAloudEngine.ets.bak` | 旧版引擎备份 |

---

## 10. 实施计划

### Phase 1：MVP（约 3-5 天）

目标：在一个 Kokoro 音色下完成离线朗读，与系统 TTS 可切换。

| 步骤 | 内容 | 预估 |
|------|------|------|
| 1 | `ohpm install sherpa_onnx`（方式一） | 0.5h |
| 2 | 定义 `ITtsBackend` 接口 | 0.5h |
| 3 | 实现 `SherpaOnnxTtsBackend`（init + synthesize + float32→int16） | 1d |
| 4 | `ReadAloudEngine` 双引擎改造（`setBackend` + 动态采样率 + `speakNext_` 改 async） | 1d |
| 5 | `TtsModelManager`（下载 + 校验 + 解压） | 1d |
| 6 | `ReadAloudPanel` UI 适配（引擎切换 + 下载入口 + 离线音色列表） | 0.5d |

验证标准：
- 手动放置模型到沙箱后，能完成一章节的离线朗读；
- 引擎切换不崩溃，采样率正确切换；
- 暂停/恢复/跳句/调速正常工作。

### Phase 2：体验优化（约 2-3 天）

| 步骤 | 内容 | 预估 |
|------|------|------|
| 1 | `TextNormalizer` 文本规范化 | 0.5d |
| 2 | 预合成队列深度限制 + 跳转时取消 | 0.5d |
| 3 | 音频缓存（当前章节 + 下一章节） | 1d |
| 4 | 真机性能调优（numThreads、首句延迟） | 1d |

### Phase 3：发布优化（约 1-2 天）

| 步骤 | 内容 | 预估 |
|------|------|------|
| 1 | 方式二：源码编译裁剪版 HAR | 1d |
| 2 | 只保留 arm64-v8a，关闭 ASR/VAD/说话人分离 | 0.5d |
| 3 | 替换 oh-package.json5 为本地 HAR 引用 | 0.5d |

### Phase 4：扩展（可选，不阻塞发布）

| 功能 | 说明 |
|------|------|
| VITS/MeloTTS 轻量引擎 | 作为"省电模式"，模型更小（~50MB） |
| 多人有声书模式 | 对话检测 + 多 sid 切换（实验功能） |
| 模型管理页 | 多模型安装/卸载/切换 |

---

## 11. 技术风险与对策

| 风险 | 等级 | 对策 |
|------|------|------|
| `.tar.bz2` 解压鸿蒙无原生 API | 中 | 方案 A: 服务端预解压为单文件列表逐个下载；方案 B: NAPI 集成 libarchive |
| int8 模型推理速度 | 中 | `numThreads=2`，首次合成预热；低端设备降级到系统 TTS |
| 模型体积大（~180-215MB） | 中 | 用户主动下载，不内置 HAP；支持下载中断续传 |
| 首句延迟（500ms-2s） | 低 | 预合成 2 句 + 播放时静默填充 |
| `espeak-ng-data` 目录加载 | 中 | 首次启动从 rawfile 拷贝到沙箱，后续直接用沙箱路径 |
| Worker 线程通信 | 低 | `generateAsync` 内部用 NAPI AsyncWorker，无需自建 Worker |
| v1_1 speaker 编号不确定 | 低 | 集成时实际测试确认，可能与 v1_0 编号不同 |

---

## 12. 配置项

### 12.1 SettingsStore 新增

| key | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `tts_engine` | string | `'system'` | 引擎选择：`'system'` \| `'sherpa-onnx'` |
| `tts_sherpa_sid` | number | `50` | sherpa-onnx speaker ID |
| `tts_sherpa_speed` | number | `1.0` | sherpa-onnx 语速（独立于系统 TTS） |
| `tts_model_downloaded` | boolean | `false` | 模型是否已下载到沙箱 |

### 12.2 现有配置（保留）

| key | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `tts_voice_language` | string | `'zh-CN'` | 系统 TTS 语言 |
| `tts_voice_person` | number | `13` | 系统 TTS 音色 ID |
| `tts_voice_style` | string | `'interaction-broadcast'` | 系统 TTS 风格 |
| `tts_speed` | number | `1.0` | 系统 TTS 语速 |
