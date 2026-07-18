/**
 * 分页阅读视图组件 — 页面索引由父组件 ReadPage 管理
 */
import { LayoutPage, LayoutLine } from '../../engine/book/TextLayout';
import { ClickZone, ClickAction } from './ClickAction';
import { ThemeColors } from '../../theme/ThemeColors';

export enum PageTurnAnim {
  NONE = 0,
  SLIDE = 1,
  COVER = 2,
  /** 保留旧值兼容已保存配置。 */
  FADE = 3,
  SIMULATION = 3,
  SCROLL = 4,
}

export interface PageTurnEvent {
  direction: 'prev' | 'next';
  currentPage: number;
  totalPages: number;
}

export interface PageViewConfig {
  animType: PageTurnAnim;
  bgColor: string; textColor: string; titleColor: string;
  fontSize: number; fontWeight: number; fontFamily: string;
  lineHeight: number; letterSpacing: number; paragraphSpacing: number;
  textAlign: 'left' | 'justify'; indentSize: number;
  paddingTop: number; paddingBottom: number; paddingLeft: number; paddingRight: number;
  showHeader: boolean; showFooter: boolean;
  headerContent: string; footerContent: string;
  brightness: number; zhFormat: boolean;
  chineseMode: string;
}

@Component
export struct PageView {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop pages: LayoutPage[] = [];
  @Prop pageIndex: number = 0;
  @Prop chapterTitle: string = '';
  @Prop totalChapters: number = 0;
  @Prop dualPage: boolean = false;
  @Prop chapterIndex: number = 0;
  @Prop config: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: ThemeColors.readingBackgroundDefault(), textColor: ThemeColors.readingTextDefault(),
    titleColor: ThemeColors.readingTitleDefault(), fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans',
    lineHeight: 1.6, letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify',
    indentSize: 2, paddingTop: 16, paddingBottom: 8,
    paddingLeft: 20, paddingRight: 20, showHeader: false, showFooter: true,
    headerContent: '', footerContent: '', brightness: 80, zhFormat: true,
    chineseMode: 'original',
  };

  onPageTurn?: (event: PageTurnEvent) => void;
  onShowMenu?: () => void;
  onShowToc?: () => void;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onToggleReadAloud?: () => void;

  /** 实测字宽和行高回调（用于精确分页） */
  onMeasured?: (charWidth: number, lineHeight: number) => void;

  /** 9 个触控区域的自定义动作配置 */
  @Prop zoneActions: number[] = [];
  onAskKimi?: (text: string) => void;
  onAskXiaoYi?: (text: string) => void;

  private safePageIndex(): number {
    if (this.pages.length === 0) return 0;
    if (this.pageIndex >= this.pages.length) return this.pages.length - 1;
    return this.pageIndex;
  }

  prevPage(): void {
    const idx = this.safePageIndex();
    console.info('[PageView] prevPage pages=' + this.pages.length + ' idx=' + idx);
    if (idx > 0) {
      this.onPageTurn?.({ direction: 'prev', currentPage: idx - 1, totalPages: this.pages.length });
    } else {
      this.onPrevChapter?.();
    }
  }

  nextPage(): void {
    const idx = this.safePageIndex();
    console.info('[PageView] nextPage pages=' + this.pages.length + ' idx=' + idx + ' last?=' + (idx >= this.pages.length - 1));
    if (idx < this.pages.length - 1) {
      this.onPageTurn?.({ direction: 'next', currentPage: idx + 1, totalPages: this.pages.length });
    } else {
      this.onNextChapter?.();
    }
  }

  /** 统一点击处理（Text 和父 Column 共享同一逻辑） */
  private handleClick_(x: number, y: number): void {
    console.info('[PageView] click! x=' + x + ' y=' + y + ' w=' + (this.pageWidth > 0 ? this.pageWidth : 360) + ' h=' + (this.pageHeight > 0 ? this.pageHeight : 640));
    const w = this.pageWidth > 0 ? this.pageWidth : 360;
    const h = this.pageHeight > 0 ? this.pageHeight : 640;
    const x3 = w / 3; const y3 = h / 3;
    let zone: number = ClickZone.MC;
    if (y < y3) {
      zone = x < x3 ? ClickZone.TL : (x > w - x3 ? ClickZone.TR : ClickZone.TC);
    } else if (y < y3 * 2) {
      zone = x < x3 ? ClickZone.ML : (x > w - x3 ? ClickZone.MR : ClickZone.MC);
    } else {
      zone = x < x3 ? ClickZone.BL : (x > w - x3 ? ClickZone.BR : ClickZone.BC);
    }
    this.dispatchZoneAction(zone);
  }

  /** 根据区域动作配置执行对应操作 */
  private dispatchZoneAction(zone: number): void {
    const actions = this.zoneActions.length === 9 ? this.zoneActions : [];
    const action = actions[zone] ?? -1;
    console.info('[PageView] zone=' + zone + ' action=' + action);
    switch (action) {
      case ClickAction.NONE:
        break;
      case ClickAction.MENU:
        this.onShowMenu?.();
        break;
      case ClickAction.NEXT_PAGE:
        this.nextPage();
        break;
      case ClickAction.PREV_PAGE:
        this.prevPage();
        break;
      case ClickAction.NEXT_CHAPTER:
        this.onNextChapter?.();
        break;
      case ClickAction.PREV_CHAPTER:
        this.onPrevChapter?.();
        break;
      case ClickAction.ADD_BOOKMARK:
        // 书签功能暂未实现
        break;
      case ClickAction.CHAPTER_LIST:
        this.onShowToc?.();
        break;
      case ClickAction.READ_ALOUD:
        this.onToggleReadAloud?.();
        break;
      case ClickAction.PREV_PARAGRAPH:
      case ClickAction.NEXT_PARAGRAPH:
        break;
      default:
        // 未知动作，默认显示菜单
        this.onShowMenu?.();
        break;
    }
  }

  getProgressText(): string {
    const t = this.pages.length;
    const c = this.safePageIndex() + 1;
    return t > 0 ? `${c}/${t} (${Math.round((c/t)*100)}%)` : '';
  }

  getOverallProgress(): string {
    if (this.totalChapters <= 0) return '';
    const chProgress = this.pages.length > 0
      ? (this.safePageIndex() + 1) / this.pages.length / this.totalChapters
      : 0;
    const overall = ((this.chapterIndex + chProgress) / this.totalChapters) * 100;
    return Math.round(overall) + '%';
  }

  /** 获取当前页的渲染文本：优先使用已格式化的 formattedText */
  private buildPageContent(): string {
    if (this.pages.length === 0) return '';
    const page = this.pages[this.safePageIndex()];
    if (page.formattedText) return page.formattedText;
    // 回退逻辑（旧数据兼容）
    if (page.lines.length === 0) return '';
    const paraBreakLines = Math.max(0, Math.round(this.config.paragraphSpacing / 10));
    let text = '';
    for (let i = 0; i < page.lines.length; i++) {
      const line = page.lines[i];
      if (i > 0 && line.isParagraphStart && paraBreakLines > 0) {
        for (let b = 0; b < paraBreakLines; b++) text += '\n';
      }
      text += line.text;
      if (i < page.lines.length - 1) text += '\n';
    }
    return text;
  }

  /** 映射字体粗细：0=细体, 1=标准, 2=粗体 */
  private getFontWeight(): FontWeight {
    if (this.config.fontWeight === 0) {
      return FontWeight.Lighter;
    } else if (this.config.fontWeight === 2) {
      return FontWeight.Bold;
    }
    return FontWeight.Normal;
  }

  build() {
    Column() {
      // 隐藏的测量文本（测量字宽和行高，用于 TextLayout 精确估算）
      Text($r('app.string.ui_582c50066c')).fontSize(this.config.fontSize)
        .fontFamily(this.config.fontFamily)
        .fontWeight(this.getFontWeight())
        .visibility(Visibility.None)
        .onAreaChange((_old: Area, n: Area) => {
          const w = typeof n.width === 'number' ? n.width : Number(n.width) || 0;
          const h = typeof n.height === 'number' ? n.height : Number(n.height) || 0;
          if (w > 0 && h > 0) {
            this.onMeasured?.(w, h);
          }
        })
      if (this.config.showHeader && this.chapterTitle) {
        Text(this.config.headerContent || this.chapterTitle)
          .fontSize(12).fontColor(this.config.titleColor)
          .width('100%').textAlign(TextAlign.Center)
      }
		      Column() {
		        if (this.pages.length > 0) {
		          Text(this.buildPageContent())
		            .fontSize(this.config.fontSize).fontColor(this.config.textColor)
		            .fontFamily(this.config.fontFamily)
		            .fontWeight(this.getFontWeight())
		            .lineHeight(this.config.fontSize * this.config.lineHeight)
		            .letterSpacing(this.config.letterSpacing)
		            .textAlign(this.config.textAlign === 'justify' ? TextAlign.JUSTIFY : TextAlign.Start)
		            .width('100%')
		            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
		            .copyOption(CopyOptions.LocalDevice)
		            .editMenuOptions({
		              onCreateMenu: (menuItems: Array<TextMenuItem>) => {
		                return menuItems;
		              },
		              onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
		                if (menuItem.id.equals(TextMenuItemId.of('askKimi'))) {
		                  const pageText = this.buildPageContent();
		                  this.onAskKimi?.(pageText.substring(range.start, range.end));
		                  return true;
		                }
		                return false;
		              },
		            } as EditMenuOptions)
		            .onClick((event: ClickEvent) => {
		              this.handleClick_(event.x, event.y);
		            })
		        }
		      }
		      .layoutWeight(1).width('100%').justifyContent(FlexAlign.Start)
		      .clip(true)
		      .onClick((event: ClickEvent) => {
		        this.handleClick_(event.x, event.y);
		      })
      if (this.config.showFooter) {
        Row() {
          Text(this.chapterTitle)
            .fontSize(11).fontColor(this.config.titleColor)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(this.safePageIndex() + 1 + '/' + this.pages.length)
            .fontSize(11).fontColor(this.config.titleColor).margin({ right: 8 })
          Text(this.getOverallProgress())
            .fontSize(11).fontColor(this.config.titleColor)
        }.width('100%').backgroundColor(this.config.bgColor)
      }
    }
    .padding({ left: this.config.paddingLeft, right: this.config.paddingRight,
      top: this.config.paddingTop, bottom: this.config.paddingBottom })
    .width('100%').height('100%')
    .backgroundColor(this.config.bgColor)
    .onAreaChange((_old: Area, n: Area) => {
      this.pageWidth = typeof n.width === 'number' ? n.width : Number(n.width) || 360;
      this.pageHeight = typeof n.height === 'number' ? n.height : Number(n.height) || 0;
      console.info('[PageView] area w=' + this.pageWidth + ' h=' + this.pageHeight +
        ' padTop=' + this.config.paddingTop + ' padBottom=' + this.config.paddingBottom +
        ' showHeader=' + this.config.showHeader + ' showFooter=' + this.config.showFooter);
    })
  }

  private pageWidth: number = 0;
  private pageHeight: number = 0;
}
