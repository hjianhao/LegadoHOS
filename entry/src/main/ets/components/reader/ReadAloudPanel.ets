/**
 * 朗读控制面板
 */
import { ReadAloudEngine, AloudState } from '../../service/ReadAloudEngine';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, bundleManager } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';

@Component
export struct ReadAloudPanel {
  @StorageLink('isDark') isDark: boolean = false;
  @State isPlaying: boolean = false;
  @State isPaused: boolean = false;
  @State speed: number = 1.0;
  @State progress: number = 0;
  @State progressText: string = '';
  @State errorText: string = '';

  text: string = '';
  textOffset: number = 0;  // 从第几个字开始读
  chapterTitle: string = '';
  externalEngine: ReadAloudEngine | null = null;
  onDismiss?: () => void;
  onNextChapter?: () => void;
  onPrevChapter?: () => void;
  engine_: ReadAloudEngine | null = null;
  private bgTaskActive_: boolean = false;
  private avSession_: avSession.AVSession | null = null;

  aboutToDisappear(): void {
    // 不停止引擎，不释放 session——后台继续播
  }

  async createAvSession_(): Promise<void> {
    if (this.avSession_) return;
    try {
      this.avSession_ = await avSession.createAVSession(getContext(), 'legado_tts', 'audio');
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
      this.avSession_.on('pause', () => { if (this.isPlaying) this.togglePlay(); });
      this.avSession_.on('stop', () => { this.stopPlay(); this.onDismiss?.(); });
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

  async startBgTask_(): Promise<void> {
    console.info('[Aloud] startBgTask_ called, active=' + this.bgTaskActive_);
    if (this.bgTaskActive_) return;
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      console.info('[Aloud] bgTask bundle=' + info.name);
      const wa = await wantAgent.getWantAgent({
        wants: [{ bundleName: info.name, abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      });
      await backgroundTaskManager.startBackgroundRunning(getContext(),
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wa);
      this.bgTaskActive_ = true;
      console.info('[Aloud] bgTask started');
    } catch (e) {
      console.error('[Aloud] bgTask failed: ' + (e as Error).message);
    }
  }

  async stopBgTask_(): Promise<void> {
    if (!this.bgTaskActive_) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext());
    } catch (_e) { /* ignore */ }
    this.bgTaskActive_ = false;
  }

  async startPlay(): Promise<void> {
    console.info('[Aloud] startPlay text.length=' + (this.text ? this.text.length : 0));
    if (this.engine_) {
      await this.engine_.release();
    }
    this.errorText = '';
    this.engine_ = new ReadAloudEngine({
      onStateChange: (state: AloudState) => {
        this.isPlaying = state === AloudState.PLAYING;
        this.isPaused = state === AloudState.PAUSED;
      },
      onProgress: (charIdx: number, total: number) => {
        this.progress = total > 0 ? Math.round((charIdx / total) * 100) : 0;
        this.progressText = charIdx + '/' + total;
      },
      onChapterEnd: () => {
        this.onNextChapter?.();
      },
      onError: (msg: string) => {
        this.errorText = msg;
      },
    });

    try {
      console.info('[Aloud] calling init...');
      await this.engine_.init();
      this.startBgTask_();
      await this.createAvSession_();  // 提早申请，不等 speak 返回
      console.info('[Aloud] calling speak...');
      const startText = this.textOffset > 0 ? this.text.substring(this.textOffset) : this.text;
      await this.engine_.speak(startText, this.speed);
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
      await this.engine_?.pause();
    } else if (this.isPaused) {
      await this.engine_?.resume();
    } else {
      await this.startPlay();
    }
  }

  async stopPlay(): Promise<void> {
    console.info('[Aloud] stopPlay called');
    this.stopBgTask_();
    await this.destroyAvSession_();
    if (this.engine_) {
      await this.engine_.stop();
    }
    this.isPlaying = false;
    this.isPaused = false;
    this.progress = 0;
  }

  async changeSpeed(v: number): Promise<void> {
    this.speed = v;
    if (this.engine_ && (this.isPlaying || this.isPaused)) {
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
      if (this.isPlaying || this.isPaused) {
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

    }
    .width('100%').backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
