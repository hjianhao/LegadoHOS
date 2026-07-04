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
import { UiUtil } from '../util/UiUtil';

/** PERF-001: LazyForEach IDataSource — 章节数据源 */
class ChapterDataSource implements IDataSource {
  private chapters_: BookSourceChapter[] = [];
  private listeners_: DataChangeListener[] = [];

  totalCount(): number {
    return this.chapters_.length;
  }

  getData(index: number): BookSourceChapter {
    return this.chapters_[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    const found = this.listeners_.find(l => l === listener);
    if (!found) {
      this.listeners_.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners_.indexOf(listener);
    if (idx !== -1) {
      this.listeners_.splice(idx, 1);
    }
  }

  setChapters(chapters: BookSourceChapter[]): void {
    this.chapters_ = chapters;
    for (const l of this.listeners_) {
      l.onDataReloaded();
    }
  }

  getChapter(index: number): BookSourceChapter {
    return this.chapters_[index];
  }
}

@Entry
@Component
struct ChapterListPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State from: string = '';               // 'BookInfoPage' | 'ReadPage'
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State origin: string = '';
  @State originUrl: string = '';
  @State header: string = '';
  @State tocUrl: string = '';
  @State durChapterIndex: number = 0;     // 当前阅读进度
  @State bookDetailUrl: string = '';       // 原始书籍详情页 URL（用于正文加载兜底）

  // 章节数据 — 使用 LazyForEach IDataSource 以支持 2000+ 章节流畅滚动
  private dataSource_: ChapterDataSource = new ChapterDataSource();

  // 保留原始数组用于排序等操作
  private chapters_: BookSourceChapter[] = [];
  @State isAscending: boolean = true;      // 是否正序（默认正序）
  @State isLoading: boolean = true;
  @State showVolumes: boolean = false;      // 是否检测到卷分组

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    if (params) {
      this.from = params['from'] || '';
      this.bookName = params['bookName'] || '';
      this.bookAuthor = params['bookAuthor'] || '';
      this.bookUrl = params['bookUrl'] || '';
      this.origin = params['origin'] || '';
      this.originUrl = params['originUrl'] || '';
      this.header = params['header'] || '';
      this.tocUrl = params['tocUrl'] || '';
      this.durChapterIndex = parseInt(params['durChapterIndex'] || '0');
    }
    this.loadChapters();
  }

