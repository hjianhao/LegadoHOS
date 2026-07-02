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

@CustomDialog
export struct ImportSourceDialog {
  controller: CustomDialogController;
  @State items: PreviewItem[] = [];
  @State isLoading: boolean = false;
  @State statusText: string = '';
  @State keepName: boolean = true;
  @State keepGroup: boolean = true;
  @State keepEnabled: boolean = true;
  @State customGroup: string = '';
  @State groupMode: number = 0; // 0=append, 1=overwrite

  onImportSuccess?: () => void;

  private async loadPreview(json: string): Promise<void> {
    this.isLoading = true; this.statusText = '解析中...';
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.items = await dao.importSourcesPreview(json);
      this.statusText = `${this.items.length} 条书源`;
    } catch (e) { UiUtil.showToast(this.getUIContext(), {message:'JSON格式错误',duration:1500}); }
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
      this.controller.close();
      if (this.onImportSuccess) this.onImportSuccess();
    } catch (e) { UiUtil.showToast(this.getUIContext(), {message:'导入失败',duration:1500}); }
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
      await this.loadPreview(json);
    } catch (e) { UiUtil.showToast(this.getUIContext(), {message:'读取失败',duration:1500}); }
  }

  private async doUrlImport(): Promise<void> {
    this.statusText = '下载中...';
    try {
      const json = await NetUtil.httpGet('');
      await this.loadPreview(json);
    } catch (e) { UiUtil.showToast(this.getUIContext(), {message:'下载失败',duration:1500}); }
  }

  private selectAll(select: boolean): void { for (const i of this.items) i.checked = select; this.items = [...this.items]; }
  private selectNew(): void { for (const i of this.items) i.checked = i.status === 'new'; this.items = [...this.items]; }
  private selectUpdate(): void { for (const i of this.items) i.checked = i.status === 'update'; this.items = [...this.items]; }

  private statusColor(s: string): string { return s==='new'?'#4CAF50':s==='update'?'#FF9800':'#AAA'; }
  private statusLabel(s: string): string { return s==='new'?'新增':s==='update'?'更新':'已有'; }

  build() {
    Column() {
      // 标题
      Row() {
        Text('导入书源' + (this.items.length>0?` (${this.items.length}条)`:'')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('✕').fontSize(16).fontColor('#888').backgroundColor('transparent').width(36).height(36).onClick(()=>{this.controller.close()})
      }.padding({left:16,right:8,top:16,bottom:8}).width('100%')

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({top:20,bottom:20})
        if (this.statusText) Text(this.statusText).fontSize(14).fontColor('#888').margin({top:8})
      } else if (this.items.length > 0) {
        // 快捷操作
        Row() {
          Text('全选').fontSize(12).fontColor('#0078D7').onClick(()=>{this.selectAll(true)}).margin({right:12})
          Text('全不选').fontSize(12).fontColor('#666').onClick(()=>{this.selectAll(false)}).margin({right:12})
          Text('选新增').fontSize(12).fontColor('#4CAF50').onClick(()=>{this.selectNew()}).margin({right:12})
          Text('选更新').fontSize(12).fontColor('#FF9800').onClick(()=>{this.selectUpdate()})
        }.padding({left:16,right:16,top:4,bottom:4}).width('100%')

        // 预览列表
        List(){ForEach(this.items,(item:PreviewItem,idx:number)=>{ListItem(){Row(){Checkbox({name:'imp_'+idx,group:'imprt'}).select(item.checked).selectedColor('#0078D7').margin({right:8}).onChange((v:boolean)=>{item.checked=v;this.items=[...this.items]});Text(item.name).fontSize(13).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1);Text(this.statusLabel(item.status)).fontSize(10).fontColor('#FFF').backgroundColor(this.statusColor(item.status)).borderRadius(8).padding({left:6,right:6,top:1,bottom:1})}.padding({left:16,right:16,top:8,bottom:8}).width('100%')}.border({width:{bottom:0.5},color:'#EEE'})})}.layoutWeight(1).width('100%')

        // 选项
        Column() {
          Row(){Text('选项').fontSize(13).fontWeight(FontWeight.Medium).margin({bottom:4})}.width('100%')
          Row(){Text('保留原名').fontSize(13).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepName}).onChange((v)=>{this.keepName=v})}.width('100%').margin({bottom:4})
          Row(){Text('保留分组').fontSize(13).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepGroup}).onChange((v)=>{this.keepGroup=v})}.width('100%').margin({bottom:4})
          Row(){Text('保留启用').fontSize(13).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.keepEnabled}).onChange((v)=>{this.keepEnabled=v})}.width('100%').margin({bottom:8})
          TextInput({placeholder:'自定义分组名',text:this.customGroup}).height(36).backgroundColor('#F0F0F0').borderRadius(8).padding({left:12}).fontSize(13).width('100%').margin({bottom:4}).onChange((v:string)=>{this.customGroup=v})
        }.padding({left:16,right:16,top:8}).width('100%')

        // 导入按钮
        Row() {
          Text('已选 ' + this.items.filter(i=>i.checked).length + '/' + this.items.length).fontSize(14).fontColor('#666').layoutWeight(1)
          Button('导入选中').fontSize(14).height(40).padding({left:24,right:24}).backgroundColor('#0078D7').fontColor('#FFF').borderRadius(20).onClick(()=>{this.doImport()})
        }.padding({left:16,right:16,top:8,bottom:16}).width('100%')
      } else {
        // 初始状态：选择导入方式
        Column() {
          Button('📁 选择本地文件').fontSize(15).height(44).width('100%').backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(8).margin({bottom:10}).onClick(()=>{this.doFileImport()})
          Button('📋 粘贴 JSON 内容').fontSize(15).height(44).width('100%').backgroundColor('#FF9800').fontColor('#FFF').borderRadius(8).margin({bottom:10}).onClick(()=>{})
          Button('🌐 从URL导入').fontSize(15).height(44).width('100%').backgroundColor('#0078D7').fontColor('#FFF').borderRadius(8).onClick(()=>{this.doUrlImport()})
        }.padding(16).width('100%')
      }
    }.width('100%').backgroundColor('#FFF').borderRadius({topLeft:16,topRight:16})
  }
}
