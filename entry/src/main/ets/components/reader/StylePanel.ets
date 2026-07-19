/**
 * 阅读风格设置面板 - 实时预览
 */
import { PageViewConfig, PageTurnAnim } from './PageView';
import { ThemeColors } from '../../theme/ThemeColors';
import { FontInfo } from '../../utils/FontManager';

@Component
export struct StylePanel {
  @StorageLink('isDark') isDark: boolean = false;
  @State cfg: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: ThemeColors.readingBackgroundDefault(), textColor: ThemeColors.readingTextDefault(),
    titleColor: ThemeColors.secondaryText(this.isDark), fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans',
    lineHeight: 1.6, letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify',
    indentSize: 2, paddingTop: 16, paddingBottom: 8,
    paddingLeft: 20, paddingRight: 20, showHeader: false, showFooter: true,
    headerContent: '', footerContent: '', brightness: 80, zhFormat: true,
    chineseMode: 'original',
  };
  @State activeTab: number = 0;
  /** 字体列表（由 ReadPage 从 FontManager 获取并传入） */
  @Prop fontList: FontInfo[] = [];
  /** 夜间模式 */
  @Prop nightMode: boolean = false;
  /** 日间背景色：夜间模式下仍编辑这份用户配置 */
  @Prop dayBgColor: string = '';
  /** 日间文字色：夜间模式下仍编辑这份用户配置 */
  @Prop dayTextColor: string = '';
  /** 图文阅读器支持分页/滚动切换；小说阅读器暂不显示。 */
  @Prop showPdfEnhance: boolean = false;
  @Prop pdfMode: string = 'original';
  @Prop pdfOrientation: string = 'auto';
  @Prop pdfAutoCrop: boolean = false;
  @Prop pdfDarken: number = 0;
  @Prop pdfWhiten: number = 0;
  @State editingDayBgColor: string = '';
  @State editingDayTextColor: string = '';

  onChange?: (config: PageViewConfig) => void;
  onDismiss?: () => void;
  onNightModeToggle?: (night: boolean) => void;
  onPdfModeChange?: (mode: string) => void;
  onPdfOrientationChange?: (mode: string) => void;
  onPdfEnhanceChange?: (autoCrop: boolean, darken: number, whiten: number) => void;

  aboutToAppear(): void {
    this.editingDayBgColor = this.dayBgColor || this.cfg.bgColor;
    this.editingDayTextColor = this.dayTextColor || this.cfg.textColor;
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text($r('app.string.ui_3de1b2251f')).fontSize(16).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1).textAlign(TextAlign.Start)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      // Tab 栏
      Row() {
        this.tabBtn('字体', 0); this.tabBtn('间距', 1); this.tabBtn('边距', 2); this.tabBtn('颜色', 3); this.tabBtn('其他', 4)
      }.width('100%').padding({ top: 2 })

      // 内容
      if (this.activeTab === 0) { this.buildFont() }
      else if (this.activeTab === 1) { this.buildSpacing() }
      else if (this.activeTab === 2) { this.buildPadding() }
      else if (this.activeTab === 3) { this.buildColors() }
      else if (this.activeTab === 4) { this.buildOther() }
    }
    .width('100%').backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 }).padding({ left: 8, right: 8 })
  }

  @Builder tabBtn(label: string, idx: number) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.activeTab === idx ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .fontWeight(this.activeTab === idx ? FontWeight.Bold : FontWeight.Normal)
        .padding({ top: 6, bottom: 6 })
      if (this.activeTab === idx) {
        Row().width('60%').height(2).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(1)
      }
    }
    .onClick(() => { this.activeTab = idx; })
    .layoutWeight(1).alignItems(HorizontalAlign.Center)
  }

  // ===== 字体 =====
  @Builder buildFont() {
    Column() { }.width('100%').padding(12)
    Row() {
      Text($r('app.string.ui_576ccdb1f1')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.fontSize, min: 10, max: 40, step: 1 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.fontSize = v; this.emitChange(); })
      Text(String(this.cfg.fontSize)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_b361526fa3')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      this.fwChip('细体', 0)
      this.fwChip('标准', 1)
      this.fwChip('粗体', 2)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_32711e1626')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Scroll() {
        Row() {
          ForEach(this.fontList, (font: FontInfo) => {
            this.fontChip(font)
          })
        }
        .constraintSize({ minWidth: '100%' })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
    }.width('100%').margin({ bottom: 6 })
    // 字体管理入口
    Row() {
      Blank().layoutWeight(1)
      Text($r('app.string.ui_25afac8c6a')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
        .onClick(() => {
          this.onDismiss?.();
          this.getUIContext().getRouter().pushUrl({ url: 'pages/FontManagerPage' }).catch(() => {});
        })
    }.width('100%').margin({ bottom: 6 })
  }

  // ===== 间距 =====
  @Builder buildSpacing() {
    Column() { }.width('100%').padding(12)
    Row() {
      Text($r('app.string.ui_514b541ac4')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.toInt(this.cfg.lineHeight * 10), min: 10, max: 25, step: 1 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.lineHeight = v / 10; this.emitChange(); })
      Text(String(this.cfg.lineHeight.toFixed(1))).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_c86f1b361f')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.toInt(this.cfg.letterSpacing * 10), min: 0, max: 20, step: 1 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.letterSpacing = v / 10; this.emitChange(); })
      Text(String(this.cfg.letterSpacing.toFixed(1))).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_f8d961b64e')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.paragraphSpacing, min: 0, max: 30, step: 1 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.paragraphSpacing = v; this.emitChange(); })
      Text(String(this.cfg.paragraphSpacing)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_3b411a009b')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
    }.width('100%')
    Row() {
      this.indentChip('无', 0)
      this.indentChip('1', 1)
      this.indentChip('2', 2)
      this.indentChip('3', 3)
      this.indentChip('4', 4)
    }.width('100%').margin({ bottom: 6 })
  }

  // ===== 边距 =====
  @Builder buildPadding() {
    Column() { }.width('100%').padding(12)
    Row() {
      Text($r('app.string.ui_c2b2faa5e1')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.paddingTop, min: 0, max: 60, step: 2 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.paddingTop = v; this.emitChange(); })
      Text(String(this.cfg.paddingTop)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_0d9189e570')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.paddingBottom, min: 0, max: 60, step: 2 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.paddingBottom = v; this.emitChange(); })
      Text(String(this.cfg.paddingBottom)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_c22a3ffa46')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.paddingLeft, min: 0, max: 40, step: 2 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.paddingLeft = v; this.emitChange(); })
      Text(String(this.cfg.paddingLeft)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
    Row() {
      Text($r('app.string.ui_a78c05fbec')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(50)
      Slider({ value: this.cfg.paddingRight, min: 0, max: 40, step: 2 }).layoutWeight(1).margin({ left: 4, right: 4 })
        .onChange((v: number) => { this.cfg.paddingRight = v; this.emitChange(); })
      Text(String(this.cfg.paddingRight)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
    }.width('100%').margin({ bottom: 6 })
  }

  // ===== 颜色 =====
  @Builder buildColors() {
    Column() { }.width('100%').padding(12)
    // 日间/夜间切换
    Row() {
      Text($r('app.string.ui_80ec9e2b1b')).fontSize(13).height(40).textAlign(TextAlign.Center)
        .fontColor(!this.nightMode ? ThemeColors.onSurface(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .accessibilityText($r('app.string.ui_80bb821d7b')).onClick(() => { this.onNightModeToggle?.(false); })
      Toggle({ type: ToggleType.Switch, isOn: this.nightMode })
        .margin({ left: 6, right: 6 })
        .onChange((v: boolean) => { this.onNightModeToggle?.(v); })
      Text($r('app.string.ui_30b2c979ac')).fontSize(13).height(40).textAlign(TextAlign.Center)
        .fontColor(this.nightMode ? ThemeColors.onSurface(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .accessibilityText($r('app.string.ui_79d4a34df5')).onClick(() => { this.onNightModeToggle?.(true); })
    }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 14 })
    Text($r('app.string.ui_498e30003d')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
    Row() {
      ForEach(ThemeColors.readingBackgroundPresets(), (color: string) => { this.bgChip(color) })
    }.width('100%').margin({ bottom: 12 })
    Text($r('app.string.ui_7fbfaef2d0')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
    Row() {
      ForEach(ThemeColors.readingTextPresets(), (color: string) => { this.txtChip(color) })
    }.width('100%').margin({ bottom: 6 })
  }

  @Builder bgChip(color: string) {
    Stack() {
      Column().width(28).height(28).backgroundColor(color)
        .border({ width: color === this.currentDayBgColor_() ? 2 : 1, color: color === this.currentDayBgColor_() ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark) }).borderRadius(14)
    }.width(44).height(44).margin({ right: 2 })
      .accessibilityText('选择阅读背景色')
      .onClick(() => { this.editingDayBgColor = color; this.emitChange(); })
  }
  @Builder txtChip(color: string) {
    Stack() {
      Column().width(28).height(28).backgroundColor(color)
        .border({ width: color === this.currentDayTextColor_() ? 2 : 1, color: color === this.currentDayTextColor_() ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark) }).borderRadius(14)
    }.width(44).height(44).margin({ right: 2 })
      .accessibilityText('选择阅读文字色')
      .onClick(() => { this.editingDayTextColor = color; this.emitChange(); })
  }

  @Builder fwChip(label: string, w: number) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.cfg.fontWeight === w ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
    }
    .backgroundColor(this.cfg.fontWeight === w ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(22).height(44).margin({ right: 6 }).justifyContent(FlexAlign.Center)
    .accessibilityText('字重' + label)
    .onClick(() => { this.cfg.fontWeight = w; this.emitChange(); })
  }

  /** 字体选择项 - 名称使用自身字体渲染预览 */
  @Builder fontChip(font: FontInfo) {
    Column() {
      Text(font.name)
        .fontSize(13)
        .fontFamily(this.fontPreviewFamily_(font))
        .fontColor(this.cfg.fontFamily === font.familyName ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
    }
    .backgroundColor(this.cfg.fontFamily === font.familyName ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(22).height(44).margin({ left: 4 }).justifyContent(FlexAlign.Center)
    .accessibilityText('字体' + font.name)
    .onClick(() => { this.cfg.fontFamily = font.familyName; this.emitChange(); })
  }

  private fontPreviewFamily_(font: FontInfo): string {
    return font.familyName.startsWith('__') ? 'HarmonyOS Sans' : font.familyName;
  }

  @Builder indentChip(label: string, n: number) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.cfg.indentSize === n ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
    }
    .backgroundColor(this.cfg.indentSize === n ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(22).height(44).margin({ right: 6 }).justifyContent(FlexAlign.Center)
    .accessibilityText('首行缩进' + label)
    .onClick(() => { this.cfg.indentSize = n; this.emitChange(); })
  }

  // ===== 其他 =====
  @Builder buildOther() {
    Column() { }.width('100%').padding(12)
    if (this.showPdfEnhance) {
      Text($r('app.string.ui_0f68d35084')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
      Row() {
        this.pdfModeChip('原版', 'original')
        this.pdfModeChip('文字重排', 'reflow')
      }.width('100%').margin({ bottom: 10 })
      Text($r('app.string.ui_6433b1cc35')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
      Row() {
        this.pdfOrientationChip('跟随系统', 'auto')
        this.pdfOrientationChip('竖屏', 'portrait')
        this.pdfOrientationChip('横屏', 'landscape')
      }.width('100%').margin({ bottom: 10 })
      if (this.pdfMode === 'original') {
        Row() {
          Text($r('app.string.ui_4a9a898510')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.pdfAutoCrop })
            .onChange((v: boolean) => { this.onPdfEnhanceChange?.(v, this.pdfDarken, this.pdfWhiten); })
        }.width('100%').margin({ bottom: 8 })
        Row() {
          Text($r('app.string.ui_a7f4eb7124')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(64)
          Slider({ value: this.pdfDarken, min: 0, max: 100, step: 5 }).layoutWeight(1).margin({ left: 4, right: 4 })
            .onChange((v: number) => { this.onPdfEnhanceChange?.(this.pdfAutoCrop, v, this.pdfWhiten); })
          Text(String(this.pdfDarken)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
        }.width('100%').margin({ bottom: 8 })
        Row() {
          Text($r('app.string.ui_064bdd2d9f')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(64)
          Slider({ value: this.pdfWhiten, min: 0, max: 100, step: 5 }).layoutWeight(1).margin({ left: 4, right: 4 })
            .onChange((v: number) => { this.onPdfEnhanceChange?.(this.pdfAutoCrop, this.pdfDarken, v); })
          Text(String(this.pdfWhiten)).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30).textAlign(TextAlign.End)
        }.width('100%').margin({ bottom: 10 })
      }
    }
    Row() {
      Text($r('app.string.ui_788be77ceb')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.cfg.zhFormat }).onChange((v: boolean) => { this.cfg.zhFormat = v; this.emitChange(); })
    }.width('100%').margin({ bottom: 10 })
    Row() {
      Text($r('app.string.ui_365bdb3b92')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.cfg.showFooter }).onChange((v: boolean) => { this.cfg.showFooter = v; this.emitChange(); })
    }.width('100%').margin({ bottom: 10 })
    Text($r('app.string.ui_fd900500a2')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width('100%').margin({ bottom: 4 })
    Row() {
      this.zhChip('原文', 'original')
      this.zhChip('简体', 'simplified')
      this.zhChip('繁体', 'traditional')
    }.width('100%')
  }

  @Builder pdfModeChip(label: string, mode: string) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.pdfMode === mode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 20, right: 20 })
    }
    .backgroundColor(this.pdfMode === mode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(16).margin({ right: 8 })
    .onClick(() => { this.onPdfModeChange?.(mode); })
  }

  @Builder pdfOrientationChip(label: string, mode: string) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.pdfOrientation === mode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 14, right: 14 })
    }
    .backgroundColor(this.pdfOrientation === mode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(16).margin({ right: 8 })
    .onClick(() => { this.onPdfOrientationChange?.(mode); })
  }

  @Builder zhChip(label: string, mode: string) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.cfg.chineseMode === mode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
    }
    .backgroundColor(this.cfg.chineseMode === mode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(16).margin({ right: 8 })
    .onClick(() => {
      if (mode === 'original' || mode === 'simplified' || mode === 'traditional') {
        this.cfg.chineseMode = mode;
      }
      this.emitChange();
    })
  }

  // ==========

  emitChange(): void {
    this.onChange?.(this.toDayConfig_());
  }

  private currentDayBgColor_(): string {
    return this.editingDayBgColor || this.dayBgColor || this.cfg.bgColor;
  }

  private currentDayTextColor_(): string {
    return this.editingDayTextColor || this.dayTextColor || this.cfg.textColor;
  }

  private toDayConfig_(): PageViewConfig {
    return {
      animType: this.cfg.animType,
      bgColor: this.currentDayBgColor_(),
      textColor: this.currentDayTextColor_(),
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

  toInt(v: number): number { return Math.round(v); }
}
