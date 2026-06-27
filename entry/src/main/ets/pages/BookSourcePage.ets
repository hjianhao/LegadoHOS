/**
 * 书源管理 — 复刻 Android BookSourceActivity 全部功能
 */
import { BookSource } from '../model/BookSource';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ImportSourceDialog } from './ImportSourceDialog';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';

@Entry
@Component
struct BookSourcePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State sources: BookSource[] = [];
  @State filtered: BookSource[] = [];
  @State searchText: string = '';
  @State sortMode: number = 0;
  @State groupFilter: string = '';
  @State groupByDomain: boolean = false;
  @State isLoading: boolean = true;
  @State selectMode: boolean = false;
  @State selected: boolean[] = [];
  @State showImport: boolean = false;
  @State showSortMenu: boolean = false;
  @State contextMenuIdx: number = -1;

  private dao_: BookSourceTable | null = null;
  private groups_: string[] = [];
  private sortLabels_: string[] = ['手动','名称','URL','权重','更新时间','响应','启用'];

  aboutToAppear(): void { this.load(); }

  async load(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      this.dao_ = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.sources = await this.dao_.getAllSources();
      this.applyFilters();
      this.buildGroups();
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  private buildGroups(): void {
    const gs = new Set<string>();
    for (const s of this.sources) {
      if (s.group) { const parts = s.group.split(/[,;]/); for (const p of parts) if (p.trim()) gs.add(p.trim()); }
    }
    this.groups_ = ['全部','已启用','已禁用', ...Array.from(gs)];
  }

  private applyFilters(): void {
    let list = [...this.sources];
    if (this.searchText.trim()) {
      const q = this.searchText.trim().toLowerCase();
      list = list.filter(s => s.sourceName.toLowerCase().includes(q) || s.sourceUrl.toLowerCase().includes(q));
    }
    if (this.groupFilter === '已启用') list = list.filter(s => s.enabled);
    else if (this.groupFilter === '已禁用') list = list.filter(s => !s.enabled);
    else if (this.groupFilter && this.groupFilter !== '全部') list = list.filter(s => (s.group||'').includes(this.groupFilter));
    const keys = ['customOrder','sourceName','sourceUrl','weight','updateTime','enabled'];
    const k = keys[this.sortMode % 6];
    list.sort((a: BookSource, b: BookSource): number => {
      let va: string = ''; let vb: string = '';
      if (k === 'customOrder') { va = `${a.customOrder||0}`; vb = `${b.customOrder||0}`; }
      else if (k === 'sourceName') { va = a.sourceName; vb = b.sourceName; }
      else if (k === 'sourceUrl') { va = a.sourceUrl; vb = b.sourceUrl; }
      else if (k === 'weight') { va = `${a.weight||0}`; vb = `${b.weight||0}`; }
      else if (k === 'updateTime') { va = `${a.updateTime||0}`; vb = `${b.updateTime||0}`; }
      else { va = a.enabled ? '1' : '0'; vb = b.enabled ? '1' : '0'; }
      return va < vb ? -1 : va > vb ? 1 : 0;
    });
    this.filtered = list;
    this.selected = new Array(list.length).fill(false);
  }

  private getDomain(url: string): string {
    try { return url.replace(/^https?:\/\//,'').split('/')[0]; } catch (_e) { return url; }
  }

  private getDisplayList(): BookSource[] {
    if (!this.groupByDomain) return this.filtered;
    const list = [...this.filtered];
    list.sort((a,b) => this.getDomain(a.sourceUrl).localeCompare(this.getDomain(b.sourceUrl)));
    return list;
  }

  private async doExport(): Promise<void> {
    if (this.filtered.length === 0) { promptAction.showToast({message:'无书源',duration:1500}); return; }
    try {
      const dp = new picker.DocumentViewPicker();
      const uris = await dp.save({ newFileNames: ['bookSources.json'] });
      if (uris && uris.length > 0) {
        const json = JSON.stringify(this.filtered);
        const f = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        fileIo.writeSync(f.fd, json);
        fileIo.closeSync(f);
        promptAction.showToast({message:'已导出 '+this.filtered.length+' 条',duration:2000});
      }
    } catch (_e) { promptAction.showToast({message:'导出失败',duration:1500}); }
  }

  private toggleSelect(idx: number): void {
    if (!this.selectMode) { this.selectMode = true; this.selected = new Array(this.filtered.length).fill(false); }
    this.selected[idx] = !this.selected[idx];
  }

  private batchEnable(val: boolean): void {
    for (let i = 0; i < this.filtered.length; i++) if (this.selected[i]) { this.filtered[i].enabled = val; this.dao_?.toggleByUrl?.(this.filtered[i].sourceUrl,val); }
    this.selectMode = false; this.applyFilters();
  }

  private batchDelete(): void {
    const urls: string[] = [];
    for (let i = 0; i < this.filtered.length; i++) if (this.selected[i]) urls.push(this.filtered[i].sourceUrl);
    if (urls.length === 0) return;
    this.dao_?.batchDeleteByUrl?.(urls).then(() => { this.load(); this.selectMode = false; promptAction.showToast({message:'已删除 '+urls.length+' 个',duration:1500}); });
  }

  private getSelCount(): number { return this.selected.filter(Boolean).length; }

  build() {
    Stack() {
    Column() {
      // 顶部栏
      Row() {
        Button('←').fontSize(18).fontColor(this.isDark?'#CCC':'#666').width(36).height(36).backgroundColor('transparent').onClick(()=>{router.back()})
        Text('书源(' + this.sources.length + ')').fontSize(16).fontWeight(FontWeight.Bold).layoutWeight(1).margin({left:4})
        if (this.selectMode) {
          Button('取消').fontSize(13).fontColor('#0078D7').height(32).padding({left:8,right:8}).onClick(()=>{this.selectMode=false;this.selected.fill(false)})
        } else {
          Button('导入').fontSize(13).height(32).padding({left:10,right:10}).backgroundColor('#0078D7').fontColor('#FFF').borderRadius(16).onClick(()=>{this.showImport=true})
          Button('分组').fontSize(13).height(32).padding({left:10,right:10}).margin({left:6}).onClick(()=>{})
        }
      }.padding({left:12,right:12,top:44}).width('100%')

      // 搜索 + 排序下拉
      Row() {
        TextInput({placeholder:'搜索书源...',text:this.searchText}).height(36).layoutWeight(1).backgroundColor(this.isDark?'#333':'#F0F0F0').borderRadius(18).padding({left:16}).fontSize(14).onChange((v:string)=>{this.searchText=v;this.applyFilters()})
        Row() {
          Text(this.sortLabels_[this.sortMode] + ' ▾').fontSize(12).fontColor('#666')
        }.padding({left:8,right:8}).height(32).backgroundColor(this.isDark?'#333':'#E0E0E0').borderRadius(16).margin({left:6})
        .onClick(()=>{this.showSortMenu=!this.showSortMenu})
      }.padding({left:12,right:12,top:8}).width('100%')

      // 排序下拉菜单
      if (this.showSortMenu) {
        Column() {
          ForEach(this.sortLabels_, (label:string, idx:number) => {
            Text(label).fontSize(13).fontColor(idx===this.sortMode?'#0078D7':this.isDark?'#CCC':'#333')
              .padding({left:16,right:16,top:10,bottom:10}).width('100%')
              .backgroundColor(idx===this.sortMode?(this.isDark?'#1A3A5A':'#E8F0FE'):'transparent')
              .onClick(()=>{this.sortMode=idx;this.showSortMenu=false;this.applyFilters()})
          })
        }.width(120).backgroundColor(this.isDark?'#2A2A2A':'#FFF').borderRadius(12).shadow({radius:8,color:'#20000000'})
        .position({x:16,y:90}).zIndex(99)
      }

      // 分组标签
      if (this.groups_.length > 0) { Scroll(){Row(){ForEach(this.groups_,(g:string)=>{Text(g).fontSize(12).fontColor(this.groupFilter===g?'#FFF':(this.isDark?'#CCC':'#666')).backgroundColor(this.groupFilter===g?'#0078D7':(this.isDark?'#333':'#E8E8E8')).borderRadius(14).padding({left:10,right:10,top:4,bottom:4}).margin({right:6}).onClick(()=>{this.groupFilter=this.groupFilter===g?'':g;this.applyFilters()})})}.padding({left:12,top:4,bottom:4})}.width('100%').scrollable(ScrollDirection.Horizontal)}

      // 域名切换
      Row(){Row(){Toggle({type:ToggleType.Switch,isOn:this.groupByDomain}).width(36).height(20).onChange((v:boolean)=>{this.groupByDomain=v})}.margin({right:6});Text('按域名分组').fontSize(12).fontColor('#888')}.padding({left:12,top:4}).width('100%')

      // 列表
      if (this.isLoading) { LoadingProgress().color('#0078D7').margin({top:60}) }
      else if (this.filtered.length===0) { Text('无书源').fontSize(14).fontColor('#888').margin({top:60}) }
      else { List(){ForEach(this.getDisplayList(),(s:BookSource,idx:number)=>{ListItem(){this.item(s,idx)}.border({width:{bottom:1},color:this.isDark?'#333':'#E8E8E8'})})}.layoutWeight(1) }

      // 批量操作栏（复刻 Android SelectActionBar）
      if (this.selectMode) { Row(){Text('已选'+this.getSelCount()+'项').fontSize(12).fontColor('#666').margin({left:8}).layoutWeight(1);Button('全选').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{for(let i=0;i<this.selected.length;i++)this.selected[i]=true});Button('启用').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.batchEnable(true)});Button('禁用').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.batchEnable(false)});Button('分组').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{promptAction.showToast({message:'分组功能待实现',duration:1500})});Button('校验').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).backgroundColor('#FF9800').fontColor('#FFF').onClick(()=>{promptAction.showToast({message:'校验功能待实现',duration:1500})});Button('导出').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.doExport()});Button('删除',{type:ButtonType.Capsule}).fontSize(11).height(28).padding({left:6,right:6}).backgroundColor('#FF5722').fontColor('#FFF').onClick(()=>{this.batchDelete()})}.width('100%').height(42).backgroundColor(this.isDark?'#1A1A1A':'#F8F8F8')}
    }.width('100%').height('100%').backgroundColor(this.isDark?'#121212':'#F5F5F5').onClick(()=>{this.showSortMenu=false;this.contextMenuIdx=-1})

    // 导入弹窗
    if (this.showImport) { Column(){}.layoutWeight(1).onClick(()=>{this.showImport=false}); ImportSourceDialog({controller:new CustomDialogController({builder:ImportSourceDialog({}),autoCancel:true}),onImportSuccess:()=>{this.showImport=false;this.load()}}) }
    }.width('100%').height('100%')
  }

  @Builder item(s:BookSource,idx:number) {
    Stack() {
    Row() {
      Column() {
        Row() {
          Text(s.sourceName||'未命名').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.isDark?'#E0E0E0':'#333').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
          .onClick(()=>{if(!this.selectMode)router.pushUrl({url:'pages/BookSourceEditPage',params:{url:s.sourceUrl}})})
          if (!this.selectMode) { Toggle({type:ToggleType.Switch,isOn:s.enabled}).width(36).height(20).margin({left:6}).onChange((v:boolean)=>{s.enabled=v;this.dao_?.toggleByUrl?.(s.sourceUrl,v)}) }
        }.width('100%')
        Text(s.sourceUrl).fontSize(11).fontColor(this.isDark?'#888':'#AAA').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%').margin({top:2})
        Row() {
          if (s.group) { Text(s.group).fontSize(10).fontColor('#0078D7').padding({left:6,right:6,top:1,bottom:1}).backgroundColor('#0078D71A').borderRadius(8).margin({right:6}) }
          Text('权重:'+(s.weight||0)).fontSize(10).fontColor('#999').margin({right:8})
          if (s.ruleSearchUrl) { Text('🔍').fontSize(10).fontColor('#4CAF50') }
          Blank()
          if (this.selectMode) { Checkbox({name:'sel_'+idx,group:'srcs'}).select(this.selected[idx]||false).selectedColor('#0078D7').margin({left:4}).onChange((v:boolean)=>{this.selected[idx]=v}) }
        }.width('100%').margin({top:3})
      }.layoutWeight(1)
      .onClick(() => { if (this.selectMode) this.toggleSelect(idx); })
      // 更多按钮（⋮ 竖向三点）
      if (!this.selectMode) {
        Text('⋮').fontSize(22).fontColor(this.isDark?'#AAA':'#666').width(32).height(32).textAlign(TextAlign.Center)
          .onClick(() => { this.contextMenuIdx = (this.contextMenuIdx === idx ? -1 : idx); })
      }
    }.width('100%').padding({left:12,right:8,top:10,bottom:10})
    .gesture(LongPressGesture().onAction(()=>{this.selectMode=true;this.selected[idx]=true}))
    // 更多菜单
    if (this.contextMenuIdx === idx) {
      Column() {
        Text('置顶').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(this.isDark?'#CCC':'#333')
          .onClick(()=>{this.contextMenuIdx=-1;this.applyFilters()})
        Text('置底').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(this.isDark?'#CCC':'#333')
          .onClick(()=>{this.contextMenuIdx=-1;this.applyFilters()})
        Text('启用发现').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor('#4CAF50')
          .onClick(()=>{this.contextMenuIdx=-1;promptAction.showToast({message:'发现功能待实现',duration:1500})})
        Text('搜索测试').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(this.isDark?'#CCC':'#333')
          .onClick(()=>{this.contextMenuIdx=-1;promptAction.showToast({message:'搜索测试待实现',duration:1500})})
        Text('调试').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor('#FF9800')
          .onClick(()=>{this.contextMenuIdx=-1;promptAction.showToast({message:'调试待实现',duration:1500})})
        Text('删除').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor('#FF5722')
          .onClick(()=>{this.contextMenuIdx=-1;this.dao_?.deleteByUrl?.(s.sourceUrl);this.load()})
      }.width(120).backgroundColor(this.isDark?'#2A2A2A':'#FFF').borderRadius(12).shadow({radius:8,color:'#20000000',offsetY:2})
      .position({x:'calc(100% - 140)',y:40}).zIndex(100)
    }
    }.width('100%')
  }
}
