/**
 * 目录页 — 参照 legado-with-MD3 TocScreen 实现
 *
 * 功能：
 * - 独立页面展示完整章节列表
 * - 正序/倒序切换（默认正序）
 * - 当前阅读章节高亮
 * - 点击章节跳转到对应阅读页
 * - 从 BookInfoPage 或 ReadPage 进入，返回时回到来源页
 */
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import router from '@ohos.router';

@Entry
@Component
export struct ChapterListPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State from: string = '';               // 'BookInfoPage' | 'ReadPage'
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State origin: string = '';
  @State originUrl: string = '';
  @State header: string = '';
  @State durChapterIndex: number = 0;     // 当前阅读进度
  @State bookDetailUrl: string = '';       // 原始书籍详情页 URL（用于正文加载兜底）

  // 章节数据
  @State chapters: BookSourceChapter[] = [];
  @State displayChapters: BookSourceChapter[] = [];  // 排序后的显示列表
  @State isAscending: boolean = true;      // 是否正序（默认正序）
  @State isLoading: boolean = true;
  @State showVolumes: boolean = false;      // 是否检测到卷分组

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    if (params) {
      this.from = params['from'] || '';
      this.bookName = params['bookName'] || '';
      this.bookAuthor = params['bookAuthor'] || '';
      this.bookUrl = params['bookUrl'] || '';
      this.origin = params['origin'] || '';
      this.originUrl = params['originUrl'] || '';
      this.header = params['header'] || '';
      this.durChapterIndex = parseInt(params['durChapterIndex'] || '0');
    }
    this.loadChapters();
  }

  async loadChapters(): Promise<void> {
    // 1) 优先从缓存读取
    if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
      this.chapters = ChapterCache.chapters;
      console.info('[ChapterList] Loaded', this.chapters.length, 'chapters from cache');
    } else {
      // 2) 缓存缺失，从书源获取
      console.info('[ChapterList] Cache miss, fetching from source');
      try {
        await AppDatabase.getInstance().waitForInit();
        const db = AppDatabase.getInstance().rdbStore;
        const dao = new BookSourceTable(db);
        const sources = await dao.getEnabledSources();
        let matched: BookSource | undefined;
        if (this.originUrl) {
          matched = sources.find(s => s.sourceUrl === this.originUrl) ||
            sources.find(s => s.sourceName === this.origin);
        }
        if (!matched) {
          matched = sources.find(s => s.ruleToc) || sources.find(s => s.ruleSearchUrl);
        }
        if (matched && this.bookUrl) {
          const tocChapters = await globalSourceExecutor.getToc(matched, this.bookUrl);
          if (tocChapters.length > 0) {
            this.chapters = tocChapters;
            // 更新缓存
            ChapterCache.chapters = tocChapters;
            ChapterCache.bookUrl = this.bookUrl;
            console.info('[ChapterList] Fetched', tocChapters.length, 'chapters from source');
          }
        }
      } catch (err) {
        console.warn('[ChapterList] Fetch failed:', (err as Error).message);
      }
    }
    // 调试：确认章节顺序
    if (this.chapters.length >= 2) {
      const f = this.chapters[0].title;
      const l = this.chapters[this.chapters.length - 1].title;
      console.info('[ChapterList] first:', f.substring(0, 30));
      console.info('[ChapterList] last:', l.substring(0, 30));
    }
    // 兜底检测：如果 getToc 的倒序检测未生效，在此修正
    if (this.chapters.length >= 6) {
      console.info('[ChL] order check:',
        'ch0=' + this.chapters[0].title.substring(0, 20),
        'ch1=' + this.chapters[1].title.substring(0, 20),
        'ch2=' + this.chapters[2].title.substring(0, 20),
        '... ch' + (this.chapters.length - 3) + '=' + this.chapters[this.chapters.length - 3].title.substring(0, 20),
        'ch' + (this.chapters.length - 2) + '=' + this.chapters[this.chapters.length - 2].title.substring(0, 20),
        'ch' + (this.chapters.length - 1) + '=' + this.chapters[this.chapters.length - 1].title.substring(0, 20));
    }
    this.ensureAscendingOrder();
    this.detectVolumes();
    this.applySort(this.isAscending);
    this.isLoading = false;
  }

  /** 检测卷标题：标题不含数字或含"卷"字的视为卷标题 */
  private detectVolumes(): void {
    let volumeCount = 0;
    for (const ch of this.chapters) {
      const t = ch.title.trim();
      if (t.length < 1) continue;
      const hasDigits = /\d/.test(t);
      const hasVol = /卷|部分|篇\s*$|部\s*$/.test(t);
      if ((!hasDigits && t.length <= 10) || hasVol) {
        ch.isVolume = true;
        volumeCount++;
      } else {
        ch.isVolume = false;
      }
    }
    this.showVolumes = volumeCount > 0;
    if (volumeCount > 0) console.info('[ChapterList] Detected', volumeCount, 'volumes');
  }

  /** 按章节数字强制升序排列（无数字的章节排最后） */
  ensureAscendingOrder(): void {
    if (this.chapters.length < 3) return;
    const getNum = (s: string): number => {
      const m = s.match(/(\d+)/);
      return m ? parseInt(m[1]) : -1;
    };
    // 等距取 20 个采样点，统计趋势
    let ascCount = 0, descCount = 0;
    const sampleCount = Math.min(20, this.chapters.length);
    const step = Math.floor(this.chapters.length / sampleCount);
    let prevNum = -1;
    for (let i = 0; i < this.chapters.length; i += step) {
      const n = getNum(this.chapters[i].title);
      if (n > 0 && prevNum > 0) {
        if (n > prevNum) ascCount++;
        else if (n < prevNum) descCount++;
      }
      if (n > 0) prevNum = n;
    }
    const rev = descCount > ascCount;
    console.info('[ChapterList] trend: asc=' + ascCount + ' desc=' + descCount + ' rev=' + rev);
    if (!rev) return;
    console.info('[ChapterList] sorting ' + this.chapters.length + ' chapters');
    const nums: number[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      nums.push(getNum(this.chapters[i].title));
    }
    for (let i = 0; i < this.chapters.length - 1; i++) {
      let minIdx = i;
      for (let j = i + 1; j < this.chapters.length; j++) {
        if (nums[j] >= 0 && (nums[minIdx] < 0 || nums[j] < nums[minIdx])) {
          minIdx = j;
        }
      }
      if (minIdx !== i) {
        const tmpCh = this.chapters[i]; this.chapters[i] = this.chapters[minIdx]; this.chapters[minIdx] = tmpCh;
        const tmpN = nums[i]; nums[i] = nums[minIdx]; nums[minIdx] = tmpN;
      }
    }
    // 排序后重新分配 index，使 ch.index 与数组位置一致
    for (let i = 0; i < this.chapters.length; i++) {
      this.chapters[i].index = i;
    }
  }

  /** 排序 */
  applySort(ascending: boolean): void {
    this.isAscending = ascending;
    const sorted = [...this.chapters];
    if (!ascending) {
      sorted.reverse();
    }
    this.displayChapters = sorted;
  }

  toggleSort(): void {
    this.applySort(!this.isAscending);
  }

  /** 点击章节跳转到阅读页 */
  onChapterClick(ch: BookSourceChapter): void {
    console.info('[ChapterList] Select chapter:', ch.index, ch.title);
    // 将当前章节列表缓存给 ReadPage 用
    ChapterCache.chapters = this.chapters;
    ChapterCache.bookUrl = this.bookUrl;
    if (this.from === 'ReadPage') {
      // 从阅读页进来的 → router.back 回到阅读页并传参
      router.back({
        url: 'pages/ReadPage',
        params: {
          durChapterIndex: ch.index,
          durChapterTitle: ch.title,
        }
      });
    } else {
      // 从其他页（如 BookInfoPage）进来的 → router.pushUrl 跳转到阅读页
      router.pushUrl({
        url: 'pages/ReadPage',
        params: {
          bookName: this.bookName,
          bookAuthor: this.bookAuthor,
          bookUrl: this.bookUrl,
          originUrl: this.originUrl,
          header: this.header,
          durChapterIndex: ch.index,
          durChapterTitle: ch.title,
        }
      });
    }
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Button() { Text('←').fontSize(18) }
          .width(40).height(40).backgroundColor('transparent')
          .onClick(() => { router.back(); })
        Text('目录').fontSize(16).fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
        Text('- ' + this.bookName).fontSize(14).fontColor(this.isDark ? '#AAA' : '#888')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).margin({ left: 4 })
        // 排序切换按钮
        Button() {
          Row() {
            Text(this.isAscending ? '↑' : '↓').fontSize(14)
            Text(this.isAscending ? '正序' : '倒序').fontSize(12)
              .fontColor(this.isDark ? '#CCC' : '#333')
          }.alignItems(VerticalAlign.Center)
        }
        .height(36).borderRadius(18)
        .backgroundColor(this.isDark ? '#333' : '#EEE')
        .padding({ left: 12, right: 12 })
        .margin({ right: 8 })
        .onClick(() => { this.toggleSort(); })
      }
      .padding({ left: 8, right: 4 }).width('100%').height(48)

      // ===== 加载中 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
      } else if (this.chapters.length === 0) {
        // ===== 空状态 =====
        Column() {
          Text('暂无目录').fontSize(16).fontColor(this.isDark ? '#AAAAAA' : '#888').margin({ top: 80 })
          Text('请确认书源支持目录获取').fontSize(13).fontColor('#AAA').margin({ top: 8 })
        }.width('100%').alignItems(HorizontalAlign.Center)
      } else {
        // ===== 章节列表 =====
        List({ space: 0 }) {
          ForEach(this.displayChapters, (ch: BookSourceChapter, idx?: number) => {
            ListItem() {
              if (ch.isVolume) {
                // 卷标题
                Row() {
                  Text(ch.title).fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor(this.isDark ? '#0078D7' : '#0078D7')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').padding({ top: 12, bottom: 12, left: 16, right: 16 })
                .backgroundColor(this.isDark ? '#1A2A3A' : '#E8F4FD')
              } else {
                Row() {
                  Text(String(ch.index + 1)).fontSize(12)
                    .fontColor(this.isDark ? '#666' : '#BBB')
                    .width(36).textAlign(TextAlign.End)
                    .margin({ right: 8 })
                  Text(ch.title).fontSize(14)
                    .fontColor(ch.index === this.durChapterIndex
                      ? '#0078D7'
                      : (this.isDark ? '#CCC' : '#444'))
                    .fontWeight(ch.index === this.durChapterIndex
                      ? FontWeight.Bold
                      : FontWeight.Normal)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%').padding({ top: 10, bottom: 10, left: 16, right: 16 })
                .backgroundColor(ch.index === this.durChapterIndex
                  ? (this.isDark ? '#1A2A3A' : '#E8F4FD')
                  : 'transparent')
              }
            }
            .onClick(() => { if (!ch.isVolume) this.onChapterClick(ch); })
          }, (ch: BookSourceChapter) => ch.index.toString())
        }
        .layoutWeight(1).width('100%')

        // ===== 底部信息 =====
        Row() {
          Text('共 ' + this.chapters.length + ' 章')
            .fontSize(12).fontColor(this.isDark ? '#888' : '#999')
          Blank()
          Text(this.isAscending ? '正序 ▲' : '倒序 ▼')
            .fontSize(12).fontColor(this.isDark ? '#888' : '#999')
            .onClick(() => { this.toggleSort(); })
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .width('100%').height(40)
        .backgroundColor(this.isDark ? '#1A1A1A' : '#F8F8F8')
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
