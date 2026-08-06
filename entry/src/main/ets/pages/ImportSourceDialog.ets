/**
 * 导入书源对话框 — 复刻 Android ImportBookSourceDialog 预览式导入
 */
import { BookSourceTable, PreviewItem } from '../data/database/BookSourceTable';
import { AppDatabase } from '../data/database/AppDatabase';
import { NetUtil } from '../util/NetUtil';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import pasteboard from '@ohos.pasteboard';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { BookSourceChangeNotifier } from '../service/BookSourceChangeNotifier';

const MAX_IMPORT_BYTES: number = 10 * 1024 * 1024;
const MAX_IMPORT_DEPTH: number = 3;
PersistentStorage.persistProp('source_import_keep_name', true);
PersistentStorage.persistProp('source_import_keep_group', true);
PersistentStorage.persistProp('source_import_keep_enabled', true);
PersistentStorage.persistProp('source_import_group_mode', 0);

@CustomDialog
export struct ImportSourceDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State items: PreviewItem[] = [];
  @State isLoading: boolean = false;
  @State statusText: string = '';
  @StorageLink('source_import_keep_name') keepName: boolean = true;
  @StorageLink('source_import_keep_group') keepGroup: boolean = true;
  @StorageLink('source_import_keep_enabled') keepEnabled: boolean = true;
  @State customGroup: string = '';
  @StorageLink('source_import_group_mode') groupMode: number = 0; // 0=append, 1=overwrite
  @State importMode: string = 'menu'; // 'menu' | 'url' | 'json'
  @State importUrl: string = '';
  @State jsonText: string = '';

  onImportSuccess?: () => Promise<void>;

  /** 通过「打开方式/分享」进入时预置的书源 JSON，非空则跳过菜单直接预览 */
  initialJson?: string;

  aboutToAppear(): void {
    if (this.initialJson && this.initialJson.trim().length > 0) {
      this.loadPreview(this.initialJson);
    }
  }

  private resetMode(): void {
    this.importMode = 'menu';
    this.importUrl = '';
    this.jsonText = '';
  }

  private async loadPreview(json: string): Promise<boolean> {
    this.isLoading = true; this.statusText = '解析中...';
    // DocumentViewPicker / 剪贴板导入的 UTF-8 文本可能保留 BOM，JSON.parse 不接受它。
    const normalizedJson = json.replace(/^\uFEFF/, '').trim();
    try {
      this.ensurePayloadSize_(normalizedJson);
      const normalizedSources = await this.resolvePayload_(normalizedJson, 0);
      if (normalizedSources.length === 0) throw new Error('没有找到可导入的书源');
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.items = await dao.importSourcesPreview(JSON.stringify(normalizedSources));
      this.statusText = `${this.items.length} 条书源`;
      console.info('[ImportSource] preview done: ' + this.items.length + ' items');
      this.isLoading = false;
      return true;
    } catch (e) {
      console.error('[ImportSource] loadPreview error: ' + e);
      UiUtil.showToast(this.getUIContext(), {message:'书源解析失败: '+String(e).substring(0,80),duration:2500});
      this.statusText = '书源解析失败';
      this.isLoading = false;
      return false;
    }
  }

  private async doImport(): Promise<void> {
    const sel = this.items.filter(i => i.checked);
    if (sel.length === 0) { UiUtil.showToast(this.getUIContext(), {message:'未选中任何书源',duration:1500}); return; }
    this.isLoading = true; this.statusText = '导入中...';
    try {
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const count = await dao.importSelected(
        sel, this.keepName, this.keepGroup, this.keepEnabled, this.customGroup.trim(), this.groupMode);
      if (count > 0) BookSourceChangeNotifier.notify();
      UiUtil.showToast(this.getUIContext(), {message:'成功导入 '+count+' 个书源',duration:2000});
      // 等宿主页完成数据库重读和列表状态更新后再关闭弹窗，避免关闭动画销毁
      // 自定义弹窗时打断异步刷新，导致新导入的书源要重新进入页面才显示。
      if (this.onImportSuccess) await this.onImportSuccess();
      this.controller.close();
    } catch (e) { console.error('[ImportSource] doImport error: ' + e); UiUtil.showToast(this.getUIContext(), {message:'导入失败',duration:1500}); }
    this.isLoading = false;
  }

  private async doFileImport(): Promise<void> {
    // 部分设备（如缺少 sysPicker/filePicker 组件的平板 ROM）没有系统文件选择器，
    // select() 会抛错(errorCode=1011)或返回空，统一降级为提示改用其它导入方式。
    let uris: string[] = [];
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.json'];
      const context = this.getUIContext().getHostContext()!;
      uris = await new picker.DocumentViewPicker(context).select(documentSelectOptions);
    } catch (e) {
      console.error('[ImportSource] file picker unavailable: ' + JSON.stringify(e));
    }
    if (!uris || uris.length === 0) {
      console.warn('[ImportSource] file picker returned empty — system file picker unavailable on this device');
      UiUtil.showToast(this.getUIContext(), {
        message: '此设备不支持文件选择器，请使用「从URL导入」或「粘贴 JSON」',
        duration: 3000
      });
      this.statusText = '';
      return;
    }
    this.statusText = '读取文件...';
    let openedFile: fileIo.File | null = null;
    try {
      openedFile = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const s = fileIo.statSync(openedFile.fd);
      if (s.size > MAX_IMPORT_BYTES) throw new Error('文件不能超过 10 MB');
      const b = new ArrayBuffer(s.size);
      fileIo.readSync(openedFile.fd, b);
      const td = util.TextDecoder.create('utf-8');
      const json = td.decodeToString(new Uint8Array(b), {stream:false});
      console.info('[ImportSource] file loaded, len=' + json.length);
      await this.loadPreview(json);
    } catch (e) {
      console.error('[ImportSource] fileImport error: ' + e);
      UiUtil.showToast(this.getUIContext(), {message:'读取失败：' + String(e).substring(0, 60),duration:1800});
    } finally {
      if (openedFile) {
        try { fileIo.closeSync(openedFile); } catch (_closeError) { /* ignore */ }
      }
    }
  }

  private async doUrlImport(url: string): Promise<void> {
    if (!url) { UiUtil.showToast(this.getUIContext(), {message:'请输入URL',duration:1500}); return; }
    if (this.isLoading) return;
    this.isLoading = true;
    this.statusText = '下载中...';
    try {
      const json = await this.fetchImportUrl_(url);
      if (await this.loadPreview(json)) this.resetMode();
    } catch (e) {
      const msg = (e as Error).message || String(e);
      console.error('[ImportSource] URL import failed:', url, msg);
      if (msg.includes('timeout') || msg.includes('Timeout')) {
        UiUtil.showToast(this.getUIContext(), {message:'连接超时，请检查网络或重试',duration:2000});
      } else {
        UiUtil.showToast(this.getUIContext(), {message:'下载失败: '+msg.substring(0,50),duration:2000});
      }
    } finally {
      this.isLoading = false;
    }
  }

  private async doJsonImport(json: string): Promise<void> {
    if (!json || json.trim().length === 0) { UiUtil.showToast(this.getUIContext(), {message:'请粘贴 JSON 内容',duration:1500}); return; }
    if (await this.loadPreview(json)) this.resetMode();
  }

  /** 通过 PasteButton 的临时授权直接读取剪贴板，绕过长文本输入事件的长度限制。 */
  private async doClipboardJsonImport(): Promise<void> {
    if (this.isLoading) return;
    const clipboard = pasteboard.getSystemPasteboard();
    let data: pasteboard.PasteData | null = null;
    let pasteStarted = false;
    try {
      data = await clipboard.getData();
      // 跨设备剪贴板需要在读取数据记录前保持通道；否则大文本可能只拿到不完整的同步结果。
      data.pasteStart();
      pasteStarted = true;
      const candidates: string[] = [];
      const recordCount = data.getRecordCount();
      if (recordCount > 0) {
        try {
          const record = data.getRecord(0);
          if (record.plainText) candidates.push(record.plainText);
          const plainText = record.toPlainText();
          if (plainText) candidates.push(plainText);
        } catch (recordError) {
          console.warn('[ImportSource] unable to read clipboard record: ' + recordError);
        }
      }
      const primaryText = data.getPrimaryText();
      if (primaryText) candidates.push(primaryText);
      console.info('[ImportSource] clipboard mime=' + data.getPrimaryMimeType()
        + ', records=' + recordCount + ', lengths=' + candidates.map((value: string) => value.length).join(','));
      let hasText = false;
      for (let i = 0; i < candidates.length; i++) {
        if (candidates[i].trim().length > 0) {
          hasText = true;
          break;
        }
      }
      if (!hasText) {
        UiUtil.showToast(this.getUIContext(), { message: '剪贴板没有 JSON 文本', duration: 1500 });
        return;
      }
      // 优先使用能通过 JSON 语法校验的候选，避免 HTML/富文本转换破坏 JSON 转义。
      let text = '';
      for (let i = 0; i < candidates.length; i++) {
        const candidate = this.normalizeClipboardJson_(candidates[i]);
        if (this.isJsonSyntaxValid_(candidate)) {
          text = candidate;
          break;
        }
      }
      if (!text) text = this.normalizeClipboardJson_(candidates[0]);
      this.ensurePayloadSize_(text);
      if (await this.loadPreview(text)) this.resetMode();
    } catch (e) {
      console.error('[ImportSource] clipboard import error: ' + e);
      UiUtil.showToast(this.getUIContext(), { message: '读取剪贴板失败：' + String(e).substring(0, 50), duration: 2000 });
    } finally {
      if (pasteStarted && data) {
        try {
          data.pasteComplete();
        } catch (completeError) {
          console.warn('[ImportSource] clipboard complete failed: ' + completeError);
        }
      }
    }
  }

  /** 去除 BOM、Markdown JSON 代码围栏及复制时附带的首尾说明。 */
  private normalizeClipboardJson_(value: string): string {
    let text = value.replace(/^\uFEFF/, '').trim();
    if (text.startsWith('```')) {
      const firstLineEnd = text.indexOf('\n');
      const lastFence = text.lastIndexOf('```');
      if (firstLineEnd >= 0 && lastFence > firstLineEnd) {
        text = text.substring(firstLineEnd + 1, lastFence).trim();
      }
    }
    if (this.isJsonSyntaxValid_(text)) return text;
    let first = -1;
    const objectStart = text.indexOf('{');
    const arrayStart = text.indexOf('[');
    if (objectStart >= 0) first = objectStart;
    if (arrayStart >= 0 && (first < 0 || arrayStart < first)) first = arrayStart;
    const objectEnd = text.lastIndexOf('}');
    const arrayEnd = text.lastIndexOf(']');
    const last = Math.max(objectEnd, arrayEnd);
    if (first > 0 || (last >= 0 && last < text.length - 1)) {
      const candidate = text.substring(Math.max(first, 0), last + 1).trim();
      if (this.isJsonSyntaxValid_(candidate)) return candidate;
    }
    return text;
  }

  private isJsonSyntaxValid_(text: string): boolean {
    if (!text || text.trim().length === 0) return false;
    try {
      JSON.parse(text);
      return true;
    } catch (_error) {
      return false;
    }
  }

  private ensurePayloadSize_(text: string): void {
    if (text.length > MAX_IMPORT_BYTES) throw new Error('导入内容不能超过 10 MB');
  }

  private async fetchImportUrl_(rawUrl: string): Promise<string> {
    const trimmed = rawUrl.trim();
    const withoutUa = trimmed.endsWith('#requestWithoutUA');
    const url = withoutUa ? trimmed.substring(0, trimmed.length - '#requestWithoutUA'.length) : trimmed;
    if (!/^https?:\/\//i.test(url)) throw new Error('仅支持 HTTP 或 HTTPS URL');
    const headers: Record<string, string> | undefined = withoutUa ? { 'User-Agent': '' } : undefined;
    const text = await NetUtil.httpGet(url, headers);
    this.ensurePayloadSize_(text);
    return text;
  }

  private async resolvePayload_(text: string, depth: number): Promise<Record<string, Object>[]> {
    if (depth > MAX_IMPORT_DEPTH) throw new Error('书源链接嵌套层级过深');
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      const message = (e as Error).message || String(e);
      const positionMatch = message.match(/position\s+(\d+)/i);
      const position = positionMatch ? positionMatch[1] : 'unknown';
      console.error('[ImportSource] invalid JSON len=' + text.length + ', position=' + position);
      throw new Error('JSON格式错误: ' + message.substring(0, 80));
    }
    if (Array.isArray(parsed)) {
      return parsed as Record<string, Object>[];
    }
    const object = parsed as Record<string, Object>;
    const sourceUrls = object['sourceUrls'];
    if (!Array.isArray(sourceUrls)) return [object];
    if (sourceUrls.length > 100) throw new Error('单次最多解析 100 个远程书源链接');
    const result: Record<string, Object>[] = [];
    for (let i = 0; i < sourceUrls.length; i++) {
      const url = String(sourceUrls[i] || '').trim();
      if (!url) continue;
      const remote = await this.fetchImportUrl_(url);
      const sources = await this.resolvePayload_(remote, depth + 1);
      result.push(...sources);
      if (result.length > 5000) throw new Error('单次最多导入 5000 个书源');
    }
    return result;
  }

  private selectAll(select: boolean): void { for (const i of this.items) i.checked = select; this.items = [...this.items]; }
  private selectNew(): void { for (const i of this.items) i.checked = i.status === 'new'; this.items = [...this.items]; }
  private selectUpdate(): void { for (const i of this.items) i.checked = i.status === 'update'; this.items = [...this.items]; }

  private statusColor(s: string): string { return s==='new'?ThemeColors.success(this.isDark):s==='update'?ThemeColors.warning(this.isDark):ThemeColors.secondaryText(this.isDark); }
  private statusLabel(s: string): string { return s==='new'?'新增':s==='update'?'更新':'已有'; }

  build() {
    Column() {
      // 标题
      Row() {
        Text(this.importMode === 'url' ? '从URL导入' :
          this.importMode === 'json' ? '粘贴 JSON 内容' :
          '导入书源' + (this.items.length>0?` (${this.items.length}条)`:'')
        ).fontSize(18).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Row() {
          if (this.importMode !== 'menu' && this.items.length === 0) {
            Button($r('app.string.ui_4968e7f610')).fontSize(14).fontColor(ThemeColors.primary(this.isDark)).backgroundColor(ThemeColors.transparent()).margin({right:8}).onClick(()=>{this.resetMode()})
          }
          Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).backgroundColor(ThemeColors.transparent()).width(40).height(40).accessibilityText($r('app.string.common_close')).onClick(()=>{this.controller.close()})
        }
      }.padding({left:16,right:8,top:16,bottom:8}).width('100%')

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({top:20,bottom:20})
        if (this.statusText) Text(this.statusText).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top:8})
      } else if (this.items.length > 0) {
        // 快捷操作
        Row() {
          Text($r('app.string.common_select_all')).fontSize(12).fontColor(ThemeColors.primary(this.isDark)).onClick(()=>{this.selectAll(true)}).margin({right:12})
          Text($r('app.string.common_select_none')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).onClick(()=>{this.selectAll(false)}).margin({right:12})
          Text($r('app.string.ui_812421bd66')).fontSize(12).fontColor(ThemeColors.success(this.isDark)).onClick(()=>{this.selectNew()}).margin({right:12})
          Text($r('app.string.ui_2aa8da7c5f')).fontSize(12).fontColor(ThemeColors.warning(this.isDark)).onClick(()=>{this.selectUpdate()})
        }.padding({left:16,right:16,top:4,bottom:4}).width('100%')

        // 预览列表
        List(){ForEach(this.items,(item:PreviewItem,idx:number)=>{ListItem(){Row(){Checkbox({name:'imp_'+idx,group:'imprt'}).select(item.checked).selectedColor(ThemeColors.primary(this.isDark)).margin({right:8}).onChange((v:boolean)=>{item.checked=v;this.items=[...this.items]});Text(item.name).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1);Text(this.statusLabel(item.status)).fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(this.statusColor(item.status)).borderRadius(8).padding({left:6,right:6,top:1,bottom:1})}.padding({left:16,right:16,top:8,bottom:8}).width('100%')}.border({width:{bottom:0.5},color:ThemeColors.outlineVariant(this.isDark)})})}.layoutWeight(1).width('100%')

        // 选项
        Column() {
          Row(){Text($r('app.string.ui_221ee0cc94')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).fontWeight(FontWeight.Medium).margin({bottom:4})}.width('100%')
          Row(){Text($r('app.string.ui_8aa8476aa8')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepName}).onChange((v)=>{this.keepName=v})}.width('100%').margin({bottom:4})
          Row(){Text($r('app.string.ui_d2570e2bf1')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepGroup}).onChange((v)=>{this.keepGroup=v})}.width('100%').margin({bottom:4})
          Row(){Text($r('app.string.ui_75598fec28')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepEnabled}).onChange((v)=>{this.keepEnabled=v})}.width('100%').margin({bottom:8})
          TextInput({placeholder: $r('app.string.ui_bd736410f9'),text:this.customGroup}).height(40).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark)).borderRadius(8).padding({left:12}).fontSize(13).width('100%').margin({bottom:4}).onChange((v:string)=>{this.customGroup=v})
          if (this.customGroup.trim()) {
            Row() {
              Button('追加分组').height(36).layoutWeight(1).borderRadius(18)
                .backgroundColor(this.groupMode === 0 ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                .fontColor(this.groupMode === 0 ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .onClick(() => { this.groupMode = 0; })
              Button('覆盖分组').height(36).layoutWeight(1).borderRadius(18).margin({ left: 8 })
                .backgroundColor(this.groupMode === 1 ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                .fontColor(this.groupMode === 1 ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .onClick(() => { this.groupMode = 1; })
            }.width('100%').margin({ top: 4, bottom: 4 })
          }
        }.padding({left:16,right:16,top:8}).width('100%')

        // 导入按钮
        Row() {
          Text('已选 ' + this.items.filter(i=>i.checked).length + '/' + this.items.length).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
          Button($r('app.string.ui_17a2c45c82')).fontSize(14).height(40).padding({left:24,right:24}).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(20).onClick(()=>{this.doImport()})
        }.padding({left:16,right:16,top:8,bottom:16}).width('100%')
      } else if (this.importMode === 'url') {
        // URL 输入模式
        Column() {
          Text($r('app.string.ui_873b2f22c0')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({bottom:8})
          TextInput({placeholder: $r('app.string.ui_a47dc3912c'),text:this.importUrl})
            .height(44).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .caretColor(ThemeColors.primary(this.isDark)).borderRadius(8).padding({left:12}).fontSize(14).width('100%')
            .margin({bottom:8}).onChange((v:string)=>{this.importUrl=v})
          Row() {
            Button($r('app.string.common_cancel')).fontSize(14).height(40).layoutWeight(1).backgroundColor(ThemeColors.surface(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(8).margin({right:6}).onClick(()=>{this.resetMode()})
            Button($r('app.string.ui_5fc350fb8d')).fontSize(14).height(40).layoutWeight(1).backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8).margin({left:6}).onClick(()=>{this.doUrlImport(this.importUrl)})
          }.width('100%')
        }.padding(16).width('100%')
      } else if (this.importMode === 'json') {
        // JSON 粘贴模式
        Column() {
          Row() {
            Text($r('app.string.ui_c5faeb98cd')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
            PasteButton().height(36).onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.doClipboardJsonImport();
              } else {
                UiUtil.showToast(this.getUIContext(), { message: '未获得剪贴板授权', duration: 1500 });
              }
            })
          }.width('100%').margin({bottom:8})
          TextArea({placeholder: $r('app.string.ui_9e6ca0bcd0'),text:this.jsonText})
            // 书源 JSON 通常包含完整的搜索、目录和正文规则；显式放宽控件字符上限，
            // 避免部分系统版本的默认输入长度限制在粘贴阶段截断内容。
            .height(160).maxLength(MAX_IMPORT_BYTES).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .caretColor(ThemeColors.primary(this.isDark)).borderRadius(8).padding({left:12,top:8}).fontSize(14).width('100%')
            .margin({bottom:8})
            // 先接管粘贴事件再更新状态，避免 TextArea 原生输入缓冲区截断长 JSON。
            .onPaste((value: string, event: PasteEvent) => {
              if (event.preventDefault) event.preventDefault();
              this.jsonText = value;
            })
            .onChange((v:string)=>{this.jsonText=v})
          Row() {
            Button($r('app.string.common_cancel')).fontSize(14).height(40).layoutWeight(1).backgroundColor(ThemeColors.surface(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(8).margin({right:6}).onClick(()=>{this.resetMode()})
            Button($r('app.string.ui_1503a5a605')).fontSize(14).height(40).layoutWeight(1).backgroundColor(ThemeColors.warning(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8).margin({left:6}).onClick(()=>{this.doJsonImport(this.jsonText)})
          }.width('100%')
        }.padding(16).width('100%')
      } else {
        // 初始状态：选择导入方式
        Column() {
          Button($r('app.string.ui_95462abb0d')).fontSize(15).height(44).width('100%').backgroundColor(ThemeColors.success(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8).margin({bottom:10}).onClick(()=>{this.doFileImport()})
          Button($r('app.string.ui_5e71071b34')).fontSize(15).height(44).width('100%').backgroundColor(ThemeColors.warning(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8).margin({bottom:10}).onClick(()=>{this.importMode = 'json'})
          Button($r('app.string.ui_a27b2f6612')).fontSize(15).height(44).width('100%').backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8).onClick(()=>{this.importMode = 'url'})
        }.padding(16).width('100%')
      }
    }.width('100%').constraintSize({ maxWidth: 640, maxHeight: '92%' })
      .backgroundColor(ThemeColors.background(this.isDark)).borderRadius({topLeft:16,topRight:16})
  }
}
