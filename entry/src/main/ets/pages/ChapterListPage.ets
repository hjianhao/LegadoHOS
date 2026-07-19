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
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookmarkTable } from '../data/database/BookmarkTable';
import { Bookmark } from '../model/Bookmark';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { ChapterCache } from '../util/ChapterCache';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { BookSourceResolver } from '../service/BookSourceResolver';

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

  /** 单项刷新（勾选状态变化时触发该行重建） */
  notifyItem(position: number): void {
    for (const l of this.listeners_) {
      l.onDataChange(position);
    }
  }

  /** 全量刷新（进入/退出多选模式、全选/反选时） */
  notifyAll(): void {
    for (const l of this.listeners_) {
      l.onDataReloaded();
    }
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
  @State isManga: boolean = false;         // 是否为漫画书源

  // 章节数据 — 使用 LazyForEach IDataSource 以支持 2000+ 章节流畅滚动
  private dataSource_: ChapterDataSource = new ChapterDataSource();

  // 保留原始数组用于排序等操作
  private chapters_: BookSourceChapter[] = [];
  @State isAscending: boolean = true;      // 是否正序（默认正序）
  @State isLoading: boolean = true;
  @State showVolumes: boolean = false;      // 是否检测到卷分组
  @State selectMode: boolean = false;       // 多选缓存模式
  @State selectedIndices: number[] = [];    // 已选章节索引（原 index 语义）
  @State cacheStarting: boolean = false;    // 缓存任务启动中（防重复点击）
  private listScroller_: Scroller = new Scroller();

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
      this.isManga = params['isManga'] === '1';
    }
    this.loadChapters();
  }

  async loadChapters(): Promise<void> {
    // 1) 优先从缓存读取
    if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
      this.chapters_ = ChapterCache.chapters;
      console.info('[ChapterList] Loaded', this.chapters_.length, 'chapters from cache');
    } else {
      // 2) 内存缓存缺失时优先读取已落库目录（AI 导入只保存目录）。
      console.info('[ChapterList] Memory cache miss, loading DB/source');
      try {
        await AppDatabase.getInstance().waitForInit();
        const db = AppDatabase.getInstance().rdbStore;
        const bookId = await this.resolveBookId_();
        if (bookId > 0) {
          const stored = await new ChapterTable(db).getChaptersByBookId(bookId);
          if (stored.length > 0) {
            this.chapters_ = stored.map((chapter): BookSourceChapter => ({
              index: chapter.index, title: chapter.title, url: chapter.url,
            }));
            ChapterCache.chapters = this.chapters_;
            ChapterCache.bookUrl = this.bookUrl;
          }
        }
        const matched = this.chapters_.length === 0
          ? await BookSourceResolver.resolveByIdentity(bookId, this.bookUrl, this.originUrl, this.origin) : null;
        if (matched && this.bookUrl && this.chapters_.length === 0) {
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
    setTimeout(() => { this.listScroller_.scrollToIndex(this.durChapterIndex); }, 0);
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
    // 本地书按 spine 顺序排列，无需自动反转
    if (this.origin === '本地') return;
    const cnNumMap: Record<string, number> = {
      '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
      '十': 10, '百': 100, '千': 1000, '万': 10000,
    };
    const extractNum = (s: string): number => {
      const arabicM = s.match(/(\d+)/);
      if (arabicM) return parseInt(arabicM[1]);
      const cnM = s.match(/第([零一二三四五六七八九十百千万]+)[章节局话回卷篇幕部]/);
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
    // 将当前章节列表缓存给阅读页用
    ChapterCache.chapters = this.chapters_;
    ChapterCache.bookUrl = this.bookUrl;
    ChapterCache.targetIndex = ch.index;
    const targetPage = this.isManga ? 'pages/ComicReadPage' : 'pages/ReadPage';
    if (this.from === 'ReadPage' || this.from === 'ComicReadPage') {
      // 从阅读页进来的 → router.back 回到阅读页并传参
      UiUtil.back(this.getUIContext(), {
        url: targetPage,
        params: {
          durChapterIndex: ch.index,
          durChapterTitle: ch.title,
        }
      });
    } else {
      // 从其他页（如 BookInfoPage）进来的 → router.pushUrl 跳转到阅读页
      UiUtil.pushUrl(this.getUIContext(), {
        url: targetPage,
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

  // ===== 多选缓存 =====

  private enterSelectMode(): void {
    this.selectMode = true;
    this.selectedIndices = [];
    this.dataSource_.notifyAll();
  }

  private exitSelectMode(): void {
    this.selectMode = false;
    this.selectedIndices = [];
    this.dataSource_.notifyAll();
  }

  private toggleSelect(ch: BookSourceChapter, position: number): void {
    if (ch.isVolume) return;
    const idx = ch.index;
    if (this.selectedIndices.includes(idx)) {
      this.selectedIndices = this.selectedIndices.filter((i: number): boolean => i !== idx);
    } else {
      this.selectedIndices = [...this.selectedIndices, idx];
    }
    this.dataSource_.notifyItem(position);
  }

  private selectAll(): void {
    const all: number[] = [];
    for (const ch of this.chapters_) {
      if (!ch.isVolume) all.push(ch.index);
    }
    this.selectedIndices = all;
    this.dataSource_.notifyAll();
  }

  private invertSelect(): void {
    const cur = new Set<number>(this.selectedIndices);
    const next: number[] = [];
    for (const ch of this.chapters_) {
      if (!ch.isVolume && !cur.has(ch.index)) next.push(ch.index);
    }
    this.selectedIndices = next;
    this.dataSource_.notifyAll();
  }

  /** 启动缓存：onlySelected=true 缓存所选，false 缓存全部（非卷章节） */
  private async startCache(onlySelected: boolean): Promise<void> {
    if (this.cacheStarting) return;
    const targets: number[] = [];
    if (onlySelected) {
      for (const i of this.selectedIndices) targets.push(i);
    } else {
      for (const ch of this.chapters_) {
        if (!ch.isVolume) targets.push(ch.index);
      }
    }
    if (targets.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '请先选择章节', duration: 1500 });
      return;
    }
    this.cacheStarting = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookId = await this.resolveBookId_();
      if (bookId <= 0) {
        UiUtil.showToast(this.getUIContext(), { message: '书籍未入库，请先加入书架', duration: 1500 });
        return;
      }
      const source = await BookSourceResolver.resolveByIdentity(bookId, this.bookUrl, this.originUrl, this.origin);
      if (!source) {
        UiUtil.showToast(this.getUIContext(), { message: '书源不可用', duration: 1500 });
        return;
      }
      // 目录落库（保留已有内容），保证缓存页统计与导出一致
      const chapterTable = new ChapterTable(db);
      await chapterTable.replaceTocPreserveContent(bookId, this.chapters_);
      const items: CacheChapterItem[] = this.chapters_.map((ch: BookSourceChapter, i: number): CacheChapterItem => {
        return { index: ch.index >= 0 ? ch.index : i, title: ch.title || '', url: ch.url || '' };
      });
      BookCacheService.getInstance().cacheBook({
        bookId: bookId,
        bookName: this.bookName,
        bookUrl: this.bookUrl,
        source: source,
        chapters: items,
        startIndex: 0,
        endIndex: items.length - 1,
        indices: targets,
        context: UiUtil.getHostContext(this.getUIContext()),
      }).then((result) => {
        if (!result) {
          UiUtil.showToast(this.getUIContext(), { message: '该书已有缓存任务进行中', duration: 1500 });
        }
      }).catch((e: Error) => {
        console.warn('[ChapterList] cache fail: ' + e.message);
      });
      UiUtil.showToast(this.getUIContext(), { message: '已开始缓存 ' + targets.length + ' 章', duration: 1800 });
      this.exitSelectMode();
    } catch (e) {
      console.warn('[ChapterList] startCache fail:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '启动缓存失败', duration: 1500 });
    } finally {
      this.cacheStarting = false;
    }
  }

  /** 解析当前书籍的 bookId（按 bookUrl，兜底按书名+作者） */
  private async resolveBookId_(): Promise<number> {
    const db = AppDatabase.getInstance().rdbStore;
    const bookTable = new BookTable(db);
    if (this.bookUrl) {
      const book = await bookTable.getBookByUrl(this.bookUrl);
      if (book) return book.id;
    }
    const byName = await bookTable.getBookByName(this.bookName, this.bookAuthor);
    return byName ? byName.id : 0;
  }

  /** 批量添加书签：每个选中章节一条（对齐安卓目录页多选添加） */
  private async addBookmarksForSelected(): Promise<void> {
    if (this.selectedIndices.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '请先选择章节', duration: 1500 });
      return;
    }
    try {
      await AppDatabase.getInstance().waitForInit();
      const bookId = await this.resolveBookId_();
      if (bookId <= 0) {
        UiUtil.showToast(this.getUIContext(), { message: '书籍未入库，请先加入书架', duration: 1500 });
        return;
      }
      const bookmarkTable = new BookmarkTable(AppDatabase.getInstance().rdbStore);
      const now = Date.now();
      let count = 0;
      for (const idx of this.selectedIndices) {
        const ch = this.chapters_[idx];
        if (!ch || ch.isVolume) continue;
        const bookmark: Bookmark = {
          id: 0,
          bookId: bookId,
          bookName: this.bookName,
          bookAuthor: this.bookAuthor,
          chapterIndex: idx,
          chapterName: ch.title || '',
          chapterPos: 0,
          text: '',
          note: '',
          createTime: now + count,
          updateTime: now + count,
        };
        await bookmarkTable.insert(bookmark);
        count++;
      }
      UiUtil.showToast(this.getUIContext(), { message: '已添加 ' + count + ' 条书签', duration: 1500 });
      this.exitSelectMode();
    } catch (e) {
      console.warn('[ChapterList] add bookmarks fail:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '添加书签失败', duration: 1500 });
    }
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Button() { Text($r('app.string.ui_8179643cdc')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_back')).onClick(() => { UiUtil.back(this.getUIContext()); })
        Text($r('app.string.ui_41e5243e2d')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
        Text('- ' + this.bookName).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).margin({ left: 4 })
        // 缓存/多选入口
        Button(this.selectMode ? '退出' : '缓存')
          .fontSize(13)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .height(40).borderRadius(20)
          .backgroundColor(this.selectMode
            ? ThemeColors.outlineVariant(this.isDark) : ThemeColors.primary(this.isDark))
          .padding({ left: 12, right: 12 })
          .margin({ right: 8 })
          .onClick(() => {
            if (this.selectMode) this.exitSelectMode();
            else this.enterSelectMode();
          })
        // 排序切换按钮
        Button() {
          Row() {
            Text(this.isAscending ? '↑' : '↓').fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14)
            Text(this.isAscending ? '正序' : '倒序').fontSize(12)
              .fontColor(ThemeColors.onBackground(this.isDark))
          }.alignItems(VerticalAlign.Center)
        }
        .height(40).borderRadius(18)
        .backgroundColor(ThemeColors.outlineVariant(this.isDark))
        .padding({ left: 12, right: 12 })
        .margin({ right: 8 })
        .onClick(() => { this.toggleSort(); })
      }
      .padding({ left: 8, right: 4 }).width('100%').height(48)

      // ===== 加载中 =====
      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 100 })
      } else if (this.chapters_.length === 0) {
        // ===== 空状态 =====
        Column() {
          Text($r('app.string.ui_d926370389')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 80 })
          Text($r('app.string.ui_7bf45985d7')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.width('100%').alignItems(HorizontalAlign.Center)
      } else {
        // ===== 章节列表 — PERF-001 使用 LazyForEach 替代 ForEach =====
        List({ space: 0, scroller: this.listScroller_ }) {
          LazyForEach(this.dataSource_, (ch: BookSourceChapter, idx: number) => {
            ListItem() {
              if (ch.isVolume) {
                // 卷标题
                Row() {
                  Text(ch.title).fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor(ThemeColors.primary(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').padding({ top: 12, bottom: 12, left: 16, right: 16 })
                .backgroundColor(ThemeColors.primaryContainer(this.isDark))
              } else {
                Row() {
                  if (this.selectMode) {
                    Text(this.selectedIndices.includes(ch.index) ? '●' : '○')
                      .fontSize(16)
                      .fontColor(this.selectedIndices.includes(ch.index)
                        ? ThemeColors.primary(this.isDark)
                        : ThemeColors.secondaryText(this.isDark))
                      .width(24).margin({ right: 4 })
                  }
                  Text(String(ch.index + 1)).fontSize(12)
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                    .width(36).textAlign(TextAlign.End)
                    .margin({ right: 8 })
                  Text(ch.title).fontSize(14)
                    .fontColor(ch.index === this.durChapterIndex
                      ? ThemeColors.primary(this.isDark)
                      : ThemeColors.onBackground(this.isDark))
                    .fontWeight(ch.index === this.durChapterIndex
                      ? FontWeight.Bold
                      : FontWeight.Normal)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .wordBreak(WordBreak.BREAK_ALL)
                    .layoutWeight(1)
                }
                .width('100%').padding({ top: 10, bottom: 10, left: 16, right: 16 })
                .backgroundColor(ch.index === this.durChapterIndex
                  ? ThemeColors.primaryContainer(this.isDark)
                  : ThemeColors.transparent())
              }
            }
            .onClick(() => {
              if (ch.isVolume) return;
              if (this.selectMode) this.toggleSelect(ch, idx);
              else this.onChapterClick(ch);
            })
          }, (ch: BookSourceChapter) => ch.index.toString())
        }
        .layoutWeight(1).width('100%')
        .cachedCount(5)

        // ===== 底部：多选操作条 / 信息栏 =====
        if (this.selectMode) {
          Row() {
            Button($r('app.string.common_select_all')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(Color.Transparent).height(40).layoutWeight(1)
              .onClick(() => { this.selectAll(); })
            Button($r('app.string.common_invert_selection')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(Color.Transparent).height(40).layoutWeight(1)
              .onClick(() => { this.invertSelect(); })
            Button($r('app.string.ui_literal_bcc0b869ef')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(Color.Transparent).height(40).layoutWeight(1)
              .onClick(() => { this.addBookmarksForSelected(); })
            Button('缓存所选(' + this.selectedIndices.length + ')').fontSize(13)
              .fontColor(this.selectedIndices.length > 0 ? ThemeColors.onPrimary(this.isDark) : ThemeColors.secondaryText(this.isDark))
              .backgroundColor(this.selectedIndices.length > 0
                ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark))
              .height(40).layoutWeight(1.4).borderRadius(20)
              .onClick(() => { this.startCache(true); })
            Button($r('app.string.common_cache_all')).fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark))
              .backgroundColor(ThemeColors.primary(this.isDark))
              .height(40).layoutWeight(1).borderRadius(20)
              .onClick(() => { this.startCache(false); })
          }
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .width('100%')
          .backgroundColor(ThemeColors.surface(this.isDark))
        } else {
          Row() {
            Text('共 ' + this.chapters_.length + ' 章')
              .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            Blank()
            Text(this.isAscending ? '正序 ▲' : '倒序 ▼')
              .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
              .onClick(() => { this.toggleSort(); })
          }
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .width('100%').height(40)
          .backgroundColor(ThemeColors.surface(this.isDark))
        }
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
