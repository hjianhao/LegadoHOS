import { BookSourceTable } from '../data/database/BookSourceTable';
import { AppDatabase } from '../data/database/AppDatabase';
import { NetUtil } from '../util/NetUtil';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';

@CustomDialog
export struct ImportSourceDialog {
  controller: CustomDialogController;

  @State importUrl: string = '';
  @State importJson: string = '';
  @State isLoading: boolean = false;

  onImportSuccess?: () => void;

  /** 本地文件选择导入 */
  private async doFileImport(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select();
      if (!uris || uris.length === 0) return;
      this.isLoading = true;
      const uri: string = uris[0];
      console.info('[Import] selected URI:', uri);
      // open file and read as text
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const size: number = stat.size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        const len: number = fileIo.readSync(file.fd, buf);
        // 使用 TextDecoder（UTF-8 正确解码中文）
        const td: util.TextDecoder = util.TextDecoder.create('utf-8');
        const json: string = td.decodeWithStream(new Uint8Array(buf, 0, len), { stream: false });
        await this.importJson_(json);
      } finally { fileIo.closeSync(file); }
    } catch (e) {
      const msg: string = (e as Error).message || String(e);
      console.error('[Import] error:', msg);
      promptAction.showToast({ message: '读取失败: ' + msg.substring(0, 40), duration: 2000 });
      this.isLoading = false;
    }
  }

  private arrayBufferToString(buf: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buf);
    // 跳过 UTF-8 BOM
    let start = 0;
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      start = 3;
    }
    let result: string = '';
    for (let i = start; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }

  /** 离线导入：粘贴 JSON 内容 */
  private async doOfflineImport(): Promise<void> {
    if (!this.importJson.trim()) {
      promptAction.showToast({ message: '请粘贴JSON内容', duration: 1500 });
      return;
    }
    this.isLoading = true;
    await this.importJson_(this.importJson);
  }

  private async importJson_(json: string): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const count = await dao.importSources(json);
      promptAction.showToast({ message: '成功导入 ' + count + ' 个书源', duration: 2000 });
      this.isLoading = false;
      this.controller.close();
      if (this.onImportSuccess) this.onImportSuccess();
    } catch (e) {
      const msg: string = (e as Error).message || String(e);
      promptAction.showToast({ message: 'JSON格式错误: ' + msg.substring(0, 30), duration: 2500 });
      this.isLoading = false;
    }
  }

  private async doOnlineImport(): Promise<void> {
    if (!this.importUrl.trim()) {
      promptAction.showToast({ message: '请输入链接', duration: 1500 });
      return;
    }
    this.isLoading = true;
    try {
      const json = await NetUtil.httpGet(this.importUrl);
      await this.importJson_(json);
    } catch (_e) {
      promptAction.showToast({ message: '导入失败', duration: 2000 });
      this.isLoading = false;
    }
  }

  build() {
    Column() {
      Text('导入书源').fontSize(18).fontWeight(FontWeight.Bold).padding({ top: 20, bottom: 12 })

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 20, bottom: 20 })
      } else {
        TextInput({ placeholder: '在线导入: 粘贴 JSON 链接...', text: this.importUrl })
          .height(44).backgroundColor('#F0F0F0')
          .borderRadius(8).padding({ left: 16 }).width('100%').margin({ bottom: 8 })
          .onChange((v: string): void => { this.importUrl = v })

        Button('📁 选择本地文件').fontSize(13).height(40).width('100%')
          .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(8).margin({ bottom: 8 })
          .onClick(() => { this.doFileImport() })

        TextInput({ placeholder: '离线导入: 粘贴 JSON 内容...', text: this.importJson })
          .height(80).backgroundColor('#F0F0F0')
          .borderRadius(8).padding({ left: 16 }).width('100%').margin({ bottom: 16 })
          .onChange((v: string): void => { this.importJson = v })

        Row() {
          Button('取消').fontSize(14).height(40).layoutWeight(1).margin({ right: 4 })
            .onClick(() => { this.controller.close() })
          Button('在线导入').fontSize(13).height(40).layoutWeight(1).margin({ left: 4, right: 4 })
            .backgroundColor('#0078D7').fontColor('#FFF').onClick(() => { this.doOnlineImport() })
          Button('粘贴导入').fontSize(13).height(40).layoutWeight(1).margin({ left: 4 })
            .backgroundColor('#FF9800').fontColor('#FFF').onClick(() => { this.doOfflineImport() })
        }.width('100%').padding({ bottom: 20 })
      }
    }
    .padding({ left: 24, right: 24 }).width('100%')
  }
}
