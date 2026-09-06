import { CheckConfig } from '../../service/SourceChecker';
import { ThemeColors } from '../../theme/ThemeColors';
import { UiUtil } from '../../util/UiUtil';

@CustomDialog
export struct SourceCheckConfigDialog {
  controller: CustomDialogController;
  initialConfig: CheckConfig = {
    keyword: '我的', timeout: 180000,
    checkSearch: true, checkDiscovery: true, checkInfo: true,
    checkCategory: true, checkContent: true, concurrency: 16
  };
  @StorageLink('isDark') isDark: boolean = false;
  @State keyword: string = '我的';
  @State timeoutText: string = '180';
  @State concurrencyText: string = '16';
  @State checkSearch: boolean = true;
  @State checkDiscovery: boolean = true;
  @State checkInfo: boolean = true;
  @State checkCategory: boolean = true;
  @State checkContent: boolean = true;
  onStart?: (config: CheckConfig) => void;

  aboutToAppear(): void {
    const config = this.initialConfig;
    this.keyword = config.keyword;
    this.timeoutText = Math.max(1, Math.round(config.timeout / 1000)).toString();
    this.concurrencyText = config.concurrency.toString();
    this.checkSearch = config.checkSearch;
    this.checkDiscovery = config.checkDiscovery;
    this.checkInfo = config.checkInfo;
    this.checkCategory = config.checkCategory;
    this.checkContent = config.checkContent;
  }

  private submit(): void {
    const timeoutSeconds = Number(this.timeoutText);
    const concurrency = Number(this.concurrencyText);
    if (!this.keyword.trim() || !Number.isFinite(timeoutSeconds) || timeoutSeconds < 1) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入关键词，超时至少为 1 秒', duration: 1800 });
      return;
    }
    if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 32) {
      UiUtil.showToast(this.getUIContext(), { message: '并发数请输入 1 至 32', duration: 1500 });
      return;
    }
    if (!this.checkSearch && !this.checkDiscovery) {
      UiUtil.showToast(this.getUIContext(), { message: '搜索和发现至少选择一项', duration: 1500 });
      return;
    }
    const config: CheckConfig = {
      keyword: this.keyword.trim(), timeout: timeoutSeconds * 1000,
      checkSearch: this.checkSearch, checkDiscovery: this.checkDiscovery,
      checkInfo: this.checkInfo, checkCategory: this.checkCategory, checkContent: this.checkContent,
      concurrency: concurrency
    };
    if (this.onStart) this.onStart(config);
    this.controller.close();
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_6190ea7cea')).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button($r('app.string.common_close')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { this.controller.close(); })
      }.height(56).width('100%')
      Scroll() {
        Column() {
          Text($r('app.string.ui_ba53d79c46')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          TextInput({ text: this.keyword, placeholder: $r('app.string.ui_afa3ab04fa') }).height(48).width('100%').borderRadius(12)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
            .onChange((value: string) => { this.keyword = value; }).margin({ top: 4, bottom: 12 })
          Text('单个阶段超时（秒）').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          TextInput({ text: this.timeoutText, placeholder: $r('app.string.ui_a5f4fde1e3') }).height(48).width('100%').borderRadius(12)
            .type(InputType.Number).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).onChange((value: string) => { this.timeoutText = value; })
            .margin({ top: 4, bottom: 12 })
          Text('并发书源数（1-32）').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          TextInput({ text: this.concurrencyText, placeholder: '16' }).height(48).width('100%').borderRadius(12)
            .type(InputType.Number).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).onChange((value: string) => { this.concurrencyText = value; })
            .margin({ top: 4, bottom: 12 })
          this.toggleRow('搜索', this.checkSearch, (value: boolean) => {
            this.checkSearch = value;
            if (!value && !this.checkDiscovery) this.checkDiscovery = true;
          })
          this.toggleRow('发现页（实际请求）', this.checkDiscovery, (value: boolean) => {
            this.checkDiscovery = value;
            if (!value && !this.checkSearch) this.checkSearch = true;
          })
          this.toggleRow('书籍详情', this.checkInfo, (value: boolean) => {
            this.checkInfo = value;
            if (!value) { this.checkCategory = false; this.checkContent = false; }
          })
          this.toggleRow('目录', this.checkCategory, (value: boolean) => {
            this.checkCategory = value;
            if (value) this.checkInfo = true;
            if (!value) this.checkContent = false;
          })
          this.toggleRow('首章正文', this.checkContent, (value: boolean) => {
            this.checkContent = value;
            if (value) { this.checkInfo = true; this.checkCategory = true; }
          })
          Button($r('app.string.ui_b324a672c3')).height(48).width('100%').borderRadius(24)
            .margin({ top: 16, bottom: 4 })
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { this.submit(); })
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }.padding({ left: 16, right: 16, bottom: 20 }).width('100%').constraintSize({ maxWidth: 640, maxHeight: '92%' })
      .backgroundColor(ThemeColors.background(this.isDark)).borderRadius({ topLeft: 20, topRight: 20 })
  }

  @Builder
  toggleRow(label: string, value: boolean, onChange: (value: boolean) => void) {
    Row() {
      Text(label).fontSize(15).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).onChange(onChange)
    }.height(48).padding({ left: 12, right: 8 }).width('100%').margin({ bottom: 4 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
  }
}
