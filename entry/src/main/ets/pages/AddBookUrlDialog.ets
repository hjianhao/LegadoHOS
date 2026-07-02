import { BookshelfTransferResult, BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';

@CustomDialog
export struct AddBookUrlDialog {
  controller: CustomDialogController;
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
        Text('添加 URL').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('✕').fontSize(16).fontColor('#888').backgroundColor(Color.Transparent)
          .width(36).height(36)
          .onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      TextArea({ text: this.inputText, placeholder: '每行一个书籍详情页 URL' })
        .width('100%').height(180).fontSize(13).backgroundColor('#F5F5F5').borderRadius(8)
        .padding(12).margin({ left: 16, right: 16 })
        .onChange((value: string): void => { this.inputText = value; })

      if (this.isRunning) {
        LoadingProgress().color('#0078D7').margin({ top: 12 })
      }
      if (this.statusText) {
        Text(this.statusText).fontSize(12).fontColor('#666').width('100%')
          .padding({ left: 16, right: 16, top: 10 })
      }

      Row() {
        Button('取消').fontSize(14).backgroundColor('#EEE').fontColor('#666').height(40)
          .borderRadius(8).layoutWeight(1).margin({ right: 8 })
          .onClick((): void => { this.controller.close(); })
        Button('添加').fontSize(14).backgroundColor('#0078D7').fontColor('#FFF').height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.doAdd(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').backgroundColor('#FFF').borderRadius({ topLeft: 16, topRight: 16 })
  }
}
