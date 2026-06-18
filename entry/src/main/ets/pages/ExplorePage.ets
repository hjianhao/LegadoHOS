import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { SearchResult, mergeSearchResults } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { searchBooks } from '../engine/search/SearchEngine';
import { WebViewFetchDialog } from './WebViewFetchDialog';
import { BookCover } from '../components/BookCover';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Component
export struct ExplorePage {
  @State keyword: string = '';
  @State isDark: boolean = false;
  @State results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State hasSearched: boolean = false;
  @State sources: BookSource[] = [];
  @State pendingWebViewUrl: string = '';
  @State searchProgress: string = '';
  @State searchUpdateTick: number = 0;

  webViewDialog: CustomDialogController = new CustomDialogController({
    builder: WebViewFetchDialog({
      fetchUrl: this.pendingWebViewUrl,
      onFetched: (content: string, url: string): void => {
        this.handleWebViewResult(content, url);
      }
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: true
  })

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.loadSources();
  }

  async loadSources(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      this.sources = await dao.getEnabledSources();
    } catch (_e) { /* ignore */ }
  }

  async doSearch(): Promise<void> {
    if (!this.keyword.trim()) { return; }
    console.info('[Explore] Searching:', this.keyword);
    this.isSearching = true;
    this.hasSearched = true;
    this.results = [];
    this.searchUpdateTick = 0;
    globalSourceExecutor.lastBlockedUrl = '';

    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      this.sources = await dao.getEnabledSources();
    } catch (_e) { /* ignore */ }

    const searchable = this.sources.filter(s => s.ruleSearchUrl);
    console.info('[Explore] Sources with URL:', searchable.length);
    if (searchable.length === 0) {
      console.warn('[Explore] No searchable sources');
      this.isSearching = false;
      return;
    }

    this.searchProgress = '正在搜索 ' + searchable.length + ' 个书源...';

    // 用共享数组 + setInterval 轮询的方式实现增量显示
    // setInterval 的回调在 ArkUI 中能正常触发 @State 更新
    const pendingResults: SearchResult[] = [];

    const searchPromise = globalSourceExecutor.search(this.keyword, searchable, (currentMerged) => {
      while (pendingResults.length > 0) pendingResults.pop();
      for (const r of currentMerged) pendingResults.push(r);
    });

    const pollTimer = setInterval(() => {
      if (pendingResults.length > 0) {
        this.results = pendingResults.slice();
      }
    }, 250);

