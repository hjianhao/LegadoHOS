/**
 * 缓存章节对话框 — 选择起始/结束章节，触发下载
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { ChapterTable } from '../../data/database/ChapterTable';
import { BookTable } from '../../data/database/BookTable';
import { BookChapter } from '../../model/BookChapter';
import { BookSource } from '../../model/BookSource';
import { BookSourceChapter } from '../../model/BookSource';
import { globalSourceExecutor } from '../../engine/source/SourceExecutor';
import promptAction from '@ohos.promptAction';
import notification from '@ohos.notification';
import { notificationManager } from '@kit.NotificationKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';

@Component
export struct CacheDialog {
  @StorageLink('isDark') isDark: boolean = false;
  @State startChapter: string = '';
  @State endChapter: string = '';
  @State isCaching: boolean = false;
  @State progressText: string = '';
  @State progressPercent: number = 0;
  @State showProgress: boolean = false;

  /** 外部传入的书籍信息 */
  bookName: string = '';
  bookOriginUrl: string = '';
  bookId: number = -1;
  source: BookSource | null = null;
  chapters: Object[] = [];
  totalChapters: number = 0;
  currentIndex: number = 0;

  onDismiss?: () => void;
  /** 缓存完成后的回调 */
  onCacheComplete?: () => void;
  /** 缓存开始时的回调 */
  onCacheStart?: () => void;
  /** 是否从后台重新打开（直接显示进度） */
  showProgressImmediate: boolean = false;

  /** 通知 ID（用于后台进度） */
  private notifId_: number = 1001;

  aboutToAppear(): void {
    // 默认值：当前章 → 最后一章
    this.startChapter = String(this.currentIndex + 1);
    this.endChapter = String(this.totalChapters);
    // 如果是从后台重新打开（缓存进行中），直接显示进度
    if (this.showProgressImmediate && this.isCaching) {
      this.showProgress = true;
    }
  }

  build() {
    Column() {
      if (!this.showProgress) {
        this.buildInputPanel()
      } else {
        this.buildProgressPanel()
      }
    }
    .width('100%')
    .backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  buildInputPanel() {
    Column() {
      Text('离线缓存').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#E0E0E0' : '#1A1A2E')
        .padding({ top: 16, left: 16, bottom: 4 }).alignSelf(ItemAlign.Start)

      Text('将章节内容下载到本地，离线阅读')
        .fontSize(13).fontColor(this.isDark ? '#AAAAAA' : '#888')
        .padding({ left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 章节范围
      Row() {
        Text('起始章节').fontSize(14).fontColor(this.isDark ? '#E0E0E0' : '#333').width(80)
        TextInput({ placeholder: '1', text: this.startChapter })
          .width(80).height(36)
          .fontSize(14)
          .backgroundColor(this.isDark ? '#444' : '#F5F5F5')
          .onChange((v: string) => { this.startChapter = v; })
      }.padding({ left: 16, right: 16, bottom: 10 }).width('100%')

      Row() {
        Text('结束章节').fontSize(14).fontColor(this.isDark ? '#E0E0E0' : '#333').width(80)
        TextInput({ placeholder: String(this.totalChapters), text: this.endChapter })
          .width(80).height(36)
          .fontSize(14)
          .backgroundColor(this.isDark ? '#444' : '#F5F5F5')
          .onChange((v: string) => { this.endChapter = v; })
      }.padding({ left: 16, right: 16, bottom: 16 }).width('100%')

      Text('共 ' + this.totalChapters + ' 章，当前第 ' + (this.currentIndex + 1) + ' 章')
        .fontSize(12).fontColor(this.isDark ? '#AAAAAA' : '#888')
        .padding({ left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 按钮
      Row() {
        Button('取消').fontSize(15).fontColor(this.isDark ? '#CCCCCC' : '#666')
          .backgroundColor(Color.Transparent)
          .height(44).layoutWeight(1)
          .onClick(() => { this.onDismiss?.(); })
        Button('开始缓存').fontSize(15).fontColor('#FFF')
          .backgroundColor('#0078D7')
          .height(44).layoutWeight(1).borderRadius(0)
          .onClick(() => { this.startCache(); })
      }.width('100%').height(48)
    }
  }

  @Builder
  buildProgressPanel() {
    Column() {
      Text('正在缓存...').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#E0E0E0' : '#1A1A2E')
        .padding({ top: 16, left: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      Text(this.progressText)
        .fontSize(13).fontColor(this.isDark ? '#CCCCCC' : '#666')
        .padding({ left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      // 进度条
      Row() {
        Column().width(this.progressPercent + '%').height(6).backgroundColor('#0078D7').borderRadius(3)
          .alignSelf(ItemAlign.Start)
      }.width('100%').height(6).backgroundColor(this.isDark ? '#444' : '#EEE').borderRadius(3)
      .padding({ left: 0, right: 0 })

      Row() {
        Button('取消缓存').fontSize(14).fontColor('#FFF')
          .backgroundColor('#F44336').height(40).layoutWeight(1).margin({ right: 4 })
          .onClick(() => { this.stopCaching(); })
        Button('后台运行').fontSize(14).fontColor('#FFF')
          .backgroundColor('#0078D7').height(40).layoutWeight(1).margin({ left: 4 })
          .onClick(() => { this.runInBackground(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 12 })
    }
  }

  /** 停止缓存并关闭面板 */
  private stopCaching(): void {
    this.isCaching = false;
    this.stopBgTask();
    this.cancelNotif();
    this.onDismiss?.();
  }

  /** 后台运行：关闭面板，在通知栏显示进度 */
  private runInBackground(): void {
    this.onDismiss?.();
    this.publishNotif(this.progressPercent, this.totalChapters);
  }

  /** 发布/更新通知进度 */
  private publishNotif(progress: number, total: number): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: this.notifId_,
        content: {
          contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '离线缓存',
            text: '已缓存 ' + progress + '/' + total + ' 章',
          },
        },
      };
      notificationManager.publish(request, (err: Error) => {
        if (err) console.warn('[Cache] notif error:', err.message);
      });
    } catch (e) {
      console.warn('[Cache] notif error:', (e as Error).message);
    }
  }

  /** 取消通知 */
  private cancelNotif(): void {
    notificationManager.cancel(this.notifId_, (err: Error) => {
      if (err) console.warn('[Cache] cancel notif error:', err.message);
    });
  }

  private async startCache(): Promise<void> {
    const start = parseInt(this.startChapter) || 1;
    const end = parseInt(this.endChapter) || this.totalChapters;
    if (start < 1 || end > this.totalChapters || start > end) {
      promptAction.showToast({ message: '章节范围无效', duration: 1500 });
      return;
    }
    if (!this.source) {
      promptAction.showToast({ message: '书源不可用', duration: 1500 });
      return;
    }
    const startIdx = start - 1;
    const endIdx = end - 1;
    const totalCh = endIdx - startIdx + 1;

    this.showProgress = true;
    this.isCaching = true;
    let completed = 0;

    // 通知父组件缓存已开始
    this.onCacheStart?.();

    // 启动后台任务，防止熄屏/切后台时暂停
    this.startBgTask();

    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const chapterTable = new ChapterTable(db);
      const bookTable = new BookTable(db);
      let bookId = this.bookId;
      if (bookId <= 0 && this.bookOriginUrl) {
        const bookByUrl = await bookTable.getBookByUrl(this.bookOriginUrl);
        if (bookByUrl) bookId = bookByUrl.id;
      }
      if (bookId <= 0) {
        const book = await bookTable.getBookByName(this.bookName, '');
        if (book) bookId = book.id;
      }

      for (let idx = startIdx; idx <= endIdx; idx++) {
        if (!this.isCaching) break; // 允许取消
        const ch = this.chapters[idx] as BookSourceChapter;

        // 检查是否已缓存（跳过已有的）
        const existing = await chapterTable.getChapterByIndex(bookId, idx);
        if (existing && (existing.isCached || existing.isDownloaded)) {
          completed++;
          this.progressPercent = Math.round((completed / totalCh) * 100);
          this.progressText = '第 ' + (idx + 1) + ' 章已存在，跳过';
          this.publishNotif(completed, totalCh);
          continue;
        }

        this.progressText = '正在缓存第 ' + (idx + 1) + ' 章: ' + (ch.title || '');
        console.info('[Cache] Downloading chapter ' + (idx + 1) + ': ' + ch.title);

        try {
          // 从书源获取内容
          const content = await globalSourceExecutor.getContent(
            this.source!, ch.url, this.bookOriginUrl);
          if (content && content.length > 10) {
            const now = Date.now();
            if (existing) {
              existing.content = content;
              existing.contentLength = content.length;
              existing.isDownloaded = true;
              existing.isCached = true;
              existing.updateTime = now;
              await chapterTable.updateChapter(existing);
            } else {
              const newCh: BookChapter = {
                id: 0, bookId: bookId, index: idx, volumeIndex: 0,
                title: ch.title || '', url: ch.url || '',
                content: content, contentLength: content.length,
                isRead: false, isDownloaded: true, isCached: true,
                duration: 0, audioUrl: '',
                createTime: now, updateTime: now,
              };
              await chapterTable.insertChapters([newCh]);
            }
          }
        } catch (err) {
          console.warn('[Cache] Failed chapter ' + (idx + 1) + ': ' + (err as Error).message);
        }

        completed++;
        this.progressPercent = Math.round((completed / totalCh) * 100);
        // 后台运行时更新通知进度
        this.publishNotif(completed, totalCh);
      }

      this.progressText = '缓存完成！共 ' + completed + ' 章';
      // 更新通知为完成状态
      this.publishNotif(completed, totalCh);
      promptAction.showToast({ message: '缓存完成: ' + completed + ' 章', duration: 2000 });
      this.onCacheComplete?.();
    } catch (err) {
      this.progressText = '缓存出错: ' + (err as Error).message;
    }
    this.isCaching = false;
    this.stopBgTask();
  }

  /** 后台任务管理 */
  private bgTaskActive_: boolean = false;

  private async startBgTask(): Promise<void> {
    if (this.bgTaskActive_) return;
    try {
      const want = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'io.legado.hos', abilityName: 'MainAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
      });
      await backgroundTaskManager.startBackgroundRunning(
        getContext(), ['dataTransfer'], want);
      this.bgTaskActive_ = true;
      console.info('[Cache] bg task started');
    } catch (e) {
      console.warn('[Cache] bg task fail:', JSON.stringify(e));
    }
  }

  private async stopBgTask(): Promise<void> {
    if (!this.bgTaskActive_) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext());
      this.bgTaskActive_ = false;
      console.info('[Cache] bg task stopped');
    } catch (e) {
      console.warn('[Cache] stopBgTask fail:', JSON.stringify(e));
    }
  }
}
