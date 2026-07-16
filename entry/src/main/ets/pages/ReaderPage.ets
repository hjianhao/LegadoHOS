/**
 * 本地图文混排阅读页：EPUB 使用 EPUB.js，MOBI/AZW/AZW3 使用 foliate-js。
 */
import web_webview from '@ohos.web.webview';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import window from '@ohos.window';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { Book } from '../model/Book';
import { BookChapter } from '../model/BookChapter';
import { ClickAction, DEFAULT_ZONE_ACTIONS } from '../components/reader/ClickAction';
import { ClickActionConfig } from '../components/reader/ClickActionConfig';
import { PageViewConfig, PageTurnAnim } from '../components/reader/PageView';
import { ReadAloudPanel } from '../components/reader/ReadAloudPanel';
import { ReadBottomMenu } from '../components/reader/ReadBottomMenu';
import { StylePanel } from '../components/reader/StylePanel';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { EpubServer, EpubFontResource } from '../utils/EpubServer';
import { FontManager, FontInfo } from '../utils/FontManager';
import { HtmlUtil } from '../util/HtmlUtil';
import { AloudChapterText, releaseGlobalAloudEngine, setAloudChapterProvider } from '../service/ReadAloudEngine';

interface ReaderEvent {
  type: string;
  data?: Object;
}

interface LocationEvent {
  cfi?: string;
  href?: string;
  chapterIndex?: number;
  page?: number;
  totalPages?: number;
  percentage?: number;
}

interface TapActionEvent {
  zone?: number;
  action?: number;
}

interface PublicationMetadataEvent {
  title?: string;
  author?: string;
  description?: string;
  pageCount?: number;
  pdfReflowAvailable?: boolean;
  pdfMode?: string;
}

interface ChapterTextEvent {
  requestId: string;
  text: string;
  error?: string;
}

interface EpubTocItem {
  label: string;
  href: string;
  level: number;
}

interface WebReaderStyle {
  animType: number;
  flowMode: string;
  pdfMode: string;
  pdfAutoCrop: boolean;
  pdfDarken: number;
  pdfWhiten: number;
  backgroundColor: string;
  color: string;
  fontSize: number;
  fontFamily: string;
  fontWeight: string;
  lineHeight: number;
  letterSpacing: number;
  paragraphSpacing: number;
  textAlign: string;
  indentSize: number;
  paddingTop: number;
  paddingBottom: number;
  paddingLeft: number;
  paddingRight: number;
  zhFormat: boolean;
  chineseMode: string;
  fontFaces: WebReaderFontFace[];
}

interface WebReaderFontFace {
  familyName: string;
  url: string;
}

interface EpubStyleSaveSnapshot {
  config: PageViewConfig;
  readBgColor: string;
  readTextColor: string;
  readNightMode: boolean;
  readFollowTheme: boolean;
}

const EPUB_BOOK_FONT_FAMILY = '__book__';
const EPUB_FONT_SIZE_KEY = 'epub_font_size';
const EPUB_FONT_FAMILY_KEY = 'epub_font_family';
const EPUB_LINE_HEIGHT_KEY = 'epub_line_height';
const EPUB_INDENT_SIZE_KEY = 'epub_indent_size';
const EPUB_LETTER_SPACING_KEY = 'epub_letter_spacing';
const EPUB_PARAGRAPH_SPACING_KEY = 'epub_para_spacing';
const EPUB_FONT_WEIGHT_KEY = 'epub_font_weight';
const EPUB_PADDING_TOP_KEY = 'epub_padding_top';
const EPUB_PADDING_BOTTOM_KEY = 'epub_padding_bottom';
const EPUB_PADDING_LEFT_KEY = 'epub_padding_left';
const EPUB_PADDING_RIGHT_KEY = 'epub_padding_right';
const EPUB_CHINESE_MODE_KEY = 'epub_chinese_mode';
const EPUB_ZH_FORMAT_KEY = 'epub_zh_format';
const EPUB_READ_BG_KEY = 'epub_read_bg';
const EPUB_READ_TEXT_KEY = 'epub_read_text';
const EPUB_READ_NIGHT_MODE_KEY = 'epub_read_night_mode';
const EPUB_READ_FOLLOW_THEME_KEY = 'epub_read_follow_theme';
const EPUB_FLOW_MODE_KEY = 'epub_flow_mode';
const PDF_AUTO_CROP_KEY = 'pdf_auto_crop';
const PDF_DARKEN_KEY = 'pdf_darken';
const PDF_WHITEN_KEY = 'pdf_whiten';
const PDF_MODE_KEY = 'pdf_read_mode';
const EPUB_BOOK_FONT: FontInfo = {
  id: 'epub_book',
  name: '书籍原始字体',
  familyName: EPUB_BOOK_FONT_FAMILY,
  type: 'system',
};

@Entry
@Component
struct ReaderPage {
  @StorageLink('isDark') @Watch('onThemeModeChange_') isDark: boolean = false;
  @State bookName: string = '';
  @State progressText: string = '加载中...';
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State showMenu: boolean = false;
  @State showToc: boolean = false;
  @State showStyle: boolean = false;
  @State showZoneConfig: boolean = false;
  @State showAloud: boolean = false;
  @State currentIndex: number = 0;
  @State currentTitle: string = '';
  @State pageText: string = '';
  @State aloudText: string = '';
  @State aloudTextOffset: number = 0;
  @State readBgColor: string = '#F5F0E8';
  @State readTextColor: string = '#333333';
  @State readNightMode: boolean = false;
  @State readFollowTheme: boolean = true;
  @State flowMode: string = 'paginated';
  @State pdfMode: string = 'original';
  @State pdfAutoCrop: boolean = false;
  @State pdfDarken: number = 0;
  @State pdfWhiten: number = 0;
  @State zoneActions: number[] = DEFAULT_ZONE_ACTIONS;
  @State tocItems: EpubTocItem[] = [];
  @State fontList: FontInfo[] = [];
  @State cfg: PageViewConfig = {
    animType: PageTurnAnim.NONE,
    bgColor: '#F5F0E8',
    textColor: '#333333',
    titleColor: '#999999',
    fontSize: 18,
    fontWeight: 1,
    fontFamily: EPUB_BOOK_FONT_FAMILY,
    lineHeight: 1.6,
    letterSpacing: 0.5,
    paragraphSpacing: 10,
    textAlign: 'justify',
    indentSize: 2,
    paddingTop: 24,
    paddingBottom: 24,
    paddingLeft: 20,
    paddingRight: 20,
    showHeader: false,
    showFooter: true,
    headerContent: '',
    footerContent: '',
    brightness: 80,
    zhFormat: true,
    chineseMode: 'original',
  };

  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private server_: EpubServer = new EpubServer();
  private book_: Book | null = null;
  private bookUrl_: string = '';
  private chapters_: BookChapter[] = [];
  private pollTimer_: number = -1;
  private pollBusy_: boolean = false;
  private styleTimer_: number = -1;
  private saveTimer_: number = -1;
  private readyTimer_: number = -1;
  private currentCfi_: string = '';
  private currentHref_: string = '';
  private currentPercent_: number = 0;
  private currentPage_: number = 0;
  private currentTotalPages_: number = 0;
  private opfDir_: string = '';
  private isMobi_: boolean = false;
  private isPdf_: boolean = false;
  private isFoliate_: boolean = false;
  private isEpubFoliate_: boolean = false;
  private lastAloudProviderIdx_: number = -1;
  private chapterTextRequestId_: string = '';
  private chapterTextResolver_: ((text: string) => void) | null = null;
  private chapterTextTimer_: number = -1;
  private pendingStyleSave_: EpubStyleSaveSnapshot | null = null;
  private styleSavePromise_: Promise<void> = Promise.resolve();
  private styleSaveScheduled_: boolean = false;
  private pdfEnhanceTimer_: number = -1;

