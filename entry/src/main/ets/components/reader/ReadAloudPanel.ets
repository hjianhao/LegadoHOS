/**
 * 朗读控制面板
 */
import { ReadAloudEngine, AloudState, ReadAloudVoice, ReadAloudVoiceConfig, TtsVoiceManager, getGlobalEngineRef, getGlobalAloudEngine, setAloudGlobalListener, setGlobalBackend } from '../../service/ReadAloudEngine';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { TtsEngineType, TTS_ENGINE_SYSTEM, TTS_ENGINE_SHERPA_ONNX, TTS_ENGINE_AZURE, TtsVoiceInfo } from '../../service/tts/ITtsBackend';
import { getSherpaOnnxBackend } from '../../service/tts/SherpaOnnxTtsBackend';
import { getAzureTtsBackend } from '../../service/tts/AzureTtsBackend';
import { TtsModelManager, CancelFlag, TtsModelType } from '../../service/tts/TtsModelManager';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, bundleManager, common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../../util/UiUtil';
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ReadAloudPanel {
  @StorageLink('isDark') isDark: boolean = false;
  @State isPlaying: boolean = false;
  @State isPaused: boolean = false;
  @State speed: number = 1.0;
  @State progress: number = 0;
  @State progressText: string = '';
  @State errorText: string = '';
  @State voices: ReadAloudVoice[] = [];
  @State voicesLoading: boolean = false;
  @State showVoiceSelect: boolean = false;
  @State downloadingVoiceKey: string = '';
  @State voiceDownloadProgress: string = '';
  @State selectedVoiceLanguage: string = 'zh-CN';
  @State selectedVoicePerson: number = 13;
  @State selectedVoiceStyle: string = 'interaction-broadcast';
  @State selectedVoiceName: string = '系统默认';
  // ---- 离线 TTS 引擎 ----
  @State selectedEngine: TtsEngineType = TTS_ENGINE_SYSTEM;
  @State selectedModelType: TtsModelType = 'kokoro';  // 离线引擎子类型
  @State showEngineSelect: boolean = false;
  @State sherpaVoices: TtsVoiceInfo[] = [];
  @State sherpaVoiceInitError: string = '';
  @State modelDownloaded: boolean = false;
  @State modelDownloading: boolean = false;
  @State modelDownloadProgress: string = '';
  @State vitsModelDownloaded: boolean = false;
  @State vitsModelDownloading: boolean = false;
  @State isWarmingUp: boolean = false;
  @State selectedSherpaVoiceId: string = 'kokoro-50';
  @State selectedSherpaVoiceName: string = '青年男声·云希';
  @State azureVoices: TtsVoiceInfo[] = [];
  @State selectedAzureVoiceId: string = 'zh-CN-XiaoxiaoNeural';
  @State selectedAzureVoiceName: string = '晓晓';
  private downloadCancelFlag_: CancelFlag = { cancelled: false };

  text: string = '';
  textOffset: number = 0;  // 从第几个字开始读
  @Prop currentChapterIndex: number = 0;  // 当前章节索引
  chapterTitle: string = '';
  externalEngine: ReadAloudEngine | null = null;
  onDismiss?: () => void;
  onNextChapter?: () => void;
  onGoToPosition?: (charIndex: number, chapterIndex?: number) => void;
  onPrevChapter?: () => void;
  engine_: ReadAloudEngine | null = null;
  curCharIdx_: number = 0;
  private curAloudChapter_: number = -1;  // 引擎当前朗读的章节(-1表示从startPlay设置)
  private bgTaskActive_: boolean = false;

  /** 直接查询引擎状态，不自己维护 */
  isPlaying_(): boolean { const s = getGlobalEngineRef()?.state; return s === AloudState.PLAYING; }
  isPaused_(): boolean { const s = getGlobalEngineRef()?.state; return s === AloudState.PAUSED; }
  private avSession_: avSession.AVSession | null = null;
  private wantAgent_: object | null = null;

  aboutToAppear(): void {
    this.loadVoicePreference_();
    this.loadVoices_();
    this.loadSpeed_();
    this.loadEnginePreference_();
    const ref = getGlobalEngineRef();
    if (ref) {
      this.isPlaying = ref.state === AloudState.PLAYING;
      this.isPaused = ref.state === AloudState.PAUSED;
      if (ref.startChapter > 0) this.curAloudChapter_ = ref.startChapter;
    }
    // 注册全局监听，追踪朗读进度
    setAloudGlobalListener({
      onState: (s: AloudState) => { this.isPlaying = s === AloudState.PLAYING; this.isPaused = s === AloudState.PAUSED; if (s === AloudState.PLAYING) this.errorText = ''; },
      onProgress: (ci: number, t: number) => { this.curCharIdx_ = ci; this.progress = t > 0 ? Math.round((ci / t) * 100) : 0; this.progressText = ci + '/' + t; },
      onChapterChange: (chapterIdx: number) => { this.curAloudChapter_ = chapterIdx; this.progress = 0; this.progressText = ''; this.curCharIdx_ = 0; this.textOffset = 0; },
      onChapterEnd: () => { this.progress = 100; this.onNextChapter?.(); },
      onError: (msg: string) => { this.errorText = msg; },
    });
  }

  aboutToDisappear(): void {
    setAloudGlobalListener(null);
  }

  private async loadVoicePreference_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      this.selectedVoiceLanguage = await settings.get('tts_voice_language', TtsVoiceManager.DEFAULT_VOICE.language);
      this.selectedVoicePerson = await settings.get('tts_voice_person', TtsVoiceManager.DEFAULT_VOICE.person);
      this.selectedVoiceStyle = await settings.get('tts_voice_style', TtsVoiceManager.DEFAULT_VOICE.style);
      this.selectedVoiceName = await settings.get('tts_voice_name', '系统默认');
    } catch (e) {
      console.warn('[Aloud] load voice preference failed: ' + (e as Error).message);
    }
  }

  private async loadSpeed_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      this.speed = await settings.getTtsSpeed();
    } catch (e) {
      console.warn('[Aloud] load speed failed: ' + (e as Error).message);
    }
  }

  // ---- 离线 TTS 引擎管理 ----

  private async loadEnginePreference_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      const engine = await settings.getTtsEngine();
      this.selectedEngine = (engine === TTS_ENGINE_SHERPA_ONNX || engine === TTS_ENGINE_AZURE) ? engine as TtsEngineType : TTS_ENGINE_SYSTEM;
      this.selectedModelType = (await settings.getTtsModelType()) as TtsModelType;
      this.selectedSherpaVoiceId = this.selectedModelType + '-' + await settings.getTtsSherpaSid();
      this.selectedAzureVoiceId = await settings.getTtsAzureVoice();
      // 从后端获取名称
      const backend = getSherpaOnnxBackend(UiUtil.getHostContext(this.getUIContext()), this.selectedModelType);
      const voices = await backend.listVoices();
      const preset = voices.find((v: TtsVoiceInfo) => v.id === this.selectedSherpaVoiceId);
      if (preset) {
        this.selectedSherpaVoiceName = preset.name;
      }
      const azureBackend = getAzureTtsBackend(UiUtil.getHostContext(this.getUIContext()));
      this.azureVoices = await azureBackend.listVoices();
      const azurePreset = this.azureVoices.find((v: TtsVoiceInfo) => v.id === this.selectedAzureVoiceId);
      if (azurePreset) {
        this.selectedAzureVoiceName = azurePreset.name;
      }
      this.modelDownloaded = await settings.getTtsModelDownloaded();
      // 检查两个模型类型的文件是否存在
      const ctx2 = UiUtil.getHostContext(this.getUIContext());
      for (const mt of ['kokoro', 'vits'] as TtsModelType[]) {
        const path = TtsModelManager.getModelPath(ctx2, mt);
        const exists = await TtsModelManager.isModelReady(path, mt);
        if (mt === 'kokoro') { this.modelDownloaded = exists; }
        else { this.vitsModelDownloaded = exists; }
      }

      // 预加载离线音色列表并初始化 backend
      if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX && this.isModelDownloaded_()) {
        this.loadSherpaVoices_();
        // 初始化后端（如果尚未创建引擎，backend 会被暂存，等引擎创建时注入）
        const ctx = UiUtil.getHostContext(this.getUIContext());
        const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
        await setGlobalBackend(backend);
      } else if (this.selectedEngine === TTS_ENGINE_AZURE) {
        const ctx = UiUtil.getHostContext(this.getUIContext());
        const backend = getAzureTtsBackend(ctx);
        backend.setVoice(this.selectedAzureVoiceId);
        await setGlobalBackend(backend);
      }
    } catch (e) {
      console.warn('[Aloud] load engine preference failed: ' + (e as Error).message);
    }
  }

  private async saveEnginePreference_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.setTtsEngine(this.selectedEngine);
      await settings.setTtsModelType(this.selectedModelType);
    } catch (e) {
      console.warn('[Aloud] save engine preference failed: ' + (e as Error).message);
    }
  }

  private async loadSherpaVoices_(): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext());
      const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
      this.sherpaVoices = await backend.listVoices();
    } catch (e) {
      console.warn('[Aloud] load sherpa voices failed: ' + (e as Error).message);
    }
  }

  /** 选择引擎（含模型类型） */
  private selectEngine_(engine: TtsEngineType, modelType: TtsModelType): void {
    this.showEngineSelect = false;
    this.selectedModelType = modelType;
    this.switchEngine_(engine);
  }

  /** 下载指定类型的模型 */
  private async downloadModelFor_(type: TtsModelType): Promise<void> {
    this.selectedModelType = type;
    await this.downloadModel_();
  }

  /** 切换引擎 */
  private async switchEngine_(engine: TtsEngineType): Promise<void> {
    // 同引擎、同模型类型 → 无需切换
    if (engine === this.selectedEngine && engine === TTS_ENGINE_SYSTEM) return;

    const wasPlaying = this.isPlaying_() || this.isPaused;
    if (wasPlaying) await this.stopPlay();

    const prevEngine = this.selectedEngine;
    this.selectedEngine = engine;
    await this.saveEnginePreference_();

    if (engine === TTS_ENGINE_SHERPA_ONNX) {
      if (!this.isModelDownloaded_()) {
        await SettingsStore.getInstance().setTtsModelDownloaded(false);
        return;
      }

      try {
        this.sherpaVoiceInitError = '';
        const ctx = UiUtil.getHostContext(this.getUIContext());
        const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
        await setGlobalBackend(backend);
        await this.loadSherpaVoices_();
        this.sherpaVoiceInitError = '';
      } catch (e) {
        this.sherpaVoiceInitError = (e as Error).message;
        console.error('[Aloud] sherpa init failed: ' + (e as Error).message);
        // 回退到系统 TTS
        this.selectedEngine = TTS_ENGINE_SYSTEM;
        await this.saveEnginePreference_();
        await setGlobalBackend(null);
      }
    } else if (engine === TTS_ENGINE_AZURE) {
      try {
        const settings = SettingsStore.getInstance();
        await settings.init(UiUtil.getHostContext(this.getUIContext()));
        const endpoint = await settings.getTtsAzureEndpoint();
        const key = await settings.getTtsAzureKey();
        if (!endpoint.trim() || !key.trim()) {
          throw new Error('请先在设置中填写端点和密钥');
        }
        const ctx = UiUtil.getHostContext(this.getUIContext());
        const backend = getAzureTtsBackend(ctx);
        backend.setVoice(this.selectedAzureVoiceId);
        await setGlobalBackend(backend);
        this.azureVoices = await backend.listVoices();
      } catch (e) {
        this.errorText = 'Azure TTS 配置不可用: ' + (e as Error).message;
        this.selectedEngine = prevEngine;
        await this.saveEnginePreference_();
        await setGlobalBackend(null);
      }
    } else {
      // 切换回系统 TTS
      await setGlobalBackend(null);
    }

    // 如果之前在播放，重新开始
    if (wasPlaying) await this.startPlay();
  }

  /** 引擎显示名称 */
  engineDisplayName_(): string {
    if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX) {
      return this.selectedModelType === 'vits' ? '自然语音（流畅）' : '自然语音（高品质）';
    }
    if (this.selectedEngine === TTS_ENGINE_AZURE) return '微软语音';
    return '系统语音';
  }

  engineSubText_(): string {
    if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX) {
      return this.isModelDownloaded_() ? '已就绪 · 完全离线' : this.selectedModelType === 'vits' ?
        '需下载模型（约 120 MB）' : '需下载模型（约 180-220 MB）';
    }
    if (this.selectedEngine === TTS_ENGINE_AZURE) return '在线合成 · Azure Neural TTS';
    return '无需下载 · 设备内置';
  }

  currentVoiceName_(): string {
    if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX) return this.selectedSherpaVoiceName;
    if (this.selectedEngine === TTS_ENGINE_AZURE) return this.selectedAzureVoiceName;
    return this.selectedVoiceName;
  }

  isEngineActive_(engine: TtsEngineType, modelType: TtsModelType): boolean {
    if (engine === TTS_ENGINE_SYSTEM) return this.selectedEngine === TTS_ENGINE_SYSTEM;
    if (engine === TTS_ENGINE_AZURE) return this.selectedEngine === TTS_ENGINE_AZURE;
    return this.selectedEngine === TTS_ENGINE_SHERPA_ONNX && this.selectedModelType === modelType;
  }
  isModelDownloaded_(): boolean {
    return this.selectedModelType === 'vits' ? this.vitsModelDownloaded : this.modelDownloaded;
  }
  isModelDownloading_(): boolean {
    return this.selectedModelType === 'vits' ? this.vitsModelDownloading : this.modelDownloading;
  }
  setModelDownloaded_(v: boolean): void {
    if (this.selectedModelType === 'vits') { this.vitsModelDownloaded = v; }
    else { this.modelDownloaded = v; }
  }
  setModelDownloading_(v: boolean): void {
    if (this.selectedModelType === 'vits') { this.vitsModelDownloading = v; }
    else { this.modelDownloading = v; }
  }

  private async saveVoicePreference_(voice: ReadAloudVoice): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.put('tts_voice_language', voice.language);
      await settings.put('tts_voice_person', voice.person);
      await settings.put('tts_voice_style', voice.style);
      await settings.put('tts_voice_name', this.voiceDisplayName_(voice));
    } catch (e) {
      console.warn('[Aloud] save voice preference failed: ' + (e as Error).message);
    }
  }

  private async loadVoices_(): Promise<void> {
    this.voicesLoading = true;
    try {
      const list = await TtsVoiceManager.listOfflineVoices();
      this.voices = list;
      this.syncSelectedVoiceName_();
    } catch (e) {
      console.error('[Aloud] list voices failed: ' + (e as Error).message);
      this.errorText = '音色列表加载失败';
    } finally {
      this.voicesLoading = false;
    }
  }

  private currentVoiceConfig_(): ReadAloudVoiceConfig {
    return {
      language: this.selectedVoiceLanguage,
      person: this.selectedVoicePerson,
      style: this.selectedVoiceStyle,
    };
  }

  private currentVoiceKey_(): string {
    return TtsVoiceManager.makeKey(this.selectedVoiceLanguage, this.selectedVoicePerson, this.selectedVoiceStyle);
  }

  private findSelectedVoice_(): ReadAloudVoice | null {
    const key = this.currentVoiceKey_();
    for (let i = 0; i < this.voices.length; i++) {
      if (this.voices[i].key === key) return this.voices[i];
    }
    return null;
  }

  private syncSelectedVoiceName_(): void {
    const voice = this.findSelectedVoice_();
    if (voice) {
      this.selectedVoiceName = this.voiceDisplayName_(voice);
    }
  }

  private voiceDisplayName_(voice: ReadAloudVoice): string {
    if (voice.description) return voice.description;
    if (voice.style) return voice.style;
    return '音色 ' + voice.person;
  }

  private voiceSubText_(voice: ReadAloudVoice): string {
    const gender = voice.gender ? voice.gender : '未知';
    return gender + ' · ' + voice.language + ' · ' + TtsVoiceManager.statusLabel(voice.status);
  }

  private async ensureSelectedVoiceReady_(): Promise<boolean> {
    const voice = this.findSelectedVoice_();
    if (!voice || voice.downloaded) return true;
    return await this.downloadAndSelectVoice_(voice, false);
  }

  private async selectVoice_(voice: ReadAloudVoice): Promise<void> {
    if (this.downloadingVoiceKey) return;
    if (!voice.downloaded) {
      await this.downloadAndSelectVoice_(voice, true);
      return;
    }
    await this.applyVoice_(voice, true);
  }

  private async downloadAndSelectVoice_(voice: ReadAloudVoice, showToast: boolean): Promise<boolean> {
    this.downloadingVoiceKey = voice.key;
    this.voiceDownloadProgress = '0%';
    this.errorText = '';
    try {
      await TtsVoiceManager.downloadVoice(voice, (progress: string) => {
        this.voiceDownloadProgress = progress;
      });
      UiUtil.showToast(this.getUIContext(), { message: '音色下载完成', duration: 1500 });
      await this.loadVoices_();
      const refreshed = this.voices.find((item: ReadAloudVoice) => item.key === voice.key) || voice;
      refreshed.downloaded = true;
      refreshed.status = refreshed.status === 'GA' ? '' : refreshed.status;
      await this.applyVoice_(refreshed, showToast);
      return true;
    } catch (e) {
      const msg = (e as Error).message || String(e);
      this.errorText = msg;
      UiUtil.showToast(this.getUIContext(), { message: msg, duration: 1800 });
      return false;
    } finally {
      this.downloadingVoiceKey = '';
      this.voiceDownloadProgress = '';
    }
  }

  private async applyVoice_(voice: ReadAloudVoice, restartIfNeeded: boolean): Promise<void> {
    this.selectedVoiceLanguage = voice.language;
    this.selectedVoicePerson = voice.person;
    this.selectedVoiceStyle = voice.style;
    this.selectedVoiceName = this.voiceDisplayName_(voice);
    this.showVoiceSelect = false;
    await this.saveVoicePreference_(voice);

    if (restartIfNeeded && (this.isPlaying_() || this.isPaused)) {
      // 先停止当前朗读，再以新音色从当前位置重新开始
      const savedOffset = this.curCharIdx_;
      const savedChapter = this.currentChapterIndex;
      await this.stopPlay();
      this.textOffset = savedOffset;
      this.currentChapterIndex = savedChapter;
      await this.startPlay();
    }
  }

  async createAvSession_(): Promise<void> {
    if (this.avSession_) return;
    try {
      this.avSession_ = await avSession.createAVSession(UiUtil.getHostContext(this.getUIContext()), 'legado_tts', 'audio');
      // 设置 WantAgent 后激活（播控中心点击拉起应用）
      if (!this.wantAgent_) {
        this.wantAgent_ = await this.createWantAgent_();
      }
      this.avSession_.setLaunchAbility(this.wantAgent_);
      await this.avSession_.activate();
      // 设置元数据
      const meta: avSession.AVMetadata = {
        assetId: '0',
        title: this.chapterTitle || '朗读中',
        artist: '开源阅读',
        duration: -1,
      };
      this.avSession_.setAVMetadata(meta);
      // 监听播控命令
      this.avSession_.on('play', () => { if (!this.isPlaying) this.togglePlay(); });
      this.avSession_.on('pause', () => { if (this.isPlaying_()) this.togglePlay(); });
      this.avSession_.on('stop', () => { if (this.isPlaying_() || this.isPaused) this.stopPlay(); });
      this.avSession_.on('playNext', () => { this.stopPlay(); this.onNextChapter?.(); });
      this.avSession_.on('playPrevious', () => { this.stopPlay(); this.onPrevChapter?.(); });
      console.info('[Aloud] AVSession created');
    } catch (e) {
      console.error('[Aloud] AVSession failed: ' + (e as Error).message);
    }
  }

  async destroyAvSession_(): Promise<void> {
    if (!this.avSession_) return;
    try { await this.avSession_.deactivate(); } catch (_) {}
    try { await this.avSession_.destroy(); } catch (_) {}
    this.avSession_ = null;
  }

  private async createWantAgent_(): Promise<object> {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      console.info('[Aloud] creating WantAgent for bundle=' + info.name);
      return await wantAgent.getWantAgent({
        wants: [{ bundleName: info.name, abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITIES,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      });
    } catch (err) {
      throw new Error(String(err));
    }
  }

  async startBgTask_(): Promise<void> {
    console.info('[Aloud] startBgTask_ called, active=' + this.bgTaskActive_);
    if (this.bgTaskActive_) return;
    try {
      if (!this.wantAgent_) {
        this.wantAgent_ = await this.createWantAgent_();
      }
      // 必须使用 UIAbilityContext，普通 Context 会导致任务启动失败
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.UIAbilityContext;
      // 申请 AUDIO_PLAYBACK 后台模式，保证音频播放不被限制
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, this.wantAgent_);
      this.bgTaskActive_ = true;
      console.info('[Aloud] bgTask started');
    } catch (e) {
      console.warn('[Aloud] bgTask not available: ' + (e as Error).message);
    }
  }

  async stopBgTask_(): Promise<void> {
    if (!this.bgTaskActive_) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(UiUtil.getHostContext(this.getUIContext()));
    } catch (_e) { /* ignore */ }
    this.bgTaskActive_ = false;
  }

  async startPlay(): Promise<void> {
    console.info('[Aloud] startPlay text.length=' + (this.text ? this.text.length : 0));
    const voiceReady = await this.ensureSelectedVoiceReady_();
    if (!voiceReady) return;
    this.errorText = '';
    this.curAloudChapter_ = this.currentChapterIndex;

    // 使用全局引擎，不覆盖回调（由 aboutToAppear 的 setAloudGlobalListener 管理）
    let eng = getGlobalEngineRef();
    if (!eng) {
      eng = getGlobalAloudEngine({
        onStateChange: () => {},
        onProgress: () => {},
        onChapterEnd: () => {},
        onError: () => {},
      });
    }
    eng.setVoice(this.selectedVoiceLanguage, this.selectedVoicePerson, this.selectedVoiceStyle);
    this.engine_ = eng;

    try {
      if (eng.state !== AloudState.IDLE) {
        await eng.release();
        if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX && this.isModelDownloaded_()) {
          const ctx = UiUtil.getHostContext(this.getUIContext());
          const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
          await eng.setBackend(backend);  // 包含 init + warmup
        } else if (this.selectedEngine === TTS_ENGINE_AZURE) {
          const ctx = UiUtil.getHostContext(this.getUIContext());
          const backend = getAzureTtsBackend(ctx);
          backend.setVoice(this.selectedAzureVoiceId);
          await eng.setBackend(backend);
        }
      }

      // 离线引擎首次合成很慢（3min+），提前告知
      if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX && this.isModelDownloaded_()) {
        const ctx = UiUtil.getHostContext(this.getUIContext());
        const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
        if (!backend.warmed) {
          this.errorText = '首次朗读加载较慢，请耐心等待...';
        }
      }

      console.info('[Aloud] calling init...');
      await eng.init();
      this.curCharIdx_ = this.textOffset;
      this.startBgTask_();
      await this.createAvSession_();
      console.info('[Aloud] calling speak...');
      const startText = this.textOffset > 0 ? this.text.substring(this.textOffset) : this.text;
      await eng.speak(startText, this.speed, this.textOffset, this.currentChapterIndex);
      console.info('[Aloud] speak done');
    } catch (e) {
      const msg = (e as Error).message || String(e);
      console.error('[Aloud] init error: ' + msg);
      this.errorText = '初始化失败: ' + msg;
    }
  }

  async togglePlay(): Promise<void> {
    console.info('[Aloud] togglePlay playing=' + this.isPlaying + ' paused=' + this.isPaused);
    if (this.isPlaying) {
      const e = this.engine_ ?? getGlobalEngineRef(); await e?.pause();
      this.stopBgTask_();
    } else if (this.isPaused) {
      await this.startBgTask_();
      const e = this.engine_ ?? getGlobalEngineRef(); await e?.resume();
    } else {
      await this.startPlay();
    }
  }

  async stopPlay(): Promise<void> {
    console.info('[Aloud] stopPlay called');
    this.stopBgTask_();
    await this.destroyAvSession_();
    const eng = this.engine_ ?? getGlobalEngineRef();
    if (eng) await eng.stop();
    this.isPlaying = false;
    this.isPaused = false;
    this.progress = 0;
  }

  async changeSpeed(v: number): Promise<void> {
    this.speed = v;
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      s.setTtsSpeed(v).catch(() => {});
    } catch (_e) { /* ignore */ }
    if (this.engine_ && (this.isPlaying_() || this.isPaused)) {
      await this.engine_.stop();
      await this.engine_.speak(this.text, this.speed);
    }
  }

  /** 选择离线音色 */
  private async selectSherpaVoice_(voice: TtsVoiceInfo): Promise<void> {
    this.selectedSherpaVoiceId = voice.id;
    this.selectedSherpaVoiceName = voice.name;
    this.showVoiceSelect = false;
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.setTtsSherpaSid(voice.sid ?? 50);

      const ctx = UiUtil.getHostContext(this.getUIContext());
      const backend = getSherpaOnnxBackend(ctx, this.selectedModelType);
      backend.setVoice(voice.id);
    } catch (e) {
      console.warn('[Aloud] save sherpa voice failed: ' + (e as Error).message);
    }

    // 如果正在播放，从当前位置重新开始（应用新音色）
    if (this.isPlaying_() || this.isPaused) {
      const savedOffset = this.curCharIdx_;
      await this.stopPlay();
      this.textOffset = savedOffset;
      await this.startPlay();
    }
  }

  /** 选择 Azure 音色 */
  private async selectAzureVoice_(voice: TtsVoiceInfo): Promise<void> {
    this.selectedAzureVoiceId = voice.id;
    this.selectedAzureVoiceName = voice.name;
    this.showVoiceSelect = false;
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.setTtsAzureVoice(voice.id);
      const backend = getAzureTtsBackend(UiUtil.getHostContext(this.getUIContext()));
      backend.setVoice(voice.id);
    } catch (e) {
      console.warn('[Aloud] save azure voice failed: ' + (e as Error).message);
    }

    if (this.isPlaying_() || this.isPaused) {
      const savedOffset = this.curCharIdx_;
      await this.stopPlay();
      this.textOffset = savedOffset;
      await this.startPlay();
    }
  }

  private async downloadModel_(): Promise<void> {
    if (this.isModelDownloading_()) return;
    this.setModelDownloading_(true);
    this.modelDownloadProgress = '0%';
    this.errorText = '';
    this.downloadCancelFlag_.cancelled = false;
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext());

      await TtsModelManager.downloadModel(
        ctx,
        this.selectedModelType,
        (percent: number, status: string) => {
          this.modelDownloadProgress = percent + '%';
          console.info('[Aloud] model download: ' + percent + '% ' + status);
        },
        this.downloadCancelFlag_,
        true,
      );

      // 下载成功
      this.setModelDownloaded_(true);
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.setTtsModelDownloaded(true);
      UiUtil.showToast(this.getUIContext(), {
        message: '离线模型下载完成，正在初始化...',
        duration: 1500,
      });
      await this.switchEngine_(TTS_ENGINE_SHERPA_ONNX);
    } catch (e) {
      const msg = (e as Error).message || String(e);
      if (this.downloadCancelFlag_.cancelled) {
        this.errorText = '下载已取消';
      } else {
        this.errorText = '模型下载失败: ' + msg;
      }
      console.error('[Aloud] model download failed: ' + msg);
    } finally {
      this.setModelDownloading_(false);
      this.modelDownloadProgress = '';
    }
  }

  speedLabel(): string {
    if (this.speed <= 0.5) return '0.5x';
    if (this.speed <= 0.75) return '0.75x';
    if (this.speed <= 1.0) return '1.0x';
    if (this.speed <= 1.25) return '1.25x';
    if (this.speed <= 1.5) return '1.5x';
    return '2.0x';
  }

  @Builder
  voiceListContent_() {
    if (this.voicesLoading) {
      Row() {
        LoadingProgress().width(18).height(18).color(ThemeColors.primary(this.isDark))
        Text($r('app.string.ui_15dc4f08ac')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
    } else if (this.voices.length === 0) {
      Text($r('app.string.ui_6243f074f1')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
    } else {
      Scroll() {
        Column() {
          ForEach(this.voices, (voice: ReadAloudVoice) => {
            Row() {
              Column() {
                Text(this.voiceDisplayName_(voice))
                  .fontSize(13)
                  .fontColor(voice.key === this.currentVoiceKey_() ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.voiceSubText_(voice))
                  .fontSize(10)
                  .fontColor(voice.downloaded ? ThemeColors.secondaryText(this.isDark) : ThemeColors.warning(this.isDark))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.downloadingVoiceKey === voice.key) {
                Row() {
                  LoadingProgress().width(16).height(16).color(ThemeColors.primary(this.isDark))
                  Text(this.voiceDownloadProgress ? this.voiceDownloadProgress : '下载中')
                    .fontSize(11)
                    .fontColor(ThemeColors.primary(this.isDark))
                    .margin({ left: 4 })
                }
              } else if (voice.key === this.currentVoiceKey_()) {
                Text($r('app.string.ui_e6aa2cbd7b')).fontSize(11).fontColor(ThemeColors.primary(this.isDark))
              } else if (voice.downloaded) {
                Button($r('app.string.ui_70b208202c'))
                  .fontSize(11)
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                  .fontColor(ThemeColors.onSurface(this.isDark))
                  .onClick(() => { this.selectVoice_(voice); })
              } else {
                Button($r('app.string.ui_2b9d013177'))
                  .fontSize(11)
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(ThemeColors.primary(this.isDark))
                  .fontColor(ThemeColors.onPrimary(this.isDark))
                  .enabled(this.downloadingVoiceKey.length === 0)
                  .onClick(() => { this.selectVoice_(voice); })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(voice.key === this.currentVoiceKey_() ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
            .borderRadius(8)
            .onClick(() => { this.selectVoice_(voice); })
          }, (voice: ReadAloudVoice) => voice.key)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }
      .width('100%')
      .height(180)
    }
  }

  @Builder
  engineSelectContent_() {
    Column() {
      // 系统语音
      this.engineOption_(
        '系统语音', '无需下载，功耗低', TTS_ENGINE_SYSTEM, 'kokoro', false, false
      )

      // 微软 Azure 语音
      this.engineOption_(
        '微软语音', 'Azure Neural TTS · 需网络和密钥', TTS_ENGINE_AZURE, 'kokoro', true, false
      )

      // 自然语音（高品质）
      this.engineOption_(
        '自然语音（高品质）', this.modelDownloaded ? 'Kokoro · 103 音色 · 完全离线' : '需下载（约 180-220 MB）',
        TTS_ENGINE_SHERPA_ONNX, 'kokoro', this.modelDownloaded, this.modelDownloading
      )

      // 自然语音（流畅）
      this.engineOption_(
        '自然语音（流畅）', this.vitsModelDownloaded ? 'VITS · 5 音色 · 轻量快速' : '需下载（约 70 MB）',
        TTS_ENGINE_SHERPA_ONNX, 'vits', this.vitsModelDownloaded, this.vitsModelDownloading
      )


      // 下载进度
      if (this.modelDownloading || this.vitsModelDownloading) {
        Row() {
          LoadingProgress().width(16).height(16).color(ThemeColors.primary(this.isDark))
          Text('正在下载模型 ' + this.modelDownloadProgress)
            .fontSize(11)
            .fontColor(ThemeColors.primary(this.isDark))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  @Builder
  engineOption_(label: string, desc: string, engine: TtsEngineType, modelType: TtsModelType, downloaded: boolean, downloading: boolean) {
    Row() {
      Column() {
        Text(label)
          .fontSize(13)
          .fontColor((engine === TTS_ENGINE_SYSTEM ? this.selectedEngine === TTS_ENGINE_SYSTEM :
            (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX && this.selectedModelType === modelType)) ?
            ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        Text(desc)
          .fontSize(10)
          .fontColor(downloaded ? ThemeColors.secondaryText(this.isDark) : ThemeColors.warning(this.isDark))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.isEngineActive_(engine, modelType)) {
        Text($r('app.string.ui_e6aa2cbd7b')).fontSize(11).fontColor(ThemeColors.primary(this.isDark))
      } else if (engine === TTS_ENGINE_SHERPA_ONNX && !downloaded) {
        Button($r('app.string.ui_1252c81119'))
          .fontSize(11)
          .height(40)
          .padding({ left: 10, right: 10 })
          .backgroundColor(ThemeColors.primary(this.isDark))
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .enabled(!downloading)
          .onClick(() => { this.downloadModelFor_(modelType as TtsModelType); })
      } else if (engine === TTS_ENGINE_SHERPA_ONNX && downloaded) {
        Row() {
          Button($r('app.string.ui_70b208202c'))
            .fontSize(11)
            .height(40)
            .padding({ left: 8, right: 8 })
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark))
            .margin({ right: 4 })
            .onClick(() => { this.selectEngine_(engine, modelType as TtsModelType); })
          Button($r('app.string.ui_49c5e3b52b'))
            .fontSize(11)
            .height(40)
            .padding({ left: 8, right: 8 })
            .backgroundColor(ThemeColors.warningContainer(this.isDark))
            .fontColor(ThemeColors.warning(this.isDark))
            .enabled(!downloading)
            .onClick(() => { this.downloadModelFor_(modelType as TtsModelType); })
        }
      } else {
        Button($r('app.string.ui_70b208202c'))
          .fontSize(11)
          .height(40)
          .padding({ left: 10, right: 10 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => { this.selectEngine_(engine, modelType as TtsModelType); })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.isEngineActive_(engine, modelType) ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
    .borderRadius(8)
    .onClick(() => {
      if (engine === TTS_ENGINE_SYSTEM || engine === TTS_ENGINE_AZURE || downloaded) {
        this.selectEngine_(engine, modelType);
      }
    })
  }

  @Builder
  azureVoiceListContent_() {
    if (this.azureVoices.length === 0) {
      Text($r('app.string.ui_8e9942fe51')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
    } else {
      Scroll() {
        Column() {
          ForEach(this.azureVoices, (voice: TtsVoiceInfo) => {
            Row() {
              Column() {
                Text(voice.name)
                  .fontSize(13)
                  .fontColor(voice.id === this.selectedAzureVoiceId ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(voice.description)
                  .fontSize(10)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (voice.id === this.selectedAzureVoiceId) {
                Text($r('app.string.ui_e6aa2cbd7b')).fontSize(11).fontColor(ThemeColors.primary(this.isDark))
              } else {
                Button($r('app.string.ui_70b208202c'))
                  .fontSize(11)
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                  .fontColor(ThemeColors.onSurface(this.isDark))
                  .onClick(() => { this.selectAzureVoice_(voice); })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(voice.id === this.selectedAzureVoiceId ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
            .borderRadius(8)
            .onClick(() => { this.selectAzureVoice_(voice); })
          }, (voice: TtsVoiceInfo) => voice.id)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }
      .width('100%')
      .height(180)
    }
  }

  @Builder
  sherpaVoiceListContent_() {
    if (this.sherpaVoices.length === 0) {
      Row() {
        LoadingProgress().width(18).height(18).color(ThemeColors.primary(this.isDark))
        Text($r('app.string.ui_280fd119d9')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
      }
      .width('100%').height(44).justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column() {
          ForEach(this.sherpaVoices, (voice: TtsVoiceInfo) => {
            Row() {
              Column() {
                Text(voice.name)
                  .fontSize(13)
                  .fontColor(voice.id === this.selectedSherpaVoiceId ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(voice.description)
                  .fontSize(10)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (voice.id === this.selectedSherpaVoiceId) {
                Text($r('app.string.ui_e6aa2cbd7b')).fontSize(11).fontColor(ThemeColors.primary(this.isDark))
              } else {
                Button($r('app.string.ui_70b208202c'))
                  .fontSize(11)
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                  .fontColor(ThemeColors.onSurface(this.isDark))
                  .onClick(() => { this.selectSherpaVoice_(voice); })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(voice.id === this.selectedSherpaVoiceId ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
            .borderRadius(8)
            .onClick(() => { this.selectSherpaVoice_(voice); })
          }, (voice: TtsVoiceInfo) => voice.id)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }
      .width('100%')
      .height(180)
    }
  }

  build() {
    Column() {
      // 标题行
      Row() {
        Text(this.chapterTitle || '朗读').fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onSurface(this.isDark)).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(ThemeColors.transparent()).width(40).height(40)
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 12, right: 8, top: 8 })

      // 进度条
      if (this.isPlaying_() || this.isPaused) {
        Row() {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%').height(3).color(ThemeColors.primary(this.isDark))
        }.width('100%').padding({ left: 12, right: 12, top: 4 })
        Text(this.progressText).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 12, top: 2 })
      }

      // 错误信息
      if (this.errorText) {
        Text(this.errorText).fontSize(11).fontColor(ThemeColors.error(this.isDark))
          .padding({ left: 12, right: 12, top: 4 })
      }

      // ---- 引擎选择 ----
      Row() {
        Text($r('app.string.ui_9413bdc38c')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(36)
        Column() {
          Text(this.engineDisplayName_())
            .fontSize(13)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.engineSubText_())
            .fontSize(10)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4, right: 8 })
        Button(this.showEngineSelect ? '收起' : '切换')
          .fontSize(12)
          .height(40)
          .padding({ left: 12, right: 12 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => { this.showEngineSelect = !this.showEngineSelect; })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      if (this.showEngineSelect) {
        this.engineSelectContent_()
      }

      // 离线引擎错误提示
      if (this.sherpaVoiceInitError && this.selectedEngine === TTS_ENGINE_SHERPA_ONNX) {
        Text(this.sherpaVoiceInitError).fontSize(11).fontColor(ThemeColors.error(this.isDark))
          .padding({ left: 12, right: 12, top: 4 })
      }

      // ---- 音色选择 ----
      Row() {
        Text($r('app.string.ui_c4301894a2')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(36)
        Column() {
          Text(this.currentVoiceName_())
            .fontSize(13)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4, right: 8 })
        Button(this.showVoiceSelect ? '收起' : '切换')
          .fontSize(12)
          .height(40)
          .padding({ left: 12, right: 12 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => {
            this.showVoiceSelect = !this.showVoiceSelect;
            if (this.showVoiceSelect && this.voices.length === 0 && !this.voicesLoading) {
              this.loadVoices_();
            }
          })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      if (this.showVoiceSelect) {
        if (this.selectedEngine === TTS_ENGINE_SHERPA_ONNX) {
          this.sherpaVoiceListContent_()
        } else if (this.selectedEngine === TTS_ENGINE_AZURE) {
          this.azureVoiceListContent_()
        } else {
          this.voiceListContent_()
        }
      }

      // 语速调节
      Row() {
        Text($r('app.string.ui_747374775d')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(36)
        Slider({ value: this.speed, min: 0.5, max: 2.0, step: 0.25 })
          .width('60%').margin({ left: 4, right: 8 })
          .onChange((v: number) => { this.changeSpeed(v); })
        Text(this.speedLabel()).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).width(40).textAlign(TextAlign.End)
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      // 控制按钮
      Row() {
        Button($r('app.string.ui_4ccc70caa6')).fontSize(22).fontColor(ThemeColors.onSurface(this.isDark))
          .backgroundColor(ThemeColors.transparent()).layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onPrevChapter?.();
          })
        Button(this.isPlaying_() ? '⏸' : '▶️').fontSize(28).fontColor(ThemeColors.onSurface(this.isDark))
          .backgroundColor(ThemeColors.transparent()).layoutWeight(1)
          .onClick(() => { this.togglePlay(); })
        Button($r('app.string.ui_dc0d472de6')).fontSize(22).fontColor(ThemeColors.onSurface(this.isDark))
          .backgroundColor(ThemeColors.transparent()).layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onNextChapter?.();
          })
        Button($r('app.string.ui_0ef94bd672')).fontSize(22).fontColor(ThemeColors.onSurface(this.isDark))
          .backgroundColor(ThemeColors.transparent()).layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onDismiss?.();
          })
      }.width('100%').padding({ top: 8, bottom: 12 })

      // 辅助操作
      Row() {
        Button($r('app.string.ui_6701c1a30b')).fontSize(12).height(40).padding({ left: 12, right: 12 }).borderRadius(16)
          .backgroundColor(ThemeColors.successContainer(this.isDark)).fontColor(ThemeColors.success(this.isDark))
          .onClick(() => { this.stopPlay(); this.startPlay(); })
        Button($r('app.string.ui_56b1c4def5')).fontSize(12).height(40).padding({ left: 12, right: 12 }).borderRadius(16)
          .backgroundColor(ThemeColors.primaryContainer(this.isDark)).fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { const eng = getGlobalEngineRef(); const ci = this.curCharIdx_; const ch = eng?.startChapter || this.curAloudChapter_ || this.currentChapterIndex; if (eng && eng.state === AloudState.PLAYING) this.onGoToPosition?.(ci, ch); })
      }.width('100%').justifyContent(FlexAlign.SpaceEvenly).padding({ bottom: 8 })

    }
    .width('100%').backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
