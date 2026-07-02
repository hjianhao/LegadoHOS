/**
 * 导入 RSS 源对话框
 */
import { RSSSourceTable } from '../data/database/RSSSourceTable';
import { RSSImportPreview } from "../model/RSSImport";
import { AppDatabase } from '../data/database/AppDatabase';
import { NetUtil } from '../util/NetUtil';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import { UiUtil } from '../util/UiUtil';

interface DecodeStreamOptions {
  stream: boolean;
}

@CustomDialog
export struct RssImportDialog {
  controller: CustomDialogController;
  @State items: RSSImportPreview[] = [];
  @State isLoading: boolean = false;
  @State statusText: string = '';
  @State keepName: boolean = true;
  @State keepGroup: boolean = true;
  @State customGroup: string = '';
  @State showPasteInput: boolean = false;
  @State pasteJson: string = '';

  onImportSuccess?: () => void;

  private async loadPreview(json: string): Promise<void> {
    this.isLoading = true;
    this.statusText = '解析中...';
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new RSSSourceTable(AppDatabase.getInstance().rdbStore);
      this.items = await dao.importSourcesPreview(json);
      this.statusText = this.items.length + ' 条RSS源';
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: 'JSON格式错误', duration: 1500 });
    }
    this.isLoading = false;
  }

  private async doImport(): Promise<void> {
    let selCount = 0;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].checked) {
        selCount++;
      }
    }
    if (selCount === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '未选中任何源', duration: 1500 });
      return;
    }
    this.isLoading = true;
    this.statusText = '导入中...';
    try {
      const dao = new RSSSourceTable(AppDatabase.getInstance().rdbStore);
      const count = await dao.importSelected(this.items, this.keepName, this.keepGroup, this.customGroup);
      UiUtil.showToast(this.getUIContext(), { message: '成功导入 ' + count + ' 个RSS源', duration: 2000 });
      this.controller.close();
      if (this.onImportSuccess) {
        this.onImportSuccess();
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '导入失败', duration: 1500 });
    }
    this.isLoading = false;
  }

  private async doFileImport(): Promise<void> {
    try {
      const uris = await new picker.DocumentViewPicker().select();
      if (!uris || uris.length === 0) {
        return;
      }
      this.statusText = '读取文件...';
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const s = fileIo.statSync(f.fd);
      const b = new ArrayBuffer(s.size);
      fileIo.readSync(f.fd, b);
      fileIo.closeSync(f);
      const td = util.TextDecoder.create('utf-8');
      const decodeOpts: DecodeStreamOptions = { stream: false };
      const json: string = td.decodeToString(new Uint8Array(b));
      await this.loadPreview(json);
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '读取失败', duration: 1500 });
    }
  }

  private async doUrlImport(): Promise<void> {
    this.statusText = '下载中...';
    try {
      const json = await NetUtil.httpGet('');
      await this.loadPreview(json);
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '下载失败', duration: 1500 });
    }
  }

  private async doPasteImport(): Promise<void> {
    if (!this.pasteJson.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请粘贴 JSON 内容', duration: 1500 });
      return;
    }
    this.showPasteInput = false;
    await this.loadPreview(this.pasteJson);
  }

  private selectAll(select: boolean): void {
    for (const i of this.items) {
      i.checked = select;
    }
    this.items = [...this.items];
  }

  private statusColor(s: string): string {
    if (s === 'new') return '#4CAF50';
    if (s === 'existing') return '#AAA';
    return '#FF9800';
  }

  private statusLabel(s: string): string {
    if (s === 'new') return '新增';
    if (s === 'existing') return '已有';
    return '更新';
  }

  private selectedCount(): number {
    let count = 0;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].checked) count++;
    }
    return count;
  }

  // 点击回调类型
  private onFullSelect(): void { this.selectAll(true); }
  private onUnselectAll(): void { this.selectAll(false); }

  build() {
    Column() {
      Row() {
        Text('导入RSS源' + (this.items.length > 0 ? ' (' + this.items.length + '条)' : ''))
          .fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('✕').fontSize(16).fontColor('#888').backgroundColor('transparent')
          .width(36).height(36)
          .onClick((): void => { this.controller.close(); })
      }.padding({ left: 16, right: 8, top: 16, bottom: 8 }).width('100%')

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 20, bottom: 20 })
        if (this.statusText) {
          Text(this.statusText).fontSize(14).fontColor('#888').margin({ top: 8 })
        }
      } else if (this.showPasteInput) {
        Column() {
          Text('粘贴 JSON 内容').fontSize(14).fontWeight(FontWeight.Medium).margin({ bottom: 8 })
          TextArea({ text: this.pasteJson, placeholder: '粘贴 RSS 源的 JSON...' })
            .height(200).width('100%').borderRadius(8).backgroundColor('#F5F5F5')
            .padding(12).fontSize(13)
            .onChange((val: string): void => { this.pasteJson = val; })
          Row() {
            Button('取消').fontSize(14).backgroundColor('#EEE').fontColor('#666').height(40)
              .borderRadius(8).layoutWeight(1).margin({ right: 8 })
              .onClick((): void => { this.showPasteInput = false; })
            Button('解析').fontSize(14).backgroundColor('#0078D7').fontColor('#FFF').height(40)
              .borderRadius(8).layoutWeight(1)
              .onClick((): void => { this.doPasteImport(); })
          }.width('100%').margin({ top: 12 })
        }.padding(16).width('100%')
      } else if (this.items.length > 0) {
        Row() {
          Text('全选').fontSize(12).fontColor('#0078D7')
            .onClick(this.onFullSelect).margin({ right: 12 })
          Text('全不选').fontSize(12).fontColor('#666')
            .onClick(this.onUnselectAll)
        }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')

        List() {
          ForEach(this.items, (item: RSSImportPreview, idx: number) => {
            ListItem() {
              Row() {
                Checkbox({ name: 'rss_imp_' + idx, group: 'rss_imprt' })
                  .select(item.checked).selectedColor('#0078D7')
                  .margin({ right: 8 })
                  .onChange((v: boolean): void => {
                    item.checked = v;
                    this.items = [...this.items];
                  })
                Text(item.source.sourceName).fontSize(13)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.statusLabel(item.status)).fontSize(10).fontColor('#FFF')
                  .backgroundColor(this.statusColor(item.status))
                  .borderRadius(8).padding({ left: 6, right: 6, top: 1, bottom: 1 })
              }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
            }.border({ width: { bottom: 0.5 }, color: '#EEE' })
          })
        }.layoutWeight(1).width('100%')

        Column() {
          Row() {
            Text('自定义分组名').fontSize(13).layoutWeight(1)
            TextInput({ placeholder: '可选', text: this.customGroup }).height(36)
              .backgroundColor('#F0F0F0').borderRadius(8).padding({ left: 12 })
              .fontSize(13).layoutWeight(1)
              .onChange((v: string): void => { this.customGroup = v; })
          }.width('100%').margin({ bottom: 8 })
        }.padding({ left: 16, right: 16, top: 8 }).width('100%')

        Row() {
          Text('已选 ' + this.selectedCount() + '/' + this.items.length)
            .fontSize(14).fontColor('#666').layoutWeight(1)
          Button('导入选中').fontSize(14).height(40).padding({ left: 24, right: 24 })
            .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(20)
            .onClick((): void => { this.doImport(); })
        }.padding({ left: 16, right: 16, top: 8, bottom: 16 }).width('100%')
      } else {
        Column() {
          Button('📁 选择本地文件').fontSize(15).height(44).width('100%')
            .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(8)
            .margin({ bottom: 10 }).onClick((): void => { this.doFileImport(); })
          Button('📋 粘贴 JSON 内容').fontSize(15).height(44).width('100%')
            .backgroundColor('#FF9800').fontColor('#FFF').borderRadius(8)
            .margin({ bottom: 10 }).onClick((): void => { this.showPasteInput = true; })
          Button('🌐 从URL导入').fontSize(15).height(44).width('100%')
            .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(8)
            .onClick((): void => { this.doUrlImport(); })
        }.padding(16).width('100%')
      }
    }.width('100%').backgroundColor('#FFF').borderRadius({ topLeft: 16, topRight: 16 })
  }
}
