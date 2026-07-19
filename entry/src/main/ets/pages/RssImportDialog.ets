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
import { ThemeColors } from '../theme/ThemeColors';

interface DecodeStreamOptions {
  stream: boolean;
}

@CustomDialog
export struct RssImportDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
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
    if (s === 'new') return ThemeColors.success(this.isDark);
    if (s === 'existing') return ThemeColors.secondaryText(this.isDark);
    return ThemeColors.warning(this.isDark);
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
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(Color.Transparent)
          .width(44).height(44).accessibilityText($r('app.string.ui_3a619b2b8d'))
          .onClick((): void => { this.controller.close(); })
      }.padding({ left: 16, right: 8, top: 16, bottom: 8 }).width('100%')

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 20, bottom: 20 })
        if (this.statusText) {
          Text(this.statusText).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
      } else if (this.showPasteInput) {
        Column() {
          Text($r('app.string.ui_5e71071b34')).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onSurface(this.isDark)).margin({ bottom: 8 })
          TextArea({ text: this.pasteJson, placeholder: $r('app.string.ui_61e567dad0') })
            .height(200).width('100%').borderRadius(8).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .padding(12).fontSize(13)
            .onChange((val: string): void => { this.pasteJson = val; })
          Row() {
            Button($r('app.string.common_cancel')).fontSize(14).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).height(44)
              .borderRadius(8).layoutWeight(1).margin({ right: 8 })
              .onClick((): void => { this.showPasteInput = false; })
            Button($r('app.string.ui_af57b02c34')).fontSize(14).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).height(44)
              .borderRadius(8).layoutWeight(1)
              .onClick((): void => { this.doPasteImport(); })
          }.width('100%').margin({ top: 12 })
        }.padding(16).width('100%')
      } else if (this.items.length > 0) {
        Row() {
          Text($r('app.string.common_select_all')).fontSize(14).fontColor(ThemeColors.primary(this.isDark)).height(44).textAlign(TextAlign.Center)
            .onClick(this.onFullSelect).margin({ right: 12 })
          Text($r('app.string.common_select_none')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).height(44).textAlign(TextAlign.Center)
            .onClick(this.onUnselectAll)
        }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')

        List() {
          ForEach(this.items, (item: RSSImportPreview, idx: number) => {
            ListItem() {
              Row() {
                Checkbox({ name: 'rss_imp_' + idx, group: 'rss_imprt' })
                  .select(item.checked).selectedColor(ThemeColors.primary(this.isDark))
                  .margin({ right: 8 })
                  .onChange((v: boolean): void => {
                    item.checked = v;
                    this.items = [...this.items];
                  })
                Text(item.source.sourceName).fontSize(13).fontColor(ThemeColors.onSurface(this.isDark))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.statusLabel(item.status)).fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark))
                  .backgroundColor(this.statusColor(item.status))
                  .borderRadius(8).padding({ left: 6, right: 6, top: 1, bottom: 1 })
              }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
            }.border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
          })
        }.layoutWeight(1).width('100%')

        Column() {
          Row() {
            Text($r('app.string.ui_bd736410f9')).fontSize(13).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
            TextInput({ placeholder: $r('app.string.ui_53e32830a5'), text: this.customGroup }).height(40)
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8).padding({ left: 12 })
              .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
              .fontSize(13).layoutWeight(1)
              .onChange((v: string): void => { this.customGroup = v; })
          }.width('100%').margin({ bottom: 8 })
        }.padding({ left: 16, right: 16, top: 8 }).width('100%')

        Row() {
          Text('已选 ' + this.selectedCount() + '/' + this.items.length)
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
          Button($r('app.string.ui_17a2c45c82')).fontSize(14).height(44).padding({ left: 24, right: 24 })
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(22)
            .onClick((): void => { this.doImport(); })
        }.padding({ left: 16, right: 16, top: 8, bottom: 16 }).width('100%')
      } else {
        Column() {
          Button($r('app.string.ui_95462abb0d')).fontSize(15).height(48).width('100%')
            .backgroundColor(ThemeColors.success(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .margin({ bottom: 10 }).onClick((): void => { this.doFileImport(); })
          Button($r('app.string.ui_5e71071b34')).fontSize(15).height(48).width('100%')
            .backgroundColor(ThemeColors.warning(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .margin({ bottom: 10 }).onClick((): void => { this.showPasteInput = true; })
          Button($r('app.string.ui_a27b2f6612')).fontSize(15).height(48).width('100%')
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
            .onClick((): void => { this.doUrlImport(); })
        }.padding(16).width('100%')
      }
    }.width('100%').constraintSize({ maxWidth: 640, maxHeight: '92%' })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius({ topLeft: 16, topRight: 16 })
  }
}
