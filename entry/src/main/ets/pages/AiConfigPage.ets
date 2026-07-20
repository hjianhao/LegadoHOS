/**
 * AI 配置页面 — LLM API 设置（增强版）
 * - 常用 API 预设一键切换
 * - 获取模型列表 + 选择
 * - 连通性测试
 */
import { AiProviderProfile, SettingsStore, upsertAiProfile } from '../data/preferences/SettingsStore';
import { NetUtil } from '../util/NetUtil';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { AppBackButton } from '../components/common/AppTitleBar';
import { WindowLayout } from '../util/WindowLayout';

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
export struct AiConfigPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State endpoint: string = 'https://api.openai.com/v1/chat/completions';
  @State apiKey: string = '';
  @State model: string = 'gpt-4o';
  @State timeoutSecondsText: string = '120';
  @State profileName: string = '默认配置';
  @State profiles: AiProviderProfile[] = [];
  @State activeProfileId: string = '';
  @State editingProfileId: string = '';
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
    await s.init(UiUtil.getHostContext(this.getUIContext()));
    this.profiles = await s.getAiProfiles();
    this.activeProfileId = await s.getActiveAiProfileId();
    let active = this.profiles.find((item: AiProviderProfile): boolean => item.id === this.activeProfileId);
    if (!active && this.profiles.length > 0) {
      active = this.profiles[0];
      await s.activateAiProfile(active);
      this.activeProfileId = active.id;
    }
    if (active) this.editProfile(active);
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
    const name = this.profileName.trim();
    const endpoint = this.endpoint.trim();
    const model = this.model.trim();
    const timeoutSeconds = Number(this.timeoutSecondsText.trim());
    if (!name || !endpoint || !model) {
      UiUtil.showToast(this.getUIContext(), { message: '请填写配置名称、API 地址和模型', duration: 1800 });
      return;
    }
    if (isNaN(timeoutSeconds) || timeoutSeconds <= 0) {
      UiUtil.showToast(this.getUIContext(), { message: '超时时间必须是大于 0 的秒数', duration: 1800 });
      return;
    }
    const s = SettingsStore.getInstance();
    await s.init(UiUtil.getHostContext(this.getUIContext()));
    const id = this.editingProfileId || ('ai_' + Date.now().toString());
    const profile: AiProviderProfile = {
      id: id,
      name: name,
      provider: this.activePreset,
      endpoint: endpoint,
      apiKey: this.apiKey.trim(),
      model: model,
      timeoutSeconds: Math.floor(timeoutSeconds),
    };
    this.profiles = upsertAiProfile(this.profiles, profile);
    await s.saveAiProfiles(this.profiles);
    await s.activateAiProfile(profile);
    this.activeProfileId = id;
    this.editingProfileId = id;
    UiUtil.showToast(this.getUIContext(), { message: '已保存并设为当前配置', duration: 1500 });
  }

  private editProfile(profile: AiProviderProfile): void {
    this.editingProfileId = profile.id;
    this.profileName = profile.name;
    this.endpoint = profile.endpoint;
    this.apiKey = profile.apiKey;
    this.model = profile.model;
    this.timeoutSecondsText = (profile.timeoutSeconds || 120).toString();
    this.activePreset = profile.provider || 'custom';
    this.models = [];
    this.showModelPicker = false;
    this.testResult = '';
    this.detectPreset_();
  }

  private async selectProfile(profile: AiProviderProfile): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.activateAiProfile(profile);
    this.activeProfileId = profile.id;
    this.editProfile(profile);
    UiUtil.showToast(this.getUIContext(), { message: '已切换到 ' + profile.name, duration: 1200 });
  }

  private createProfile(): void {
    this.editingProfileId = '';
    this.profileName = '新配置';
    this.endpoint = 'https://openrouter.ai/api/v1/chat/completions';
    this.apiKey = '';
    this.model = 'openrouter/free';
    this.timeoutSecondsText = '120';
    this.activePreset = 'openrouter';
    this.models = [];
    this.showModelPicker = false;
    this.testResult = '';
  }

  private deleteCurrentProfile(): void {
    if (!this.editingProfileId || this.profiles.length <= 1) return;
    const deletingId = this.editingProfileId;
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '删除 AI 配置', message: '确定删除“' + this.profileName + '”吗？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: ThemeColors.error(this.isDark), action: (): void => {
        void this.confirmDelete(deletingId);
      } }
    });
  }

  private async confirmDelete(id: string): Promise<void> {
    const next = this.profiles.filter((item: AiProviderProfile): boolean => item.id !== id);
    if (next.length === 0) return;
    const s = SettingsStore.getInstance();
    await s.saveAiProfiles(next);
    this.profiles = next;
    let active = next.find((item: AiProviderProfile): boolean => item.id === this.activeProfileId);
    if (!active || id === this.activeProfileId) active = next[0];
    await s.activateAiProfile(active);
    this.activeProfileId = active.id;
    this.editProfile(active);
    UiUtil.showToast(this.getUIContext(), { message: '配置已删除', duration: 1200 });
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
        const nextModels: string[] = [];
        for (let i = 0; i < data.length; i++) {
          if (data[i]['id']) { nextModels.push(data[i]['id']); }
        }
        this.models = nextModels.sort();
        this.showModelPicker = true;
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '获取失败: ' + (e as Error).message?.substring(0, 30), duration: 2000 });
    }
    this.isFetchingModels = false;
  }

  async testConnection(): Promise<void> {
    const keyOptional = this.activePreset === 'ollama' || this.endpoint.includes(':11434/');
    if (!this.apiKey && !keyOptional) {
      UiUtil.showToast(this.getUIContext(), { message: '请先填写 API Key', duration: 1500 });
      return;
    }
    this.isTesting = true;
    this.testResult = '测试中...';
    try {
      const body = '{"model":"' + this.model + '","messages":[{"role":"user","content":"hi"}],"max_tokens":5}';
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (this.apiKey) headers['Authorization'] = 'Bearer ' + this.apiKey;
      const configuredTimeout = Number(this.timeoutSecondsText.trim());
      const timeoutMs = (!isNaN(configuredTimeout) && configuredTimeout > 0 ? Math.floor(configuredTimeout) : 120) * 1000;
      const resp = await NetUtil.httpPost(this.endpoint, body, headers, timeoutMs);
      const json = JSON.parse(resp) as Record<string, Object>;
      if (json['choices']) {
        this.testResult = '连接成功';
        UiUtil.showToast(this.getUIContext(), { message: '连接成功', duration: 1500 });
      } else {
        this.testResult = '响应异常';
      }
    } catch (e) {
      this.testResult = (e as Error).message?.substring(0, 60) || '连接失败';
    }
    this.isTesting = false;
  }

  @Builder presetChip(p: PresetItem) {
    Text(p.label)
      .fontSize(12).padding({ top: 6, bottom: 6, left: 10, right: 10 })
      .fontColor(this.activePreset === p.name ? ThemeColors.onPrimary(this.isDark) : ThemeColors.secondaryText(this.isDark))
      .backgroundColor(this.activePreset === p.name ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark))
      .borderRadius(14).margin({ right: 6, bottom: 6 })
      .onClick(() => { this.onPresetTap(p); })
  }

  @Builder modelItem(m: string) {
    Row() {
      Text(m).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.model === m) { Text($r('app.string.ui_698a879938')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 }) }
    }.padding({ left: 8, right: 8, top: 8, bottom: 8 }).width('100%')
    .backgroundColor(this.model === m ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.transparent())
    .borderRadius(6)
    .onClick(() => { this.model = m; this.showModelPicker = false; })
  }

  @Builder profileCard(profile: AiProviderProfile) {
    Column() {
      Row() {
        Text(profile.name).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.activeProfileId === profile.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.activeProfileId === profile.id) {
          Text($r('app.string.ui_25e74dceac')).fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark)).margin({ left: 8 })
        }
      }.width('100%')
      Text(profile.model || '未设置模型').fontSize(11).margin({ top: 5 })
        .fontColor(this.activeProfileId === profile.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text('超时 ' + (profile.timeoutSeconds || 120) + ' 秒').fontSize(10).margin({ top: 3 })
        .fontColor(this.activeProfileId === profile.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .width('100%')
    }
    .width(168).padding(12).margin({ right: 8 })
    .backgroundColor(this.activeProfileId === profile.id ? ThemeColors.primary(this.isDark) : ThemeColors.surface(this.isDark))
    .borderRadius(10).border({ width: 1,
      color: this.editingProfileId === profile.id ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark) })
    .onClick((): void => { void this.selectProfile(profile); })
  }

  build() {
    Column() {
      Row() {
        AppBackButton({ onBack: () => { UiUtil.back(this.getUIContext()); } })
        Text($r('app.string.ui_dc95e4a9f8')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Button($r('app.string.ui_2cd9e6ce81')).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
          .height(40).padding({ left: 10, right: 10 }).onClick((): void => { this.createProfile(); })
        Button($r('app.string.common_save')).fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.primary(this.isDark))
          .height(40).padding({ left: 14, right: 14 }).borderRadius(16)
          .onClick(() => { this.save(); })
      }.height(56).padding({ left: 4, right: 12 }).width('100%')
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

      Scroll() {
        Column() {
          Text($r('app.string.ui_038f5a0fe2')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 12, bottom: 6 })
          Scroll() {
            Row() {
              ForEach(this.profiles, (profile: AiProviderProfile) => {
                this.profileCard(profile)
              }, (profile: AiProviderProfile): string => profile.id)
            }.padding({ bottom: 3 })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')

          Row() {
            Text(this.editingProfileId ? '编辑配置' : '新增配置').fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
            if (this.editingProfileId && this.profiles.length > 1) {
              Text($r('app.string.common_delete')).fontSize(12).fontColor(ThemeColors.error(this.isDark))
                .onClick((): void => { this.deleteCurrentProfile(); })
            }
          }.width('100%').margin({ top: 18, bottom: 6 })

          Text($r('app.string.ui_a5f08c1d33')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 6, bottom: 4 })
          TextInput({ text: this.profileName, placeholder: $r('app.string.ui_c1d25f3cd3') })
            .fontSize(14).width('100%').fontColor(ThemeColors.onBackground(this.isDark))
            .onChange((v: string): void => { this.profileName = v; })

          // ===== 常用 API 预设 =====
          Text($r('app.string.ui_b21af4486d')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 6 })
          Row() {
            ForEach(PRESETS, (p: PresetItem) => { this.presetChip(p); })
          }.width('100%')

          // ===== API 地址 =====
          Text($r('app.string.ui_acd8a50431')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          TextInput({ text: this.endpoint, placeholder: $r('app.string.ui_e4d0357e84') })
            .fontSize(14).width('100%')
            .onChange((v: string) => { this.endpoint = v; this.detectPreset_(); })

          // ===== API Key =====
          Text($r('app.string.ui_47acd2028c')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          Row() {
            TextInput({ text: this.apiKey, placeholder: $r('app.string.ui_ec3810e10f') })
              .fontSize(14).layoutWeight(1).height(48).type(this.showKey ? InputType.Normal : InputType.Password)
              .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
              .onChange((v: string) => { this.apiKey = v; })
            Button(this.showKey ? '隐藏' : '显示').fontSize(12)
              .backgroundColor(ThemeColors.transparent()).width(40).height(40)
              .onClick(() => { this.showKey = !this.showKey; })
          }.width('100%')

          // ===== 模型 =====
          Text($r('app.string.ui_98fd0cbd9c')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          Row() {
            TextInput({ text: this.model, placeholder: $r('app.string.ui_6d9372f6ba') })
              .fontSize(14).layoutWeight(1).height(48)
              .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
              .onChange((v: string) => { this.model = v; })
            Button(this.isFetchingModels ? '获取中' : '获取模型').fontSize(12)
              .backgroundColor(ThemeColors.transparent()).width(40).height(40)
              .onClick(() => { this.fetchModels(); })
          }.width('100%')

          if (this.showModelPicker && this.models.length > 0) {
            Text('选择模型 (' + this.models.length + ' 个)').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
              .padding({ top: 8, bottom: 4 }).alignSelf(ItemAlign.Start)
            List() {
              ForEach(this.models, (m: string) => {
                ListItem() { this.modelItem(m); }
              })
            }
            .height(Math.min(this.models.length * 36, 180)).width('100%')
            .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(8)
          }

          Text($r('app.string.ui_0d38dfddcb')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 4 })
          TextInput({ text: this.timeoutSecondsText, placeholder: $r('app.string.ui_775bc5c30e') })
            .fontSize(14).width('100%').type(InputType.Number)
            .onChange((v: string): void => { this.timeoutSecondsText = v; })
          Text($r('app.string.ui_e6400fa473'))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 4 })

          // ===== 测试连通性 =====
          Button(this.isTesting ? '测试中...' : '🧪 测试连通性').fontSize(14)
            .fontColor(ThemeColors.onBackground(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .width('100%').height(40).borderRadius(20).margin({ top: 20 })
            .onClick(() => { this.testConnection(); })

          if (this.testResult) {
            Text(this.testResult).fontSize(12)
              .fontColor(this.testResult === '连接成功' ? ThemeColors.success(this.isDark) : ThemeColors.error(this.isDark))
              .margin({ top: 8 }).alignSelf(ItemAlign.Start)
          }
        }
        .padding({ left: 16, right: 16 }).width('100%')
        .constraintSize({ maxWidth: WindowLayout.isWide ? 640 : Number.MAX_SAFE_INTEGER })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
