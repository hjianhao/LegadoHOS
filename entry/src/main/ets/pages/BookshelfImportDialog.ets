import { BookshelfTransferResult, BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import { UiUtil } from '../util/UiUtil';

@CustomDialog
export struct BookshelfImportDialog {
  controller: CustomDialogController;
  @State inputText: string = '';
  @State isRunning: boolean = false;
  @State statusText: string = '';
  groupId: number = 0;
  onImportSuccess?: () => void;

  private async chooseFile(): Promise<void> {
    try {
      const uris = await new picker.DocumentViewPicker().select();
      if (!uris || uris.length === 0) return;
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(f.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buffer);
      fileIo.closeSync(f);
      const decoder = util.TextDecoder.create('utf-8');
      this.inputText = decoder.decodeToString(new Uint8Array(buffer));
      this.statusText = '已读取文件，准备导入';
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '读取文件失败', duration: 1500 });
    }
  }

  private async doImport(): Promise<void> {
    if (!this.inputText.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请粘贴 JSON 或 URL', duration: 1500 });
      return;
    }
    this.isRunning = true;
    this.statusText = '准备导入...';
    try {
      const result = await BookshelfTransferService.importBookshelfText(this.inputText, this.groupId,
        (done: number, total: number, message: string): void => {
          this.statusText = message + ' (' + done + '/' + total + ')';
        });
      this.showResult(result);
      if (result.success > 0 && this.onImportSuccess) this.onImportSuccess();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '导入失败: ' + ((e as Error).message || ''), duration: 2000 });
    }
    this.isRunning = false;
  }

  private showResult(result: BookshelfTransferResult): void {
    const message = '成功 ' + result.success + ' 本，跳过 ' + result.skipped + ' 本，失败 ' + result.failed + ' 本';
    this.statusText = message + (result.messages.length > 0 ? '\n' + result.messages.slice(0, 4).join('\n') : '');
    UiUtil.showToast(this.getUIContext(), { message: message, duration: 2000 });
  }

  build() {
    Column() {
      Row() {
        Text('导入书架').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('✕').fontSize(16).fontColor('#888').backgroundColor(Color.Transparent)
          .width(36).height(36)
          .onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      Row() {
        Button('选择文件').fontSize(13).height(34).fontColor('#0078D7').backgroundColor('#EAF4FF')
          .borderRadius(8).padding({ left: 12, right: 12 })
          .enabled(!this.isRunning)
          .onClick((): void => { this.chooseFile(); })
        Text('支持 Android 书架导出的 JSON，或填写远程 JSON 地址')
          .fontSize(12).fontColor('#888').margin({ left: 10 }).layoutWeight(1)
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      TextArea({ text: this.inputText, placeholder: '[{\"name\":\"书名\",\"author\":\"作者\",\"intro\":\"简介\"}] 或 https://...' })
        .width('100%').height(190).fontSize(12).backgroundColor('#F5F5F5').borderRadius(8)
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
        Button('导入').fontSize(14).backgroundColor('#0078D7').fontColor('#FFF').height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.doImport(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').backgroundColor('#FFF').borderRadius({ topLeft: 16, topRight: 16 })
  }
}
