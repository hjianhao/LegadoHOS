/**
 * 书架布局配置面板 — 通过 GlobalConfig 统一管理
 */
import { GlobalConfig } from '../data/preferences/GlobalConfig';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct BookshelfConfigDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  onConfigChanged?: () => void;

  // 用 @State 做 UI 响应式副本，读写都通过 GlobalConfig
  @State groupStyle: number = 0;
  @State sortMode: number = 0;
  @State sortOrder: number = 0;
  @State layoutMode: number = 0;
  @State gridColumns: number = 3;
  @State gridStyle: number = 0;
  @State showDivider: boolean = true;
  @State coverWidth: number = 84;
  @State isCompact: boolean = false;
  @State titleMaxLines: number = 2;
  @State coverShadow: boolean = false;
  @State showUnread: boolean = true;
  @State showTip: boolean = true;
  @State showLastUpdateTime: boolean = true;
  @State showBookIntro: boolean = true;
  @State showLatestChapter: boolean = true;
  @State showTag: boolean = true;
  @State introMaxLines: number = 2;
  @State refreshLimit: number = 0;

  private groupStyleLabels = ['Tab 标签', '隐藏 Tab', '文件夹'];
  private sortLabels = ['最后阅读', '书名', '更新时间', '手动排序'];
  private gridStyleLabels = ['标准', '紧凑', '仅封面'];

  aboutToAppear(): void {
    const cfg = GlobalConfig.getInstance();
    this.groupStyle = cfg.groupStyle;
    this.sortMode = cfg.sortMode;
    this.sortOrder = cfg.sortOrder;
    this.layoutMode = cfg.layoutMode;
    this.gridColumns = cfg.gridColumns;
    this.gridStyle = cfg.gridStyle;
    this.showDivider = cfg.showDivider;
    this.coverWidth = cfg.coverWidth;
    this.isCompact = cfg.isCompact;
    this.titleMaxLines = cfg.titleMaxLines;
    this.coverShadow = cfg.coverShadow;
    this.showUnread = cfg.showUnread;
    this.showTip = cfg.showTip;
    this.showLastUpdateTime = cfg.showLastUpdateTime;
    this.showBookIntro = cfg.showBookIntro;
    this.showLatestChapter = cfg.showLatestChapter;
    this.showTag = cfg.showTag;
    this.introMaxLines = cfg.introMaxLines;
    this.refreshLimit = cfg.refreshLimit;
  }

  /** 每次修改后：写 GlobalConfig + 持久化 + 通知 */
  private onChanged(): void {
    const cfg = GlobalConfig.getInstance();
    cfg.groupStyle = this.groupStyle;
    cfg.sortMode = this.sortMode;
    cfg.sortOrder = this.sortOrder;
    cfg.layoutMode = this.layoutMode;
    cfg.gridColumns = this.gridColumns;
    cfg.gridStyle = this.gridStyle;
    cfg.showDivider = this.showDivider;
    cfg.coverWidth = this.coverWidth;
    cfg.isCompact = this.isCompact;
    cfg.titleMaxLines = this.titleMaxLines;
    cfg.coverShadow = this.coverShadow;
    cfg.showUnread = this.showUnread;
    cfg.showTip = this.showTip;
    cfg.showLastUpdateTime = this.showLastUpdateTime;
    cfg.showBookIntro = this.showBookIntro;
    cfg.showLatestChapter = this.showLatestChapter;
    cfg.showTag = this.showTag;
    cfg.introMaxLines = this.introMaxLines;
    cfg.refreshLimit = this.refreshLimit;
    cfg.syncToAppStorage();
    cfg.save();
    if (this.onConfigChanged) this.onConfigChanged();
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_99f30ec7d9')).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }.padding(12).width('100%')

      Scroll() {
        Column() {
          Row() {
            Text($r('app.string.ui_b42911985e')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
            Button(this.groupStyleLabels[this.groupStyle] + ' ›')
              .fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
              .onClick(() => { this.groupStyle = (this.groupStyle + 1) % 3; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_3bf3689a69')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
            Button(this.sortLabels[this.sortMode] + ' ›')
              .fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
              .onClick(() => { this.sortMode = (this.sortMode + 1) % 4; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.ui_c0276ec9a7')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.sortOrder === 1 })
              .onChange((v: boolean) => { this.sortOrder = v ? 1 : 0; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_c6b568b516')).fontSize(14).layoutWeight(1)
            Button((this.layoutMode === 0 ? '列表' : '网格') + ' ›')
              .fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
              .onClick(() => { this.layoutMode = this.layoutMode === 0 ? 1 : 0; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          if (this.layoutMode === 1) {
            Row() {
              Text($r('app.string.ui_b65a519f48')).fontSize(14).layoutWeight(1)
              Button(this.gridStyleLabels[this.gridStyle] + ' ›')
                .fontSize(13).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(Color.Transparent)
                .onClick(() => { this.gridStyle = (this.gridStyle + 1) % 3; this.onChanged(); })
            }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

            Row() {
              Text($r('app.string.ui_94e885c673')).fontSize(14)
              Text(String(this.gridColumns)).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
              Slider({ value: this.gridColumns, min: 2, max: 7, step: 1 }).width('50%').margin({ left: 8 })
                .onChange((v: number) => { this.gridColumns = v; this.onChanged(); })
            }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)
          }

          if (this.layoutMode === 0) {
            Row() {
              Text($r('app.string.ui_76b7708dba')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.showDivider })
                .onChange((v: boolean) => { this.showDivider = v; this.onChanged(); })
            }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

            Row() {
              Text($r('app.string.ui_5631e62f4e')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.isCompact })
                .onChange((v: boolean) => { this.isCompact = v; this.onChanged(); })
            }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

            Row() {
              Text($r('app.string.ui_10f8d00352')).fontSize(14)
              Text(String(this.coverWidth)).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
              Slider({ value: this.coverWidth, min: 40, max: 120, step: 5 }).width('50%').margin({ left: 8 })
                .onChange((v: number) => { this.coverWidth = v; this.onChanged(); })
            }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)
          }

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_33f508cafc')).fontSize(14)
            Text(String(this.titleMaxLines)).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
            Slider({ value: this.titleMaxLines, min: 1, max: 5, step: 1 }).width('50%').margin({ left: 8 })
              .onChange((v: number) => { this.titleMaxLines = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.ui_d88a491209')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.coverShadow })
              .onChange((v: boolean) => { this.coverShadow = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_56e7fe236f')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showUnread })
              .onChange((v: boolean) => { this.showUnread = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.ui_cb637b277a')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showTip })
              .onChange((v: boolean) => { this.showTip = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.ui_250914a225')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showLastUpdateTime })
              .onChange((v: boolean) => { this.showLastUpdateTime = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_3f1dbc33b9')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showBookIntro })
              .onChange((v: boolean) => { this.showBookIntro = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          if (this.showBookIntro) {
            Column() {
              Row() {
                Text($r('app.string.ui_297c07c337')).fontSize(14).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.showLatestChapter })
                  .onChange((v: boolean) => { this.showLatestChapter = v; this.onChanged(); })
              }.width('100%').height(48).padding({ left: 16, right: 8 }).alignItems(VerticalAlign.Center)
              Row() {
                Text($r('app.string.ui_6c64d7e6ab')).fontSize(14).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.showTag })
                  .onChange((v: boolean) => { this.showTag = v; this.onChanged(); })
              }.width('100%').height(48).padding({ left: 16, right: 8 }).alignItems(VerticalAlign.Center)
              Row() {
                Text($r('app.string.ui_5ca7f32445')).fontSize(14)
                Text(this.introMaxLines === 0 ? '全部' : String(this.introMaxLines)).fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
                Slider({ value: this.introMaxLines, min: 0, max: 10, step: 1 }).width('50%').margin({ left: 8 })
                  .onChange((v: number) => { this.introMaxLines = v; this.onChanged(); })
              }.width('100%').height(48).padding({ left: 16, right: 8 }).alignItems(VerticalAlign.Center)
            }
          }

          Divider().color(ThemeColors.outlineVariant(this.isDark)).width('100%').margin({ left: 8 })

          Row() {
            Text($r('app.string.ui_d9fa520992')).fontSize(14)
            Text(this.refreshLimit === 0 ? '不限制' : `${this.refreshLimit}本`).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 6 })
            Slider({ value: this.refreshLimit, min: 0, max: 100, step: 5 }).width('50%').margin({ left: 8 })
              .onChange((v: number) => { this.refreshLimit = v; this.onChanged(); })
          }.width('100%').height(48).padding({ left: 8, right: 8 }).alignItems(VerticalAlign.Center)

          Blank().height(32)
        }.width('100%').padding({ left: 8, right: 8 })
      }.layoutWeight(1).width('100%')
    }
    .padding({ left: 8, right: 8, top: 0, bottom: 12 })
    .width('100%').height('70%').constraintSize({ maxWidth: 640, maxHeight: 720 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
