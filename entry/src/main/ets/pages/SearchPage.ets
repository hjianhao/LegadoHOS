/**
 * 搜索页面 — 对标 Android Legado
 * 功能：搜索历史、多源并发搜索、结果归并、封面显示
 */
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import { WebViewEngine } from '../components/WebViewEngine';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { NetUtil } from '../util/NetUtil';
import router from '@ohos.router';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @StorageLink('isDark') isDark: boolean = false;
  @State results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State hasSearched: boolean = false;
  @State sources: BookSource[] = [];
  @State progress: string = '';
  @State history: string[] = [];
  @State showHistory: boolean = false;

  aboutToAppear(): void {
    this.loadSources();
    this.loadHistory();
  }

  async loadHistory(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(getContext());
      this.history = await s.getSearchHistory();
      if (this.history.length > 0) this.showHistory = true;
    } catch (_e) { this.history = []; }
  }

  async saveHistory(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.setSearchHistory(this.history);
    } catch (_e) { /* ignore */ }
  }

  addToHistory(kw: string): void {
    const q = kw.trim();
    if (!q) return;
    this.history = [q, ...this.history.filter((h: string) => h !== q)].slice(0, 30);
    this.saveHistory();
  }

  removeHistory(idx: number): void {
    this.history.splice(idx, 1);
    this.history = [...this.history];
    this.saveHistory();
  }

  async loadSources(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.sources = await dao.getEnabledSources();
    } catch (_e) { /* ignore */ }
  }

  async doSearch(kw?: string): Promise<void> {
    const q = (kw || this.keyword).trim();
    if (!q) return;
    this.keyword = q;
    this.isSearching = true; this.hasSearched = true;
    this.showHistory = false;
    this.results = [];
    this.addToHistory(q);
    const searchable = this.sources.filter((s: BookSource) => s.ruleSearchUrl);
    if (searchable.length === 0) { this.isSearching = false; return; }
    this.progress = '正在搜索...';
    try {
      const merged = await globalSourceExecutor.search(q, searchable,
        (partial: SearchResult[], done: number, total: number) => {
          this.results = partial;
          this.progress = '搜索中 ' + done + '/' + total;
        });
      this.results = merged;
    } catch (_e) { /* ignore */ }
    this.isSearching = false; this.progress = '';
    // 后台抓取缺失封面
    this.fetchMissingCovers();
  }

  /** 后台为没有封面的结果抓取详情页封面（并发 3）*/
  async fetchMissingCovers(): Promise<void> {
    const noCover = this.results.filter((r: SearchResult) => !r.coverUrl && r.noteUrl);
    if (noCover.length === 0) return;
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < noCover.length) {
        const idx = cursor++;
        const r = noCover[idx];
        try {
          const html = await NetUtil.httpGet(r.noteUrl, {
            'Accept': 'text/html,*/*',
            'Referer': r.originUrl || r.noteUrl,
          }, 8000);
          if (!html) continue;
          // 优先匹配图片扩展名，兜底匹配任意 src
          let m = html.match(/<img[^>]*src=["']([^"']+\.(?:jpe?g|png|webp|gif|bmp))["']/i);
          if (!m) m = html.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["']/i);
          if (!m) m = html.match(/background(?:-image)?\s*:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
          if (m) {
            let url = m[1];
            if (url.startsWith('//')) url = 'https:' + url;
            if (!url.startsWith('http')) {
              const base = r.noteUrl.replace(/\/[^/]*$/, '');
              url = (base || '') + (url.startsWith('/') ? url : '/' + url);
            }
            if (url) {
              r.coverUrl = url;
              // 触发 UI 刷新
              this.results = [...this.results];
            }
          }
        } catch (_e) { /* ignore */ }
      }
    };
    const workers: Promise<void>[] = [];
    for (let w = 0; w < Math.min(3, noCover.length); w++) workers.push(worker());
    await Promise.all(workers);
  }

  goToBookInfo(item: SearchResult): void {
    router.pushUrl({ url: 'pages/BookInfoPage', params: {
      name: item.name, author: item.author, coverUrl: item.coverUrl,
      noteUrl: item.noteUrl, origin: item.origin, originUrl: item.originUrl,
      introduce: item.introduce || '', kind: item.kind || '',
      sourceCount: item.sourceCount, sourceOrigins: JSON.stringify(item.sourceOrigins || []),
    }});
  }

  build() {
    Stack() {
      Column() {
        // 点击空白处收起历史
        if (this.showHistory && !this.hasSearched) {
          Column() {}.height(44).width('100%').onClick(() => { this.showHistory = false; })
        }
        // 搜索栏
        Row() {
          Button('\u2190').fontSize(20).fontColor(this.isDark ? '#CCC' : '#666')
            .width(36).height(36).backgroundColor('transparent')
            .onClick(() => { router.back(); })
          Row() {
            TextInput({ placeholder: '搜索书名或作者...', text: this.keyword })
              .height(40).layoutWeight(1).backgroundColor(Color.Transparent)
              .fontSize(15).padding({ left: 8 })
              .onChange((v: string) => {
                this.keyword = v;
                if (!v && !this.hasSearched) this.showHistory = true;
                else if (v) this.showHistory = false;
              })
              .onClick(() => {
                if (!this.keyword && !this.hasSearched && this.history.length > 0) this.showHistory = true;
              })
              .onFocus(() => {
                if (!this.keyword && !this.hasSearched && this.history.length > 0) this.showHistory = true;
              })
            if (this.keyword) {
              Text('✕').fontSize(14).fontColor('#999').width(28).height(28).textAlign(TextAlign.Center)
                .onClick(() => { this.keyword = ''; this.results = []; this.hasSearched = false; this.showHistory = this.history.length > 0; })
            }
          }
          .height(40).layoutWeight(1).margin({ left: 8, right: 8 })
          .backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0').borderRadius(20)

          Text('搜索').fontSize(14).fontColor('#FFF').padding({left:14,right:14})
            .height(36).backgroundColor('#0078D7').borderRadius(18).textAlign(TextAlign.Center)
            .onClick(() => { this.doSearch(); })
        }.padding({ left: 12, right: 12, top: 44 }).width('100%')

        // 搜索历史
        if (this.showHistory && this.history.length > 0) {
          Column() {
            Row() {
              Text('搜索历史').fontSize(13).fontColor('#888').layoutWeight(1)
              Text('清除全部').fontSize(12).fontColor('#FF5722').onClick(() => {
                this.history = []; this.saveHistory(); this.showHistory = false;
              })
            }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })
            List() {
              ForEach(this.history, (h: string, idx: number) => {
                ListItem() {
                  Row() {
                    Text('🕐').fontSize(12).margin({ right: 8 })
                    Text(h).fontSize(14).fontColor(this.isDark ? '#CCC' : '#444').layoutWeight(1).maxLines(1)
                    Text('✕').fontSize(12).fontColor('#AAA').width(24).height(24).textAlign(TextAlign.Center)
                      .onClick(() => { this.removeHistory(idx); })
                  }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .onClick(() => { this.doSearch(h); })
                }
              }, (h: string, idx: number): string => h + idx.toString())
            }.layoutWeight(1)
          }.width('100%').layoutWeight(1)
          .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
        }

        // 进度
        if (this.progress) {
          Row() {
            if (this.isSearching) { LoadingProgress().width(14).height(14).color('#0078D7').margin({right:6}) }
            Text(this.progress).fontSize(12).fontColor(this.isDark ? '#AAA' : '#888')
            Blank()
            Text(this.results.length + '条').fontSize(12).fontColor('#888')
          }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 2 })
        }

        // 结果列表 — 搜索中就已显示部分结果
        if (this.hasSearched && this.results.length === 0 && !this.isSearching) {
          Column() {
            Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
            Text('没有找到结果').fontSize(16).fontColor(this.isDark ? '#AAA' : '#888').margin({ top: 8 })
            Text('已搜索 ' + this.sources.filter((s: BookSource) => s.ruleSearchUrl).length + ' 个源').fontSize(12).fontColor('#AAA').margin({top:4})
          }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
        } else if (this.hasSearched || this.isSearching) {
          List({ space: 1 }) {
            ForEach(this.results, (item: SearchResult) => {
              ListItem() {
                Row() {
                  BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 48, coverHeight: 64 })
                    .margin({ right: 12 })
                  Column() {
                    Text(item.name).fontSize(15).fontWeight(FontWeight.Bold).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
                    if (item.author) {
                      Text(item.author).fontSize(12).fontColor('#888').alignSelf(ItemAlign.Start).margin({ top: 2 })
                    }
                    Row() {
                      if (item.kind) { Text(item.kind).fontSize(9).fontColor('#0078D7').padding({left:3,right:3}).margin({right:4}).backgroundColor('#0078D71A').borderRadius(3) }
                      if (item.sourceCount > 1) {
                        Text(item.sourceCount + '源').fontSize(9).fontColor('#4CAF50').padding({left:3,right:3}).margin({right:4}).backgroundColor('#4CAF501A').borderRadius(3)
                      }
                      Text(item.origin).fontSize(9).fontColor('#AAA').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
                    }.margin({ top: 3 }).alignSelf(ItemAlign.Start)
                  }.layoutWeight(1).justifyContent(FlexAlign.Center).height(64)
                  Text('›').fontSize(18).fontColor('#CCC').margin({left:4})
                }.padding({ left: 12, right: 12, top: 10, bottom: 10 }).width('100%')
                .onClick(() => { this.goToBookInfo(item); })
              }.backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
              .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })
            })
          }.layoutWeight(1).width('100%')
          .backgroundColor(this.isDark ? '#121212' : '#F0F0F0')
        } else {
          Column() {
            Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
            Text('搜索你想看的书籍').fontSize(16).fontColor('#888').margin({ top: 8 })
            Text('已加载 ' + this.sources.length + ' 个书源').fontSize(12).fontColor('#AAA').margin({ top: 4 })
          }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
        }

        // 隐藏 WebView
        WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
      }.width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F0F0F0')
  }
}
