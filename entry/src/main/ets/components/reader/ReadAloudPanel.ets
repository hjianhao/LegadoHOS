/**
 * 朗读控制面板
 */
import { ReadAloudEngine, AloudState, ReadAloudVoice, ReadAloudVoiceConfig, TtsVoiceManager, getGlobalEngineRef, getGlobalAloudEngine, setAloudGlobalListener } from '../../service/ReadAloudEngine';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, bundleManager } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../../util/UiUtil';

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

  text: string = '';
  textOffset: number = 0;  // 从第几个字开始读
  chapterTitle: string = '';
  externalEngine: ReadAloudEngine | null = null;
  onDismiss?: () => void;
  onNextChapter?: () => void;
  onGoToPosition?: (charIndex: number) => void;
  onPrevChapter?: () => void;
  engine_: ReadAloudEngine | null = null;
  curCharIdx_: number = 0;
  private curAloudChapter_: number = 0;  // 引擎当前朗读的章节
  private bgTaskActive_: boolean = false;

  /** 直接查询引擎状态，不自己维护 */
  isPlaying_(): boolean { const s = getGlobalEngineRef()?.state; return s === AloudState.PLAYING; }
  isPaused_(): boolean { const s = getGlobalEngineRef()?.state; return s === AloudState.PAUSED; }
  private avSession_: avSession.AVSession | null = null;
  private wantAgent_: object | null = null;

  aboutToAppear(): void {
    this.loadVoicePreference_();
    this.loadVoices_();
    const ref = getGlobalEngineRef();
    if (ref) {
      this.isPlaying = ref.state === AloudState.PLAYING;
      this.isPaused = ref.state === AloudState.PAUSED;
    }
    // 注册全局监听，追踪朗读进度
    setAloudGlobalListener({
      onState: (s: AloudState) => { this.isPlaying = s === AloudState.PLAYING; this.isPaused = s === AloudState.PAUSED; },
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
      await backgroundTaskManager.startBackgroundRunning(
        UiUtil.getHostContext(this.getUIContext()), backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, this.wantAgent_);
      this.bgTaskActive_ = true;
      console.info('[Aloud] bgTask started');
    } catch (e) {
      console.error('[Aloud] bgTask failed: ' + (e as Error).message);
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
      if (eng.state === AloudState.IDLE) {
        console.info('[Aloud] calling init...');
        await eng.init();
      }
      this.curCharIdx_ = this.textOffset;
      this.startBgTask_();
      await this.createAvSession_();
      console.info('[Aloud] calling speak...');
      const startText = this.textOffset > 0 ? this.text.substring(this.textOffset) : this.text;
      await eng.speak(startText, this.speed, this.textOffset);
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
    if (this.engine_ && (this.isPlaying_() || this.isPaused)) {
      // 重新开始以应用新语速
      await this.engine_.stop();
      await this.engine_.speak(this.text, this.speed);
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
        LoadingProgress().width(18).height(18).color('#0078D7')
        Text('正在加载音色').fontSize(12).fontColor(this.isDark ? '#AAA' : '#666').margin({ left: 8 })
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
    } else if (this.voices.length === 0) {
      Text('未获取到系统音色').fontSize(12).fontColor(this.isDark ? '#AAA' : '#666')
        .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
    } else {
      Scroll() {
        Column() {
          ForEach(this.voices, (voice: ReadAloudVoice) => {
            Row() {
              Column() {
                Text(this.voiceDisplayName_(voice))
                  .fontSize(13)
                  .fontColor(voice.key === this.currentVoiceKey_() ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.voiceSubText_(voice))
                  .fontSize(10)
                  .fontColor(voice.downloaded ? (this.isDark ? '#888' : '#777') : '#F57C00')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.downloadingVoiceKey === voice.key) {
                Row() {
                  LoadingProgress().width(16).height(16).color('#0078D7')
                  Text(this.voiceDownloadProgress ? this.voiceDownloadProgress : '下载中')
                    .fontSize(11)
                    .fontColor('#0078D7')
                    .margin({ left: 4 })
                }
              } else if (voice.key === this.currentVoiceKey_()) {
                Text('使用中').fontSize(11).fontColor('#0078D7')
              } else if (voice.downloaded) {
                Button('选择')
                  .fontSize(11)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(this.isDark ? '#333' : '#F0F0F0')
                  .fontColor(this.isDark ? '#E0E0E0' : '#333')
                  .onClick(() => { this.selectVoice_(voice); })
              } else {
                Button('下载')
                  .fontSize(11)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor('#0078D7')
                  .fontColor('#FFF')
                  .enabled(this.downloadingVoiceKey.length === 0)
                  .onClick(() => { this.selectVoice_(voice); })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(voice.key === this.currentVoiceKey_() ? (this.isDark ? '#153047' : '#EAF4FF') : 'transparent')
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

  build() {
    Column() {
      // 标题行
      Row() {
        Text(this.chapterTitle || '朗读').fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#333').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button('✕').fontSize(16).fontColor(this.isDark ? '#AAA' : '#888')
          .backgroundColor('transparent').width(32).height(32)
          .onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 12, right: 8, top: 8 })

      // 进度条
      if (this.isPlaying_() || this.isPaused) {
        Row() {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%').height(3).color('#0078D7')
        }.width('100%').padding({ left: 12, right: 12, top: 4 })
        Text(this.progressText).fontSize(10).fontColor('#888').margin({ left: 12, top: 2 })
      }

      // 错误信息
      if (this.errorText) {
        Text(this.errorText).fontSize(11).fontColor('#FF4444')
          .padding({ left: 12, right: 12, top: 4 })
      }

      // 音色选择
      Row() {
        Text('音色').fontSize(12).fontColor('#888').width(36)
        Column() {
          Text(this.selectedVoiceName)
            .fontSize(13)
            .fontColor(this.isDark ? '#E0E0E0' : '#333')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4, right: 8 })
        Button(this.showVoiceSelect ? '收起' : '切换')
          .fontSize(12)
          .height(30)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.isDark ? '#333' : '#F2F2F2')
          .fontColor(this.isDark ? '#E0E0E0' : '#333')
          .onClick(() => {
            this.showVoiceSelect = !this.showVoiceSelect;
            if (this.showVoiceSelect && this.voices.length === 0 && !this.voicesLoading) {
              this.loadVoices_();
            }
          })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      if (this.showVoiceSelect) {
        this.voiceListContent_()
      }

      // 语速调节
      Row() {
        Text('语速').fontSize(12).fontColor('#888').width(36)
        Slider({ value: this.speed, min: 0.5, max: 2.0, step: 0.25 })
          .width('60%').margin({ left: 4, right: 8 })
          .onChange((v: number) => { this.changeSpeed(v); })
        Text(this.speedLabel()).fontSize(13).fontColor('#0078D7').width(40).textAlign(TextAlign.End)
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      // 控制按钮
      Row() {
        Button('⏮').fontSize(22)
          .backgroundColor('transparent').layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onPrevChapter?.();
          })
        Button(this.isPlaying ? '⏸' : '▶️').fontSize(28)
          .backgroundColor('transparent').layoutWeight(1)
          .onClick(() => { this.togglePlay(); })
        Button('⏭').fontSize(22)
          .backgroundColor('transparent').layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onNextChapter?.();
          })
        Button('⏹').fontSize(22)
          .backgroundColor('transparent').layoutWeight(1)
          .onClick(() => {
            this.stopPlay(); this.stopBgTask_();
            this.onDismiss?.();
          })
      }.width('100%').padding({ top: 8, bottom: 12 })

      // 辅助操作
      Row() {
        Button('从本页朗读').fontSize(12).height(32).padding({ left: 12, right: 12 }).borderRadius(16)
          .backgroundColor(this.isDark ? '#1A3A2A' : '#E8F5E9').fontColor('#4CAF50')
          .onClick(() => { this.stopPlay(); this.startPlay(); })
        Button('跳转到朗读进度').fontSize(12).height(32).padding({ left: 12, right: 12 }).borderRadius(16)
          .backgroundColor(this.isDark ? '#1A2A3A' : '#E8F4FD').fontColor('#0078D7')
          .onClick(() => { const ci = this.curCharIdx_; const ch = this.curAloudChapter_; if (ci > 0 || ch > 0) this.onGoToPosition?.(ci, ch); })
      }.width('100%').justifyContent(FlexAlign.SpaceEvenly).padding({ bottom: 8 })

    }
    .width('100%').backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