  private static readonly NIGHT_BG: string = '#1A1A1A';
  private static readonly NIGHT_TEXT: string = '#C0C0C0';

  async aboutToAppear(): Promise<void> {
    await this.initFonts_();
    this.startLoad_();
    this.setSystemBarVisible_(false);
  }

  onPageShow(): void {
    this.setSystemBarVisible_(false);
    this.reloadFollowThemeSetting_();
    this.refreshFonts_();
  }

  private onThemeModeChange_(): void {
    this.syncReadThemeWithApp_();
  }

  private reloadFollowThemeSetting_(): void {
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(async () => {
        this.readFollowTheme = await SettingsStore.getInstance().get<boolean>(EPUB_READ_FOLLOW_THEME_KEY, true);
        this.syncReadThemeWithApp_();
      })
      .catch(() => {});
  }

  private syncReadThemeWithApp_(): void {
    if (!this.readFollowTheme || this.readNightMode === this.isDark) {
      return;
    }
    this.readNightMode = this.isDark;
    this.applyReadColors_();
    if (!this.isLoading && !this.loadError) {
      this.applyStyleNow_();
    }
  }

  async aboutToDisappear(): Promise<void> {
    this.stopPoll_();
    if (this.styleTimer_ > 0) clearTimeout(this.styleTimer_);
    if (this.saveTimer_ > 0) clearTimeout(this.saveTimer_);
    if (this.readyTimer_ > 0) clearTimeout(this.readyTimer_);
    if (this.pdfEnhanceTimer_ > 0) {
      clearTimeout(this.pdfEnhanceTimer_);
      this.pdfEnhanceTimer_ = -1;
      await this.savePdfEnhance_();
    }
    this.finishChapterTextRequest_('');
    await this.flushStyleSave_();
    this.server_.stop();
    releaseGlobalAloudEngine().catch(() => {});
    this.setSystemBarVisible_(true);
  }

  private async setSystemBarVisible_(visible: boolean): Promise<void> {
    try {
      const context = UiUtil.getHostContext(this.getUIContext());
      if (!context) return;
      const win: window.Window = await window.getLastWindow(context);
      if (visible) {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        await win.setWindowSystemBarEnable([]);
      }
    } catch (err) {
      console.warn('[ReaderPage] setSystemBar failed:', (err as Error).message);
    }
  }

