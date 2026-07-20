import { BookshelfTransferResult, BookshelfTransferService } from '../service/BookshelfTransferService';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct BookshelfImportDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State inputText: string = '';
  @State isRunning: boolean = false;
  @State statusText: string = '';
  groupId: number = 0;
  onImportSuccess?: () => void;

  private async chooseFile(): Promise<void> {
    // 部分设备（如缺少 sysPicker/filePicker 组件的平板 ROM）没有系统文件选择器，
    // select() 会抛错或返回空，统一降级为提示改用粘贴 JSON。
    let uris: string[] = [];
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.json'];
      const context = this.getUIContext().getHostContext()!;
      uris = await new picker.DocumentViewPicker(context).select(documentSelectOptions);
    } catch (e) {
      console.error('[BookshelfImport] file picker unavailable: ' + JSON.stringify(e));
    }
    if (!uris || uris.length === 0) {
      console.warn('[BookshelfImport] file picker returned empty — system file picker unavailable');
      UiUtil.showToast(this.getUIContext(), {
        message: '此设备不支持文件选择器，请在下方粘贴 JSON', duration: 3000
      });
      return;
    }
    try {
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
        Text($r('app.string.ui_356fb1b027')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(Color.Transparent)
          .width(40).height(40)
          .accessibilityText($r('app.string.common_close')).onClick((): void => { this.controller.close(); })
      }.width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      Row() {
        Button($r('app.string.ui_21a6f5a8d9')).fontSize(13).height(40).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(ThemeColors.primaryContainer(this.isDark))
          .borderRadius(8).padding({ left: 12, right: 12 })
          .enabled(!this.isRunning)
          .onClick((): void => { this.chooseFile(); })
        Text($r('app.string.ui_346e030c2f'))
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 10 }).layoutWeight(1)
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      TextArea({ text: this.inputText, placeholder: $r('app.string.ui_3dc9907c14') })
        .width('100%').height(190).fontSize(12).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
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
        Button($r('app.string.common_import')).fontSize(14).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).height(40)
          .borderRadius(8).layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick((): void => { this.doImport(); })
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%').constraintSize({ maxWidth: 640 })
    .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 })
  }
}
