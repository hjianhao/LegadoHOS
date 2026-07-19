import { BookshelfTransferResult, BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct AddBookUrlDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State inputText: string = '';
  @State isRunning: boolean = false;
  @State statusText: string = '';
  groupId: number = 0;
  onSuccess?: () => void;

  private async doAdd(): Promise<void> {
    if (!this.inputText.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书籍 URL', duration: 1500 });
      return;
    }
    this.isRunning = true;
    this.statusText = '准备添加...';
    try {
      const result = await BookshelfTransferService.addBooksByUrl(this.inputText, this.groupId,
        (done: number, total: number, message: string): void => {
          this.statusText = message + ' (' + done + '/' + total + ')';
        });
      this.showResult(result);
      if (result.success > 0 && this.onSuccess) this.onSuccess();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '添加失败: ' + ((e as Error).message || ''), duration: 2000 });
    }
    this.isRunning = false;
  }

  private showResult(result: BookshelfTransferResult): void {
    const message = '成功 ' + result.success + ' 本，跳过 ' + result.skipped + ' 本，失败 ' + result.failed + ' 本';
    this.statusText = message + (result.messages.length > 0 ? '\n' + result.messages.slice(0, 3).join('\n') : '');
    UiUtil.showToast(this.getUIContext(), { message: message, duration: 2000 });
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_0eb27905fd')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(Color.Transparent)
          .width(40).height(40)
          .accessibilityText($r('app.string.common_close')).onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      TextArea({ text: this.inputText, placeholder: $r('app.string.ui_9bab3618b6') })
        .width('100%').height(180).fontSize(13).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
        .padding(12).margin({ left: 16, right: 16 })
        .onChange((value: string): void => { this.inputText = value; })

      if (this.isRunning) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 12 })
      }
      if (this.statusText) {
        Text(this.statusText).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          .padding({ left: 16, right: 16, top: 10 })
      }

      Row() {
        Button($r('app.string.common_cancel')).fontSize(14).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.secondaryText(this.isDark)).height(40)
          .borderRadius(8).layoutWeight(1).margin({ right: 8 })
          .onClick((): void => { this.controller.close(); })
        Button($r('app.string.common_add')).fontSize(14).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.doAdd(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').constraintSize({ maxWidth: 640 })
    .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 })
  }
}