  private async initFonts_(): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.Context;
      await FontManager.getInstance().init(ctx);
      FontManager.getInstance().registerAll(this.getUIContext());
      this.fontList = this.buildEpubFontList_();
      this.server_.setFontFiles(this.toFontResources_());
    } catch (err) {
      console.warn('[ReaderPage] Font init failed:', (err as Error).message);
    }
  }

  private refreshFonts_(): void {
    try {
      this.fontList = this.buildEpubFontList_();
      this.server_.setFontFiles(this.toFontResources_());
      if (!this.isSupportedEpubFont_(this.cfg.fontFamily)) {
        this.cfg.fontFamily = EPUB_BOOK_FONT_FAMILY;
        this.onStyleChange_(this.cfg);
      }
      if (!this.isLoading && !this.loadError) {
        this.applyStyleNow_();
      }
    } catch (_e) {}
  }

  private buildEpubFontList_(): FontInfo[] {
    const fonts: FontInfo[] = [EPUB_BOOK_FONT];
    for (const font of FontManager.getInstance().getAllFonts()) {
      if (font.familyName !== 'serif' && font.familyName !== 'monospace') {
        fonts.push(font);
      }
    }
    return fonts;
  }

  private isSupportedEpubFont_(familyName: string): boolean {
    return this.fontList.some((font: FontInfo): boolean => font.familyName === familyName);
  }

  private toFontResources_(): EpubFontResource[] {
    const fonts: EpubFontResource[] = [];
    for (const font of this.fontList) {
      if (font.type === 'custom' && font.filePath) {
        fonts.push({ familyName: font.familyName, filePath: font.filePath });
      }
    }
    return fonts;
  }

  private async startLoad_(): Promise<void> {
    this.isLoading = true;
    this.loadError = '';
    this.progressText = '准备阅读内容...';
    const loadStart = Date.now();
    let lastStep = loadStart;
    const trace = (step: string): void => {
      const now = Date.now();
      console.info(`[ReaderPage] load ${step}: +${now - lastStep}ms total=${now - loadStart}ms`);
      lastStep = now;
    };
    try {
      const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
      this.bookUrl_ = params['bookUrl'] || '';
      if (!this.bookUrl_) {
        throw new Error('缺少书籍地址');
      }

      await AppDatabase.getInstance().waitForInit();
      trace('db-ready');
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const chapterDao = new ChapterTable(db);
      const book = await bookDao.getBookByUrl(this.bookUrl_);
      trace('book-loaded');
      if (!book) {
        throw new Error('书籍不存在');
      }
      this.isMobi_ = book.kind === 'MOBI' || book.kind === 'AZW' || book.kind === 'AZW3';
      this.isPdf_ = book.kind === 'PDF';
      this.isEpubFoliate_ = book.kind === 'EPUB' && params['epubEngine'] === 'foliate';
      this.isFoliate_ = this.isMobi_ || this.isPdf_ || this.isEpubFoliate_;
      const publicationPath = this.isMobi_ || this.isPdf_ ? book.originUrl : book.tocUrl;
      if (!publicationPath || !fileFs.accessSync(publicationPath)) {
        throw new Error(this.isPdf_ ? '本地 PDF 文件不存在，请重新导入' :
          (this.isMobi_ ? '本地 MOBI/AZW 文件不存在，请重新导入' : 'EPUB 解压目录不存在，请重新导入'));
      }

      this.book_ = book;
      this.bookName = book.name;
      this.currentIndex = Math.max(0, book.durChapterIndex || 0);
      this.progressText = '应用阅读设置...';
      const context = UiUtil.getHostContext(this.getUIContext());
      const chaptersPromise = chapterDao.getChaptersByBookId(book.id);
      const settingsPromise = this.loadSettings_();

      this.progressText = '准备图文内容...';
      const serverRoot = this.isMobi_ || this.isPdf_ ? this.getParentPath_(publicationPath) : publicationPath;
      const serverPromise = this.server_.start(serverRoot, context, 0);
      await Promise.all([chaptersPromise, serverPromise]);
      const chapters = await chaptersPromise;
      const port = await serverPromise;
      this.chapters_ = chapters;
      this.currentTitle = this.chapters_[this.currentIndex]?.title || '';
      setAloudChapterProvider((): Promise<AloudChapterText | null> => this.getNextChapterForAloud_());
      trace('chapters-and-server-ready');
      await settingsPromise;
      trace('settings-ready');
      const startTarget = await this.getStartTarget_();
      trace('progress-ready');
      const opfPath = this.isMobi_ || this.isPdf_ ? '' : this.findOpfPath_(book.tocUrl);
      this.opfDir_ = this.getParentDir_(opfPath);
      const bookEntry = this.isMobi_ || this.isPdf_ ? this.toBookUrl_(this.getBaseName_(publicationPath)) :
        (this.isEpubFoliate_ ? '/book/' : (opfPath ? this.toBookUrl_(opfPath) : '/book/'));
      const readerTarget = this.isFoliate_ ? startTarget : this.toEpubTarget_(startTarget);
      const initialStyle = JSON.stringify(this.toWebStyle_());
      const initialActions = JSON.stringify(this.zoneActions);
      console.info(`[ReaderPage] publication server=${port} kind=${book.kind} root=${serverRoot} target=${readerTarget}`);
      const readerPath = this.isFoliate_ ? '/foliate/foliate-reader.html' : '/reader/epub-reader.html';
      const formatParam = this.isEpubFoliate_ ? '&format=epub-dir' : (this.isPdf_ ? '&format=pdf' : '');
      const url = `http://127.0.0.1:${port}${readerPath}?book=${encodeURIComponent(bookEntry)}&target=${encodeURIComponent(readerTarget)}&style=${encodeURIComponent(initialStyle)}&actions=${encodeURIComponent(initialActions)}${formatParam}`;
      this.controller.loadUrl(url);
      trace('webview-load-started');
      this.armReadyTimeout_();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : String(e);
      this.progressText = this.loadError;
      this.isLoading = false;
    }
  }

  private async loadSettings_(): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.init(UiUtil.getHostContext(this.getUIContext()));
    const fontSizePromise = s.get<number>(EPUB_FONT_SIZE_KEY, 18);
    const fontFamilyPromise = s.get<string>(EPUB_FONT_FAMILY_KEY, EPUB_BOOK_FONT_FAMILY);
    const lineHeightPromise = s.get<number>(EPUB_LINE_HEIGHT_KEY, 1.6);
    const indentSizePromise = s.get<number>(EPUB_INDENT_SIZE_KEY, 2);
    const letterSpacingPromise = s.get<number>(EPUB_LETTER_SPACING_KEY, 0.5);
    const paragraphSpacingPromise = s.get<number>(EPUB_PARAGRAPH_SPACING_KEY, 10);
    const fontWeightPromise = s.get<number>(EPUB_FONT_WEIGHT_KEY, 1);
    const paddingTopPromise = s.get<number>(EPUB_PADDING_TOP_KEY, 24);
    const paddingBottomPromise = s.get<number>(EPUB_PADDING_BOTTOM_KEY, 24);
    const paddingLeftPromise = s.get<number>(EPUB_PADDING_LEFT_KEY, 20);
    const paddingRightPromise = s.get<number>(EPUB_PADDING_RIGHT_KEY, 20);
    const chineseModePromise = s.get<string>(EPUB_CHINESE_MODE_KEY, 'original');
    const zhFormatPromise = s.get<boolean>(EPUB_ZH_FORMAT_KEY, true);
    const bgColorPromise = s.get<string>(EPUB_READ_BG_KEY, '#F5F0E8');
    const textColorPromise = s.get<string>(EPUB_READ_TEXT_KEY, '#333333');
    const nightModePromise = s.get<boolean>(EPUB_READ_NIGHT_MODE_KEY, false);
    const followThemePromise = s.get<boolean>(EPUB_READ_FOLLOW_THEME_KEY, true);
    const flowModePromise = s.get<string>(EPUB_FLOW_MODE_KEY, 'paginated');
    const pdfAutoCropPromise = s.get<boolean>(PDF_AUTO_CROP_KEY, false);
    const pdfDarkenPromise = s.get<number>(PDF_DARKEN_KEY, 0);
    const pdfWhitenPromise = s.get<number>(PDF_WHITEN_KEY, 0);
    const pdfModePromise = s.get<string>(PDF_MODE_KEY, 'original');
    const actionPromises: Promise<number>[] = [];
    for (let z = 0; z < 9; z++) {
      actionPromises.push(s.getClickAction(z));
    }

    await Promise.all([
      fontSizePromise,
      fontFamilyPromise,
      lineHeightPromise,
      indentSizePromise,
      letterSpacingPromise,
      paragraphSpacingPromise,
      fontWeightPromise,
      paddingTopPromise,
      paddingBottomPromise,
      paddingLeftPromise,
      paddingRightPromise,
      chineseModePromise,
      zhFormatPromise,
      bgColorPromise,
      textColorPromise,
      nightModePromise,
      followThemePromise,
      flowModePromise,
      pdfAutoCropPromise,
      pdfDarkenPromise,
      pdfWhitenPromise,
      pdfModePromise,
      Promise.all(actionPromises),
    ]);

    // 翻页动画入口暂时隐藏；忽略历史保存值，保持稳定的无动画分页。
    this.cfg.animType = PageTurnAnim.NONE;
    this.cfg.fontSize = await fontSizePromise;
    let fontFamily = await fontFamilyPromise;
    if (fontFamily === '默认') fontFamily = EPUB_BOOK_FONT_FAMILY;
    if (!this.isSupportedEpubFont_(fontFamily)) fontFamily = EPUB_BOOK_FONT_FAMILY;
    this.cfg.fontFamily = fontFamily;
    this.cfg.lineHeight = await lineHeightPromise;
    this.cfg.indentSize = await indentSizePromise;
    this.cfg.letterSpacing = await letterSpacingPromise;
    this.cfg.paragraphSpacing = await paragraphSpacingPromise;
    this.cfg.fontWeight = await fontWeightPromise;
    this.cfg.paddingTop = await paddingTopPromise;
    this.cfg.paddingBottom = await paddingBottomPromise;
    this.cfg.paddingLeft = await paddingLeftPromise;
    this.cfg.paddingRight = await paddingRightPromise;
    this.cfg.chineseMode = await chineseModePromise;
    this.cfg.zhFormat = await zhFormatPromise;
    this.readBgColor = await bgColorPromise;
    this.readTextColor = await textColorPromise;
    if (this.readBgColor === ReaderPage.NIGHT_BG && this.readTextColor === ReaderPage.NIGHT_TEXT) {
      this.readBgColor = '#F5F0E8';
      this.readTextColor = '#333333';
      s.put(EPUB_READ_BG_KEY, this.readBgColor).catch(() => {});
      s.put(EPUB_READ_TEXT_KEY, this.readTextColor).catch(() => {});
    }
    this.readNightMode = await nightModePromise;
    this.readFollowTheme = await followThemePromise;
    this.flowMode = await flowModePromise === 'scrolled' ? 'scrolled' : 'paginated';
    this.pdfAutoCrop = await pdfAutoCropPromise;
    this.pdfDarken = Math.min(100, Math.max(0, await pdfDarkenPromise));
    this.pdfWhiten = Math.min(100, Math.max(0, await pdfWhitenPromise));
    this.pdfMode = await pdfModePromise === 'reflow' ? 'reflow' : 'original';
    if (this.readFollowTheme) {
      this.readNightMode = this.isDark;
    }
    this.applyReadColors_();
    const actions = await Promise.all(actionPromises);
    this.zoneActions = actions.length === 9 ? actions : DEFAULT_ZONE_ACTIONS;
  }

  private applyReadColors_(): void {
    const bg = this.readNightMode ? ReaderPage.NIGHT_BG : this.readBgColor;
    const text = this.readNightMode ? ReaderPage.NIGHT_TEXT : this.readTextColor;
    if (this.cfg.bgColor !== bg || this.cfg.textColor !== text) {
      this.cfg = {
        animType: this.cfg.animType,
        bgColor: bg,
        textColor: text,
        titleColor: this.cfg.titleColor,
        fontSize: this.cfg.fontSize,
        fontWeight: this.cfg.fontWeight,
        fontFamily: this.cfg.fontFamily,
        lineHeight: this.cfg.lineHeight,
        letterSpacing: this.cfg.letterSpacing,
        paragraphSpacing: this.cfg.paragraphSpacing,
        textAlign: this.cfg.textAlign,
        indentSize: this.cfg.indentSize,
        paddingTop: this.cfg.paddingTop,
        paddingBottom: this.cfg.paddingBottom,
        paddingLeft: this.cfg.paddingLeft,
        paddingRight: this.cfg.paddingRight,
        showHeader: this.cfg.showHeader,
        showFooter: this.cfg.showFooter,
        headerContent: this.cfg.headerContent,
        footerContent: this.cfg.footerContent,
        brightness: this.cfg.brightness,
        zhFormat: this.cfg.zhFormat,
        chineseMode: this.cfg.chineseMode,
      };
    }
  }

  private async getStartTarget_(): Promise<string> {
    const s = SettingsStore.getInstance();
    const saved = await s.get<string>(this.progressKey_(), '');
    if (saved) {
      return saved;
    }
    if (this.isPdf_ && this.currentIndex > 0) return String(this.currentIndex);
    const chapter = this.chapters_[this.currentIndex];
    return chapter?.url || '';
  }

  private progressKey_(): string {
    const engine = this.isPdf_ ? 'pdf' : (this.isMobi_ ? 'mobi' : (this.isEpubFoliate_ ? 'epub_foliate' : 'epub'));
    return `${engine}_progress_${this.book_?.id || 0}`;
  }

  private getParentPath_(path: string): string {
    const index = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : path;
  }

  private getBaseName_(path: string): string {
    const index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }

  private findOpfPath_(rootDir: string): string {
    try {
      const containerPath = rootDir + '/META-INF/container.xml';
      if (!fileFs.accessSync(containerPath)) return '';
      const xml = this.readTextFile_(containerPath);
      const match = xml.match(/<rootfile\b[^>]*\bfull-path=["']([^"']+)["'][^>]*>/i);
      return match ? match[1] : '';
    } catch (_e) {
      return '';
    }
  }

  private readTextFile_(path: string): string {
    let fd: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fd = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(fd.fd, buf);
      const decoder = new util.TextDecoder('utf-8', { fatal: false });
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (err) {
      throw new Error(`Read EPUB text failed: ${path}: ${(err as Error).message}`);
    } finally {
      if (fd) {
        try {
          fileFs.closeSync(fd);
        } catch (err) {
          console.warn('[ReaderPage] close file failed:', (err as Error).message);
        }
      }
    }
  }

  private stripHrefAnchor_(href: string): string {
    let value = (href || '').trim().replace(/\\/g, '/');
    const hashIndex = value.indexOf('#');
    if (hashIndex >= 0) value = value.substring(0, hashIndex);
    const queryIndex = value.indexOf('?');
    if (queryIndex >= 0) value = value.substring(0, queryIndex);
    while (value.startsWith('/')) value = value.substring(1);
    while (value.startsWith('./')) value = value.substring(2);
    try {
      value = decodeURIComponent(value);
    } catch (_e) {}
    return value;
  }

  private resolveEpubFilePath_(href: string): string {
    if (!this.book_?.tocUrl || !href) return '';
    const root = this.book_.tocUrl.endsWith('/') ? this.book_.tocUrl : this.book_.tocUrl + '/';
    const clean = this.stripHrefAnchor_(href);
    if (!clean) return '';
    const candidates: string[] = [];
    candidates.push(root + clean);
    if (this.opfDir_) {
      candidates.push(root + this.opfDir_ + clean);
      if (clean.startsWith(this.opfDir_)) {
        candidates.push(root + clean.substring(this.opfDir_.length));
      }
    }
    for (const path of candidates) {
      try {
        if (fileFs.accessSync(path)) return path;
      } catch (_e) {}
    }
    return '';
  }

  private getEpubChapterText_(index: number): string {
    if (index < 0 || index >= this.chapters_.length) return '';
    const chapter = this.chapters_[index];
    if (chapter.content && chapter.content.length > 20) {
      return chapter.content;
    }
    const path = this.resolveEpubFilePath_(chapter.url || '');
    if (!path) return '';
    try {
      const html = this.readTextFile_(path);
      return HtmlUtil.toPlainText(html);
    } catch (err) {
      console.warn('[ReaderPage] read EPUB chapter text failed: ' + (err as Error).message);
      return '';
    }
  }

  private estimateCurrentTextOffset_(text: string): number {
    if (!text || this.currentTotalPages_ <= 1 || this.currentPage_ <= 1) return 0;
    const page = Math.min(Math.max(1, this.currentPage_), this.currentTotalPages_);
    let offset = Math.floor(text.length * ((page - 1) / this.currentTotalPages_));
    offset = Math.min(Math.max(0, offset), Math.max(0, text.length - 1));
    const searchStart = Math.max(0, offset - 120);
    const prefix = text.substring(searchStart, offset);
    const markers = ['\n\n', '\n', '。', '！', '？', '；', ';'];
    let best = -1;
    let markerLen = 0;
    for (const marker of markers) {
      const pos = prefix.lastIndexOf(marker);
      if (pos >= best) {
        best = pos;
        markerLen = marker.length;
      }
    }
    if (best >= 0) {
      offset = searchStart + best + markerLen;
    }
    return Math.min(Math.max(0, offset), text.length);
  }

  private async prepareAloudPanel_(): Promise<void> {
    const text = this.isMobi_ ? await this.getMobiChapterText_(this.currentIndex) :
      this.getEpubChapterText_(this.currentIndex);
    if (!text || text.trim().length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '当前章节没有可朗读文本', duration: 1500 });
      return;
    }
    this.aloudText = text;
    this.aloudTextOffset = this.estimateCurrentTextOffset_(text);
    this.lastAloudProviderIdx_ = this.currentIndex;
    setAloudChapterProvider((): Promise<AloudChapterText | null> => this.getNextChapterForAloud_());
    this.showAloud = true;
  }

  private async getNextChapterForAloud_(): Promise<AloudChapterText | null> {
    const startIdx = this.lastAloudProviderIdx_ >= 0 ? this.lastAloudProviderIdx_ : this.currentIndex;
    const nextIdx = startIdx + 1;
    if (nextIdx >= this.chapters_.length) return null;
    const text = this.isMobi_ ? await this.getMobiChapterText_(nextIdx) : this.getEpubChapterText_(nextIdx);
    if (!text || text.trim().length === 0) return null;
    this.lastAloudProviderIdx_ = nextIdx;
    return { text, offset: 0, chapterIndex: nextIdx };
  }

  private goToAloudPosition_(charIndex: number, chapterIndex?: number): void {
    const targetIndex = chapterIndex !== undefined && chapterIndex >= 0 ? chapterIndex : this.currentIndex;
    if (targetIndex !== this.currentIndex && targetIndex < this.chapters_.length) {
      this.goToChapterIndex_(targetIndex);
      return;
    }
    UiUtil.showToast(this.getUIContext(), { message: '朗读定位已同步到当前章节', duration: 1000 });
  }

  private getMobiChapterText_(index: number): Promise<string> {
    const items = this.tocItems.length > 0 ? this.tocItems : this.tocDisplayItems_();
    if (index < 0 || index >= items.length) return Promise.resolve('');
    const href = items[index]?.href || '';
    const nextHref = index + 1 < items.length ? items[index + 1]?.href || '' : '';
    this.finishChapterTextRequest_('');
    return new Promise<string>((resolve: (text: string) => void) => {
      const requestId = `${Date.now()}-${index}`;
      this.chapterTextRequestId_ = requestId;
      this.chapterTextResolver_ = resolve;
      this.chapterTextTimer_ = setTimeout(() => {
        if (this.chapterTextRequestId_ === requestId) this.finishChapterTextRequest_('');
      }, 8000);
      this.runJs_('window.requestChapterText && window.requestChapterText(' +
        JSON.stringify(requestId) + ',' + JSON.stringify(href) + ',' + JSON.stringify(nextHref) + ')');
    });
  }

  private finishChapterTextRequest_(text: string): void {
    if (this.chapterTextTimer_ > 0) clearTimeout(this.chapterTextTimer_);
    this.chapterTextTimer_ = -1;
    const resolve = this.chapterTextResolver_;
    this.chapterTextResolver_ = null;
    this.chapterTextRequestId_ = '';
    if (resolve) resolve(text);
  }

  private toBookUrl_(relativePath: string): string {
    const parts = relativePath.split('/');
    const encoded: string[] = [];
    for (const part of parts) {
      if (part.length > 0) {
        encoded.push(encodeURIComponent(part));
      }
    }
    return '/book/' + encoded.join('/');
  }

  private getParentDir_(path: string): string {
    const index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(0, index + 1) : '';
  }

  private toEpubTarget_(target: string): string {
    if (!target) return '';
    if (target.startsWith('epubcfi(')) return target;
    let result = target;
    if (result.startsWith('/')) {
      result = result.substring(1);
    }
    if (this.opfDir_ && result.startsWith(this.opfDir_)) {
      result = result.substring(this.opfDir_.length);
    }
    return result;
  }

  private normalizeEpubHref_(href: string): string {
    let value = (href || '').trim().replace(/\\/g, '/');
    const bookIndex = value.indexOf('/book/');
    if (bookIndex >= 0) {
      value = value.substring(bookIndex + '/book/'.length);
    }
    const queryIndex = value.indexOf('?');
    if (queryIndex >= 0) {
      value = value.substring(0, queryIndex);
    }
    const hashIndex = value.indexOf('#');
    if (hashIndex >= 0) {
      value = value.substring(0, hashIndex);
    }
    try {
      value = decodeURIComponent(value);
    } catch (_e) {}
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    if (this.opfDir_ && value.startsWith(this.opfDir_)) {
      value = value.substring(this.opfDir_.length);
    }
    return value.toLowerCase();
  }

  private findChapterIndexByHref_(href: string): number {
    const target = this.normalizeEpubHref_(href);
    if (!target) return -1;
    for (let i = 0; i < this.chapters_.length; i++) {
      const chapterHref = this.normalizeEpubHref_(this.chapters_[i].url);
      if (!chapterHref) continue;
      if (chapterHref === target || chapterHref.endsWith('/' + target) || target.endsWith('/' + chapterHref)) {
        return i;
      }
    }
    return -1;
  }

  private armReadyTimeout_(): void {
    if (this.readyTimer_ > 0) clearTimeout(this.readyTimer_);
    this.readyTimer_ = setTimeout(() => {
      this.readyTimer_ = -1;
      if (this.isLoading && !this.loadError) {
        this.progressText = '内容加载较慢，继续等待...';
        console.warn('[ReaderPage] EPUB ready timeout, waiting for bridge event');
      }
    }, 6000);
  }

  private onWebReady_(): void {
    if (this.readyTimer_ > 0) {
      clearTimeout(this.readyTimer_);
      this.readyTimer_ = -1;
    }
    this.isLoading = false;
    this.progressText = '';
    this.applyStyleNow_();
  }

  private startPoll_(): void {
    this.stopPoll_();
    this.pollTimer_ = setInterval(() => {
      if (this.pollBusy_) return;
      this.pollBusy_ = true;
      try {
        this.controller.runJavaScript('window.pollEvents ? window.pollEvents() : (window.pollEvent && window.pollEvent())', (err: BusinessError, result: string) => {
          this.pollBusy_ = false;
          if (err || !result || result === 'null' || result === 'undefined') return;
          try {
            const events = this.parseReaderEvents_(result);
            for (const evt of events) {
              this.handleReaderEvent_(evt);
            }
          } catch (_e) {}
        });
      } catch (_e) {
        this.pollBusy_ = false;
      }
    }, 80);
  }

  private parseReaderEvents_(result: string): ReaderEvent[] {
    let value: Object | string = result;
    for (let i = 0; i < 2; i++) {
      if (typeof value !== 'string') {
        break;
      }
      const text = value.trim();
      if (!text || text === 'null' || text === 'undefined') {
        return [];
      }
      value = JSON.parse(text) as Object;
    }

    const events: ReaderEvent[] = [];
    if (Array.isArray(value)) {
      const rows = value as Object[];
      for (const row of rows) {
        const evt = this.toReaderEvent_(row);
        if (evt) {
          events.push(evt);
        }
      }
      return events;
    }

    const evt = this.toReaderEvent_(value);
    if (evt) {
      events.push(evt);
    }
    return events;
  }

  private toReaderEvent_(raw: Object): ReaderEvent | null {
    const evt = raw as Record<string, Object>;
    const type = evt['type'] as string;
    if (!type) return null;
    return { type, data: evt['data'] as Object };
  }

  private stopPoll_(): void {
    if (this.pollTimer_ > 0) {
      clearInterval(this.pollTimer_);
      this.pollTimer_ = -1;
    }
    this.pollBusy_ = false;
  }

  private handleReaderEvent_(evt: ReaderEvent): void {
    if (evt.type !== 'page') {
      console.info(`[ReaderPage] publication event=${evt.type}`);
    }
    switch (evt.type) {
      case 'ready':
        this.onWebReady_();
        break;
      case 'location':
        this.onLocation_(evt.data as LocationEvent);
        break;
      case 'page':
        this.onLivePage_(evt.data as LocationEvent);
        break;
      case 'toc':
        this.onToc_(evt.data as Object[]);
        break;
      case 'metadata':
        this.onMetadata_(evt.data as PublicationMetadataEvent).catch(() => {});
        break;
      case 'chapterText':
        this.onChapterText_(evt.data as ChapterTextEvent);
        break;
      case 'menu':
        this.showMenu = true;
        break;
      case 'tapAction':
        this.dispatchTapAction_(evt.data as TapActionEvent);
        break;
      case 'error':
        this.loadError = ((evt.data as Record<string, Object>)?.['message'] as string) || '加载失败';
        this.progressText = this.loadError;
        this.isLoading = false;
        break;
      case 'debug':
        console.info(`[ReaderPage] publication debug=${((evt.data as Record<string, Object>)?.['message'] as string) || ''}`);
        break;
    }
  }

  private onChapterText_(event: ChapterTextEvent): void {
    if (!event || event.requestId !== this.chapterTextRequestId_) return;
    if (event.error) console.warn('[ReaderPage] MOBI chapter text failed: ' + event.error);
    this.finishChapterTextRequest_(event.text || '');
  }

  private onToc_(rawItems: Object[]): void {
    if (!Array.isArray(rawItems)) return;
    const items: EpubTocItem[] = [];
    for (const raw of rawItems) {
      const row = raw as Record<string, Object>;
      const label = (row['label'] as string) || '';
      const href = (row['href'] as string) || '';
      const levelValue = row['level'] as number;
      items.push({
        label,
        href,
        level: typeof levelValue === 'number' ? Math.min(Math.max(0, levelValue), 6) : 0,
      });
    }
    this.tocItems = items;
    console.info(`[ReaderPage] publication toc items=${items.length}`);
    if (this.isMobi_ && items.length > 0) {
      this.persistMobiToc_(items).catch((err: Error) => {
        console.warn('[ReaderPage] persist MOBI toc failed:', err.message);
      });
    }
  }

  private async onMetadata_(meta: PublicationMetadataEvent): Promise<void> {
    if (!this.book_ || (!this.isMobi_ && !this.isPdf_)) return;
    if (this.isPdf_ && this.pdfMode === 'reflow' && meta.pdfReflowAvailable === false) {
      this.pdfMode = 'original';
      await SettingsStore.getInstance().put(PDF_MODE_KEY, 'original');
      UiUtil.showToast(this.getUIContext(), {
        message: '该 PDF 没有可重排文字，已切回原版',
        duration: 1800,
      });
    }
    let changed = false;
    if (meta.title && meta.title !== this.book_.name) {
      this.book_.name = meta.title;
      this.bookName = meta.title;
      changed = true;
    }
    if (meta.author && meta.author !== this.book_.author) {
      this.book_.author = meta.author;
      changed = true;
    }
    if (meta.description && meta.description !== this.book_.introduce) {
      this.book_.introduce = HtmlUtil.stripHtml(meta.description);
      changed = true;
    }
    if (this.isPdf_ && meta.pageCount && meta.pageCount > 0 &&
      meta.pageCount !== this.book_.totalChapterNum) {
      this.book_.chapterCount = meta.pageCount;
      this.book_.totalChapterNum = meta.pageCount;
      changed = true;
    }
    if (changed) {
      const db = AppDatabase.getInstance().rdbStore;
      await new BookTable(db).updateBook(this.book_);
    }
  }

  private async persistMobiToc_(items: EpubTocItem[]): Promise<void> {
    if (!this.book_) return;
    const now = Date.now();
    const chapters: BookChapter[] = items.map((item: EpubTocItem, index: number): BookChapter => ({
      id: 0, bookId: this.book_!.id, index, volumeIndex: item.level,
      title: item.label || `第 ${index + 1} 章`, url: item.href, content: '', contentLength: 0,
      isRead: false, isDownloaded: true, isCached: false,
      duration: 0, audioUrl: '', createTime: now, updateTime: now,
    }));
    this.chapters_ = chapters;
    this.book_.chapterCount = chapters.length;
    this.book_.totalChapterNum = chapters.length;
    this.book_.latestChapterTitle = chapters[chapters.length - 1]?.title || '';
    const db = AppDatabase.getInstance().rdbStore;
    const chapterDao = new ChapterTable(db);
    await chapterDao.deleteChaptersByBookId(this.book_.id);
    await chapterDao.insertChapters(chapters);
    await new BookTable(db).updateBook(this.book_);
  }

  private onLocation_(loc: LocationEvent): void {
    this.currentCfi_ = loc.cfi || this.currentCfi_;
    this.currentHref_ = loc.href || this.currentHref_;
    this.currentPercent_ = typeof loc.percentage === 'number' ? loc.percentage : this.currentPercent_;
    const hrefIndex = this.findChapterIndexByHref_(this.currentHref_);
    const idx = hrefIndex >= 0 ? hrefIndex : (typeof loc.chapterIndex === 'number' ? loc.chapterIndex : this.currentIndex);
    if (this.isPdf_) {
      this.currentIndex = Math.max(0, idx);
      this.currentTitle = `第 ${this.currentIndex + 1} 页`;
    } else {
      this.currentIndex = Math.min(Math.max(0, idx), Math.max(0, this.chapters_.length - 1));
      this.currentTitle = this.chapters_[this.currentIndex]?.title || '';
    }
    console.info(`[ReaderPage] publication location href=${this.currentHref_} section=${loc.chapterIndex ?? -1} chapter=${this.currentIndex} title=${this.currentTitle}`);
    const page = typeof loc.page === 'number' ? loc.page : 0;
    const total = typeof loc.totalPages === 'number' ? loc.totalPages : 0;
    this.currentPage_ = page;
    this.currentTotalPages_ = total;
    this.pageText = total > 0 ? `${page}/${total}` : '';
    this.scheduleSaveProgress_();
  }

  private onLivePage_(loc: LocationEvent): void {
    const page = typeof loc.page === 'number' ? loc.page : 0;
    const total = typeof loc.totalPages === 'number' ? loc.totalPages : 0;
    if (page === this.currentPage_ && total === this.currentTotalPages_) return;
    this.currentPage_ = page;
    this.currentTotalPages_ = total;
    this.pageText = total > 0 ? `${page}/${total}` : '';
  }

  private scheduleSaveProgress_(): void {
    if (this.saveTimer_ > 0) clearTimeout(this.saveTimer_);
    this.saveTimer_ = setTimeout(() => {
      this.saveTimer_ = -1;
      this.saveProgress_();
    }, 500);
  }

  private async saveProgress_(): Promise<void> {
    if (!this.book_) return;
    try {
      const s = SettingsStore.getInstance();
      await s.put(this.progressKey_(), this.currentCfi_ || this.currentHref_);
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      await bookDao.updateReadingProgress(
        this.bookUrl_,
        this.currentIndex,
        this.currentTitle,
        this.isPdf_ ? Math.max(1, this.book_.totalChapterNum) : this.chapters_.length,
        Math.round(this.currentPercent_ * 100000)
      );
    } catch (_e) {}
  }

  private onStyleChange_(config: PageViewConfig): void {
    this.readBgColor = config.bgColor;
    this.readTextColor = config.textColor;
    this.cfg = config;
    this.applyReadColors_();
    if (this.styleTimer_ > 0) clearTimeout(this.styleTimer_);
    this.styleTimer_ = setTimeout(() => {
      this.styleTimer_ = -1;
      this.applyStyleNow_();
    }, 200);
    this.queueStyleSave_(config);
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

  private async saveStyleSnapshot_(snapshot: EpubStyleSaveSnapshot): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      const config = snapshot.config;
      const values: Record<string, Object> = {};
      values[EPUB_FONT_SIZE_KEY] = config.fontSize;
      values[EPUB_FONT_FAMILY_KEY] = config.fontFamily;
      values[EPUB_LINE_HEIGHT_KEY] = config.lineHeight;
      values[EPUB_INDENT_SIZE_KEY] = config.indentSize;
      values[EPUB_LETTER_SPACING_KEY] = config.letterSpacing;
      values[EPUB_PARAGRAPH_SPACING_KEY] = config.paragraphSpacing;
      values[EPUB_FONT_WEIGHT_KEY] = config.fontWeight;
      values[EPUB_PADDING_TOP_KEY] = config.paddingTop;
      values[EPUB_PADDING_BOTTOM_KEY] = config.paddingBottom;
      values[EPUB_PADDING_LEFT_KEY] = config.paddingLeft;
      values[EPUB_PADDING_RIGHT_KEY] = config.paddingRight;
      values[EPUB_READ_BG_KEY] = snapshot.readBgColor;
      values[EPUB_READ_TEXT_KEY] = snapshot.readTextColor;
      values[EPUB_READ_NIGHT_MODE_KEY] = snapshot.readNightMode;
      values[EPUB_READ_FOLLOW_THEME_KEY] = snapshot.readFollowTheme;
      values[EPUB_CHINESE_MODE_KEY] = config.chineseMode;
      values[EPUB_ZH_FORMAT_KEY] = config.zhFormat;
      try {
        await s.putMany(values);
      } catch (_e) {
        await s.init(UiUtil.getHostContext(this.getUIContext()));
        await s.putMany(values);
      }
    } catch (err) {
      console.warn('[ReaderPage] save style failed:', (err as Error).message);
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

  private onNightModeToggle_(night: boolean): void {
    this.readNightMode = night;
    this.applyReadColors_();
    this.applyStyleNow_();
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(() => SettingsStore.getInstance().put(EPUB_READ_NIGHT_MODE_KEY, night))
      .catch(() => {});
  }

  private onFlowModeChange_(mode: string): void {
    const normalized = mode === 'scrolled' ? 'scrolled' : 'paginated';
    if (this.flowMode === normalized) return;
    this.flowMode = normalized;
    this.applyStyleNow_();
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(() => SettingsStore.getInstance().put(EPUB_FLOW_MODE_KEY, normalized))
      .catch(() => {});
  }

  private onPdfModeChange_(mode: string): void {
    const normalized = mode === 'reflow' ? 'reflow' : 'original';
    if (this.pdfMode === normalized) return;
    this.pdfMode = normalized;
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(() => SettingsStore.getInstance().put(PDF_MODE_KEY, normalized))
      .catch(() => {});
    this.runJs_('window.setPdfMode && window.setPdfMode(' + JSON.stringify(normalized) + ')');
  }

  private onPdfEnhanceChange_(autoCrop: boolean, darken: number, whiten: number): void {
    this.pdfAutoCrop = autoCrop;
    this.pdfDarken = Math.min(100, Math.max(0, Math.round(darken)));
    this.pdfWhiten = Math.min(100, Math.max(0, Math.round(whiten)));
    if (this.pdfEnhanceTimer_ > 0) clearTimeout(this.pdfEnhanceTimer_);
    this.pdfEnhanceTimer_ = setTimeout(() => {
      this.pdfEnhanceTimer_ = -1;
      this.applyStyleNow_();
      this.savePdfEnhance_().catch(() => {});
    }, 160);
  }

  private async savePdfEnhance_(): Promise<void> {
    const values: Record<string, Object> = {};
    values[PDF_AUTO_CROP_KEY] = this.pdfAutoCrop;
    values[PDF_DARKEN_KEY] = this.pdfDarken;
    values[PDF_WHITEN_KEY] = this.pdfWhiten;
    await SettingsStore.getInstance().putMany(values);
  }

  private applyStyleNow_(): void {
    this.runJs_('window.applyStyle && window.applyStyle(' + JSON.stringify(this.toWebStyle_()) + ')');
    this.runJs_('window.setZoneActions && window.setZoneActions(' + JSON.stringify(this.zoneActions) + ')');
  }

  private toWebStyle_(): WebReaderStyle {
    let fontWeight = '400';
    if (this.cfg.fontWeight === 0) {
      fontWeight = '200';
    } else if (this.cfg.fontWeight === 2) {
      fontWeight = '700';
    }
    return {
      animType: this.cfg.animType,
      flowMode: this.flowMode,
      pdfMode: this.pdfMode,
      pdfAutoCrop: this.pdfAutoCrop,
      pdfDarken: this.pdfDarken,
      pdfWhiten: this.pdfWhiten,
      backgroundColor: this.cfg.bgColor,
      color: this.cfg.textColor,
      fontSize: this.cfg.fontSize,
      fontFamily: this.cfg.fontFamily,
      fontWeight,
      lineHeight: this.cfg.lineHeight,
      letterSpacing: this.cfg.letterSpacing,
      paragraphSpacing: this.cfg.paragraphSpacing,
      textAlign: this.cfg.textAlign,
      indentSize: this.cfg.indentSize,
      paddingTop: this.cfg.paddingTop,
      paddingBottom: this.cfg.paddingBottom,
      paddingLeft: this.cfg.paddingLeft,
      paddingRight: this.cfg.paddingRight,
      zhFormat: this.cfg.zhFormat,
      chineseMode: this.cfg.chineseMode,
      fontFaces: this.toWebFontFaces_(),
    };
  }

  private toWebFontFaces_(): WebReaderFontFace[] {
    const port = this.server_.port;
    if (port <= 0) return [];
    const faces: WebReaderFontFace[] = [];
    for (const font of this.fontList) {
      if (font.type === 'custom' && font.filePath) {
        faces.push({
          familyName: font.familyName,
          url: `http://127.0.0.1:${port}/font/${encodeURIComponent(font.familyName)}`,
        });
      }
    }
    return faces;
  }

  private runJs_(code: string): void {
    try {
      this.controller.runJavaScript(code);
    } catch (_e) {}
  }

  private goToChapter_(chapter: BookChapter): void {
    this.showToc = false;
    this.showMenu = false;
    const target = this.isFoliate_ ? chapter.url : this.toEpubTarget_(chapter.url);
    this.runJs_('window.goToHref && window.goToHref(' + JSON.stringify(target) + ')');
  }

  private goToTocItem_(item: EpubTocItem): void {
    if (!item.href) return;
    this.showToc = false;
    this.showMenu = false;
    this.runJs_('window.goToHref && window.goToHref(' + JSON.stringify(item.href) + ')');
  }

  private isTocItemCurrent_(item: EpubTocItem): boolean {
    if (!item.href || !this.currentHref_) return false;
    return this.normalizeEpubHref_(item.href) === this.normalizeEpubHref_(this.currentHref_);
  }

  private chapterToTocItem_(chapter: BookChapter): EpubTocItem {
    return {
      label: chapter.title || `第 ${chapter.index + 1} 章`,
      href: chapter.url,
      level: 0,
    };
  }

  private tocDisplayItems_(): EpubTocItem[] {
    if (this.tocItems.length > 0) {
      return this.tocItems;
    }
    return this.chapters_.map((chapter: BookChapter): EpubTocItem => this.chapterToTocItem_(chapter));
  }

  private goToChapterIndex_(index: number): void {
    if ((this.isMobi_ || this.isPdf_) && this.tocItems.length > 0) {
      if (index < 0 || index >= this.tocItems.length) return;
      this.currentIndex = index;
      this.currentTitle = this.tocItems[index].label;
      this.goToTocItem_(this.tocItems[index]);
      return;
    }
    if (index < 0 || index >= this.chapters_.length) return;
    this.currentIndex = index;
    this.currentTitle = this.chapters_[index]?.title || '';
    this.goToChapter_(this.chapters_[index]);
  }

  private dispatchTapAction_(tap: TapActionEvent): void {
    const action = typeof tap.action === 'number' ? tap.action : ClickAction.NONE;
    console.info(`[ReaderPage] publication tap zone=${tap.zone ?? -1} action=${action}`);
    switch (action) {
      case ClickAction.NONE:
        break;
      case ClickAction.MENU:
        this.showMenu = true;
        break;
      case ClickAction.NEXT_PAGE:
        this.runJs_('window.nextPage && window.nextPage()');
        break;
      case ClickAction.PREV_PAGE:
        this.runJs_('window.prevPage && window.prevPage()');
        break;
      case ClickAction.NEXT_CHAPTER:
        this.goToChapterIndex_(this.currentIndex + 1);
        break;
      case ClickAction.PREV_CHAPTER:
        this.goToChapterIndex_(this.currentIndex - 1);
        break;
      case ClickAction.CHAPTER_LIST:
        this.showToc = true;
        break;
      default:
        this.showMenu = true;
        break;
    }
  }

  private formatCurTime_(): string {
    const d = new Date();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private footerPageText_(): string {
    return this.pageText || (this.currentPercent_ > 0 ? `${Math.round(this.currentPercent_ * 100)}%` : '');
  }

  build() {
    Stack() {
      Web({ src: '', controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .backgroundColor(this.cfg.bgColor)
        .onPageEnd(() => {
          this.startPoll_();
          this.applyStyleNow_();
        })

      if (this.isLoading || this.loadError) {
        this.LoadingLayer()
      }

      if (!this.isLoading && !this.loadError && this.cfg.showFooter) {
        this.FooterLayer()
      }

      if (this.showMenu) {
        this.MenuLayer()
      }

      if (this.showToc) {
        this.TocLayer()
      }

      if (this.showStyle) {
        this.StyleLayer()
      }

      if (this.showAloud) {
        this.AloudLayer()
      }

      if (this.showZoneConfig) {
        this.ZoneConfigLayer()
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.cfg.bgColor)
  }

  @Builder
  FooterLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row().width('100%').height(1).backgroundColor(ThemeColors.outlineVariant(this.isDark))
          .margin({ top: 4, bottom: 4 })
        Row() {
          Text(this.currentTitle || this.bookName)
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.formatCurTime_())
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ right: 10 })
          Text(this.footerPageText_())
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }
        .width('100%')
        .padding({ left: this.cfg.paddingLeft, right: this.cfg.paddingRight })
      }
      .width('100%')
      .backgroundColor(this.cfg.bgColor)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  LoadingLayer() {
    Column() {
      if (!this.loadError) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(ThemeColors.primary(this.isDark))
      }
      Text(this.progressText)
        .fontSize(14)
        .fontColor(this.loadError ? ThemeColors.error(this.isDark) : ThemeColors.onBackground(this.isDark))
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
      if (this.loadError) {
        Button('返回')
          .margin({ top: 18 })
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark))
          .onClick(() => UiUtil.back(this.getUIContext()))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(ThemeColors.background(this.isDark))
    .padding(24)
  }

  @Builder
  MenuLayer() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .onClick(() => UiUtil.back(this.getUIContext()))
        Column() {
          Text(this.bookName)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.currentTitle)
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        Text(this.pageText)
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .width(52)
          .textAlign(TextAlign.End)
      }
      .height(56)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark))

      Blank().layoutWeight(1).onClick(() => { this.showMenu = false; })

      ReadBottomMenu({
        isLocalBook: true,
        onToc: () => { this.showMenu = false; this.showToc = true; },
        onReadAloud: () => {
          this.showMenu = false;
          this.prepareAloudPanel_();
        },
        onBookmark: () => {
          this.showMenu = false;
          UiUtil.showToast(this.getUIContext(), { message: '书签功能开发中', duration: 1200 });
        },
        onStyle: () => { this.showMenu = false; this.showStyle = true; },
        onSettings: () => { this.showMenu = false; this.showZoneConfig = true; },
        onSearch: () => {
          this.showMenu = false;
          UiUtil.showToast(this.getUIContext(), { message: '页内搜索开发中', duration: 1200 });
        },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.scrim(this.isDark))
  }

  @Builder
  TocLayer() {
    Row() {
      Column() {
        Row() {
          Text('目录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .layoutWeight(1)
          Button('关闭')
            .fontSize(13)
            .fontColor(ThemeColors.primary(this.isDark))
            .backgroundColor('transparent')
            .onClick(() => { this.showToc = false; })
        }
        .height(52)
        .width('100%')
        .padding({ left: 16, right: 10 })

        List() {
          ForEach(this.tocDisplayItems_(), (item: EpubTocItem, index: number) => {
            ListItem() {
              Row() {
                if (item.level > 0) {
                  Blank()
                    .width(Math.min(48, item.level * 14))
                    .height(1)
                }
                Text(item.label || `第 ${index + 1} 章`)
                  .fontSize(item.level === 0 ? 16 : 15)
                  .fontWeight(item.level === 0 ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.isTocItemCurrent_(item) ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
                  .lineHeight(item.level === 0 ? 21 : 20)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            }
            .enabled(!!item.href)
            .onClick(() => this.goToTocItem_(item))
          }, (item: EpubTocItem, index: number) => `${index}-${item.level}-${item.href}-${item.label}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('84%')
      .height('100%')
      .backgroundColor(ThemeColors.surface(this.isDark))

      Blank().layoutWeight(1).onClick(() => { this.showToc = false; })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.scrim(this.isDark))
  }

  @Builder
  AloudLayer() {
    Column() {
      Blank().layoutWeight(1).onClick(() => { this.showAloud = false; })
      ReadAloudPanel({
        text: this.aloudText,
        textOffset: this.aloudTextOffset,
        currentChapterIndex: this.currentIndex,
        chapterTitle: this.currentTitle || this.bookName,
        externalEngine: null,
        onDismiss: () => { this.showAloud = false; },
        onGoToPosition: (charIndex: number, chapterIndex?: number) => { this.goToAloudPosition_(charIndex, chapterIndex); },
        onNextChapter: () => {
          this.showAloud = false;
          this.goToChapterIndex_(this.currentIndex + 1);
        },
        onPrevChapter: () => {
          this.showAloud = false;
          this.goToChapterIndex_(this.currentIndex - 1);
        },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.scrim(this.isDark))
  }

  @Builder
  StyleLayer() {
    Column() {
      Blank().layoutWeight(1).onClick(() => { this.showStyle = false; })
      StylePanel({
        cfg: this.cfg,
        fontList: this.fontList,
        nightMode: this.readNightMode,
        dayBgColor: this.readBgColor,
        dayTextColor: this.readTextColor,
        showFlowMode: !this.isPdf_ || this.pdfMode === 'reflow',
        flowMode: this.flowMode,
        showPdfEnhance: this.isPdf_,
        pdfMode: this.pdfMode,
        pdfAutoCrop: this.pdfAutoCrop,
        pdfDarken: this.pdfDarken,
        pdfWhiten: this.pdfWhiten,
        onNightModeToggle: (night: boolean) => this.onNightModeToggle_(night),
        onFlowModeChange: (mode: string) => this.onFlowModeChange_(mode),
        onPdfModeChange: (mode: string) => this.onPdfModeChange_(mode),
        onPdfEnhanceChange: (autoCrop: boolean, darken: number, whiten: number) =>
          this.onPdfEnhanceChange_(autoCrop, darken, whiten),
        onChange: (config: PageViewConfig) => this.onStyleChange_(config),
        onDismiss: () => { this.showStyle = false; },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.scrim(this.isDark))
  }

  @Builder
  ZoneConfigLayer() {
    Column() {
      Blank().layoutWeight(1).onClick(() => { this.showZoneConfig = false; })
      ClickActionConfig({
        onDismiss: () => { this.showZoneConfig = false; },
        onChanged: (actions: number[]) => {
          this.zoneActions = actions;
          this.runJs_('window.setZoneActions && window.setZoneActions(' + JSON.stringify(actions) + ')');
        },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.scrim(this.isDark))
  }
}