  async loadChapters(): Promise<void> {
    // 1) 优先从缓存读取
    if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
      this.chapters_ = ChapterCache.chapters;
      console.info('[ChapterList] Loaded', this.chapters_.length, 'chapters from cache');
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
          const tocChapters = await globalSourceExecutor.getToc(matched, this.tocUrl || this.bookUrl);
          if (tocChapters.length > 0) {
            this.chapters_ = tocChapters;
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
    if (this.chapters_.length >= 2) {
      const f = this.chapters_[0].title;
      const l = this.chapters_[this.chapters_.length - 1].title;
      console.info('[ChapterList] first:', f.substring(0, 30));
      console.info('[ChapterList] last:', l.substring(0, 30));
    }
    // 兜底检测：如果 getToc 的倒序检测未生效，在此修正
    if (this.chapters_.length >= 6) {
      console.info('[ChL] order check:',
        'ch0=' + this.chapters_[0].title.substring(0, 20),
        'ch1=' + this.chapters_[1].title.substring(0, 20),
        'ch2=' + this.chapters_[2].title.substring(0, 20),
        '... ch' + (this.chapters_.length - 3) + '=' + this.chapters_[this.chapters_.length - 3].title.substring(0, 20),
        'ch' + (this.chapters_.length - 2) + '=' + this.chapters_[this.chapters_.length - 2].title.substring(0, 20),
        'ch' + (this.chapters_.length - 1) + '=' + this.chapters_[this.chapters_.length - 1].title.substring(0, 20));
    }
    this.ensureAscendingOrder();
    this.detectVolumes();
    this.applySort(this.isAscending);
    this.isLoading = false;
  }

  /** 检测卷标题：仅包含明确卷关键词的视为卷标题（不再基于长度/数字推断） */
  private detectVolumes(): void {
    let volumeCount = 0;
    for (const ch of this.chapters_) {
      const t = ch.title.trim();
      if (t.length < 1) continue;
      // 仅包含明确的卷/篇/部关键词才视为卷标题
      const hasVol = /^第[零一二三四五六七八九十百千万\d]+卷/.test(t) ||
                     /^第[零一二三四五六七八九十百千万\d]+[篇部]/.test(t) ||
                     /^[卷篇部]\s*\d+/.test(t) ||
                     /^\s*第[零一二三四五六七八九十百千万\d]+\s*卷/.test(t);
      if (hasVol) {
        ch.isVolume = true;
        volumeCount++;
      }
    }
    this.showVolumes = volumeCount > 0;
    if (volumeCount > 0) console.info('[ChapterList] Detected', volumeCount, 'volumes');
  }

  /** 确保目录排序正确（依赖 getToc 已排序，仅做最终兜底反转） */
  ensureAscendingOrder(): void {
    if (this.chapters_.length < 3) return;
    const cnNumMap: Record<string, number> = {
      '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
      '十': 10, '百': 100, '千': 1000, '万': 10000,
    };
    const extractNum = (s: string): number => {
      const arabicM = s.match(/(\d+)/);
      if (arabicM) return parseInt(arabicM[1]);
      const cnM = s.match(/第([零一二三四五六七八九十百千万]+)章/);
      if (cnM) {
        let cn = cnM[1];
        let result = 0;
        let section = 0;
        for (let i = 0; i < cn.length; i++) {
          const nv = cnNumMap[cn.charAt(i)];
          if (nv === undefined) continue;
          if (nv >= 10) {
            section = (section || 1) * nv;
            result += section;
            section = 0;
          } else {
            section = nv;
          }
        }
        result += section;
        return result > 0 ? result : -1;
      }
      return -1;
    };
    // 等距采样20个点，如果多数递减则反转（兜底 getToc 未处理的场景）
    let ascCount = 0, descCount = 0;
    const sampleCount = Math.min(20, this.chapters_.length);
    const step = Math.max(1, Math.floor(this.chapters_.length / sampleCount));
    let prevNum = -1;
    for (let i = 0; i < this.chapters_.length; i += step) {
      const n = extractNum(this.chapters_[i].title);
      if (n > 0 && prevNum > 0) {
        if (n > prevNum) ascCount++;
        else if (n < prevNum) descCount++;
      }
      if (n > 0) prevNum = n;
    }
    const rev = descCount > ascCount;
    console.info('[ChapterList] trend: asc=' + ascCount + ' desc=' + descCount + ' rev=' + rev);
    if (!rev) return;
    console.info('[ChapterList] sorting ' + this.chapters_.length + ' chapters');
    // STATE-002: build new array instead of in-place reverse + element-by-element mutation
    const reordered: BookSourceChapter[] = [];
    for (let i = this.chapters_.length - 1; i >= 0; i--) {
      const src = this.chapters_[i];
      reordered.push({
        title: src.title,
        url: src.url,
        index: reordered.length,
        isVolume: src.isVolume
      });
    }
    this.chapters_ = reordered;
  }

  /** 排序 */
  applySort(ascending: boolean): void {
    this.isAscending = ascending;
    // STATE-002: use new array instead of in-place reverse
    const sorted: BookSourceChapter[] = [];
    if (ascending) {
      for (let i = 0; i < this.chapters_.length; i++) {
        sorted.push(this.chapters_[i]);
      }
    } else {
      for (let i = this.chapters_.length - 1; i >= 0; i--) {
        sorted.push(this.chapters_[i]);
      }
    }
    this.dataSource_.setChapters(sorted);
  }

  toggleSort(): void {
    this.applySort(!this.isAscending);
  }

  /** 点击章节跳转到阅读页 */
  onChapterClick(ch: BookSourceChapter): void {
    console.info('[ChapterList] Select chapter:', ch.index, ch.title);
    // 将当前章节列表缓存给 ReadPage 用
    ChapterCache.chapters = this.chapters_;
    ChapterCache.bookUrl = this.bookUrl;
    ChapterCache.targetIndex = ch.index;
    if (this.from === 'ReadPage') {
      // 从阅读页进来的 → router.back 回到阅读页并传参
      UiUtil.back(this.getUIContext(), {
        url: 'pages/ReadPage',
        params: {
          durChapterIndex: ch.index,
          durChapterTitle: ch.title,
        }
      });
    } else {
      // 从其他页（如 BookInfoPage）进来的 → router.pushUrl 跳转到阅读页
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/ReadPage',
        params: {
          bookName: this.bookName,
          bookAuthor: this.bookAuthor,
          bookUrl: this.bookUrl,
          tocUrl: this.tocUrl,
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
          .onClick(() => { UiUtil.back(this.getUIContext()); })
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
      } else if (this.chapters_.length === 0) {
        // ===== 空状态 =====
        Column() {
          Text('暂无目录').fontSize(16).fontColor(this.isDark ? '#AAAAAA' : '#888').margin({ top: 80 })
          Text('请确认书源支持目录获取').fontSize(13).fontColor('#AAA').margin({ top: 8 })
        }.width('100%').alignItems(HorizontalAlign.Center)
      } else {
        // ===== 章节列表 — PERF-001 使用 LazyForEach 替代 ForEach =====
        List({ space: 0 }) {
          LazyForEach(this.dataSource_, (ch: BookSourceChapter, idx: number) => {
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
        .cachedCount(5)

        // ===== 底部信息 =====
        Row() {
          Text('共 ' + this.chapters_.length + ' 章')
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
