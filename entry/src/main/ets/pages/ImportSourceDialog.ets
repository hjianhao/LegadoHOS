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
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct ImportSourceDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State items: PreviewItem[] = [];
  @State isLoading: boolean = false;
  @State statusText: string = '';
  @State keepName: boolean = true;
  @State keepGroup: boolean = true;
  @State keepEnabled: boolean = true;
  @State customGroup: string = '';
  @State groupMode: number = 0; // 0=append, 1=overwrite
  @State importMode: string = 'menu'; // 'menu' | 'url' | 'json'
  @State importUrl: string = '';
  @State jsonText: string = '';

  onImportSuccess?: () => void;

  private resetMode(): void {
    this.importMode = 'menu';
    this.importUrl = '';
    this.jsonText = '';
  }

  private async loadPreview(json: string): Promise<void> {
    this.isLoading = true; this.statusText = '解析中...';
    // DocumentViewPicker / 剪贴板导入的 UTF-8 文本可能保留 BOM，JSON.parse 不接受它。
    const normalizedJson = json.replace(/^\uFEFF/, '').trim();
    try {
      JSON.parse(normalizedJson);
    } catch (e) {
      const message = (e as Error).message || String(e);
      console.error('[ImportSource] invalid JSON: ' + message + ', first100=' + normalizedJson.substring(0, 100));
      UiUtil.showToast(this.getUIContext(), {message:'JSON格式错误: '+message.substring(0,80),duration:2500});
      this.statusText = 'JSON格式错误';
      this.isLoading = false;
      return;
    }
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.items = await dao.importSourcesPreview(normalizedJson);
      this.statusText = `${this.items.length} 条书源`;
      console.info('[ImportSource] preview done: ' + this.items.length + ' items');
    } catch (e) {
      console.error('[ImportSource] loadPreview error: ' + e);
      UiUtil.showToast(this.getUIContext(), {message:'书源解析失败: '+String(e).substring(0,80),duration:2500});
      this.statusText = '书源解析失败';
    }
    this.isLoading = false;
  }

  private async doImport(): Promise<void> {
    const sel = this.items.filter(i => i.checked);
    if (sel.length === 0) { UiUtil.showToast(this.getUIContext(), {message:'未选中任何书源',duration:1500}); return; }
    this.isLoading = true; this.statusText = '导入中...';
    try {
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const count = await dao.importSelected(sel, this.keepName, this.keepGroup, this.keepEnabled, this.customGroup);
      UiUtil.showToast(this.getUIContext(), {message:'成功导入 '+count+' 个书源',duration:2000});
      // 先通知宿主页刷新，再销毁弹窗，避免关闭后回调随组件一起失效。
      if (this.onImportSuccess) this.onImportSuccess();
      this.controller.close();
    } catch (e) { console.error('[ImportSource] doImport error: ' + e); UiUtil.showToast(this.getUIContext(), {message:'导入失败',duration:1500}); }
    this.isLoading = false;
  }

  private async doFileImport(): Promise<void> {
    try {
      const uris = await new picker.DocumentViewPicker().select();
      if (!uris || uris.length === 0) return;
      this.statusText = '读取文件...';
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const s = fileIo.statSync(f.fd);
      const b = new ArrayBuffer(s.size);
      fileIo.readSync(f.fd, b);
      fileIo.closeSync(f);
      const td = util.TextDecoder.create('utf-8');
      const json = td.decodeToString(new Uint8Array(b), {stream:false});
      console.info('[ImportSource] file loaded, len=' + json.length);
      await this.loadPreview(json);
    } catch (e) { console.error('[ImportSource] fileImport error: ' + e); UiUtil.showToast(this.getUIContext(), {message:'读取失败',duration:1500}); }
  }

  private async doUrlImport(url: string): Promise<void> {
    if (!url) { UiUtil.showToast(this.getUIContext(), {message:'请输入URL',duration:1500}); return; }
    this.statusText = '下载中...';
    try {
      const json = await NetUtil.httpGet(url);
      await this.loadPreview(json);
      this.resetMode();
    } catch (e) {
      const msg = (e as Error).message || String(e);
      console.error('[ImportSource] URL import failed:', url, msg);
      // HTTPS 失败时自动回退到 HTTP
      if ((msg.includes('SSL') || msg.includes('ssl') || msg.includes('TLS') || msg.includes('certificate'))
          && url.startsWith('https://')) {
        const httpUrl = 'http://' + url.substring(8);
        console.info('[ImportSource] retrying with HTTP:', httpUrl);
        this.statusText = 'HTTPS失败，尝试HTTP...';
        try {
          const json = await NetUtil.httpGet(httpUrl);
          await this.loadPreview(json);
          this.resetMode();
          return;
        } catch (e2) {
          const msg2 = (e2 as Error).message || String(e2);
          console.error('[ImportSource] HTTP fallback also failed:', httpUrl, msg2);
          UiUtil.showToast(this.getUIContext(), {message:'链接不可用（HTTPS和HTTP均失败）',duration:2000});
        }
      } else if (msg.includes('timeout') || msg.includes('Timeout')) {
        UiUtil.showToast(this.getUIContext(), {message:'连接超时，请检查网络或重试',duration:2000});
      } else {
        UiUtil.showToast(this.getUIContext(), {message:'下载失败: '+msg.substring(0,50),duration:2000});
      }
    }
  }

  private async doJsonImport(json: string): Promise<void> {
    if (!json || json.trim().length === 0) { UiUtil.showToast(this.getUIContext(), {message:'请粘贴 JSON 内容',duration:1500}); return; }
    await this.loadPreview(json);
    this.resetMode();
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
          Text($r('app.string.ui_c5faeb98cd')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({bottom:8})
          TextArea({placeholder: $r('app.string.ui_9e6ca0bcd0'),text:this.jsonText})
            .height(160).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .caretColor(ThemeColors.primary(this.isDark)).borderRadius(8).padding({left:12,top:8}).fontSize(14).width('100%')
            .margin({bottom:8}).onChange((v:string)=>{this.jsonText=v})
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
