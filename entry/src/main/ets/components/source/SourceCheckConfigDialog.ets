import { CheckConfig } from '../../service/SourceChecker';
import { ThemeColors } from '../../theme/ThemeColors';
import { UiUtil } from '../../util/UiUtil';

@CustomDialog
export struct SourceCheckConfigDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State keyword: string = '我';
  @State timeoutText: string = '30000';
  @State checkSearch: boolean = true;
  @State checkDiscovery: boolean = false;
  @State checkInfo: boolean = true;
  @State checkCategory: boolean = true;
  @State checkContent: boolean = true;
  onStart?: (config: CheckConfig) => void;

  private submit(): void {
    const timeout = Number(this.timeoutText);
    if (!this.keyword.trim() || !Number.isFinite(timeout) || timeout < 1000) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入关键词，超时至少为 1000 ms', duration: 1800 });
      return;
    }
    if (!this.checkSearch && !this.checkDiscovery && !this.checkInfo && !this.checkCategory && !this.checkContent) {
      UiUtil.showToast(this.getUIContext(), { message: '请至少选择一个检查阶段', duration: 1500 });
      return;
    }
    if (this.onStart) this.onStart({
      keyword: this.keyword.trim(), timeout: timeout,
      checkSearch: this.checkSearch, checkDiscovery: this.checkDiscovery,
      checkInfo: this.checkInfo, checkCategory: this.checkCategory, checkContent: this.checkContent
    });
    this.controller.close();
  }

  build() {
    Column() {
      Row() {
        Text('校验配置').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button('关闭').height(40).backgroundColor('transparent').fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { this.controller.close(); })
      }.height(56).width('100%')
      Text('搜索关键词').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
      TextInput({ text: this.keyword, placeholder: '输入常见关键词' }).height(48).width('100%').borderRadius(12)
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
        .onChange((value: string) => { this.keyword = value; }).margin({ top: 4, bottom: 12 })
      Text('单阶段超时（毫秒）').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
      TextInput({ text: this.timeoutText, placeholder: '30000' }).height(48).width('100%').borderRadius(12)
        .type(InputType.Number).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .fontColor(ThemeColors.onSurface(this.isDark)).onChange((value: string) => { this.timeoutText = value; })
        .margin({ top: 4, bottom: 12 })
      this.toggleRow('搜索', this.checkSearch, (value: boolean) => { this.checkSearch = value; })
      this.toggleRow('发现配置', this.checkDiscovery, (value: boolean) => { this.checkDiscovery = value; })
      this.toggleRow('书籍详情', this.checkInfo, (value: boolean) => { this.checkInfo = value; })
      this.toggleRow('目录', this.checkCategory, (value: boolean) => { this.checkCategory = value; })
      this.toggleRow('首章正文', this.checkContent, (value: boolean) => { this.checkContent = value; })
      Button('开始校验').height(48).width('100%').borderRadius(24).margin({ top: 16 })
        .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
        .onClick(() => { this.submit(); })
    }.padding({ left: 16, right: 16, bottom: 20 }).width('100%')
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
