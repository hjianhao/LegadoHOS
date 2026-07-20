/**
 * 阅读页
 */
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { ThemeColors } from '../theme/ThemeColors';
import { MeasureUtils } from '@kit.ArkUI';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ChapterCache } from '../util/ChapterCache';
import { DirEpubParser } from '../engine/book/DirEpubParser';
import { TextLayout, LayoutConfig, LayoutPage, DEFAULT_LAYOUT_CONFIG } from '../engine/book/TextLayout';
import { convertChinese } from '../util/ChineseConverter';
import { PageView, PageViewConfig, PageTurnAnim, PageTurnEvent } from '../components/reader/PageView';
import { ClickAction, DEFAULT_ZONE_ACTIONS } from '../components/reader/ClickAction';
import { StylePanel } from '../components/reader/StylePanel';
import { ReadBottomMenu } from '../components/reader/ReadBottomMenu';
import { ReadTopMenu } from '../components/reader/ReadTopMenu';
import { ReadProgressBar } from '../components/reader/ReadProgressBar';
import { ClickActionConfig } from '../components/reader/ClickActionConfig';
import { NetUtil } from '../util/NetUtil';
import { HtmlUtil } from '../util/HtmlUtil';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import relationalStore from '@ohos.data.relationalStore';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookmarkTable } from '../data/database/BookmarkTable';
import { Bookmark } from '../model/Bookmark';
import { BookmarkEditDialog } from '../components/reader/BookmarkEditDialog';
import { BookProgress } from '../model/BookProgress';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookChapter } from '../model/BookChapter';
import { Book } from '../model/Book';
import { SearchResult } from '../model/SearchResult';
import { CacheDialog } from '../components/reader/CacheDialog';
import { ChangeSourceSheet, ChapterPickSheet, OptionItem, OptionSelectSheet } from '../components/BookInfoSheets';
import * as ChapterMatcher from '../util/ChapterMatcher';
import { ReadAloudPanel } from '../components/reader/ReadAloudPanel';
import { ReadAloudEngine, AloudState, setAloudChapterProvider, releaseGlobalAloudEngine, AloudChapterText } from '../service/ReadAloudEngine';
import window from '@ohos.window';
import { WebDavService } from '../service/WebDavService';
import { UiUtil } from '../util/UiUtil';
import { Want, common } from '@kit.AbilityKit';
import { LoginDialog } from '../components/reader/LoginDialog';
import { FontManager, FontInfo } from '../utils/FontManager';
import { LOCAL_BOOK_ORIGIN } from '../engine/book/LocalBookEngine';
import { TxtParser } from '../engine/book/TxtParser';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { ContentReplaceEngine } from '../engine/book/ContentReplace';

interface ReadableEpubChapter {
  index: number;
  content: string;
}

interface ReadStyleSaveSnapshot {
  config: PageViewConfig;
  readBgColor: string;
  readTextColor: string;
  readNightMode: boolean;
  readFollowTheme: boolean;
}

