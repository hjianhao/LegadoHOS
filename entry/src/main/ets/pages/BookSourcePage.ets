/**
 * 书源管理 — 复刻 Android BookSourceActivity 全部功能
 */
import { BookSource } from '../model/BookSource';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ImportSourceDialog } from './ImportSourceDialog';
import { SourceChecker, CheckResult, CheckDetail } from '../service/SourceChecker';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import { WebViewEngine } from '../components/WebViewEngine';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

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
  @State isChecking: boolean = false;
  @State checkProgress: number = 0;
  @State checkTotal: number = 0;
  @State checkResults: CheckResult[] = [];
  @State checkResByUrl: Map<string, CheckResult> = new Map();
  @State showCheckSummary: boolean = false;

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
    if (this.filtered.length === 0) { UiUtil.showToast(this.getUIContext(), {message:'无书源',duration:1500}); return; }
    try {
      const dp = new picker.DocumentViewPicker();
      const uris = await dp.save({ newFileNames: ['bookSources.json'] });
      if (uris && uris.length > 0) {
        const json = JSON.stringify(this.filtered);
        const f = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        fileIo.writeSync(f.fd, json);
        fileIo.closeSync(f);
        UiUtil.showToast(this.getUIContext(), {message:'已导出 '+this.filtered.length+' 条',duration:2000});
      }
    } catch (_e) { UiUtil.showToast(this.getUIContext(), {message:'导出失败',duration:1500}); }
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
    this.dao_?.batchDeleteByUrl?.(urls).then(() => { this.load(); this.selectMode = false; UiUtil.showToast(this.getUIContext(), {message:'已删除 '+urls.length+' 个',duration:1500}); });
  }

  private getCheckDetails(url: string): CheckDetail[] {
    const res: CheckResult | undefined = this.checkResByUrl.get(url);
    if (res !== undefined && res.details) {
      return res.details;
    }
    return [];
  }

  private startCheck(): void {
    const toCheck: BookSource[] = [];
    for (let i = 0; i < this.filtered.length; i++) if (this.selected[i]) toCheck.push(this.filtered[i]);
    if (toCheck.length === 0) { UiUtil.showToast(this.getUIContext(), {message:'请先选择书源',duration:1500}); return; }

    this.isChecking = true;
    this.checkTotal = toCheck.length;
    this.checkProgress = 0;
    this.checkResults = [];
    this.checkResByUrl = new Map();
    this.showCheckSummary = false;
    this.selectMode = false;

    const checker = new SourceChecker({keyword:'凡人修仙传',timeout:20000,checkSearch:true,checkDiscovery:false,checkInfo:false,checkCategory:true,checkContent:true});
    checker.checkSources(toCheck, (completed: number, total: number, result: CheckResult) => {
      this.checkProgress = completed;
      this.checkTotal = total;
      this.checkResults.push(result);
      this.checkResByUrl.set(result.sourceUrl, result);
    }).then(() => {
      this.isChecking = false;
      this.showCheckSummary = true;
    });
  }

  private getSelCount(): number { return this.selected.filter(Boolean).length; }

  build() {
    Stack() {
    Column() {
      // 顶部栏
      Row() {
        Button('←').fontSize(18).fontColor(ThemeColors.secondaryText(this.isDark)).width(36).height(36).backgroundColor('transparent').onClick(()=>{UiUtil.back(this.getUIContext())})
        Text('书源(' + this.sources.length + ')').fontSize(16).fontWeight(FontWeight.Bold).layoutWeight(1).margin({left:4})
        if (this.selectMode) {
          Button('取消').fontSize(13).fontColor(ThemeColors.primary(this.isDark)).height(32).padding({left:8,right:8}).onClick(()=>{this.selectMode=false;this.selected.fill(false)})
        } else {
          Button('导入').fontSize(13).height(32).padding({left:10,right:10}).backgroundColor(ThemeColors.primary(this.isDark)).fontColor('#FFF').borderRadius(16).onClick(()=>{this.showImport=true})
          Button('分组').fontSize(13).height(32).padding({left:10,right:10}).margin({left:6}).onClick(()=>{})
        }
      }.padding({left:12,right:12,top:44}).width('100%')

      // 搜索 + 排序下拉
      Row() {
        TextInput({placeholder:'搜索书源...',text:this.searchText}).height(36).layoutWeight(1).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(18).padding({left:16}).fontSize(14).onChange((v:string)=>{this.searchText=v;this.applyFilters()})
        Row() {
          Text(this.sortLabels_[this.sortMode] + ' ▾').fontSize(12).fontColor('#666')
        }.padding({left:8,right:8}).height(32).backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(16).margin({left:6})
        .onClick(()=>{this.showSortMenu=!this.showSortMenu})
      }.padding({left:12,right:12,top:8}).width('100%')

      // 排序下拉菜单
      if (this.showSortMenu) {
        Column() {
          ForEach(this.sortLabels_, (label:string, idx:number) => {
            Text(label).fontSize(13).fontColor(idx===this.sortMode?ThemeColors.primary(this.isDark):ThemeColors.onBackground(this.isDark))
              .padding({left:16,right:16,top:10,bottom:10}).width('100%')
              .backgroundColor(idx===this.sortMode?(this.isDark?'#1A3A5A':'#E8F0FE'):'transparent')
              .onClick(()=>{this.sortMode=idx;this.showSortMenu=false;this.applyFilters()})
          })
        }.width(120).backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12).shadow({radius:8,color:'#20000000'})
        .position({x:16,y:90}).zIndex(99)
      }

      // 分组标签
      if (this.groups_.length > 0) { Scroll(){Row(){ForEach(this.groups_,(g:string)=>{Text(g).fontSize(12).fontColor(this.groupFilter===g?'#FFF':ThemeColors.secondaryText(this.isDark)).backgroundColor(this.groupFilter===g?ThemeColors.primary(this.isDark):ThemeColors.outlineVariant(this.isDark)).borderRadius(14).padding({left:10,right:10,top:4,bottom:4}).margin({right:6}).onClick(()=>{this.groupFilter=this.groupFilter===g?'':g;this.applyFilters()})})}.padding({left:12,top:4,bottom:4})}.width('100%').scrollable(ScrollDirection.Horizontal)}

      // 域名切换
      Row(){Row(){Toggle({type:ToggleType.Switch,isOn:this.groupByDomain}).width(36).height(20).onChange((v:boolean)=>{this.groupByDomain=v})}.margin({right:6});Text('按域名分组').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))}.padding({left:12,top:4}).width('100%')

      // 列表
      if (this.isLoading) { LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({top:60}) }
      else if (this.filtered.length===0) { Text('无书源').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top:60}) }
      else { List(){ForEach(this.getDisplayList(),(s:BookSource,idx:number)=>{ListItem(){this.item(s,idx)}.border({width:{bottom:1},color:ThemeColors.outlineVariant(this.isDark)})})}.layoutWeight(1) }

      // 批量操作栏（复刻 Android SelectActionBar）
      if (this.selectMode) { Row(){Text('已选'+this.getSelCount()+'项').fontSize(12).fontColor('#666').margin({left:8}).layoutWeight(1);Button(this.getSelCount()===this.selected.length?'取消':'全选').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{const all=this.getSelCount()===this.selected.length;for(let i=0;i<this.selected.length;i++)this.selected[i]=!all});Button('启用').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.batchEnable(true)});Button('禁用').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.batchEnable(false)});Button('分组').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{UiUtil.showToast(this.getUIContext(), {message:'分组功能待实现',duration:1500})});Button('校验').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).backgroundColor('#FF9800').fontColor('#FFF').onClick(()=>{this.startCheck()}).enabled(!this.isChecking);Button('导出').fontSize(11).height(28).padding({left:6,right:6}).margin({right:3}).onClick(()=>{this.doExport()});Button('删除',{type:ButtonType.Capsule}).fontSize(11).height(28).padding({left:6,right:6}).backgroundColor(ThemeColors.error(this.isDark)).fontColor('#FFF').onClick(()=>{this.batchDelete()})}.width('100%').height(42).backgroundColor(ThemeColors.surface(this.isDark))}

      // 校验进度条
      if (this.isChecking) {
        Column() {
          Progress({value:this.checkProgress,total:Math.max(1,this.checkTotal),type:ProgressType.Linear}).width('100%').color('#FF9800').style({strokeWidth:4})
          Text(this.checkProgress + '/' + this.checkTotal + ' 已完成').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top:3})
        }.width('100%').padding({left:12,right:12,top:6,bottom:6})
      }

      // 校验结果摘要
      if (this.showCheckSummary && this.checkResults.length > 0) {
        Column() {
          Row() {
            Text('校验结果').fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1)
            Text('关闭').fontSize(12).fontColor(ThemeColors.primary(this.isDark)).onClick(()=>{this.showCheckSummary=false})
          }.width('100%').padding({left:12,right:12,top:8,bottom:4})
          Row() {
            Text('通过: '+this.checkResults.filter((r:CheckResult)=>r.status==='success').length).fontSize(11).fontColor('#4CAF50').margin({right:12})
            Text('部分: '+this.checkResults.filter((r:CheckResult)=>r.status==='partial').length).fontSize(11).fontColor('#FF9800').margin({right:12})
            Text('失败: '+this.checkResults.filter((r:CheckResult)=>r.status==='fail').length).fontSize(11).fontColor('#FF5722')
          }.padding({left:12,right:12,bottom:8})
        }.width('100%').backgroundColor(ThemeColors.surface(this.isDark)).margin({top:4}).borderRadius(8)
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark)).onClick(()=>{this.showSortMenu=false;this.contextMenuIdx=-1})

    // 导入弹窗
    if (this.showImport) { Column(){}.layoutWeight(1).onClick(()=>{this.showImport=false}); ImportSourceDialog({controller:new CustomDialogController({builder:ImportSourceDialog({}),autoCancel:true}),onImportSuccess:()=>{this.showImport=false;this.load()}}) }
    // 隐藏 WebView（Cloudflare 兜底）
    WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%')
  }

  @Builder item(s:BookSource,idx:number) {
    Stack() {
    Row() {
      Column() {
        Row() {
          Text(s.sourceName||'未命名').fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark)).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
          if (!this.selectMode) { Toggle({type:ToggleType.Switch,isOn:s.enabled}).width(36).height(20).margin({left:6}).onChange((v:boolean)=>{s.enabled=v;this.dao_?.toggleByUrl?.(s.sourceUrl,v)}) }
        }.width('100%')
        Text(s.sourceUrl).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%').margin({top:2})
        // 校验结果标签（仿 Android）
        if (!this.selectMode && this.checkResByUrl.has(s.sourceUrl)) {
          Row() {
            ForEach(this.getCheckDetails(s.sourceUrl), (d: CheckDetail, i: number) => {
              this.checkBadge(d)
            }, (d: CheckDetail): string => d.name)
            Blank()
          }.width('100%').margin({top:4})
        }
        Row() {
          if (s.group) { Text(s.group).fontSize(10).fontColor(ThemeColors.primary(this.isDark)).padding({left:6,right:6,top:1,bottom:1}).backgroundColor('#0078D71A').borderRadius(8).margin({right:6}) }
          Text('权重:'+(s.weight||0)).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({right:8})
          if (s.ruleSearchUrl) { Text('🔍').fontSize(10).fontColor('#4CAF50') }
          Blank()
          if (this.selectMode) { Checkbox({name:'sel_'+idx,group:'srcs'}).select(this.selected[idx]||false).selectedColor(ThemeColors.primary(this.isDark)).margin({left:4}).onChange((v:boolean)=>{this.selected[idx]=v}) }
          if (!this.selectMode) {
            Text('✎').fontSize(16).fontColor(ThemeColors.primary(this.isDark)).margin({left:6}).onClick(()=>{UiUtil.pushUrl(this.getUIContext(), {url:'pages/BookSourceEditPage',params:{url:s.sourceUrl}})})
          }
        }.width('100%').margin({top:3})
      }.layoutWeight(1)
      .onClick(() => { if (this.selectMode) this.toggleSelect(idx); })
      // 更多按钮（⋮ 竖向三点）
      if (!this.selectMode) {
        Text('⋮').fontSize(22).fontColor(ThemeColors.secondaryText(this.isDark)).width(32).height(32).textAlign(TextAlign.Center)
          .onClick(() => { this.contextMenuIdx = (this.contextMenuIdx === idx ? -1 : idx); })
      }
    }.width('100%').padding({left:12,right:8,top:10,bottom:10})
    .gesture(LongPressGesture().onAction(()=>{this.selectMode=true;this.selected[idx]=true}))
    // 更多菜单
    if (this.contextMenuIdx === idx) {
      Column() {
        Text('置顶').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(ThemeColors.onBackground(this.isDark))
          .onClick(()=>{this.contextMenuIdx=-1;this.applyFilters()})
        Text('置底').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(ThemeColors.onBackground(this.isDark))
          .onClick(()=>{this.contextMenuIdx=-1;this.applyFilters()})
        Text('启用发现').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor('#4CAF50')
          .onClick(()=>{this.contextMenuIdx=-1;UiUtil.showToast(this.getUIContext(), {message:'发现功能待实现',duration:1500})})
        Text('搜索测试').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(ThemeColors.onBackground(this.isDark))
          .onClick(()=>{this.contextMenuIdx=-1;UiUtil.showToast(this.getUIContext(), {message:'搜索测试待实现',duration:1500})})
        Text('调试').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor('#FF9800')
          .onClick(()=>{this.contextMenuIdx=-1;UiUtil.showToast(this.getUIContext(), {message:'调试待实现',duration:1500})})
        Text('删除').fontSize(13).padding({left:14,right:14,top:10,bottom:10}).width('100%').fontColor(ThemeColors.error(this.isDark))
          .onClick(()=>{this.contextMenuIdx=-1;this.dao_?.deleteByUrl?.(s.sourceUrl);this.load()})
      }.width(120).backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12).shadow({radius:8,color:'#20000000',offsetY:2})
      .position({x:'calc(100% - 140)',y:40}).zIndex(100)
    }
    }.width('100%')
  }

  @Builder checkBadge(d: CheckDetail) {
    Row() {
      Text('')
        .width(6).height(6)
        .borderRadius(3)
        .backgroundColor(d.passed ? '#4CAF50' : '#FF5722')
      if (d.passed) {
        Text(d.name + (d.duration > 0 ? ' ' + d.duration + 'ms' : ''))
          .fontSize(10).fontColor('#4CAF50').margin({left:3})
      } else {
        Text(d.name + ': ' + d.message)
          .fontSize(10).fontColor('#FF5722').margin({left:3}).maxLines(1)
      }
    }.padding({left:5,right:5,top:2,bottom:2}).backgroundColor(d.passed?'#4CAF5018':'#FF572218').borderRadius(4).margin({right:4})
  }
}