    searchPromise.then((merged) => {
      clearInterval(pollTimer);
      console.info('[Explore] Search completed,', merged.length, 'merged results');
      this.results = merged;
      this.isSearching = false;
      this.searchProgress = '';

      if (merged.length === 0) {
        console.info('[Explore] No results, trying fallback SearchEngine');
        searchBooks(searchable, this.keyword).then((fallback) => {
          if (fallback.length > 0) {
            const fallbackMerged = mergeSearchResults(fallback);
            this.results = fallbackMerged;
            console.info('[Explore] Fallback got', fallbackMerged.length, 'merged results');
          }
        }).catch(() => {});
      }

      if (this.results.length === 0 && globalSourceExecutor.lastBlockedUrl) {
        console.info('[Explore] Cloudflare detected, offering WebView');
        this.pendingWebViewUrl = globalSourceExecutor.lastBlockedUrl;
      }
    }).catch(() => {
      clearInterval(pollTimer);
      this.isSearching = false;
      this.searchProgress = '';
    });
  }
  handleWebViewResult(content: string, url: string): void {
    if (content && content.length > 100) {
      // 简单取前几个结果
      const lines = content.split('\n').filter(l => l.trim().length > 0);
      const items: SearchResult[] = [];
      for (let i = 0; i < Math.min(lines.length, 50); i++) {
        const line = lines[i].trim();
        if (line.length < 2) continue;
        items.push({
          key: url + '|' + i,
          name: line.substring(0, 50),
          author: '',
          coverUrl: '',
          noteUrl: url,
          origin: 'WebView',
          originUrl: url,
          kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
          duration: 0, searchTime: Date.now(),
          sourceCount: 1,
          sourceOrigins: []
        });
      }
      if (items.length > 0) {
        this.results = items;
      }
    }
    this.pendingWebViewUrl = '';
  }

  tryWebViewFetch(): void {
    if (!this.pendingWebViewUrl) return;
    this.webViewDialog.open();
  }

  build() {
    Column() {
      Text('\uD83D\uDD0D 发现').fontSize(20).fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Start).padding(16)

      Row() {
        TextInput({ placeholder: '搜索书名或作者...', text: this.keyword })
          .height(44).backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
          .borderRadius(22).padding({ left: 20 }).layoutWeight(1)
          .onChange((v: string): void => { this.keyword = v; })
        Button('搜索').margin({ left: 8 }).fontSize(14)
          .onClick((): void => { this.doSearch(); })
      }.padding({ left: 12, right: 12 })

      if (this.isSearching) {
        Column() {
          LoadingProgress().color('#0078D7').margin({ top: 40 })
          Text('搜索中...').fontSize(14).fontColor('#888').margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.hasSearched && this.results.length === 0) {
        Column() {
          Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
          Text('没有找到结果').fontSize(16).fontColor('#888').margin({ top: 8 })
          if (this.pendingWebViewUrl) {
            Text('网站被 Cloudflare 保护，是否尝试用浏览器模式加载？')
              .fontSize(13).fontColor('#FF9800').margin({ top: 8 })
            Button('使用浏览器模式重试').margin({ top: 8 }).fontSize(13)
              .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
              .onClick((): void => { this.tryWebViewFetch(); })
          }
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.hasSearched) {
        if (this.isSearching && this.searchProgress) {
          Text(this.searchProgress + ' | 已合并 ' + this.results.length + ' 条').fontSize(12)
            .fontColor('#888').padding({ left: 16, top: 8 })
        } else {
          Text('找到 ' + this.results.length + ' 条结果').fontSize(12)
            .fontColor('#888').padding({ left: 16, top: 8 })
        }

        List() {
          ForEach(this.results, (item: SearchResult) => {
            ListItem() {
              Row() {
                // 封面
                BookCover({
                  name: item.name,
                  coverUrl: item.coverUrl,
                  coverWidth: 44,
                  coverHeight: 62
                }).margin({ right: 12 })

                Column() {
                  Text(item.name).fontSize(15).fontWeight(FontWeight.Bold)
                    .alignSelf(ItemAlign.Start).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.author || '未知作者').fontSize(12).fontColor('#888')
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  // 来源行：书源名 + 来源计数
                  Row() {
                    Text(item.origin).fontSize(11).fontColor('#AAA')
                    if (item.sourceCount > 1) {
                      Text(item.sourceCount + '个源').fontSize(10).fontColor('#FFF')
                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                        .backgroundColor('#5C6BC0').borderRadius(4)
                        .margin({ left: 4 })
                        .onClick(() => {
                          const sources = item.sourceOrigins.join(', ');
                          promptAction.showToast({
                            message: '来源: ' + sources,
                            duration: 3000
                          });
                        })
                    }
                  }.alignSelf(ItemAlign.Start).margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start).height(62)
                .justifyContent(FlexAlign.Center)
              }
              .padding(12).width('100%')
              .onClick((): void => {
                router.pushUrl({
                  url: 'pages/BookInfoPage',
                  params: {
                    name: item.name, author: item.author, coverUrl: item.coverUrl,
                    noteUrl: item.noteUrl, origin: item.origin, originUrl: item.originUrl,
                    introduce: item.introduce, kind: item.kind, wordCount: item.wordCount
                  }
                });
              })
            }
            .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
          })
        }.width('100%').layoutWeight(1).margin({ top: 4 })
      } else {
        Column() {
          Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
          Text('搜索你想看的书籍').fontSize(16).fontColor('#888').margin({ top: 8 })
          Text('已加载 ' + this.sources.length + ' 个书源').fontSize(12).fontColor('#888').margin({ top: 4 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
