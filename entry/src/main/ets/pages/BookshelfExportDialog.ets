import { Book } from '../model/Book';
import { BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import { UiUtil } from '../util/UiUtil';

@CustomDialog
export struct BookshelfExportDialog {
  controller: CustomDialogController;
  @State jsonText: string = '';
  @State isRunning: boolean = false;
  books: Book[] = [];

  aboutToAppear(): void {
    this.generate();
  }

  private async generate(): Promise<void> {
    this.isRunning = true;
    try {
      this.jsonText = await BookshelfTransferService.exportBookshelf(this.books.length > 0 ? this.books : undefined);
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '生成导出内容失败', duration: 1500 });
    }
    this.isRunning = false;
  }

  private async saveFile(): Promise<void> {
    if (!this.jsonText) await this.generate();
    try {
      const uris = await new picker.DocumentViewPicker().save({ newFileNames: ['bookshelf.json'] });
      if (!uris || uris.length === 0) return;
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(f.fd, this.jsonText);
      fileIo.closeSync(f);
      UiUtil.showToast(this.getUIContext(), { message: '书架已导出', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '保存失败', duration: 1500 });
    }
  }

  build() {
    Column() {
      Row() {
        Text('导出书架').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('✕').fontSize(16).fontColor('#888').backgroundColor(Color.Transparent)
          .width(36).height(36)
          .onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      if (this.isRunning) {
        LoadingProgress().color('#0078D7').margin({ top: 20, bottom: 20 })
      } else {
        TextArea({ text: this.jsonText, placeholder: '导出内容' })
          .width('100%').height(240).fontSize(12).backgroundColor('#F5F5F5').borderRadius(8)
          .padding(12).margin({ left: 16, right: 16 })
          .onChange((value: string): void => { this.jsonText = value; })
      }

      Row() {
        Button('重新生成').fontSize(14).backgroundColor('#EEE').fontColor('#666').height(40)
          .borderRadius(8).layoutWeight(1).margin({ right: 8 })
          .enabled(!this.isRunning)
          .onClick((): void => { this.generate(); })
        Button('保存文件').fontSize(14).backgroundColor('#0078D7').fontColor('#FFF').height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.saveFile(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').backgroundColor('#FFF').borderRadius({ topLeft: 16, topRight: 16 })
  }
}