@Entry
@Component
struct ReadPage {
  @StorageLink('isDark') @Watch('onThemeModeChange') isDark: boolean = false;
  @StorageLink('loginRequired') @Watch('onLoginRequired') loginRequired: boolean = false;
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State originUrl: string = '';
  @State origin: string = '';
  @State tocUrl: string = '';
  @State chapters: BookSourceChapter[] = [];
  @State currentIndex: number = 0;
  @State pageIndex: number = 0;
  @State text: string = '';
  @State isLoading: boolean = true;
  @State pages: LayoutPage[] = [];
  // 预加载下一章，实现无缝翻页
  private nextChapterContent_: string = '';
  private nextChapterIdx_: number = -1;
  private isPreloading_: boolean = false;
  private preloadingChapterPromises_: Map<number, Promise<string>> = new Map<number, Promise<string>>();
  private bookId_: number = -1;
  private cacheSize_: number = 10;
  private isCaching_: boolean = false;
  /** 自动缓存失败计数（对齐安卓：失败 3 次后不再预下载该章） */
  private preloadFailCount_: Map<number, number> = new Map<number, number>();
  private measureCharW_: number = 0;
  private measureLineH_: number = 0;
  private measureUtil_: MeasureUtils | null = null;
  @State showMenu: boolean = false;
  @State showStyle: boolean = false;
  @State showCacheDialog: boolean = false;
  @State showZoneConfig: boolean = false;
  @State showAloud: boolean = false;
  @State showBookmarkDlg: boolean = false;
  /** 书签草稿（原文/笔记初值） */
  @State bookmarkDraftText_: string = '';
  @State bookmarkDraftNote_: string = '';
  /** 书签/云同步跳转：按字符偏移定位（一次性，-1 无效） */
  private pendingCharPos_: number = -1;
  /** pendingCharPos_ 是否来自云端进度（来自云端时仅向前定位，本地更深则反向上传） */
  private pendingCharPosFromCloud_: boolean = false;
  /** 待反向上传本地进度（等排版完成后拿到字符偏移） */
  private reverseUploadPending_: boolean = false;
  /** 云端进度确认弹窗（plus 模式） */
  @State showCloudProgressDlg: boolean = false;
  private pendingCloudProgress_: BookProgress | null = null;
  /** 阅读中定时上传进度的定时器 */
  private progressUploadTimer_: number = -1;
  @State flowMode: string = 'paginated';
  @State readBgColor: string = ThemeColors.readingBackgroundDefault();
  @State readTextColor: string = ThemeColors.readingTextDefault();
  @State readNightMode: boolean = false;
  @State readFollowTheme: boolean = true;
  @State zoneActions: number[] = DEFAULT_ZONE_ACTIONS;
  @State fontList: FontInfo[] = [];
  @State cfg: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: ThemeColors.readingBackgroundDefault(), textColor: ThemeColors.readingTextDefault(), titleColor: ThemeColors.secondaryText(this.isDark),
    fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans', lineHeight: 1.6,
    letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify', indentSize: 2,
    paddingTop: 24, paddingBottom: 24, paddingLeft: 20, paddingRight: 20,
    showHeader: false, showFooter: true, headerContent: '', footerContent: '',
    brightness: 80, zhFormat: true, chineseMode: 'original',
  };
  @State pageW: number = 360;
  @State pageH: number = 640;
  private source_: BookSource | null = null;
  private isLocalBook_: boolean = false;
  private isLocalEpub_: boolean = false;
  private isLocalTxt_: boolean = false;
  private txtFilePath_: string = '';
  private txtEncoding_: string = 'utf-8';
  private txtChapterCache_: Map<number, string> = new Map<number, string>();
  private targetIdx_: number = -1;
  private allChapters_: BookSourceChapter[] = [];
  private totalChapters_: number = 0;
  private lastProviderIdx_: number = -1;
  private aloudEngine_: ReadAloudEngine | null = null;
  private sourceDlg?: CustomDialogController;
  private chapterPickDlg?: CustomDialogController;
  private optionDlg?: CustomDialogController;
  private loginDlg?: CustomDialogController;
  private pendingStyleSave_: ReadStyleSaveSnapshot | null = null;
  private styleSavePromise_: Promise<void> = Promise.resolve();
  private styleSaveScheduled_: boolean = false;
  /** 替换净化引擎（规则在打开书/换源/从规则页返回时加载） */
  private replaceEngine_: ContentReplaceEngine = new ContentReplaceEngine();
  /** 替换净化全局开关（SettingsStore.replace_enabled，默认开） */
  private replaceEnabled_: boolean = true;
  /** 当前章净化前原文（含书源级清洗，未过用户规则），供规则变更后不重抓网络直接重排 */
  private rawChapterContent_: string = '';
  /** 当前章净化后的显示标题（用户规则 applyTitle 结果） */
  @State displayTitle_: string = '';

  onLoginRequired(): void {
    if (this.loginRequired && !this.loginDlg) {
      this.loginDlg = new CustomDialogController({
        builder: LoginDialog({ controller: this.loginDlg! }),
        autoCancel: true,
        customStyle: true,
        alignment: DialogAlignment.Center,
      });
      this.loginDlg.open();
      AppStorage.setOrCreate<boolean>('loginRequired', false);
	    }
	  }

	  async aboutToAppear(): Promise<void> {
	    const p = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
	    this.bookName = String(p['bookName'] || p['name'] || '');
	    this.bookAuthor = String(p['bookAuthor'] || p['author'] || '');
	    this.bookUrl = String(p['bookUrl'] || '');
	    this.originUrl = String(p['originUrl'] || '');
	    this.origin = String(p['origin'] || '');
	    this.tocUrl = String(p['tocUrl'] || '');
	    if (p['durChapterIndex'] !== undefined) this.targetIdx_ = Number(p['durChapterIndex']);
	    if (p['durPageIndex'] !== undefined) this.pageIndex = Number(p['durPageIndex']);
    if (p['durCharPos'] !== undefined) this.pendingCharPos_ = Number(p['durCharPos']);
	    // 初始化字体管理器并注册已安装的自定义字体
	    this.initFonts();
	    // 先加载设置，确保首次渲染使用用户配置的样式（而非默认值再切换）
	    await this.loadSettings();
	    // 阅读页保留系统栏，避免调出菜单时可用高度变化导致正文跳动。
	    this.setSystemBarVisible_(true, false);
	    // 初始化测量工具
	    try { this.measureUtil_ = this.getUIContext().getMeasureUtils(); } catch (_) { /* ignore */ }
	    // 云端同步（异步，不阻塞主流程）
	    this.syncFromCloud();
	    // 设置加载完成后立即加载内容（此时 cfg 已为用户配置）
	    this.loadContent();
	    // 阅读中每 5 分钟静默上传一次进度（对齐安卓 startBackupJob）
	    this.progressUploadTimer_ = setInterval((): void => {
	      this.saveAndUploadProgress(true);
	    }, 5 * 60 * 1000);
	  }

  /** 初始化 FontManager 并注册已安装的自定义字体 */
  private async initFonts(): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.Context;
      await FontManager.getInstance().init(ctx);
      FontManager.getInstance().registerAll(this.getUIContext());
      this.fontList = FontManager.getInstance().getAllFonts();
    } catch (e) {
      console.warn('[ReadPage] Font init failed:', (e as Error).message);
    }
  }

  /**
   * 开书时与云端双向同步进度：
   * - 云端章节更远 → 恢复云端（plus 开关开启时弹窗确认）
   * - 本地章节更远 / 云端无进度 → 反向上传
   * - 同章 → 云端字符偏移经 pendingCharPos_ 在排版后定位（本地更深则反向上传）
   */
  private async syncFromCloud(): Promise<void> {
    try {
      const syncOn = AppStorage.get<boolean>('webdav_sync_progress');
      if (syncOn !== true || !WebDavService.getInstance().isConfigured()) return;
      if (!this.bookName || !this.bookAuthor) return;

      const cloud = await WebDavService.getInstance().downloadBookProgress(this.bookName, this.bookAuthor);
      if (!cloud) {
        // 云端无进度：本地已读过则反向上传
        if (this.targetIdx_ > 0 || this.pageIndex > 0) {
          this.reverseUploadPending_ = true;
        }
        return;
      }

      if (cloud.durChapterIndex > this.targetIdx_) {
        // 云端章节更远
        const plus = AppStorage.get<boolean>('webdav_sync_progress_plus') === true;
        if (plus) {
          this.pendingCloudProgress_ = cloud;
          this.showCloudProgressDlg = true;
        } else {
          this.applyCloudProgress_(cloud);
        }
      } else if (cloud.durChapterIndex < this.targetIdx_) {
        // 本地章节更远 → 反向上传（等排版完成后拿到字符偏移再传）
        this.reverseUploadPending_ = true;
      } else {
        // 同章：云端字符偏移交给排版后处理
        if (cloud.durChapterPos > 0) {
          this.pendingCharPos_ = cloud.durChapterPos;
          this.pendingCharPosFromCloud_ = true;
        }
      }
    } catch (e) {
      console.warn('[ReadPage] Sync from cloud failed:', (e as Error).message);
    }
  }

  /** 应用云端进度（静默恢复路径与弹窗确认路径共用） */
  private applyCloudProgress_(cloud: BookProgress): void {
    this.targetIdx_ = cloud.durChapterIndex;
    if (this.pages.length > 0 && cloud.durChapterIndex !== this.currentIndex) {
      // 内容已加载 → 切到云端章节并按字符偏移定位
      this.pendingCharPos_ = cloud.durChapterPos;
      this.loadChapter(cloud.durChapterIndex);
    } else if (this.pages.length > 0) {
      this.goToReadingPosition_(cloud.durChapterPos);
    } else {
      // 开书竞态：内容未加载 → 交给加载流程按 targetIdx_/pendingCharPos_ 处理
      this.pendingCharPos_ = cloud.durChapterPos;
      this.pendingCharPosFromCloud_ = true;
    }
    UiUtil.showToast(this.getUIContext(), {
      message: '已恢复云端进度：第 ' + (cloud.durChapterIndex + 1) + ' 章', duration: 2000 });
    console.info('[ReadPage] Cloud progress restored:', cloud.durChapterIndex, cloud.durChapterPos);
  }

  onPageShow(): void {
    // 始终保留系统栏，保证阅读区域尺寸稳定。
    this.setSystemBarVisible_(true, false);
    this.reloadFollowThemeSetting();
    // 刷新字体列表（从字体管理页返回时可能有变化）
    this.fontList = FontManager.getInstance().getAllFonts();
    // 如果当前使用的字体已被删除，回退到系统默认
    if (this.cfg.fontFamily !== 'HarmonyOS Sans' && this.cfg.fontFamily !== 'serif' && this.cfg.fontFamily !== 'monospace') {
      if (!FontManager.getInstance().findByFamilyName(this.cfg.fontFamily)) {
        this.cfg.fontFamily = 'HarmonyOS Sans';
        this.onStyleChange(this.cfg);
      }
    }
    if (!this.isLoading) {
      // 从规则管理页等返回时：重新加载替换规则，净化结果有变化则用原文重排当前章（不清缓存）
      this.reloadReplaceRules_().then(() => { this.relayoutWithRawContent_(); }).catch(() => {});
      // 从目录页返回时，通过 ChapterCache 获取目标章节索引
      if (ChapterCache.targetIndex >= 0) {
        const idx = ChapterCache.targetIndex;
        ChapterCache.targetIndex = -1;
        // 同步章节列表（目录页可能已重新排序）
        if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
          this.allChapters_ = ChapterCache.chapters;
          this.totalChapters_ = ChapterCache.chapters.length;
          this.chapters = ChapterCache.chapters;
        }
        if (idx < this.allChapters_.length && idx !== this.currentIndex) {
          console.info('[ReadPage] Jump to chapter from toc:', idx);
          this.loadChapter(idx);
        }
      }
	      return;
	    }
	    // loadContent 已在 aboutToAppear 中调用，此处不再重复执行
	  }

	  private async loadSettings(): Promise<void> {
	    try {
	      const s = SettingsStore.getInstance();
	      await s.init(UiUtil.getHostContext(this.getUIContext()));
	      this.cfg.fontSize = await s.getFontSize();
	      let fontFamily = await s.getFontFamily();
	      // 兼容旧版默认值 '默认'
	      if (fontFamily === '默认') fontFamily = 'HarmonyOS Sans';
	      this.cfg.fontFamily = fontFamily;
	      this.cfg.lineHeight = await s.getLineHeight();
	      this.cfg.indentSize = await s.getIndentSize();
	      this.cfg.letterSpacing = await s.getLetterSpacing();
	      this.cfg.paragraphSpacing = await s.getParagraphSpacing();
	      this.cfg.fontWeight = await s.getFontWeight();
	      this.cfg.paddingTop = await s.getPaddingTop();
	      this.cfg.paddingBottom = await s.getPaddingBottom();
	      this.cfg.paddingLeft = await s.getPaddingLeft();
	      this.cfg.paddingRight = await s.getPaddingRight();
	      this.cfg.chineseMode = await s.getChineseMode();
	    this.cfg.zhFormat = await s.getZhFormat();
	    this.readBgColor = await s.getReadBgColor();
	    this.readTextColor = await s.getReadTextColor();
        if (this.readBgColor === ReadPage.NIGHT_BG && this.readTextColor === ReadPage.NIGHT_TEXT) {
          this.readBgColor = ThemeColors.readingBackgroundDefault();
          this.readTextColor = ThemeColors.readingTextDefault();
          s.setReadBgColor(this.readBgColor).catch(() => {});
          s.setReadTextColor(this.readTextColor).catch(() => {});
        }
	    this.readNightMode = await s.getReadNightMode();
	    this.readFollowTheme = await s.getReadFollowTheme();
        if (this.readFollowTheme) {
          this.readNightMode = this.isDark;
        }
	      this.cacheSize_ = await s.getAutoCacheSize();
	      // 加载自定义触控区域配置
	      const za: number[] = [];
	      for (let z = 0; z < 9; z++) za.push(await s.getClickAction(z));
	      this.zoneActions = za;
	      // 加载完成后根据夜间模式和主题跟随应用颜色
	      this.applyReadColors();
	    } catch (_e) { /* ignore */ }
	  }

	  /** 夜间模式阅读背景色 */
	  private static readonly NIGHT_BG: string = ThemeColors.readingNightBackground();
	  /** 夜间模式阅读文字色 */
	  private static readonly NIGHT_TEXT: string = ThemeColors.readingNightText();

	  /**
	   * 根据 readNightMode 和 readFollowTheme 应用阅读颜色
	   */
	  private applyReadColors(): void {
	    const bg = this.readNightMode ? ReadPage.NIGHT_BG : this.readBgColor;
	    const text = this.readNightMode ? ReadPage.NIGHT_TEXT : this.readTextColor;
	    if (this.cfg.bgColor !== bg || this.cfg.textColor !== text) {
	      this.cfg = {
	        animType: this.cfg.animType, bgColor: bg, textColor: text, titleColor: this.cfg.titleColor,
	        fontSize: this.cfg.fontSize, fontWeight: this.cfg.fontWeight, fontFamily: this.cfg.fontFamily,
	        lineHeight: this.cfg.lineHeight, letterSpacing: this.cfg.letterSpacing,
	        paragraphSpacing: this.cfg.paragraphSpacing, textAlign: this.cfg.textAlign,
	        indentSize: this.cfg.indentSize, paddingTop: this.cfg.paddingTop,
	        paddingBottom: this.cfg.paddingBottom, paddingLeft: this.cfg.paddingLeft,
	        paddingRight: this.cfg.paddingRight, showHeader: this.cfg.showHeader,
	        showFooter: this.cfg.showFooter, headerContent: this.cfg.headerContent,
	        footerContent: this.cfg.footerContent, brightness: this.cfg.brightness,
        zhFormat: this.cfg.zhFormat, chineseMode: this.cfg.chineseMode,
	      };
	    }
      // 状态栏保留占位，但颜色和图标明暗始终跟随当前阅读背景。
      this.setSystemBarVisible_(true, false);
	  }

	  private async loadContent(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      let localBookKind = '';

      // 书架只传 bookUrl，从 DB 补全 origin/tocUrl
      try {
        const bookTable = new BookTable(db);
        const book = await bookTable.getBookByUrl(this.bookUrl);
        if (book) {
          this.bookId_ = book.id;
          if (!this.tocUrl) this.tocUrl = book.tocUrl || '';
          if (!this.originUrl) this.originUrl = book.originUrl || '';
          if (!this.origin) this.origin = book.origin || '';
          if (!this.bookName) this.bookName = book.name || '';
          if (!this.bookAuthor) this.bookAuthor = book.author || '';
          localBookKind = book.kind || '';
        }
      } catch (_) { /* ignore */ }

      // 检测是否为本地书籍（origin 为 "本地"）
      this.isLocalBook_ = this.origin === LOCAL_BOOK_ORIGIN;
      this.isLocalEpub_ = this.isLocalBook_ && localBookKind.toLowerCase() === 'epub';
      this.isLocalTxt_ = this.isLocalBook_ && localBookKind.toLowerCase() === 'txt';
      if (this.isLocalTxt_) {
        this.txtFilePath_ = this.originUrl;
        try {
          const bookTable = new BookTable(db);
          const book = await bookTable.getBookByUrl(this.bookUrl);
          this.txtEncoding_ = book?.charset || 'utf-8';
        } catch (_e) { /* ignore */ }
        this.txtChapterCache_.clear();
      }

		      let chapters: BookSourceChapter[] = [];

		      // 本地书籍：跳过 BookSource 匹配和网络目录获取
		      if (this.isLocalBook_) {
		        console.info('[ReadPage] Local book detected, kind=', localBookKind, 'tocUrl=', this.tocUrl);
		        if (this.isLocalEpub_) {
		          if (!this.tocUrl) {
		            throw new Error('EPUB 缺少解压目录');
		          }
		          const parser = new DirEpubParser(this.tocUrl, true);
		          const result = await parser.parse();
		          chapters = result.chapters.map((ch: BookChapter, idx: number): BookSourceChapter => ({
		            index: idx,
		            title: ch.title,
		            url: ch.url,
		          }));
		          console.info('[ReadPage] Loaded EPUB chapters from extracted dir:', chapters.length);
		        } else if (this.bookId_ > 0) {
		          try {
		            const ct = new ChapterTable(db);
		            const dbChapters = await ct.getChaptersByBookId(this.bookId_);
		            if (dbChapters.length > 0) {
	              chapters = dbChapters.map((ch: BookChapter): BookSourceChapter => ({
	                index: ch.index,
	                title: ch.title,
	                url: ch.url,
	              }));
		              console.info('[ReadPage] Loaded chapters from DB:', chapters.length);
		            }
		          } catch (_e) { /* ignore */ }
		        }
	      }

      this.source_ = this.isLocalBook_ ? null : await BookSourceResolver.resolveByIdentity(
        this.bookId_, this.bookUrl, this.originUrl, this.origin);
      console.info('[ReadPage] loadContent: source_=', this.source_ ? this.source_.sourceName : 'NULL',
        'originUrl=', this.originUrl, 'origin=', this.origin, 'bookUrl=', this.bookUrl.substring(0, 80), 'tocUrl=', this.tocUrl);
      if (!this.tocUrl) {
        try {
          const bookTable = new BookTable(db);
          const book = await bookTable.getBookByUrl(this.bookUrl);
          if (book) {
            this.bookId_ = book.id;
            this.tocUrl = book.tocUrl || '';
          }
        } catch (_) { /* ignore */ }
      }

	      if (!this.isLocalBook_) {
	        if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
	          chapters = ChapterCache.chapters;
	          console.info('[ReadPage] Loaded chapters from memory cache:', chapters.length);
	        } else {
	          // 尝试从数据库加载缓存的目录
	          let dbChapterCount = 0;
	          if (this.bookId_ > 0) {
	            try {
	              const ct = new ChapterTable(db);
	              const dbChapters = await ct.getChaptersByBookId(this.bookId_);
	              if (dbChapters.length > 0) {
	                chapters = dbChapters.map((ch: BookChapter): BookSourceChapter => ({
	                  index: ch.index,
	                  title: ch.title,
	                  url: ch.url,
	                }));
	                dbChapterCount = chapters.length;
	                console.info('[ReadPage] Loaded chapters from DB cache:', chapters.length);
	              }
	            } catch (_e) { /* fall through to network */ }
	          }
	          // 如果 DB 目录不完整，从网络刷新完整目录
	          const expectedCount = await this.getExpectedChapterCount_(db);
	          if (expectedCount > 0 && dbChapterCount > 0 && dbChapterCount < expectedCount * 0.8) {
          console.info('[ReadPage] DB chapters incomplete (' + dbChapterCount + '/' + expectedCount + '), fetching from network');
          const primaryTocUrl = this.tocUrl || this.bookUrl;
          const netChapters = await globalSourceExecutor.getToc(this.source_, primaryTocUrl);
          if (netChapters.length === 0 && primaryTocUrl !== this.bookUrl) {
            const fallback = await globalSourceExecutor.getToc(this.source_, this.bookUrl);
            if (fallback.length > 0) {
              chapters = fallback;
            }
          } else if (netChapters.length > 0) {
            chapters = netChapters;
          }
          // 将完整目录保存到 DB（仅标题和URL，不含内容）
          if (chapters.length > 0 && this.bookId_ > 0) {
            await this.saveFullTocToDb_(this.bookId_, chapters);
          }
        }
      }
      }
      if (chapters.length === 0) { this.text = '无目录'; this.isLoading = false; console.info('[ReadPage] no chapters'); return; }
      this.allChapters_ = chapters;
      this.totalChapters_ = chapters.length;
      this.currentIndex = this.targetIdx_ >= 0 && this.targetIdx_ < chapters.length ? this.targetIdx_ : 0;
      this.chapters = chapters;
      if (ChapterCache.bookUrl !== this.bookUrl || ChapterCache.chapters.length === 0) {
        ChapterCache.chapters = chapters;
        ChapterCache.bookUrl = this.bookUrl;
      }
      setAloudChapterProvider(() => this.getNextChapterForAloud_());
      // 获取 bookId 用于缓存，并从 DB 恢复阅读位置
      try {
        const bookTable = new BookTable(db);
        const book = await bookTable.getBookByUrl(this.bookUrl);
        if (book) {
          this.bookId_ = book.id;
          if (!this.tocUrl) this.tocUrl = book.tocUrl || '';
          if (this.targetIdx_ < 0) this.targetIdx_ = book.durChapterIndex || 0;
          if (this.pageIndex <= 0 && (book.durChapterPos || 0) > 0) this.pageIndex = book.durChapterPos;
        }
      } catch (_) { /* ignore */ }
      if (this.targetIdx_ >= 0 && this.targetIdx_ < this.allChapters_.length) {
        this.currentIndex = this.targetIdx_;
      }
      console.info('[ReadPage] pos: targetIdx_=' + this.targetIdx_ + ' pageIdx=' + this.pageIndex + ' chapters=' + this.allChapters_.length);
      // 打开书时加载一次替换净化规则（书不换则规则集合不变；换源时会重新加载）
      await this.reloadReplaceRules_();
      await this.loadChapter(this.currentIndex);
    } catch (e) {
      this.text = '加载失败';
      this.isLoading = false;
    }
  }

  private onThemeModeChange(): void {
    this.syncReadThemeWithApp();
  }

  private reloadFollowThemeSetting(): void {
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(async () => {
        this.readFollowTheme = await SettingsStore.getInstance().getReadFollowTheme();
        this.syncReadThemeWithApp();
      })
      .catch(() => {});
  }

  private syncReadThemeWithApp(): void {
    if (!this.readFollowTheme || this.readNightMode === this.isDark) {
      return;
    }
    this.readNightMode = this.isDark;
    this.applyReadColors();
  }

  private async loadChapter(idx: number, forceFetch: boolean = false): Promise<void> {
    if (idx < 0 || idx >= this.allChapters_.length) return;
    this.isLoading = true;
    const previousIndex = this.currentIndex;
    this.currentIndex = idx;
    const ch = this.allChapters_[idx];
    this.displayTitle_ = this.purifyTitle_(ch?.title || '');

    // 非强制刷新的情况下，尝试从数据库缓存加载
	    if (!forceFetch) {
	      const cachedContent = await this.readChapterCache_(idx);
	      if (cachedContent && cachedContent.length > 50) {
	        console.info('[ReadPage] Loaded from cache:', ch.title?.substring(0, 20));
	        this.applyChapterContent_(idx, cachedContent);
	        this.isLoading = false;
	        this.saveProgress();
	        this.preloadNextChapter_(idx);
	        this.cacheSurrounding_(idx);
	        return;
	      }
	    }

    try {
      let loadedIdx = idx;
      let content = await this.fetchChapterContent_(idx);
      if ((!content || content.length <= 50) && this.isLocalEpub_) {
        const direction = idx < previousIndex ? -1 : 1;
        const readable = await this.findReadableLocalEpubChapter_(idx + direction, direction);
        if (readable) {
          loadedIdx = readable.index;
          content = readable.content;
          console.info('[ReadPage] Skipped image-only EPUB chapter:', idx, '->', loadedIdx);
        }
      }
      if (content && content.length > 50) {
        this.applyChapterContent_(loadedIdx, content);
        // 持久化缓存到数据库（content 为净化前原文，净化结果不落缓存）
        this.saveToDbCache_(loadedIdx, content);
      } else if (this.isLocalEpub_ && previousIndex !== idx && this.text.length > 50) {
        // 向前/向后已经没有可读文本章节时，保留当前页，避免用错误提示覆盖正文。
        this.currentIndex = previousIndex;
        this.displayTitle_ = this.purifyTitle_(this.allChapters_[previousIndex]?.title || '');
        this.isLoading = false;
        return;
      } else {
        this.rawChapterContent_ = '';
        this.text = this.isLocalEpub_ ? '当前章节没有可提取的文本，请在设置中切换为“图文混排”引擎' :
          (content || '加载失败');
        this.layoutText(this.text);
      }
    } catch (e) {
      this.rawChapterContent_ = '';
      this.text = '加载失败';
    }
    this.isLoading = false;
    // 保存阅读进度
    this.saveProgress();
    // 无缝翻页：预加载下一章
    this.preloadNextChapter_(this.currentIndex);
    // 自动缓存前后 ±n 章
    this.cacheSurrounding_(this.currentIndex);
  }

  private async findReadableLocalEpubChapter_(startIdx: number, direction: number): Promise<ReadableEpubChapter | null> {
    const step = direction < 0 ? -1 : 1;
    for (let idx = startIdx; idx >= 0 && idx < this.allChapters_.length; idx += step) {
      let content = await this.readChapterCache_(idx);
      if (!content || content.length <= 50) {
        try {
          content = await this.fetchChapterContent_(idx);
        } catch (_e) {
          content = '';
        }
      }
      if (content && content.length > 50) return { index: idx, content };
    }
    return null;
  }

  private async readChapterCache_(idx: number): Promise<string> {
    if (this.bookId_ <= 0) return '';
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const cached = await ct.getChapterByIndex(this.bookId_, idx);
      const result = cached?.content || '';
      console.info('[ReadPage] readChapterCache_ idx=' + idx + ' bookId=' + this.bookId_ + ' found=' + (cached ? 'yes' : 'no') + ' len=' + result.length);
      return result;
    } catch (_e) {
      return '';
    }
  }

  /** 读取本地 TXT 章节内容（按字节偏移从原始文件读取，带内存缓存） */
  private async readLocalTxtChapter_(idx: number): Promise<string> {
    if (!this.isLocalTxt_ || !this.txtFilePath_) return '';
    const cached = this.txtChapterCache_.get(idx);
    if (cached !== undefined) return cached;
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const ch = await ct.getChapterByIndex(this.bookId_, idx);
      const start = ch?.start ?? 0;
      const end = ch?.end ?? 0;
      if (!ch || end <= start) return '';
      const content = await TxtParser.readChapterContent(this.txtFilePath_, start, end, this.txtEncoding_);
      this.txtChapterCache_.set(idx, content);
      // 缓存控制在最近 5 章，避免内存膨胀
      if (this.txtChapterCache_.size > 5) {
        const keys = Array.from(this.txtChapterCache_.keys());
        for (const k of keys) {
          if (Math.abs(k - idx) > 2) this.txtChapterCache_.delete(k);
        }
      }
      return content;
    } catch (e) {
      console.warn('[ReadPage] readLocalTxtChapter_ failed:', idx, (e as Error).message);
      return '';
    }
  }

  private async fetchChapterContent_(idx: number): Promise<string> {
    const ch = this.allChapters_[idx];
    if (!ch) return '';
    const url = ch.url || this.bookUrl;
    console.info('[ReadPage] fetchChapterContent_: idx=', idx, 'title=', ch.title, 'url=', url?.substring(0, 80));
    let content = '';

			    // 本地书籍：EPUB 从当前解压目录读取，其他本地格式从 DB 读取
			    if (this.isLocalBook_) {
			      if (this.isLocalTxt_) {
			        content = await this.readLocalTxtChapter_(idx);
			        console.info('[ReadPage] Local TXT content:', content ? content.length : 0, 'bytes');
			        return content;
			      }
			      if (!this.isLocalEpub_) {
			        content = await this.readChapterCache_(idx);
			        console.info('[ReadPage] Local book content:', content ? content.length : 0, 'bytes');
			        return content;
			      }
			      if (!this.tocUrl) {
			        throw new Error('EPUB 缺少解压目录');
			      }
			      if (ch.url) {
			        const filePath = `${this.tocUrl}/${ch.url}`;
		        console.info('[ReadPage] Loading from extracted file:', filePath);
		        let fd: fileFs.File | null = null;
		        try {
		          if (fileFs.accessSync(filePath)) {
		            const stat = fileFs.statSync(filePath);
		            const buf = new ArrayBuffer(stat.size);
		            fd = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
		            fileFs.readSync(fd.fd, buf);
		            const decoder = new util.TextDecoder('utf-8', { fatal: false });
		            const html = decoder.decodeToString(new Uint8Array(buf));
		            content = HtmlUtil.toPlainText(html);
		            console.info('[ReadPage] Extracted file loaded:', content.length, 'chars');
		          }
		        } catch (e) {
		          console.warn('[ReadPage] Failed to load extracted file:', e);
		        } finally {
		          if (fd) {
		            try {
		              fileFs.closeSync(fd);
		            } catch (err) {
		              console.warn('[ReadPage] close extracted file failed:', (err as Error).message);
		            }
		          }
		        }
		      }
			      if (!content) {
			        console.info('[ReadPage] EPUB chapter contains no extractable text:', ch.url || ch.title || idx.toString());
			      }
	      console.info('[ReadPage] Local book content:', content ? content.length : 0, 'bytes');
	      return content;
	    }

    if (this.source_) {
      content = await globalSourceExecutor.getContent(this.source_, url, this.bookUrl);
      console.info('[ReadPage] getContent returned:', content ? content.length : 0, 'bytes');
    }
    if (!content && url && url.startsWith('http')) {
      console.info('[ReadPage] Trying direct HTTP GET');
      const r = await NetUtil.httpGet(url);
      if (r) content = HtmlUtil.stripHtml(r);
    }
    console.info('[ReadPage] fetchChapterContent_ final:', content ? content.length : 0, 'bytes');
    // 返回原文（仅含书源级清洗）。简繁转换 + 用户规则替换统一在展示前 processForDisplay_ 处理，
    // 保证写入 DB 缓存的始终是原文（对齐安卓：用户规则净化结果不落缓存）
    return content;
  }

  /** 加载替换净化规则（正文 + 标题两个 scope）并刷新全局开关 */
  private async reloadReplaceRules_(): Promise<void> {
    try {
      this.replaceEnabled_ = await SettingsStore.getInstance().getReplaceEnabled();
      await AppDatabase.getInstance().waitForInit();
      const ruleTable = new ReplaceRuleTable(AppDatabase.getInstance().rdbStore);
      await this.replaceEngine_.loadRules(ruleTable, this.bookName, this.originUrl);
    } catch (e) {
      console.warn('[ReadPage] load replace rules failed:', (e as Error).message);
    }
  }

  /**
   * 展示前内容处理（对齐安卓 ContentProcessor.getContent 的顺序：简繁转换 → 用户规则替换）。
   * 只作用于排版展示，处理结果不写缓存；用户规则替换受全局开关 replaceEnabled_ 控制。
   */
  private processForDisplay_(raw: string): string {
    let text = raw;
    if (text && text.length > 50 && this.cfg.chineseMode !== 'original') {
      text = convertChinese(text, this.cfg.chineseMode);
    }
    if (text && this.replaceEnabled_) {
      text = this.replaceEngine_.applyContent(text);
    }
    return text;
  }

  /** 标题净化（受全局开关控制） */
  private purifyTitle_(title: string): string {
    if (!title || !this.replaceEnabled_) return title;
    return this.replaceEngine_.applyTitle(title);
  }

  /**
   * 规则/开关变更后：不重抓网络，用 rawChapterContent_ 重走「简繁+替换→排版」刷新当前章。
   * 净化结果无变化时直接返回（避免无谓重排）；有变化时按原页首字符偏移尽量保持阅读位置。
   */
  private relayoutWithRawContent_(): void {
    if (!this.rawChapterContent_) return;
    const content = this.processForDisplay_(this.rawChapterContent_);
    const newTitle = this.purifyTitle_(this.allChapters_[this.currentIndex]?.title || '');
    if (content === this.text && newTitle === this.displayTitle_) return;
    const charPos = this.pages.length > 0 ? (this.pages[this.pageIndex]?.startOffset || 0) : 0;
    this.displayTitle_ = newTitle;
    this.text = content;
    this.layoutText(content);
    for (let i = 0; i < this.pages.length; i++) {
      if (charPos >= this.pages[i].startOffset && charPos < this.pages[i].endOffset) {
        this.pageIndex = i;
        break;
      }
    }
  }

  /**
   * 应用章节内容到阅读页。入参必须是净化前原文（缓存/网络抓取原始结果）：
   * 原文存入 rawChapterContent_（供规则变更后重排），展示文本经 processForDisplay_
   * （简繁转换 → 用户规则替换）处理后排版；处理结果不写缓存。
   */
  private applyChapterContent_(idx: number, rawContent: string): void {
    this.currentIndex = idx;
    this.rawChapterContent_ = rawContent;
    this.displayTitle_ = this.purifyTitle_(this.allChapters_[idx]?.title || '');
    const content = this.processForDisplay_(rawContent);
    this.text = content;
    this.layoutText(content);
    // 书签/云同步跳转：按字符偏移定位分页（一次性生效）
    if (this.pendingCharPos_ >= 0 && idx === this.targetIdx_) {
      const pos = this.pendingCharPos_;
      const fromCloud = this.pendingCharPosFromCloud_;
      this.pendingCharPos_ = -1;
      this.pendingCharPosFromCloud_ = false;
      for (let i = 0; i < this.pages.length; i++) {
        if (pos >= this.pages[i].startOffset && pos < this.pages[i].endOffset) {
          if (!fromCloud || i > this.pageIndex) {
            this.pageIndex = i;
          } else if (i < this.pageIndex) {
            // 云同步同章但本地读得更深 → 本地进度反向上传
            this.reverseUploadPending_ = true;
          }
          break;
        }
      }
    }
    // 反向上传：此时排版已完成，能拿到正确的字符偏移
    if (this.reverseUploadPending_ && idx === this.targetIdx_) {
      this.reverseUploadPending_ = false;
      this.saveAndUploadProgress(true);
    }
    this.initAloudEngine_();
  }

  /** 预加载下一章文本，用于无缝翻页 */
  private preloadNextChapter_(currentIdx: number): void {
    const nextIdx = currentIdx + 1;
    if (nextIdx >= this.allChapters_.length || this.preloadingChapterPromises_.has(nextIdx)) return;
    this.isPreloading_ = true;

    const ch = this.allChapters_[nextIdx];
    const preloadBookUrl = this.bookUrl;
    const promise = (this.isLocalTxt_ ? this.readLocalTxtChapter_(nextIdx) : this.readChapterCache_(nextIdx))
      .then((cached: string): Promise<string> | string => {
        if (cached && cached.length > 50) return cached;
        return this.fetchChapterContent_(nextIdx);
      });
    this.preloadingChapterPromises_.set(nextIdx, promise);
    promise
      .then(async (content: string): Promise<void> => {
        if (preloadBookUrl !== this.bookUrl) return;
        if (content && content.length > 50) {
          this.nextChapterContent_ = content;
          this.nextChapterIdx_ = nextIdx;
          await this.saveToDbCache_(nextIdx, content);
          console.info('[ReadPage] Preloaded next chapter:', nextIdx, ch.title?.substring(0, 20));
        }
      })
      .catch((_e: Error) => { /* ignore preload failure */ })
      .then(() => {
        if (this.preloadingChapterPromises_.get(nextIdx) === promise) {
          this.preloadingChapterPromises_.delete(nextIdx);
        }
        this.isPreloading_ = this.preloadingChapterPromises_.size > 0;
      });
  }

  private async tryUsePreloadedChapter_(idx: number): Promise<boolean> {
    let content = '';
    if (this.nextChapterIdx_ === idx && this.nextChapterContent_ && this.nextChapterContent_.length > 50) {
      content = this.nextChapterContent_;
    } else {
      const pending = this.preloadingChapterPromises_.get(idx);
      if (pending) {
        try {
          content = await pending;
        } catch (_e) {
          content = '';
        }
      }
      if (!content) {
        content = this.isLocalTxt_ ? await this.readLocalTxtChapter_(idx) : await this.readChapterCache_(idx);
      }
    }
    if (!content || content.length <= 50) return false;
    console.info('[ReadPage] Seamless switch to chapter:', idx);
    this.applyChapterContent_(idx, content);
    if (this.nextChapterIdx_ === idx) {
      this.nextChapterContent_ = '';
      this.nextChapterIdx_ = -1;
    }
    this.isLoading = false;
    this.saveProgress();
    this.saveToDbCache_(idx, content);
    this.preloadNextChapter_(idx);
    this.cacheSurrounding_(idx);
    return true;
  }

  /** 将章节内容存入数据库缓存 */
  private async saveToDbCache_(idx: number, content: string): Promise<void> {
    if (this.bookId_ <= 0 || !content || content.length <= 50) return;
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const existing = await ct.getChapterByIndex(this.bookId_, idx);
      const ch = this.allChapters_[idx];
      const now = Date.now();
      if (existing) {
        existing.content = content;
        existing.contentLength = content.length;
        existing.isCached = true;
        existing.updateTime = now;
        await ct.updateChapter(existing);
      } else {
        await ct.insertChapters([{
          id: 0, bookId: this.bookId_, index: idx, volumeIndex: 0,
          title: ch?.title || '', url: ch?.url || '',
          content: content, contentLength: content.length,
          isRead: false, isDownloaded: false, isCached: true,
          duration: 0, audioUrl: '', createTime: now, updateTime: now,
        }]);
      }
    } catch (_e) { /* ignore */ }
  }

  /**
   * 获取书籍应有的章数（从 books 表的 totalChapterNum 或 chapterCount 字段）
   */
  private async getExpectedChapterCount_(db: relationalStore.RdbStore): Promise<number> {
    try {
      const bookTable = new BookTable(db);
      const book = await bookTable.getBookByUrl(this.bookUrl);
      if (book) {
        return book.totalChapterNum || book.chapterCount || 0;
      }
    } catch (_) { /* ignore */ }
    return 0;
  }

  /**
   * 将完整目录保存到数据库（仅标题和URL，不含内容）
   * 保留已有章节的内容缓存，避免丢失已下载的内容
   */
  private async saveFullTocToDb_(bookId: number, chapters: BookSourceChapter[]): Promise<void> {
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      // 备份已有章节的内容
      const oldChapters = await ct.getChaptersByBookId(bookId);
      // 目录骤减保护：新目录不足旧目录一半通常是书源解析失败，直接覆盖会丢掉缓存内容
      if (oldChapters.length >= 10 && chapters.length * 2 < oldChapters.length) {
        console.warn('[ReadPage] toc shrink rejected: bookId=', bookId, ' old=', oldChapters.length, ' new=', chapters.length);
        return;
      }
      const contentByUrl = new Map<string, string>();
      for (const old of oldChapters) {
        if (old.content && old.content.length > 50 && old.url) {
          contentByUrl.set(old.url, old.content);
        }
      }
      // 删除旧目录，写入新目录
      await ct.deleteChaptersByBookId(bookId);
      const now = Date.now();
      const newChapters: BookChapter[] = chapters.map((ch: BookSourceChapter, idx: number): BookChapter => {
        const item: BookChapter = {
          id: 0, bookId: bookId, index: ch.index >= 0 ? ch.index : idx, volumeIndex: 0,
          title: ch.title || '', url: ch.url || '',
          content: '', contentLength: 0,
          isRead: false, isDownloaded: false, isCached: false,
          duration: 0, audioUrl: '', createTime: now, updateTime: now,
        };
        // 还原已缓存的内容
        const cached = contentByUrl.get(ch.url);
        if (cached) {
          item.content = cached;
          item.contentLength = cached.length;
          item.isCached = true;
        }
        return item;
      });
      await ct.insertChapters(newChapters);
      console.info('[ReadPage] Saved full TOC to DB:', chapters.length, 'chapters for bookId=', bookId);
    } catch (e) {
      console.warn('[ReadPage] Failed to save full TOC to DB:', (e as Error).message);
    }
  }

  /** 自动缓存当前章节前后 ±cacheSize_ 章 */
  private async cacheSurrounding_(currentIdx: number): Promise<void> {
    if (this.bookId_ <= 0 || this.isCaching_ || !this.source_) return;
    this.isCaching_ = true;
    const total = this.allChapters_.length;
    const start = Math.max(0, currentIdx - this.cacheSize_);
    const end = Math.min(total - 1, currentIdx + this.cacheSize_);
    try {
      let count = 0;
      for (let i = start; i <= end; i++) {
        if (i === currentIdx) continue; // 当前章节已缓存
        const ch = this.allChapters_[i];
        if (!ch) continue;
        // 失败 3 次的章节不再预下载（对齐安卓 downloadFailChapters 逻辑）
        if ((this.preloadFailCount_.get(i) || 0) >= 3) continue;
        try {
          let content = await this.readChapterCache_(i);
          if (content && content.length > 50) continue;

          const pending = this.preloadingChapterPromises_.get(i);
          if (pending) {
            content = await pending;
          } else {
            content = await this.fetchChapterContent_(i);
          }
          if (content && content.length > 50) {
            await this.saveToDbCache_(i, content);
            this.preloadFailCount_.delete(i);
            count++;
          } else {
            this.preloadFailCount_.set(i, (this.preloadFailCount_.get(i) || 0) + 1);
          }
        } catch (_e) {
          this.preloadFailCount_.set(i, (this.preloadFailCount_.get(i) || 0) + 1);
        }
      }
      if (count > 0) console.info('[ReadPage] Auto-cached', count, 'chapters around', currentIdx);
    } catch (_e) { /* ignore */ }
    this.isCaching_ = false;
  }

  private saveProgress(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters_, this.pageIndex).catch(() => {});
  }

	  async aboutToDisappear(): Promise<void> {
	    console.info('[ReadPage] aboutToDisappear, page=' + this.pageIndex + ' chapter=' + this.currentIndex);
	    if (this.progressUploadTimer_ >= 0) {
	      clearInterval(this.progressUploadTimer_);
	      this.progressUploadTimer_ = -1;
	    }
	    await this.flushStyleSave_();
	    await this.saveProgressAsync_();
	    // 退出阅读时静默上传一次进度（对齐安卓 onPause 上传）
	    await this.saveAndUploadProgress(true);
	    releaseGlobalAloudEngine();
    // 退出时恢复系统栏
    this.setSystemBarVisible_(true);
  }

  /** 阅读时只显示状态栏；离开阅读页时恢复状态栏和系统导航栏。 */
  private async setSystemBarVisible_(visible: boolean, showNavigation: boolean = true): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext());
      if (!ctx) return;
      const win: window.Window = await window.getLastWindow(ctx);
      const barColor = showNavigation ? ThemeColors.background(this.isDark) : this.cfg.bgColor;
      await win.setWindowSystemBarProperties({
        statusBarColor: barColor,
        isStatusBarLightIcon: ThemeColors.useLightSystemBarIcons(barColor),
        navigationBarColor: barColor,
        isNavigationBarLightIcon: ThemeColors.useLightSystemBarIcons(barColor),
      });
      if (visible) {
        await win.setWindowSystemBarEnable(showNavigation ? ['status', 'navigation'] : ['status']);
      } else {
        await win.setWindowSystemBarEnable([]);
      }
      // 手势导航条在新系统中是独立的 navigationIndicator，旧接口不会稳定地同步其可见性。
      // 阅读时保留状态栏但隐藏底部两种导航形态；退出时三者一起恢复。
      try {
        await win.setSpecificSystemBarEnabled('status', visible, false);
        await win.setSpecificSystemBarEnabled('navigation', visible && showNavigation, false);
        await win.setSpecificSystemBarEnabled('navigationIndicator', visible && showNavigation, false);
      } catch (_unsupportedError) { /* API 11 以下由 setWindowSystemBarEnable 兜底 */ }
    } catch (err) {
      console.warn('[ReadPage] setSystemBar failed:', (err as Error).message);
    }
  }

  private async saveProgressAsync_(): Promise<void> {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    console.info('[ReadPage] saveProgressAsync calling DB...');
    try { await bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters_, this.pageIndex); console.info('[ReadPage] saveProgressAsync DB done: page=' + this.pageIndex); } catch (_) { console.info('[ReadPage] saveProgressAsync DB failed'); }
  }

  /** 保存进度并尝试上传到云端（silent=true 时静默，供定时/退出场景） */
  private async saveAndUploadProgress(silent: boolean = false): Promise<void> {
    this.saveProgress();
    try {
      const syncOn = AppStorage.get<boolean>('webdav_sync_progress');
      if (syncOn !== true || !WebDavService.getInstance().isConfigured()) return;
      if (!this.bookName || !this.bookUrl) return;
      const ch = this.allChapters_[this.currentIndex];
      if (!ch) return;
      // 云端格式对齐安卓：durChapterPos 存章节内字符偏移（页首 startOffset）
      const pos = this.pages.length > 0 ? (this.pages[this.pageIndex]?.startOffset || 0) : 0;
      if (!silent) {
        UiUtil.showToast(this.getUIContext(), { message: '同步进度中…', duration: 2000 });
      }
      await WebDavService.getInstance().uploadBookProgress({
        name: this.bookName,
        author: this.bookAuthor,
        durChapterIndex: this.currentIndex,
        durChapterPos: pos,
        durChapterTitle: ch.title || '',
      });
      // 更新本地 syncTime
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      await bookTable.updateSyncTime(this.bookUrl, Date.now());
      if (!silent) {
        UiUtil.showToast(this.getUIContext(), { message: '同步成功：已上传进度', duration: 2000 });
      }
    } catch (e) {
      console.warn('[ReadPage] Upload progress failed:', (e as Error).message);
      if (!silent) {
        UiUtil.showToast(this.getUIContext(), { message: '同步失败：' + (e as Error).message, duration: 2000 });
      }
    }
  }



  private getProgressPercent(): number {
    if (this.totalChapters_ <= 0) return 0;
    return Math.min(100, Math.round((this.currentIndex / this.totalChapters_) * 100));
  }

  private normalizeReaderText_(text: string): string {
    if (!text) return '';
    return text
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .split('\n')
      .map((line: string): string => line.trim())
      .join('\n')
      .replace(/[ \t\u00a0]+/g, ' ')
      .replace(/\n[ \t]*\n+/g, '\n')
      .trim();
  }

  private layoutText(text: string): void {
    text = this.normalizeReaderText_(text);
    const lc: LayoutConfig = {
      fontFamily: this.cfg.fontFamily,
      fontSize: this.cfg.fontSize,
      fontBold: this.cfg.fontWeight >= 2,
      fontWeight: this.cfg.fontWeight,
      lineHeightMultiplier: this.cfg.lineHeight,
      paragraphSpacing: this.cfg.paragraphSpacing,
      letterSpacing: this.cfg.letterSpacing,
      textAlign: this.cfg.textAlign as 'left' | 'justify',
      firstLineIndent: this.cfg.indentSize > 0,
      indentSize: this.cfg.indentSize,
      pagePadding: 20,
      pagePaddingTop: this.cfg.paddingTop,
      pagePaddingBottom: this.cfg.paddingBottom,
      pagePaddingLeft: this.cfg.paddingLeft,
      pagePaddingRight: this.cfg.paddingRight,
      zhFormat: this.cfg.zhFormat,
      chineseMode: this.cfg.chineseMode,
      measuredCharWidth: this.measureCharW_,
      measuredLineHeight: this.measureLineH_,
      pxToVp: (px: number): number => this.getUIContext().px2vp(px),
    };
    const footerH = this.cfg.showFooter ? this.footerH_() : 0;
    // 页脚叠加在正文区域上方，需从可用于排版的高度中扣除
    const layoutH = Math.max(this.pageH * 0.5, this.pageH - footerH);
    this.pages = TextLayout.splitIntoPages(text, lc, this.pageW, layoutH, this.measureUtil_ || undefined);
    if (this.pages.length === 0) this.pages = [{ lines: [], startOffset: 0, endOffset: 0 }];
    if (this.pageIndex >= this.pages.length) this.pageIndex = Math.max(0, this.pages.length - 1);
  }

  private styleTimer_: number = -1;

	  private onStyleChange(c: PageViewConfig): void {
	    this.cfg = c;
	    this.readBgColor = c.bgColor;
	    this.readTextColor = c.textColor;
    this.applyReadColors();
    // 防抖：连续调整风格时延迟排版，避免大章节频繁测量卡顿
    if (this.styleTimer_ > 0) clearTimeout(this.styleTimer_);
    this.styleTimer_ = setTimeout(() => {
      this.styleTimer_ = -1;
      // 有原文时基于原文重走「简繁+替换」（此时 cfg 已是新配置）；无原文（错误提示页）保持现状
      const text = this.rawChapterContent_ ? this.processForDisplay_(this.rawChapterContent_) : this.text;
      this.text = text;
      // 排版前先应用夜间模式颜色覆盖（排版使用 display 颜色）
      this.applyReadColors();
      this.layoutText(text);
    }, 200);
	    this.queueStyleSave_(c);
	  }

	  private queueStyleSave_(config: PageViewConfig): void {
	    this.pendingStyleSave_ = {
	      config: this.cloneStyleConfig_(config),
	      readBgColor: this.readBgColor,
	      readTextColor: this.readTextColor,
	      readNightMode: this.readNightMode,
	      readFollowTheme: this.readFollowTheme,
	    };
	    if (this.styleSaveScheduled_) return;
	    this.styleSaveScheduled_ = true;
	    this.styleSavePromise_ = this.drainStyleSaveQueue_();
	  }

	  private async drainStyleSaveQueue_(): Promise<void> {
	    while (this.pendingStyleSave_) {
	      const snapshot = this.pendingStyleSave_;
	      this.pendingStyleSave_ = null;
	      await this.saveStyleSnapshot_(snapshot);
	    }
	    this.styleSaveScheduled_ = false;
	  }

	  private async flushStyleSave_(): Promise<void> {
	    await this.styleSavePromise_.catch(() => {});
	    if (this.pendingStyleSave_ && !this.styleSaveScheduled_) {
	      this.queueStyleSave_(this.pendingStyleSave_.config);
	      await this.styleSavePromise_.catch(() => {});
	    }
	  }

	  private async saveStyleSnapshot_(snapshot: ReadStyleSaveSnapshot): Promise<void> {
	    try {
	      const s = SettingsStore.getInstance();
	      const c = snapshot.config;
	      const values: Record<string, Object> = {};
	      values['font_size'] = c.fontSize;
	      values['font_family'] = c.fontFamily;
	      values['line_height'] = c.lineHeight;
	      values['indent_size'] = c.indentSize;
	      values['letter_spacing'] = c.letterSpacing;
	      values['para_spacing'] = c.paragraphSpacing;
	      values['font_weight'] = c.fontWeight;
	      values['padding_top'] = c.paddingTop;
	      values['padding_bottom'] = c.paddingBottom;
	      values['padding_left'] = c.paddingLeft;
	      values['padding_right'] = c.paddingRight;
	      values['read_bg'] = snapshot.readBgColor;
	      values['read_text'] = snapshot.readTextColor;
	      values['read_night_mode'] = snapshot.readNightMode;
	      values['read_follow_theme'] = snapshot.readFollowTheme;
	      values['chinese_mode'] = c.chineseMode;
	      values['zh_format'] = c.zhFormat;
	      try {
	        await s.putMany(values);
	      } catch (_e) {
	        await s.init(UiUtil.getHostContext(this.getUIContext()));
	        await s.putMany(values);
	      }
	    } catch (err) {
	      console.warn('[ReadPage] save style failed:', (err as Error).message);
	    }
	  }

	  private cloneStyleConfig_(c: PageViewConfig): PageViewConfig {
	    return {
	      animType: c.animType, bgColor: c.bgColor, textColor: c.textColor, titleColor: c.titleColor,
	      fontSize: c.fontSize, fontWeight: c.fontWeight, fontFamily: c.fontFamily,
	      lineHeight: c.lineHeight, letterSpacing: c.letterSpacing,
	      paragraphSpacing: c.paragraphSpacing, textAlign: c.textAlign, indentSize: c.indentSize,
	      paddingTop: c.paddingTop, paddingBottom: c.paddingBottom,
	      paddingLeft: c.paddingLeft, paddingRight: c.paddingRight,
	      showHeader: c.showHeader, showFooter: c.showFooter,
	      headerContent: c.headerContent, footerContent: c.footerContent,
	      brightness: c.brightness, zhFormat: c.zhFormat,
	      chineseMode: c.chineseMode,
	    };
	  }

  /**
   * 日间/夜间模式切换（由 StylePanel 回调触发）
   */
  private onNightModeToggle(night: boolean): void {
    this.readNightMode = night;
    this.applyReadColors();
    // 持久化夜间模式状态
    (async () => {
      try {
        const s = SettingsStore.getInstance();
        await s.init(UiUtil.getHostContext(this.getUIContext()));
        s.setReadNightMode(night).catch(() => {});
      } catch (_e) { /* ignore */ }
    })();
  }

  private onPageTurn(ev: PageTurnEvent): void { this.pageIndex = ev.currentPage; }

  private onPrevChapter(): void {
    if (this.currentIndex > 0) {
      this.loadChapter(this.currentIndex - 1).then(() => {
        this.pageIndex = Math.max(0, this.pages.length - 1);
      });
    }
  }
  private async onNextChapter(): Promise<void> {
    const n = this.currentIndex + 1;
    if (n >= this.totalChapters_) return;
    this.pageIndex = 0; // 新章从第 1 页开始
    // 无缝翻页：尝试使用预加载内容
    if (await this.tryUsePreloadedChapter_(n)) {
      return;
    }
    console.info('[ReadPage] Fallback loadChapter for:', n);
    this.loadChapter(n);
  }
  private onPrevPage(): void { if (this.pageIndex > 0) this.pageIndex--; else this.onPrevChapter(); }
  private onNextPage(): void { if (this.pageIndex < this.pages.length - 1) this.pageIndex++; else this.onNextChapter(); }

  private onOpenToc(): void {
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/ChapterListPage', params: { from: 'ReadPage', bookName: this.bookName, bookAuthor: this.bookAuthor, bookUrl: this.bookUrl, tocUrl: this.tocUrl, originUrl: this.originUrl, origin: this.origin, durChapterIndex: this.currentIndex, isManga: '0' } });
  }

  private onOpenSearchContent(): void {
    if (this.allChapters_.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '章节列表未加载', duration: 1500 });
      return;
    }
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/SearchContentPage',
      params: {
        bookId: this.bookId_,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        bookUrl: this.bookUrl,
        originUrl: this.originUrl,
        currentIndex: this.currentIndex,
      }
    });
  }

  /** 切换编码并重新解析 TXT */
  private async changeTxtEncoding_(encoding: string): Promise<void> {
    if (!this.isLocalTxt_ || !this.txtFilePath_) return;
    this.isLoading = true;
    try {
      const result = await TxtParser.parse(this.txtFilePath_, undefined, encoding);
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);
      const chapterDao = new ChapterTable(db);
      const book = await bookTable.getBookByUrl(this.bookUrl);
      if (!book) throw new Error('书籍不存在');

      // 更新书籍编码
      book.charset = encoding;
      await bookTable.updateBook(book);

      // 删除旧章节，写入新目录
      await chapterDao.deleteChaptersByBookId(book.id);
      const now = Date.now();
      const bookChapters: BookChapter[] = result.chapters.map((ch: BookChapter, idx: number): BookChapter => ({
        id: 0,
        bookId: book.id,
        index: ch.index >= 0 ? ch.index : idx,
        volumeIndex: ch.volumeIndex,
        title: ch.title,
        url: ch.url,
        content: '',
        contentLength: ch.contentLength,
        isRead: false,
        isDownloaded: true,
        isCached: false,
        duration: 0,
        audioUrl: '',
        createTime: now,
        updateTime: now,
        start: ch.start,
        end: ch.end,
      }));
      await chapterDao.insertChapters(bookChapters);

      // 更新章节列表并回到第一章
      this.allChapters_ = bookChapters.map((ch: BookChapter): BookSourceChapter => ({
        index: ch.index,
        title: ch.title,
        url: ch.url,
      }));
      this.totalChapters_ = this.allChapters_.length;
      this.chapters = this.allChapters_;
      this.txtEncoding_ = encoding;
      this.txtChapterCache_.clear();
      this.currentIndex = 0;
      this.pageIndex = 0;
      await this.loadChapter(0);
      UiUtil.showToast(this.getUIContext(), { message: `已切换编码为 ${encoding}`, duration: 1500 });
    } catch (e) {
      console.error('[ReadPage] change encoding failed:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '切换编码失败', duration: 1500 });
      this.isLoading = false;
    }
  }

  /** 清理换源时的瞬态阅读状态（不重置章节位置） */
  private clearTransientReadState_(): void {
    this.text = '';
    this.pages = [];
    this.nextChapterContent_ = '';
    this.nextChapterIdx_ = -1;
    this.isPreloading_ = false;
    this.preloadingChapterPromises_.clear();
  }

  /**
   * 整本换源（对齐 Legado ReadBookViewModel.applyChangeSource）：
   * 1. 先加载新源详情 + 目录并校验，目录为空则失败回退（不动数据库）
   * 2. 按章节标题/章节号匹配新目录中的当前章节（BookHelp.getDurChapter）
   * 3. 预验证匹配章节正文可读，避免换到一个目录有效但正文不可用的源
   * 4. 数据库迁移放在事务中执行；提交后若出现意外，用快照明确恢复
   * 5. 迁移阅读进度：保留匹配章节和章节内位置（durChapterPos）
   */
  private async applySourceChange(result: SearchResult): Promise<void> {
    const newBookUrl = result.noteUrl || '';
    const newOriginUrl = result.originUrl || '';
    if (!newBookUrl || !newOriginUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '书源信息不完整', duration: 1500 });
      return;
    }
    if (newBookUrl === this.bookUrl && newOriginUrl === this.originUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '已经是当前书源', duration: 1200 });
      return;
    }

    this.showMenu = false;
    this.isLoading = true;
    UiUtil.showToast(this.getUIContext(), { message: '正在校验新书源...', duration: 1500 });
    // 回滚快照
    let bookBackup: Book | null = null;
    let chaptersBackup: BookChapter[] = [];
    let migrated = false;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;

      // 1. 定位新源
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = newOriginUrl.replace(/\/+$/, '');
      const newSource = sources.find(s => s.sourceUrl === newOriginUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === result.origin) || null;
      if (!newSource) throw new Error('未找到对应书源');

      // 2. 加载书籍详情获取目录 URL
      let newTocUrl = '';
      try {
        const info = await globalSourceExecutor.getBookInfo(newSource, newBookUrl);
        newTocUrl = info.tocUrl || '';
      } catch (_e) { /* 详情失败时用 bookUrl 兜底拉目录 */ }

      // 3. 加载新目录并校验（关键：先验证成功，再动数据库）
      const primaryTocUrl = newTocUrl || newBookUrl;
      let newToc = await globalSourceExecutor.getToc(newSource, primaryTocUrl);
      if (newToc.length === 0 && primaryTocUrl !== newBookUrl) {
        newToc = await globalSourceExecutor.getToc(newSource, newBookUrl);
      }
      if (newToc.length === 0) throw new Error('新源目录为空');

      // 4. 在新目录中匹配当前阅读章节（保留阅读进度）
      const oldChapterTitle = this.allChapters_[this.currentIndex]?.title || '';
      const matchedIdx = ChapterMatcher.getDurChapterIndex(
        this.currentIndex, oldChapterTitle, newToc, this.totalChapters_);

      // 5. 目标 URL 查重：已是另一书架记录则拒绝，避免产生重复 bookUrl
      const bookTable = new BookTable(db);
      const shelfBook = this.bookUrl ? await bookTable.getBookByUrl(this.bookUrl) : null;
      const dupBook = await bookTable.getBookByUrl(newBookUrl);
      if (dupBook && (!shelfBook || dupBook.id !== shelfBook.id)) {
        if (dupBook.isShelf) throw new Error('目标源的书籍已在书架中');
        await bookTable.deleteBook(dupBook.id);
      }

      // 6. 预验证匹配章节正文可读（loadChapter 内部会吞异常，这里主动验证）
      const matchedChapter = newToc[matchedIdx];
      let verifiedContent = '';
      if (matchedChapter?.url) {
        try {
          verifiedContent = await globalSourceExecutor.getContent(newSource, matchedChapter.url, newBookUrl);
        } catch (_e) {
          verifiedContent = '';
        }
      }
      if (!verifiedContent || verifiedContent.length <= 50) throw new Error('新源正文加载失败');

      // 7. 事务迁移：更新书籍记录 + 替换目录（旧章节内容缓存一并清除）
      const chapterTable = new ChapterTable(db);
      if (shelfBook) {
        // 快照旧记录，供提交后异常时明确恢复（ArkTS 禁止对象展开，用 JSON 深拷贝）
        bookBackup = JSON.parse(JSON.stringify(shelfBook)) as Book;
        chaptersBackup = await chapterTable.getChaptersByBookId(shelfBook.id);

        shelfBook.bookUrl = newBookUrl;
        shelfBook.origin = result.origin || newSource.sourceName || this.origin;
        shelfBook.originUrl = newOriginUrl;
        shelfBook.tocUrl = primaryTocUrl;
        if (result.coverUrl && !shelfBook.customCoverPath) shelfBook.coverUrl = result.coverUrl;
        if (result.kind) shelfBook.kind = result.kind;
        if (result.wordCount) shelfBook.wordCount = result.wordCount;
        if (result.introduce) shelfBook.introduce = result.introduce;
        shelfBook.latestChapterTitle = newToc[newToc.length - 1]?.title || '';
        shelfBook.chapterCount = newToc.length;
        shelfBook.totalChapterNum = newToc.length;
        shelfBook.durChapterIndex = matchedIdx;
        shelfBook.durChapterTitle = newToc[matchedIdx]?.title || '';
        shelfBook.durChapterPos = this.pageIndex; // 保留章节内位置
        shelfBook.durChapterProgress = newToc.length > 0 ? matchedIdx / newToc.length : 0;
        shelfBook.lastOpenTime = Date.now();
        shelfBook.updateTime = Date.now();

        const now = Date.now();
        const rows: BookChapter[] = newToc.map((ch: BookSourceChapter, idx: number): BookChapter => ({
          id: 0,
          bookId: shelfBook.id,
          index: ch.index >= 0 ? ch.index : idx,
          volumeIndex: 0,
          title: ch.title || '',
          url: ch.url || '',
          content: '',
          contentLength: 0,
          isRead: false,
          isDownloaded: false,
          isCached: false,
          duration: 0,
          audioUrl: '',
          createTime: now,
          updateTime: now,
        }));
        db.beginTransaction();
        try {
          await bookTable.updateBook(shelfBook);
          await chapterTable.deleteChaptersByBookId(shelfBook.id);
          await chapterTable.insertChapters(rows);
          db.commit();
          migrated = true;
        } catch (txErr) {
          db.rollBack();
          throw new Error('数据库迁移失败: ' + (txErr as Error).message);
        }
        this.bookId_ = shelfBook.id;
        AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      }

      // 8. 更新内存状态（保留 pageIndex，即章节内阅读位置）
      this.origin = result.origin || newSource.sourceName || this.origin;
      this.originUrl = newOriginUrl;
      this.bookUrl = newBookUrl;
      this.tocUrl = primaryTocUrl;
      this.source_ = newSource;
      this.allChapters_ = newToc;
      this.totalChapters_ = newToc.length;
      this.chapters = newToc;
      this.targetIdx_ = matchedIdx;
      this.currentIndex = matchedIdx;
      this.clearTransientReadState_();
      ChapterCache.bookUrl = newBookUrl;
      ChapterCache.chapters = newToc;
      ChapterCache.targetIndex = matchedIdx;

      // 9. 换源后 origin 变化会改变规则集合，先重新加载替换规则；再直接应用已验证的正文
      // （pageIndex 由 layoutText 收敛到合法范围；verifiedContent 保持原文，净化在展示前进行，缓存存原文）
      await this.reloadReplaceRules_();
      this.applyChapterContent_(matchedIdx, verifiedContent);
      this.isLoading = false;
      await this.saveToDbCache_(matchedIdx, verifiedContent);
      this.saveProgress();
      this.preloadNextChapter_(matchedIdx);
      this.cacheSurrounding_(matchedIdx);
      UiUtil.showToast(this.getUIContext(), {
        message: '已更换书源：' + (newToc[matchedIdx]?.title || '第 ' + (matchedIdx + 1) + ' 章'),
        duration: 2000
      });
    } catch (e) {
      console.error('[ReadPage] applySourceChange failed:', (e as Error).message);
      // 已提交事务后出现意外：用快照明确恢复旧书籍记录和旧目录
      if (migrated && bookBackup) {
        try {
          const db = AppDatabase.getInstance().rdbStore;
          const bookTable = new BookTable(db);
          const chapterTable = new ChapterTable(db);
          await bookTable.updateBook(bookBackup);
          await chapterTable.deleteChaptersByBookId(bookBackup.id);
          if (chaptersBackup.length > 0) await chapterTable.insertChapters(chaptersBackup);
        } catch (rbErr) {
          console.error('[ReadPage] rollback failed:', (rbErr as Error).message);
        }
      }
      this.isLoading = false;
      UiUtil.showToast(this.getUIContext(), { message: '换源失败：' + (e as Error).message, duration: 2000 });
    }
  }

  private openSourceSheet(singleChapter: boolean = false): void {
    // 读取保存的搜索结果缓存（从 BookInfoPage 进入时写入了 router params）
    let cachedForSheet: SearchResult[] = [];
    try {
      const p = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
      if (p['cachedSources']) {
        cachedForSheet = JSON.parse(String(p['cachedSources'])) as SearchResult[];
      }
    } catch (_e) { /* ignore */ }

    this.sourceDlg = new CustomDialogController({
      builder: ChangeSourceSheet({
        controller: this.sourceDlg!,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        currentOriginUrl: this.originUrl,
        cachedSources: cachedForSheet,
        singleChapterMode: singleChapter,
        allowAddAsNew: false,
        currentSourceType: this.source_ ? this.source_.sourceType : -1,
        onReplace: (result: SearchResult) => {
          if (singleChapter) {
            this.applySingleChapterSource_(result);
          } else {
            this.applySourceChange(result);
          }
        },
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.sourceDlg.open();
  }

  /** 长按换源按钮：选择整本换源或单章换源（对齐 Legado ReadBookMenuBar） */
  private showChangeSourceMenu_(): void {
    this.showMenu = false;
    this.optionDlg = new CustomDialogController({
      builder: OptionSelectSheet({
        controller: this.optionDlg!,
        title: '换源方式',
        options: [
          {
            title: '整本换源',
            description: '替换整本书的书源，迁移阅读进度',
            action: () => { this.openSourceSheet(false); }
          },
          {
            title: '单章换源',
            description: '只从其他源替换当前章节内容',
            action: () => { this.openSourceSheet(true); }
          },
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.optionDlg.open();
  }

  /** 替换净化菜单（RR-8）：全局开关 + 跳规则管理页 */
  private showReplaceRuleMenu_(): void {
    this.showMenu = false;
    this.optionDlg = new CustomDialogController({
      builder: OptionSelectSheet({
        controller: this.optionDlg!,
        title: '替换净化',
        options: [
          {
            title: '替换净化',
            description: this.replaceEnabled_ ? '当前：已开启（点击关闭）' : '当前：已关闭（点击开启）',
            action: () => { this.toggleReplaceEnabled_(); }
          },
          {
            title: '替换净化设置',
            description: '管理替换规则',
            action: () => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/ReplaceRulePage' }); }
          },
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.optionDlg.open();
  }

  private currentChapterUrl_(): string {
    return this.allChapters_[this.currentIndex]?.url || this.bookUrl || '';
  }

  private currentSourceName_(): string {
    return this.source_?.sourceName || this.origin || (this.isLocalBook_ ? '本地书籍' : '未知书源');
  }

  /** 顶部“更多”承载低频阅读工具，底部只保留高频入口。 */
  private showReadToolsMenu_(): void {
    this.showMenu = false;
    const options: OptionItem[] = [];
    if (!this.isLocalBook_) {
      options.push({
        title: '更换书源',
        description: '为整本书选择其他书源',
        action: () => { this.openSourceSheet(false); }
      });
      options.push({
        title: '缓存章节',
        description: '缓存当前章节附近或整本书',
        action: () => { this.showCacheDialog = true; }
      });
    }
    options.push({
      title: '刷新当前章',
      description: '重新加载当前章节内容',
      action: () => {
        this.loadChapter(this.currentIndex, true);
        UiUtil.showToast(this.getUIContext(), { message: '已刷新', duration: 1500 });
      }
    });
    options.push({
      title: '替换净化',
      description: '切换净化状态或管理替换规则',
      action: () => { setTimeout((): void => { this.showReplaceRuleMenu_(); }, 120); }
    });
    this.optionDlg = new CustomDialogController({
      builder: OptionSelectSheet({
        controller: this.optionDlg!,
        title: '更多阅读工具',
        options: options
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.optionDlg.open();
  }

  /** 切换替换净化全局开关：写入设置并立即用原文重排当前章（不重抓网络、不清缓存） */
  private async toggleReplaceEnabled_(): Promise<void> {
    this.replaceEnabled_ = !this.replaceEnabled_;
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      await s.setReplaceEnabled(this.replaceEnabled_);
    } catch (_e) { /* ignore */ }
    UiUtil.showToast(this.getUIContext(), {
      message: this.replaceEnabled_ ? '已开启替换净化' : '已关闭替换净化', duration: 1500 });
    this.relayoutWithRawContent_();
  }

  /**
   * 单章换源（对齐 Legado ChangeChapterSourceViewModel）：
   * 只替换当前章节的正文，不改变整本书的书源和目录。
   * 选中源 → 加载其目录 → 按当前章节匹配预选 → 用户确认章节 → 加载正文替换。
   */
  private async applySingleChapterSource_(result: SearchResult): Promise<void> {
    const newBookUrl = result.noteUrl || '';
    const newOriginUrl = result.originUrl || '';
    if (!newBookUrl || !newOriginUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '书源信息不完整', duration: 1500 });
      return;
    }
    this.showMenu = false;
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = newOriginUrl.replace(/\/+$/, '');
      const newSource = sources.find(s => s.sourceUrl === newOriginUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === result.origin) || null;
      if (!newSource) throw new Error('未找到对应书源');

      let tocUrl = '';
      try {
        const info = await globalSourceExecutor.getBookInfo(newSource, newBookUrl);
        tocUrl = info.tocUrl || '';
      } catch (_e) { /* 用 bookUrl 兜底 */ }
      const primaryTocUrl = tocUrl || newBookUrl;
      let toc = await globalSourceExecutor.getToc(newSource, primaryTocUrl);
      if (toc.length === 0 && primaryTocUrl !== newBookUrl) {
        toc = await globalSourceExecutor.getToc(newSource, newBookUrl);
      }
      if (toc.length === 0) throw new Error('该源目录为空');
      this.isLoading = false;

      // 按当前章节标题在新目录中预选（同一套 getDurChapter 匹配算法）
      const curTitle = this.allChapters_[this.currentIndex]?.title || '';
      const matched = ChapterMatcher.getDurChapterIndex(
        this.currentIndex, curTitle, toc, this.totalChapters_);
      this.chapterPickDlg = new CustomDialogController({
        builder: ChapterPickSheet({
          controller: this.chapterPickDlg!,
          chapters: toc,
          currentIndex: matched,
          onPick: (idx: number) => { this.fetchAndReplaceChapter_(newSource, newBookUrl, toc, idx); },
        }),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        customStyle: true
      });
      this.chapterPickDlg.open();
    } catch (e) {
      console.error('[ReadPage] singleChapterSource failed:', (e as Error).message);
      this.isLoading = false;
      UiUtil.showToast(this.getUIContext(), { message: '单章换源失败：' + (e as Error).message, duration: 2000 });
    }
  }

  /** 单章换源：加载目标章节正文并替换当前章节缓存 */
  private async fetchAndReplaceChapter_(
    source: BookSource, bookUrl: string, toc: BookSourceChapter[], idx: number
  ): Promise<void> {
    const ch = toc[idx];
    if (!ch || !ch.url) {
      UiUtil.showToast(this.getUIContext(), { message: '章节信息不完整', duration: 1500 });
      return;
    }
    this.isLoading = true;
    try {
      let content = await globalSourceExecutor.getContent(source, ch.url, bookUrl);
      if (!content || content.length <= 50) throw new Error('正文为空');
      const target = this.currentIndex;
      // content 为原文；简繁转换 + 用户规则替换在 applyChapterContent_ 内统一处理
      this.applyChapterContent_(target, content);
      this.isLoading = false;
      // 覆盖数据库中本章的内容缓存（存净化前原文），后续翻页不再回退到旧源内容
      await this.saveToDbCache_(target, content);
      this.preloadNextChapter_(target);
      this.cacheSurrounding_(target);
      UiUtil.showToast(this.getUIContext(), { message: '已替换本章内容', duration: 1500 });
    } catch (e) {
      console.error('[ReadPage] fetchAndReplaceChapter failed:', (e as Error).message);
      this.isLoading = false;
      UiUtil.showToast(this.getUIContext(), { message: '单章换源失败：' + (e as Error).message, duration: 2000 });
    }
  }

  private getNextChapterForAloud_(): Promise<import('../service/ReadAloudEngine').AloudChapterText | null> {
    return (async (): Promise<import('../service/ReadAloudEngine').AloudChapterText | null> => {
      const startIdx = this.lastProviderIdx_ >= 0 ? this.lastProviderIdx_ : this.currentIndex;
      const n = startIdx + 1;
      console.info('[ReadPage] getNextChapterAloud: lastProvider=' + startIdx + ' next=' + n);
      if (n >= this.totalChapters_) return null;
      this.lastProviderIdx_ = n;
      if (this.nextChapterIdx_ === n && this.nextChapterContent_ && this.nextChapterContent_.length > 50) {
        const raw = this.nextChapterContent_; this.nextChapterContent_ = ''; this.nextChapterIdx_ = -1;
        // 预加载内容为原文，朗读前补一遍展示处理（简繁 + 用户规则替换）
        const text = this.processForDisplay_(raw);
        console.info('[ReadPage] provider: using preloaded ch=' + n + ' len=' + text.length);
        return { text: text, offset: 0, chapterIndex: n };
      }
      if (!this.preloadingChapterPromises_.has(n)) {
        const ch = this.allChapters_[n];
        if (ch) {
          let promise: Promise<string>;
          if (this.isLocalTxt_) {
            promise = this.readLocalTxtChapter_(n);
          } else if (this.isLocalBook_) {
            promise = this.readChapterCache_(n);
          } else {
            const src = this.source_;
            promise = src ? globalSourceExecutor.getContent(src, ch.url || '', this.bookUrl) : Promise.resolve('');
          }
          this.preloadingChapterPromises_.set(n, promise);
        }
      }
      const promise = this.preloadingChapterPromises_.get(n);
      if (promise) { const content = await promise; this.preloadingChapterPromises_.delete(n); return content ? { text: this.processForDisplay_(content), offset: 0, chapterIndex: n } : null; }
      return null;
    })();
  }

  private async goToReadingPosition_(charIndex: number, chapterIdx?: number): Promise<void> {
    // 如果引擎在朗读另一章，先加载目标章节
    if (chapterIdx !== undefined && chapterIdx >= 0 && chapterIdx !== this.currentIndex) {
      this.showAloud = false;
      if (chapterIdx < this.allChapters_.length) {
        await this.loadChapter(chapterIdx);
        // pages 已由 loadChapter → applyChapterContent_ → layoutText 生成
      } else {
        return;
      }
    }
    if (this.pages.length === 0) return;
    for (let i = 0; i < this.pages.length; i++) {
      if (charIndex >= this.pages[i].startOffset && charIndex < this.pages[i].endOffset) {
        this.pageIndex = i;
        return;
      }
    }
  }

  private formatCurTime(): string {
    const d = new Date();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${hh}:${mm}`;
  }

  /** 添加书签：当前章节 + 页首字符偏移 + 当前页文本（对齐安卓阅读页菜单入口） */
  private addBookmark_(): void {
    if (this.bookId_ <= 0) {
      UiUtil.showToast(this.getUIContext(), { message: '书籍未入库，无法添加书签', duration: 1500 });
      return;
    }
    const page = this.pages.length > 0 ? this.pages[this.pageIndex] : null;
    const start = page ? page.startOffset : 0;
    const end = page ? page.endOffset : 0;
    let pageText = this.text.substring(start, end).trim();
    if (pageText.length > 200) pageText = pageText.substring(0, 200);
    this.bookmarkDraftText_ = pageText;
    this.bookmarkDraftNote_ = '';
    this.showBookmarkDlg = true;
  }

  private async saveBookmark_(text: string, note: string): Promise<void> {
    this.showBookmarkDlg = false;
    try {
      const ch = this.allChapters_[this.currentIndex];
      const page = this.pages.length > 0 ? this.pages[this.pageIndex] : null;
      const now = Date.now();
      const bookmark: Bookmark = {
        id: 0,
        bookId: this.bookId_,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        chapterIndex: this.currentIndex,
        chapterName: ch ? ch.title || '' : '',
        chapterPos: page ? page.startOffset : 0,
        text: text,
        note: note,
        createTime: now,
        updateTime: now,
      };
      await AppDatabase.getInstance().waitForInit();
      await new BookmarkTable(AppDatabase.getInstance().rdbStore).insert(bookmark);
      UiUtil.showToast(this.getUIContext(), { message: '已添加书签', duration: 1500 });
    } catch (e) {
      console.warn('[ReadPage] save bookmark fail:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '添加书签失败', duration: 1500 });
    }
  }

  // 页脚高度：分割线(4+1+4) + 文本行(~15) + 底部留白(10)，需与页脚布局保持一致
  private footerH_(): number { return 34; }

  private initAloudEngine_(): void {
    if (this.aloudEngine_) {
      try { this.aloudEngine_.release(); } catch (_) {}
      this.aloudEngine_ = null;
    }
    this.aloudEngine_ = new ReadAloudEngine({
      onStateChange: (s: AloudState) => {
        console.info('[ReadPage] Aloud state: ' + s);
      },
      onProgress: (_charIdx: number, _total: number) => { },
      onChapterEnd: () => {
        this.onNextChapter();
      },
      onError: (msg: string) => {
        console.error('[ReadPage] Aloud error: ' + msg);
        UiUtil.showToast(this.getUIContext(), { message: msg, duration: 2000 });
      },
    });
  }

  /** 问 Kimi */
  private onAskKimi(text: string): void {
    if (!text) return;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        bundleName: 'com.hos.moonshot.kimichat', abilityName: 'EntryAbility',
        parameters: { 'query': text, 'text': text },
      };
      ctx.startAbility(want).catch(() => {
        UiUtil.showToast(this.getUIContext(), { message: '未安装Kimi', duration: 1500 });
      });
    } catch (_e) { UiUtil.showToast(this.getUIContext(), { message: '启动失败', duration: 1500 }); }
  }

  /** 问小艺 */
  private onAskXiaoYi(text: string): void {
    if (!text) return;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.startAbility({
        action: 'ohos.want.action.search',
        parameters: { 'query': text },
      }).catch(() => { /* ignore */ });
    } catch (_e) { /* ignore */ }
  }

  build() {
    Stack() {
	      if (this.isLoading) {
	        Column() { LoadingProgress().width(40).height(40).color(ThemeColors.primary(this.isDark)) }
	        .width('100%').height('100%').justifyContent(FlexAlign.Center)
	      } else if (this.pages.length > 0) {
        if (this.flowMode === 'scrolled') {
          // 滚动阅读模式
          Scroll() {
            Text(this.text)
              .fontSize(this.cfg.fontSize)
              .fontColor(this.cfg.textColor)
              .fontFamily(this.cfg.fontFamily)
              .fontWeight(this.cfg.fontWeight >= 2 ? FontWeight.Bold : FontWeight.Normal)
              .lineHeight(this.cfg.fontSize * this.cfg.lineHeight)
              .letterSpacing(this.cfg.letterSpacing)
              .textAlign(this.cfg.textAlign === 'justify' ? TextAlign.JUSTIFY : TextAlign.Start)
              .width('100%')
              .padding({
                left: this.cfg.paddingLeft,
                right: this.cfg.paddingRight,
                top: this.cfg.paddingTop,
                bottom: this.cfg.paddingBottom,
              })
              .onClick(() => { this.showMenu = true; })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .backgroundColor(this.cfg.bgColor)
          .onReachEnd(() => { this.onNextChapter(); })
          .onReachStart(() => { this.onPrevChapter(); })
          .width('100%').height('100%')
        } else {
	        PageView({
          pages: this.pages, chapterTitle: this.displayTitle_,
          chapterIndex: this.currentIndex, pageIndex: this.pageIndex, totalChapters: this.totalChapters_,
          zoneActions: this.zoneActions,
          config: {
            animType: this.cfg.animType, bgColor: this.cfg.bgColor, textColor: this.cfg.textColor,
            titleColor: this.cfg.titleColor, fontSize: this.cfg.fontSize, fontWeight: this.cfg.fontWeight,
            fontFamily: this.cfg.fontFamily, lineHeight: this.cfg.lineHeight, letterSpacing: this.cfg.letterSpacing,
            paragraphSpacing: this.cfg.paragraphSpacing, textAlign: this.cfg.textAlign, indentSize: this.cfg.indentSize,
            paddingTop: this.cfg.paddingTop, paddingBottom: this.cfg.paddingBottom,
            paddingLeft: this.cfg.paddingLeft, paddingRight: this.cfg.paddingRight,
            showHeader: false, showFooter: false, headerContent: '', footerContent: '',
            brightness: this.cfg.brightness, zhFormat: this.cfg.zhFormat, chineseMode: this.cfg.chineseMode,
          },
          onPageTurn: (ev: PageTurnEvent) => { this.onPageTurn(ev); },
          onPrevChapter: () => { this.onPrevChapter(); },
          onNextChapter: () => { this.onNextChapter(); },
          onShowMenu: () => { this.showMenu = true; },
          onShowToc: () => { this.onOpenToc(); },
          onAskKimi: (text: string) => { this.onAskKimi(text); },
          onAskXiaoYi: (text: string) => { this.onAskXiaoYi(text); },
          onMeasured: (cw: number, lh: number) => {
            if (cw > 0 && this.measureCharW_ !== cw) { this.measureCharW_ = cw; }
            if (lh > 0 && this.measureLineH_ !== lh) { this.measureLineH_ = lh; }
          },
        }).width('100%').height('100%')
      }
      }
      // 页脚：直接渲染在 ReadPage Stack 中，PageView 上方
      if (!this.isLoading && this.pages.length > 0 && this.cfg.showFooter) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Row().width('100%').height(1).backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ top: 4, bottom: 4 })
            Row() {
              Text(this.displayTitle_)
                .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
                .fontFamily(this.cfg.fontFamily)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text(this.formatCurTime())
                .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
                .fontFamily(this.cfg.fontFamily).margin({ right: 10 })
              if (this.flowMode !== 'scrolled') {
                Text(`${this.pageIndex + 1}/${this.pages.length}` +
                  (this.totalChapters_ > 0 ? ` (${this.getProgressPercent()}%)` : '')).fontColor(ThemeColors.onSurface(this.isDark))
                  .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
                  .fontFamily(this.cfg.fontFamily)
              }
            }.width('100%')
              .padding({ left: this.cfg.paddingLeft, right: this.cfg.paddingRight })
          }
          .width('100%')
          .padding({ bottom: 10 })
          .backgroundColor(this.cfg.bgColor)
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.showMenu) {
        Column() {
          ReadTopMenu({
            bookName: this.bookName,
            chapterTitle: this.displayTitle_,
            chapterUrl: this.currentChapterUrl_(),
            sourceName: this.currentSourceName_(),
            onBack: () => { UiUtil.back(this.getUIContext()); },
            onSearch: () => { this.showMenu = false; this.onOpenSearchContent(); },
            onBookmark: () => { this.showMenu = false; this.addBookmark_(); },
            onMore: () => { this.showReadToolsMenu_(); },
          })
          Column().width('100%').layoutWeight(1).onClick(() => { this.showMenu = false; })
          ReadProgressBar({
            currentIndex: this.currentIndex,
            total: this.totalChapters_,
            onPrevious: () => { this.showMenu = false; this.onPrevChapter(); },
            onNext: () => { this.showMenu = false; this.onNextChapter(); },
            onSeek: (index: number) => {
              this.showMenu = false;
              this.pageIndex = 0;
              this.loadChapter(index);
            },
          })
          ReadBottomMenu({
            onToc: () => { this.showMenu = false; this.onOpenToc(); },
            onReadAloud: () => { this.showMenu = false; if (!this.aloudEngine_) { UiUtil.showToast(this.getUIContext(), {message:'请先加载章节内容',duration:1500}); return; } this.showAloud = true; },
            onStyle: () => { this.showMenu = false; this.showStyle = true; },
            onSettings: () => { this.showMenu = false; this.showZoneConfig = true; },
          })
        }.width('100%').height('100%')
      }
      if (this.showStyle) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showStyle = false; })
          StylePanel({
            cfg: this.cfg, onChange: (c: PageViewConfig) => { this.onStyleChange(c); },
            onDismiss: () => { this.showStyle = false; },
            fontList: this.fontList,
            nightMode: this.readNightMode,
            dayBgColor: this.readBgColor,
            dayTextColor: this.readTextColor,
            onNightModeToggle: (night: boolean) => { this.onNightModeToggle(night); },
          })
        }.width('100%').height('100%')
      }
      if (this.showCacheDialog) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showCacheDialog = false; })
          CacheDialog({
            bookName: this.bookName,
            bookOriginUrl: this.bookUrl,
            bookId: this.bookId_,
            source: this.source_,
            chapters: this.allChapters_,
            totalChapters: this.totalChapters_,
            currentIndex: this.currentIndex,
            onDismiss: () => { this.showCacheDialog = false; },
            onCacheComplete: () => { UiUtil.showToast(this.getUIContext(), { message: '缓存完成', duration: 1500 }); },
            onCacheStart: () => {},
          })
        }.width('100%').height('100%')
      }

      if (this.showBookmarkDlg) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showBookmarkDlg = false; })
          BookmarkEditDialog({
            title: '添加书签',
            initialText: this.bookmarkDraftText_,
            initialNote: this.bookmarkDraftNote_,
            onSave: (text: string, note: string) => { this.saveBookmark_(text, note); },
            onDismiss: () => { this.showBookmarkDlg = false; },
          })
        }.width('100%').height('100%')
      }

      // 云端进度确认弹窗（增强同步模式：云端更远时询问是否恢复）
      if (this.showCloudProgressDlg && this.pendingCloudProgress_) {
        Column() {
          Column().width('100%').height('100%').backgroundColor(ThemeColors.strongScrim(this.isDark))
            .onClick(() => { this.showCloudProgressDlg = false; })
          Column() {
            Text($r('app.string.ui_literal_d65ca51e8a')).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.onBackground(this.isDark))
              .padding({ top: 16, bottom: 8 })
            Text('云端已读到第 ' + (this.pendingCloudProgress_!.durChapterIndex + 1) + ' 章'
              + (this.pendingCloudProgress_!.durChapterTitle ? '「' + this.pendingCloudProgress_!.durChapterTitle + '」' : '')
              + '，是否恢复？').fontColor(ThemeColors.onSurface(this.isDark))
              .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
              .padding({ left: 20, right: 20, bottom: 16 })
            Row() {
              Button($r('app.string.ui_literal_763d09922a')).fontSize(15).fontColor(ThemeColors.secondaryText(this.isDark))
                .backgroundColor(Color.Transparent).height(44).layoutWeight(1)
                .onClick(() => {
                  this.showCloudProgressDlg = false;
                  this.pendingCloudProgress_ = null;
                  // 保留本地进度并回传云端
                  this.saveAndUploadProgress(true);
                })
              Button($r('app.string.ui_literal_79748ca1c6')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark))
                .backgroundColor(ThemeColors.primary(this.isDark)).height(44).layoutWeight(1)
                .onClick(() => {
                  const cloud = this.pendingCloudProgress_!;
                  this.showCloudProgressDlg = false;
                  this.pendingCloudProgress_ = null;
                  this.applyCloudProgress_(cloud);
                })
            }.width('100%')
          }
          .width('80%').backgroundColor(ThemeColors.surface(this.isDark))
          .borderRadius(16)
          .position({ x: '10%', y: '35%' })
        }.width('100%').height('100%')
      }

      if (this.showAloud) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showAloud = false; })
          ReadAloudPanel({
            text: this.text,
            textOffset: this.pages.length > 0 ? (this.pages[this.pageIndex]?.startOffset || 0) : 0,
            currentChapterIndex: this.currentIndex,
            chapterTitle: this.displayTitle_,
            externalEngine: this.aloudEngine_!,
            onDismiss: () => { this.showAloud = false; },
            onGoToPosition: (charIdx: number, chapterIdx?: number) => { this.goToReadingPosition_(charIdx, chapterIdx); },
            onNextChapter: () => { this.showAloud = false; this.onNextChapter(); },
            onPrevChapter: () => { this.showAloud = false; this.onPrevChapter(); },
          })
        }.width('100%').height('100%')
      }
      if (this.showZoneConfig) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showZoneConfig = false; })
          ClickActionConfig({
            onDismiss: () => { this.showZoneConfig = false; },
            onChanged: (actions: number[]) => { this.zoneActions = [...actions]; },
            isLocalTxt: this.isLocalTxt_,
            txtEncoding: this.txtEncoding_,
            flowMode: this.flowMode,
            onEncodingChange: (enc: string) => { this.changeTxtEncoding_(enc); },
            onFlowModeChange: (mode: string) => { this.flowMode = mode; },
          })
        }.width('100%').height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor(this.cfg.bgColor)
    .onAreaChange((_old: Area, n: Area) => {
      const w = typeof n.width === 'number' ? n.width : Number(n.width) || 360;
      const h = typeof n.height === 'number' ? n.height : Number(n.height) || 640;
      if (w > 0 && h > 0) { this.pageW = w; this.pageH = h; if (this.text) this.layoutText(this.text); }
    })
  }
}
