/**
 * 有声书阅读页。
 *
 * Android Legado 的 AudioPlayActivity 负责目录、网络音频地址解析、播放进度
 * 和上下章切换。HOS 端复用现有 AVPlayer/SourceGateway，把 qysg/Legado 返回的
 * 音频内容统一交给 AudioPlayer；文本书和漫画仍分别使用自己的阅读页。
 */
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { BookChapter } from '../model/BookChapter';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { ChapterCache } from '../util/ChapterCache';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { globalSourceGateway } from '../engine/source/SourceGateway';
import { AudioTrack, globalAudioPlayer, PlayState } from '../engine/audio/AudioPlayer';
import { globalAudioPlaybackSession } from '../service/AudioPlaybackSession';
import { QysgRuntimeHostComponent } from '../engine/qysg/QysgRuntimeManager';

// 音频地址通常是带时效的 CDN 地址，临时网络抖动时重新执行章节规则
// 比复用失败的地址更可靠。总共最多尝试 4 次，避免永久失效的书源阻塞播放。
const AUDIO_RETRY_LIMIT: number = 3;
const AUDIO_RETRY_DELAYS: number[] = [1000, 2000, 4000];

@Entry
@Component
export struct AudioReadPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State origin: string = '';
  @State originUrl: string = '';
  @State tocUrl: string = '';
  @State coverUrl: string = '';
  @State chapters: BookSourceChapter[] = [];
  @State currentIndex: number = 0;
  @State currentTitle: string = '';
  @State isLoading: boolean = true;
  @State isLoadingAudio: boolean = false;
  @State loadError: string = '';
  @State playState: PlayState = PlayState.IDLE;
  @State playPosition: number = 0;
  @State duration: number = 0;
  @State speed: number = 1;
  @State showSpeedMenu: boolean = false;

  private source_: BookSource | null = null;
  // 与 Android AudioPlayService 对齐：页面只是控制器，播放器跨页面复用。
  private player_ = globalAudioPlayer;
  private bookId_: number = 0;
  private targetIndex_: number = -1;
  private targetPosition_: number = 0;
  private lastProgressSave_: number = 0;
  private disposed_: boolean = false;
  private hostContext_: Context | null = null;
  // 章节地址获取是异步的；新选择应使之前尚未完成的请求失效，避免旧章节抢先播放。
  private chapterRequestId_: number = 0;
  // 同一章节的临时网络/播放器错误最多自动重试 AUDIO_RETRY_LIMIT 次。
  private audioRetryCount_: number = 0;

  aboutToAppear(): void {
    this.disposed_ = false;
    try {
      this.hostContext_ = UiUtil.getHostContext(this.getUIContext());
      globalAudioPlaybackSession.attach(this.hostContext_, this.player_)
        .catch((error: Error) => console.warn('[AudioReadPage] AVSession unavailable: ' + error.message));
    } catch (error) {
      console.warn('[AudioReadPage] AVSession context unavailable: ' + (error as Error).message);
    }
    // 重新进入页面时先同步跨页面播放器状态，避免正在后台播放时界面仍显示“播放”。
    this.playState = this.player_.state;
    this.playPosition = this.player_.position;
    this.duration = this.player_.duration;
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    this.bookName = String(params['bookName'] || params['name'] || '');
    this.bookAuthor = String(params['bookAuthor'] || params['author'] || '');
    this.bookUrl = String(params['bookUrl'] || '');
    this.origin = String(params['origin'] || '');
    this.originUrl = String(params['originUrl'] || '');
    this.tocUrl = String(params['tocUrl'] || '');
    this.coverUrl = String(params['coverUrl'] || '');
    if (params['bookId'] !== undefined) this.bookId_ = Number(params['bookId']);
    if (params['durChapterIndex'] !== undefined) this.targetIndex_ = Number(params['durChapterIndex']);
    if (params['durChapterPos'] !== undefined) this.targetPosition_ = Number(params['durChapterPos']);
    if (params['durCharPos'] !== undefined) this.targetPosition_ = Number(params['durCharPos']);
    this.player_.onStateChange = (state: PlayState): void => {
      globalAudioPlaybackSession.updatePlayback(state, this.player_.position, this.player_.duration, this.player_.speed);
      if (!this.disposed_) this.playState = state;
    };
    this.player_.onProgress = (current: number, total: number): void => {
      globalAudioPlaybackSession.updatePlayback(this.player_.state, current, total, this.player_.speed);
      if (this.disposed_) return;
      this.playPosition = current;
      if (total > 0) this.duration = Math.floor(total);
      // 进度写入限频，避免 timeUpdate 回调频繁触发数据库写操作。
      if (Date.now() - this.lastProgressSave_ > 5000) this.saveProgress_();
    };
    this.player_.onCompletion = (): void => {
      if (!this.disposed_) this.playNext_();
    };
    this.player_.onError = (error: string): void => {
      if (this.disposed_) return;
      // playChapter_ 的首次加载/重试会自行捕获 play() 抛出的错误；此处只
      // 处理已经播放起来后由 AVPlayer 异步上报的断流错误，避免一次失败重试两遍。
      if (this.isLoadingAudio) return;
      if (this.audioRetryCount_ >= AUDIO_RETRY_LIMIT || this.currentIndex < 0 ||
        this.currentIndex >= this.chapters.length) {
        this.isLoadingAudio = false;
        this.loadError = '音频播放失败：' + error;
        return;
      }
      this.isLoadingAudio = true;
      this.loadError = '音频播放中断，正在重新获取（1/' + AUDIO_RETRY_LIMIT + '）…';
      this.playChapter_(this.currentIndex, true).catch((retryError: Error): void => {
        console.warn('[AudioReadPage] Background audio retry failed: ' + retryError.message);
      });
    };
    this.loadBook_();
  }

  async aboutToDisappear(): Promise<void> {
    this.disposed_ = true;
    this.chapterRequestId_++;
    this.isLoadingAudio = false;
    this.saveProgress_();
    // 不主动 stop：与 Android AudioPlayService 一致，离开页面后音频仍可继续播放。
    // 下一次进入该书时会复用本页播放器状态或重新创建播放器。
  }

  onPageShow(): void {
    this.disposed_ = false;
    if (this.isLoading) return;
    // 从目录页返回时，ChapterListPage 会通过 ChapterCache 传回选中的章节。
    if (ChapterCache.targetIndex >= 0) {
      const index = ChapterCache.targetIndex;
      ChapterCache.targetIndex = -1;
      if (ChapterCache.bookUrl === this.bookUrl && ChapterCache.chapters.length > 0) {
        this.chapters = ChapterCache.chapters.slice();
      }
      if (index >= 0 && index < this.chapters.length) {
        this.currentIndex = index;
        this.currentTitle = this.chapters[index].title || '';
        this.playChapter_(index);
      }
    }
  }

  private async loadBook_(): Promise<void> {
    this.isLoading = true;
    this.loadError = '';
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      if (this.bookId_ <= 0 && this.bookUrl) {
        const stored = await new BookTable(db).getBookByUrl(this.bookUrl);
        if (stored) {
          this.bookId_ = stored.id;
          if (!this.bookName) this.bookName = stored.name;
          if (!this.bookAuthor) this.bookAuthor = stored.author;
          if (!this.origin) this.origin = stored.origin;
          if (!this.originUrl) this.originUrl = stored.originUrl;
          if (!this.tocUrl) this.tocUrl = stored.tocUrl;
          if (!this.coverUrl) this.coverUrl = stored.coverUrl;
          if (this.targetIndex_ < 0) this.targetIndex_ = stored.durChapterIndex;
          if (this.targetPosition_ <= 0) this.targetPosition_ = stored.durChapterPos;
        }
      }
      this.source_ = await BookSourceResolver.resolveByIdentity(
        this.bookId_, this.bookUrl, this.originUrl, this.origin);
      let chapters: BookSourceChapter[] = [];
      if (ChapterCache.bookUrl === this.bookUrl && ChapterCache.chapters.length > 0) {
        chapters = ChapterCache.chapters.slice();
      }
      if (chapters.length === 0 && this.bookId_ > 0) {
        const stored = await new ChapterTable(db).getChaptersByBookId(this.bookId_);
        chapters = stored.map((item: BookChapter): BookSourceChapter => ({
          title: item.title,
          url: item.url,
          index: item.index,
          isVolume: false,
          isVip: item.isVip,
          isPay: item.isPay,
          updateTime: item.chapterUpdateTime || '',
        }));
      }
      if (chapters.length === 0 && this.source_ && this.bookUrl) {
        chapters = await globalSourceGateway.getToc(this.source_, this.tocUrl || this.bookUrl, this.bookUrl);
      }
      this.chapters = chapters;
      ChapterCache.chapters = chapters;
      ChapterCache.bookUrl = this.bookUrl;
      this.currentIndex = this.resolveIndex_(this.targetIndex_);
      this.currentTitle = this.chapters[this.currentIndex]?.title || '';
      this.playPosition = Math.max(0, this.targetPosition_);
      if (!this.source_) this.loadError = '书源不存在，无法播放音频';
      else if (this.chapters.length === 0) this.loadError = '未获取到音频目录';
    } catch (error) {
      this.loadError = '加载音频目录失败：' + String(error);
    } finally {
      this.isLoading = false;
    }
  }

  private resolveIndex_(requested: number): number {
    if (this.chapters.length === 0) return 0;
    const wanted = Number.isFinite(requested) && requested >= 0 ? requested : 0;
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].index === wanted && this.chapters[i].url) return i;
    }
    for (let i = Math.min(wanted, this.chapters.length - 1); i >= 0; i--) {
      if (this.chapters[i].url) return i;
    }
    return 0;
  }

  private async playChapter_(index: number, autoRetry: boolean = false): Promise<void> {
    if (index < 0 || index >= this.chapters.length) return;
    if (!this.source_) {
      this.isLoadingAudio = false;
      this.loadError = '书源不存在，无法播放音频';
      return;
    }
    if (!autoRetry) this.audioRetryCount_ = 0;
    if (autoRetry && this.audioRetryCount_ >= AUDIO_RETRY_LIMIT) {
      this.isLoadingAudio = false;
      this.loadError = '音频播放失败，已重试 ' + AUDIO_RETRY_LIMIT + ' 次';
      return;
    }
    const requestId = ++this.chapterRequestId_;
    const chapter = this.chapters[index];
    if (!chapter.url) {
      this.playNextFrom_(index);
      return;
    }
    this.isLoadingAudio = true;
    this.loadError = '';
    let lastError: Error = new Error('未知音频错误');
    for (let attempt = 0; attempt <= AUDIO_RETRY_LIMIT; attempt++) {
      if (requestId !== this.chapterRequestId_ || this.disposed_) return;
      try {
        const result = await globalSourceGateway.getContentResult(this.source_, chapter.url, this.bookUrl);
        if (requestId !== this.chapterRequestId_ || this.disposed_) return;
        const audioUrl = (result.raw || '').trim();
        if (!audioUrl) throw new Error('书源没有返回音频地址');
        const track: AudioTrack = {
          title: chapter.title || ('第' + (index + 1) + '章'),
          artist: this.bookAuthor || this.bookName,
          url: audioUrl,
          duration: 0,
          coverUrl: this.coverUrl,
        };
        globalAudioPlaybackSession.setTrack(track);
        if (requestId !== this.chapterRequestId_ || this.disposed_) return;
        // 播放前先申请 UIAbility 级连续任务，避免息屏恰好发生在 prepare/play
        // 的异步窗口内；任务由全局媒体会话持有，离开阅读页后仍有效。
        if (this.hostContext_) {
          await globalAudioPlaybackSession.startBackgroundTask(this.hostContext_);
        }
        if (requestId !== this.chapterRequestId_ || this.disposed_) {
          // 若是离开页面导致请求失效，播放尚未开始，不能留下孤儿连续任务；
          // 同页切换章节则交给新请求复用任务，避免误停新章节。
          if (this.disposed_) await globalAudioPlaybackSession.stopBackgroundTask();
          return;
        }
        await this.player_.play(track);
        if (requestId !== this.chapterRequestId_ || this.disposed_) return;
        this.currentIndex = index;
        this.currentTitle = track.title;
        this.playPosition = 0;
        this.duration = 0;
        this.isLoadingAudio = false;
        this.audioRetryCount_ = 0;
        // 清除之前重试过程中显示的红色失败提示，避免成功播放后仍残留错误文案。
        this.loadError = '';
        this.saveProgress_();
        return;
      } catch (error) {
        lastError = error as Error;
        if (requestId !== this.chapterRequestId_ || this.disposed_) return;
        if (attempt >= AUDIO_RETRY_LIMIT) break;
        this.audioRetryCount_ = Math.min(AUDIO_RETRY_LIMIT, this.audioRetryCount_ + 1);
        const delayMs = AUDIO_RETRY_DELAYS[Math.min(this.audioRetryCount_ - 1, AUDIO_RETRY_DELAYS.length - 1)];
        this.loadError = '获取音频失败，' + Math.ceil(delayMs / 1000) + '秒后重试（' +
          this.audioRetryCount_ + '/' + AUDIO_RETRY_LIMIT + '）…';
        console.warn('[AudioReadPage] Audio attempt ' + (attempt + 1) + ' failed, retrying: ' +
          String(error));
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, delayMs); });
      }
    }
    if (requestId !== this.chapterRequestId_ || this.disposed_) return;
    // 获取地址失败时可能仍在播放上一章，不能因为本次请求失败误停旧任务；
    // 只有播放器已不在播放态时才清理本次可能残留的任务。
    if (this.player_.state !== PlayState.PLAYING && this.player_.state !== PlayState.PAUSED) {
      await globalAudioPlaybackSession.stopBackgroundTask();
    }
    this.isLoadingAudio = false;
    this.loadError = '获取音频失败：' + String(lastError);
  }

  private playNextFrom_(index: number): void {
    for (let i = index + 1; i < this.chapters.length; i++) {
      if (this.chapters[i].url) {
        this.playChapter_(i);
        return;
      }
    }
    this.playState = PlayState.STOPPED;
  }

  private playNext_(): void {
    this.playNextFrom_(this.currentIndex);
  }

  private playPrev_(): void {
    for (let i = this.currentIndex - 1; i >= 0; i--) {
      if (this.chapters[i].url) {
        this.playChapter_(i);
        return;
      }
    }
  }

  private async togglePlay_(): Promise<void> {
    if (this.playState === PlayState.PLAYING) {
      await this.player_.pause();
      await globalAudioPlaybackSession.stopBackgroundTask();
    } else if (this.playState === PlayState.PAUSED) {
      if (this.hostContext_) {
        await globalAudioPlaybackSession.startBackgroundTask(this.hostContext_);
      }
      await this.player_.resume();
    } else {
      await this.playChapter_(this.currentIndex);
    }
  }

  private saveProgress_(): void {
    if (!this.bookUrl || this.chapters.length === 0) return;
    this.lastProgressSave_ = Date.now();
    const chapter = this.chapters[this.currentIndex];
    if (!chapter) return;
    try {
      new BookTable(AppDatabase.getInstance().rdbStore).updateReadingProgress(
        this.bookUrl, chapter.index, chapter.title || '', this.chapters.length, this.playPosition).catch(() => {});
    } catch (_e) { /* 数据库尚未初始化时忽略 */ }
  }

  private formatTime_(seconds: number): string {
    const value = Math.max(0, Math.floor(seconds || 0));
    const min = Math.floor(value / 60);
    const sec = String(value % 60).padStart(2, '0');
    return min + ':' + sec;
  }

  private displayCover_(): string {
    const raw = (this.coverUrl || '').trim();
    const comma = raw.lastIndexOf(',');
    if (comma > 0 && raw.substring(comma + 1).trim().startsWith('{')) return raw.substring(0, comma);
    return raw;
  }

  private openToc_(): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/ChapterListPage',
      params: {
        from: 'AudioReadPage', bookName: this.bookName, bookAuthor: this.bookAuthor,
        bookUrl: this.bookUrl, origin: this.origin, originUrl: this.originUrl,
        tocUrl: this.tocUrl, durChapterIndex: this.currentIndex,
        isAudio: '1', isManga: '0'
      }
    });
  }

  private setSpeed_(value: number): void {
    this.speed = value;
    this.player_.setSpeed(value);
    this.showSpeedMenu = false;
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Button('‹').fontSize(34).fontColor(ThemeColors.onBackground(this.isDark))
            .backgroundColor(Color.Transparent).width(48).height(48)
            .onClick(() => UiUtil.back(this.getUIContext()));
          Text(this.bookName || '有声书').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1).maxLines(1);
          Button('目录').fontSize(14).fontColor(ThemeColors.primary(this.isDark))
            .backgroundColor(Color.Transparent).onClick(() => this.openToc_());
        }
        .width('100%').height(64).padding({ left: 8, right: 8 })
        .backgroundColor(ThemeColors.surface(this.isDark));

        Scroll() {
          Column() {
            if (this.displayCover_()) {
              Image(this.displayCover_()).width(180).height(180).objectFit(ImageFit.Cover)
                .borderRadius(12).margin({ top: 28, bottom: 14 });
            } else {
              Text('🎧').fontSize(96).margin({ top: 38, bottom: 26 });
            }
            Text(this.currentTitle || '请选择章节').fontSize(21).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.onBackground(this.isDark)).maxLines(2).textAlign(TextAlign.Center)
              .padding({ left: 20, right: 20 });
            Text(this.bookAuthor || this.origin || '').fontSize(14)
              .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8, bottom: 20 });

            Slider({ value: this.playPosition, min: 0, max: Math.max(1, this.duration), step: 1 })
              .width('86%')
              .onChange((value: number): void => {
                this.playPosition = value;
                this.player_.seek(value * 1000);
              });
            Row() {
              Text(this.formatTime_(this.playPosition)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark));
              Blank();
              Text(this.formatTime_(this.duration)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark));
            }.width('86%');

            Row() {
              Button('上一章').fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).onClick(() => this.playPrev_());
              Button(this.isLoadingAudio ? '加载中' : (this.playState === PlayState.PLAYING ? '暂停' : '播放'))
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onPrimary(this.isDark))
                .backgroundColor(ThemeColors.primary(this.isDark)).width(110).height(52)
                .borderRadius(26).enabled(!this.isLoadingAudio).onClick(() => this.togglePlay_());
              Button('下一章').fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).onClick(() => this.playNext_());
            }.width('100%').justifyContent(FlexAlign.SpaceEvenly).margin({ top: 18 });

            Row() {
              Text('倍速').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark));
              Button(this.speed.toFixed(2) + 'x').fontSize(14).fontColor(ThemeColors.primary(this.isDark))
                .backgroundColor(Color.Transparent).onClick(() => { this.showSpeedMenu = !this.showSpeedMenu; });
            }.margin({ top: 16 });
            if (this.showSpeedMenu) {
              Row() {
                ForEach([0.75, 1, 1.25, 1.5, 2], (value: number) => {
                  Button(value.toFixed(2) + 'x').fontSize(12)
                    .fontColor(this.speed === value ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                    .backgroundColor(this.speed === value ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                    .margin({ left: 3, right: 3 }).onClick(() => this.setSpeed_(value));
                }, (value: number) => String(value));
              }.margin({ top: 4 });
            }

            if (this.loadError) {
              Text(this.loadError).fontSize(14).fontColor(ThemeColors.error(this.isDark))
                .margin({ top: 18, left: 20, right: 20 }).textAlign(TextAlign.Center);
            }
            Text('章节 ' + (this.chapters.length > 0 ? (this.currentIndex + 1) : 0) + ' / ' + this.chapters.length)
              .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 12, bottom: 10 });
            List() {
              ForEach(this.chapters, (chapter: BookSourceChapter, index: number) => {
                ListItem() {
                  Row() {
                    Text(String(index + 1)).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width(34);
                    Text(chapter.title || ('第' + (index + 1) + '章')).fontSize(15)
                      .fontColor(index === this.currentIndex ? ThemeColors.primary(this.isDark) : ThemeColors.onBackground(this.isDark))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
                    if (!chapter.url) Text('卷').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark));
                  }
                  .width('100%').padding({ left: 20, right: 20, top: 13, bottom: 13 })
                  .backgroundColor(index === this.currentIndex ? ThemeColors.surfaceVariant(this.isDark) : Color.Transparent)
                  .onClick(() => { if (chapter.url) this.playChapter_(index); });
                }
              }, (chapter: BookSourceChapter, index: number) => String(chapter.index) + '-' + index);
            }.width('100%').divider({ strokeWidth: 0.5, color: ThemeColors.outlineVariant(this.isDark) });
          }.width('100%').padding({ bottom: 36 });
        }.layoutWeight(1).width('100%').scrollable(ScrollDirection.Vertical);
      }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark));
      if (this.isLoading) {
        Column() {
          LoadingProgress().color(ThemeColors.primary(this.isDark));
          Text('正在加载音频目录…').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 12 });
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(ThemeColors.background(this.isDark));
      }
      QysgRuntimeHostComponent();
    }.width('100%').height('100%');
  }
}
