import { Book } from '../model/Book';
import { BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct BookshelfExportDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
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
        Text($r('app.string.ui_8ce30b48a4')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(Color.Transparent)
          .width(40).height(40)
          .accessibilityText($r('app.string.common_close')).onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      if (this.isRunning) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 20, bottom: 20 })
      } else {
        TextArea({ text: this.jsonText, placeholder: $r('app.string.ui_7d1a7c3218') })
          .width('100%').height(240).fontSize(12).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
          .padding(12).margin({ left: 16, right: 16 })
          .onChange((value: string): void => { this.jsonText = value; })
      }

      Row() {
        Button($r('app.string.ui_2e19057052')).fontSize(14).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.secondaryText(this.isDark)).height(40)
          .borderRadius(8).layoutWeight(1).margin({ right: 8 })
          .enabled(!this.isRunning)
          .onClick((): void => { this.generate(); })
        Button($r('app.string.ui_184adfdabf')).fontSize(14).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.saveFile(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').constraintSize({ maxWidth: 640 })
    .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 })
  }
}
