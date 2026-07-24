/**
 * 分页阅读视图组件 — 页面索引由父组件 ReadPage 管理
 *
 * 九宫格分区使用「内容区」宽高（不含外层 padding / 页眉页脚），
 * 与点击坐标同一坐标系。
 *
 * 双页模式：左右 Text 会拦截点击（可选择文本），不能只绑 Row.onClick；
 * 需在左右页 / 页缝分别 onClick，并把局部 x 映射回整页内容区坐标。
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
  @Prop @Watch('onDisplaySourceChange_') pages: LayoutPage[] = [];
  @Prop @Watch('onDisplaySourceChange_') pageIndex: number = 0;
  @Prop chapterTitle: string = '';
  @Prop totalChapters: number = 0;
  @Prop @Watch('onDisplaySourceChange_') dualPage: boolean = false;
  @Prop dualPageGutter: number = 48;
  @Prop chapterIndex: number = 0;
  @Prop config: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: ThemeColors.readingBackgroundDefault(), textColor: ThemeColors.readingTextDefault(),
    titleColor: ThemeColors.secondaryText(this.isDark), fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans',
    lineHeight: 1.6, letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify',
    indentSize: 2, paddingTop: 16, paddingBottom: 8,
    paddingLeft: 20, paddingRight: 20, showHeader: false, showFooter: true,
    headerContent: '', footerContent: '', brightness: 80, zhFormat: true,
    chineseMode: 'original',
  };

  onPageTurn?: (event: PageTurnEvent) => void;
  onShowMenu?: () => void;
  onShowToc?: () => void;
  /** 显式「上一章」：落到上一章开头 */
  onPrevChapter?: () => void;
  /** 上一页跨章：落到上一章末尾（连续阅读） */
  onPrevChapterAtEnd?: () => void;
  onNextChapter?: () => void;
  onToggleReadAloud?: () => void;

  /** 实测字宽和行高回调（用于精确分页） */
  onMeasured?: (charWidth: number, lineHeight: number) => void;

  /** 9 个触控区域的自定义动作配置 */
  @Prop zoneActions: number[] = [];
  onAskKimi?: (text: string) => void;
  onAskXiaoYi?: (text: string) => void;

  /**
   * 用 @State 持有当前展示正文，保证 pageIndex 变化时 Text 一定刷新。
   * 仅靠 @Prop + 内联表达式时，textSelectable 的 Text 仍可能不更新字符串。
   */
  @State private leftText_: string = '';
  @State private rightText_: string = '';
  @State private hasRightPage_: boolean = false;
  @State private displayIdx_: number = 0;

  aboutToAppear(): void {
    this.refreshDisplayTexts_();
  }

  private onDisplaySourceChange_(): void {
    this.refreshDisplayTexts_();
  }

  private refreshDisplayTexts_(): void {
    const idx = this.safePageIndex();
    this.displayIdx_ = idx;
    this.leftText_ = this.buildPageContentForPage_(idx);
    this.hasRightPage_ = this.dualPage && (idx + 1 < this.pages.length);
    this.rightText_ = this.hasRightPage_ ? this.buildPageContentForPage_(idx + 1) : '';
    console.info('[PageView] refreshDisplay idx=' + idx +
      ' dual=' + this.dualPage +
      ' leftLen=' + this.leftText_.length +
      ' rightLen=' + this.rightText_.length +
      ' pages=' + this.pages.length);
  }

  private safePageIndex(): number {
    if (this.pages.length === 0) return 0;
    if (this.pageIndex >= this.pages.length) return this.pages.length - 1;
    return this.pageIndex;
  }

  prevPage(): void {
    const idx = this.safePageIndex();
    const step = this.dualPage ? 2 : 1;
    console.info('[PageView] prevPage pages=' + this.pages.length + ' idx=' + idx + ' step=' + step);
    if (idx - step >= 0) {
      this.onPageTurn?.({ direction: 'prev', currentPage: idx - step, totalPages: this.pages.length });
    } else if (idx > 0) {
      this.onPageTurn?.({ direction: 'prev', currentPage: 0, totalPages: this.pages.length });
    } else {
      // 章首再上一页：连续阅读 → 上一章末页
      if (this.onPrevChapterAtEnd) {
        this.onPrevChapterAtEnd();
      } else {
        this.onPrevChapter?.();
      }
    }
  }

  nextPage(): void {
    const idx = this.safePageIndex();
    const step = this.dualPage ? 2 : 1;
    console.info('[PageView] nextPage pages=' + this.pages.length + ' idx=' + idx + ' step=' + step + ' last?=' + (idx >= this.pages.length - 1));
    if (idx + step < this.pages.length) {
      this.onPageTurn?.({ direction: 'next', currentPage: idx + step, totalPages: this.pages.length });
    } else if (idx < this.pages.length - 1) {
      this.onPageTurn?.({ direction: 'next', currentPage: this.pages.length - 1, totalPages: this.pages.length });
    } else {
      this.onNextChapter?.();
    }
  }

  /**
   * 分页模式统一使用物理滑动方向：右滑上一页，左滑下一页。
   * 仅接受明显的横向手势，避免轻微抖动和斜向滚动误触发翻页。
   */
  private handlePageSwipe_(event: GestureEvent): void {
    const offsetX: number = event.offsetX;
    const offsetY: number = event.offsetY;
    const minDistance: number = Math.max(40, (this.pageWidth > 0 ? this.pageWidth : 360) * 0.08);
    if (Math.abs(offsetX) < minDistance || Math.abs(offsetX) <= Math.abs(offsetY) * 1.25) return;
    if (offsetX > 0) {
      this.prevPage();
    } else {
      this.nextPage();
    }
  }

  /** 九宫格用内容区尺寸（不含根布局 padding / 页眉页脚） */
  private zoneWidth_(): number {
    if (this.contentWidth > 0) return this.contentWidth;
    if (this.pageWidth > 0) {
      return Math.max(1, this.pageWidth - this.config.paddingLeft - this.config.paddingRight);
    }
    return 360;
  }

  private zoneHeight_(): number {
    if (this.contentHeight > 0) return this.contentHeight;
    if (this.pageHeight > 0) {
      return Math.max(1, this.pageHeight - this.config.paddingTop - this.config.paddingBottom);
    }
    return 640;
  }

  /** 双页左栏内容宽度（不含页缝） */
  private dualPaneWidth_(): number {
    return Math.max(1, (this.zoneWidth_() - this.dualPageGutter) / 2);
  }

  /**
   * @param x 相对「整页内容区」左上角的 x
   * @param y 相对「整页内容区」左上角的 y
   */
  private handleClick_(x: number, y: number): void {
    const w = this.zoneWidth_();
    const h = this.zoneHeight_();
    console.info('[PageView] click! x=' + x.toFixed(1) + ' y=' + y.toFixed(1) +
      ' w=' + w.toFixed(1) + ' h=' + h.toFixed(1) + ' dual=' + this.dualPage);
    const x3 = w / 3;
    const y3 = h / 3;
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

  /** 双页局部坐标 → 内容区坐标后分发 */
  private handleDualPaneClick_(localX: number, localY: number, offsetX: number): void {
    this.handleClick_(localX + offsetX, localY);
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
        // 显式上一章 → 章首（不是章末）
        this.onPrevChapter?.();
        break;
      case ClickAction.ADD_BOOKMARK:
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

  /** 构建指定页码的页面文本内容（用于双页模式，支持 formattedText） */
  private buildPageContentForPage_(pageIdx: number): string {
    if (pageIdx < 0 || pageIdx >= this.pages.length) return '';
    const page = this.pages[pageIdx];
    if (page.formattedText) return page.formattedText;
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
      // 隐藏的测量文本
      Text($r('app.string.ui_582c50066c')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(this.config.fontSize)
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
          if (this.dualPage) {
            // 双页：Text 绑定 @State leftText_/rightText_（由 @Watch pageIndex 刷新）
            Row() {
              Column() {
                Text(this.leftText_)
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
                    onCreateMenu: (menuItems: Array<TextMenuItem>) => { return menuItems; },
                    onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
                      if (menuItem.id.equals(TextMenuItemId.of('askKimi'))) {
                        this.onAskKimi?.(this.leftText_.substring(range.start, range.end));
                        return true;
                      }
                      return false;
                    },
                  } as EditMenuOptions)
                  .onClick((event: ClickEvent) => {
                    this.handleDualPaneClick_(event.x, event.y, 0);
                  })
              }
              .layoutWeight(1).height('100%').clip(true)
              .justifyContent(FlexAlign.Start)
              .onClick((event: ClickEvent) => {
                this.handleDualPaneClick_(event.x, event.y, 0);
              })

              Column()
                .width(this.dualPageGutter)
                .height('100%')
                .backgroundColor(this.config.bgColor)
                .onClick((event: ClickEvent) => {
                  this.handleDualPaneClick_(event.x, event.y, this.dualPaneWidth_());
                })

              if (this.hasRightPage_) {
                Column() {
                  Text(this.rightText_)
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
                      onCreateMenu: (menuItems: Array<TextMenuItem>) => { return menuItems; },
                      onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
                        if (menuItem.id.equals(TextMenuItemId.of('askKimi'))) {
                          this.onAskKimi?.(this.rightText_.substring(range.start, range.end));
                          return true;
                        }
                        return false;
                      },
                    } as EditMenuOptions)
                    .onClick((event: ClickEvent) => {
                      this.handleDualPaneClick_(
                        event.x,
                        event.y,
                        this.dualPaneWidth_() + this.dualPageGutter
                      );
                    })
                }
                .layoutWeight(1).height('100%').clip(true)
                .justifyContent(FlexAlign.Start)
                .onClick((event: ClickEvent) => {
                  this.handleDualPaneClick_(
                    event.x,
                    event.y,
                    this.dualPaneWidth_() + this.dualPageGutter
                  );
                })
              } else {
                Column()
                  .layoutWeight(1)
                  .height('100%')
                  .onClick((event: ClickEvent) => {
                    this.handleDualPaneClick_(
                      event.x,
                      event.y,
                      this.dualPaneWidth_() + this.dualPageGutter
                    );
                  })
              }
            }
            .width('100%')
            .height('100%')
          } else {
            // 单页：同样绑定 @State leftText_
            Column() {
              Text(this.leftText_)
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
                  onCreateMenu: (menuItems: Array<TextMenuItem>) => { return menuItems; },
                  onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
                    if (menuItem.id.equals(TextMenuItemId.of('askKimi'))) {
                      this.onAskKimi?.(this.leftText_.substring(range.start, range.end));
                      return true;
                    }
                    return false;
                  },
                } as EditMenuOptions)
                .onClick((event: ClickEvent) => {
                  this.handleClick_(event.x, event.y);
                })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
              .onClick((event: ClickEvent) => {
                this.handleClick_(event.x, event.y);
              })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .clip(true)
      .onAreaChange((_old: Area, n: Area) => {
        const w = typeof n.width === 'number' ? n.width : Number(n.width) || 0;
        const h = typeof n.height === 'number' ? n.height : Number(n.height) || 0;
        if (w > 0) this.contentWidth = w;
        if (h > 0) this.contentHeight = h;
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
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 10 })
        .onActionEnd((event: GestureEvent) => {
          this.handlePageSwipe_(event);
        })
    )
    .onAreaChange((_old: Area, n: Area) => {
      this.pageWidth = typeof n.width === 'number' ? n.width : Number(n.width) || 360;
      this.pageHeight = typeof n.height === 'number' ? n.height : Number(n.height) || 0;
    })
  }

  private pageWidth: number = 0;
  private pageHeight: number = 0;
  /** 正文内容区（layoutWeight 中间列）实测尺寸，九宫格以此为准 */
  private contentWidth: number = 0;
  private contentHeight: number = 0;
}
