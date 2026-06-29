/**
 * AI 配置页面 — LLM API 设置（增强版）
 * - 常用 API 预设一键切换
 * - 获取模型列表 + 选择
 * - 连通性测试
 */
import { SettingsStore } from '../data/preferences/SettingsStore';
import { NetUtil } from '../util/NetUtil';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

interface PresetItem { name: string; label: string; endpoint: string; }

/** 常用 API 预设 */
const PRESETS: PresetItem[] = [
  { name: 'openai',     label: 'OpenAI',        endpoint: 'https://api.openai.com/v1/chat/completions' },
  { name: 'deepseek',   label: 'DeepSeek',      endpoint: 'https://api.deepseek.com/v1/chat/completions' },
  { name: 'openrouter', label: 'OpenRouter',    endpoint: 'https://openrouter.ai/api/v1/chat/completions' },
  { name: 'silicon',    label: '硅基流动',       endpoint: 'https://api.siliconflow.cn/v1/chat/completions' },
  { name: 'ollama',     label: 'Ollama',        endpoint: 'http://localhost:11434/v1/chat/completions' },
  { name: 'custom',     label: '自定义',          endpoint: '' },
];

@Entry
@Component
struct AiConfigPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State endpoint: string = 'https://api.openai.com/v1/chat/completions';
  @State apiKey: string = '';
  @State model: string = 'gpt-4o';
  @State showKey: boolean = false;
  @State activePreset: string = 'openai';
  @State models: string[] = [];
  @State isFetchingModels: boolean = false;
  @State showModelPicker: boolean = false;
  @State isTesting: boolean = false;
  @State testResult: string = '';

  aboutToAppear(): void { this.load(); }

  async load(): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.init(getContext());
    this.endpoint = await s.getAiEndpoint();
    this.apiKey = await s.getAiApiKey();
    this.model = await s.getAiModel();
    this.detectPreset_();
  }

  detectPreset_(): void {
    for (let i = 0; i < PRESETS.length; i++) {
      if (PRESETS[i].endpoint && this.endpoint.startsWith(PRESETS[i].endpoint.replace('/chat/completions', ''))) {
        this.activePreset = PRESETS[i].name;
        return;
      }
    }
    this.activePreset = 'custom';
  }

  async save(): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.init(getContext());
    await s.setAiEndpoint(this.endpoint);
    await s.setAiApiKey(this.apiKey);
    await s.setAiModel(this.model);
    promptAction.showToast({ message: '已保存', duration: 1500 });
  }

  onPresetTap(p: PresetItem): void {
    this.activePreset = p.name;
    if (p.endpoint) { this.endpoint = p.endpoint; }
  }

  getBaseUrl_(): string {
    return this.endpoint.replace(/\/chat\/completions\/?$/, '');
  }

  async fetchModels(): Promise<void> {
    const base = this.getBaseUrl_();
    const url = base + '/models';
    this.isFetchingModels = true;
    this.models = [];
    try {
      const headers: Record<string, string> = this.apiKey ? { 'Authorization': 'Bearer ' + this.apiKey } : {};
      const resp = await NetUtil.httpGet(url, headers, 15000);
      const json = JSON.parse(resp) as Record<string, Object>;
      const data = json['data'] as Record<string, string>[];
      if (data && data.length > 0) {
        for (let i = 0; i < data.length; i++) {
          if (data[i]['id']) { this.models.push(data[i]['id']); }
        }
        this.models.sort();
        this.showModelPicker = true;
      }
    } catch (e) {
      promptAction.showToast({ message: '获取失败: ' + (e as Error).message?.substring(0, 30), duration: 2000 });
    }
    this.isFetchingModels = false;
  }

  async testConnection(): Promise<void> {
    if (!this.apiKey) { promptAction.showToast({ message: '请先填写 API Key', duration: 1500 }); return; }
    this.isTesting = true;
    this.testResult = '测试中...';
    try {
      const body = '{"model":"' + this.model + '","messages":[{"role":"user","content":"hi"}],"max_tokens":5}';
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + this.apiKey,
      };
      const resp = await NetUtil.httpPost(this.endpoint, body, headers, 20000);
      const json = JSON.parse(resp) as Record<string, Object>;
      if (json['choices']) {
        this.testResult = '✅ 连接成功';
        promptAction.showToast({ message: '连接成功', duration: 1500 });
      } else {
        this.testResult = '❌ 响应异常';
      }
    } catch (e) {
      this.testResult = '❌ ' + (e as Error).message?.substring(0, 60);
    }
    this.isTesting = false;
  }

  @Builder presetChip(p: PresetItem) {
    Text(p.label)
      .fontSize(12).padding({ top: 6, bottom: 6, left: 10, right: 10 })
      .fontColor(this.activePreset === p.name ? '#FFF' : (this.isDark ? '#CCC' : '#555'))
      .backgroundColor(this.activePreset === p.name ? '#0078D7' : (this.isDark ? '#333' : '#E8E8E8'))
      .borderRadius(14).margin({ right: 6, bottom: 6 })
      .onClick(() => { this.onPresetTap(p); })
  }

  @Builder modelItem(m: string) {
    Row() {
      Text(m).fontSize(13).fontColor(this.isDark ? '#CCC' : '#333').layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.model === m) { Text('✓').fontSize(13).fontColor('#0078D7').margin({ left: 8 }) }
    }.padding({ left: 8, right: 8, top: 8, bottom: 8 }).width('100%')
    .backgroundColor(this.model === m ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
    .borderRadius(6)
    .onClick(() => { this.model = m; this.showModelPicker = false; })
  }

  build() {
    Column() {
      Row() {
        Button('←').fontSize(18).fontColor(this.isDark ? '#CCC' : '#666').width(36).height(36)
          .backgroundColor('transparent').onClick(() => { router.back(); })
        Text('AI 配置').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('保存').fontSize(13).fontColor('#FFF').backgroundColor('#0078D7')
          .height(32).padding({ left: 14, right: 14 }).borderRadius(16)
          .onClick(() => { this.save(); })
      }.padding({ left: 12, right: 12, top: 44 }).width('100%')

      Scroll() {
        Column() {
          // ===== 常用 API 预设 =====
          Text('常用 API').fontSize(13).fontColor('#888').alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 6 })
          Row() {
            ForEach(PRESETS, (p: PresetItem) => { this.presetChip(p); })
          }.width('100%')

          // ===== API 地址 =====
          Text('API 地址').fontSize(13).fontColor('#888').alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          TextInput({ text: this.endpoint, placeholder: 'https://api.openai.com/v1/chat/completions' })
            .fontSize(14).width('100%')
            .onChange((v: string) => { this.endpoint = v; this.detectPreset_(); })

          // ===== API Key =====
          Text('API Key').fontSize(13).fontColor('#888').alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          Row() {
            TextInput({ text: this.apiKey, placeholder: 'sk-...' })
              .fontSize(14).layoutWeight(1).type(this.showKey ? InputType.Normal : InputType.Password)
              .onChange((v: string) => { this.apiKey = v; })
            Button(this.showKey ? '🙈' : '👁').fontSize(14)
              .backgroundColor('transparent').width(36).height(36)
              .onClick(() => { this.showKey = !this.showKey; })
          }.width('100%')

          // ===== 模型 =====
          Text('模型').fontSize(13).fontColor('#888').alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          Row() {
            TextInput({ text: this.model, placeholder: 'gpt-4o' })
              .fontSize(14).layoutWeight(1)
              .onChange((v: string) => { this.model = v; })
            Button(this.isFetchingModels ? '⏳' : '📋').fontSize(14)
              .backgroundColor('transparent').width(36).height(36)
              .onClick(() => { this.fetchModels(); })
          }.width('100%')

          if (this.showModelPicker && this.models.length > 0) {
            Text('选择模型 (' + this.models.length + ' 个)').fontSize(12).fontColor('#888')
              .padding({ top: 8, bottom: 4 }).alignSelf(ItemAlign.Start)
            List() {
              ForEach(this.models, (m: string) => {
                ListItem() { this.modelItem(m); }
              })
            }
            .height(Math.min(this.models.length * 36, 180)).width('100%')
            .backgroundColor(this.isDark ? '#1A1A1A' : '#F8F8F8').borderRadius(8)
          }

          // ===== 测试连通性 =====
          Button(this.isTesting ? '测试中...' : '🧪 测试连通性').fontSize(14)
            .fontColor(this.isDark ? '#CCC' : '#333')
            .backgroundColor(this.isDark ? '#333' : '#E8E8E8')
            .width('100%').height(40).borderRadius(20).margin({ top: 20 })
            .onClick(() => { this.testConnection(); })

          if (this.testResult) {
            Text(this.testResult).fontSize(12)
              .fontColor(this.testResult.startsWith('✅') ? '#28A745' : '#FF4444')
              .margin({ top: 8 }).alignSelf(ItemAlign.Start)
          }
        }
        .padding({ left: 16, right: 16 }).width('100%')
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
