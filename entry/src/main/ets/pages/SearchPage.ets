/**
 * 搜索页面
 */
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
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

  aboutToAppear(): void { this.loadSources(); }

  async loadSources(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.sources = await dao.getEnabledSources();
    } catch (_e) { /* ignore */ }
  }

  async doSearch(): Promise<void> {
    if (!this.keyword.trim()) return;
    this.isSearching = true; this.hasSearched = true;
    this.results = [];
    const searchable = this.sources.filter(s => s.ruleSearchUrl);
    if (searchable.length === 0) { this.isSearching = false; return; }
    this.progress = '正在搜索...';
    try {
      const merged = await globalSourceExecutor.search(this.keyword, searchable,
        (partial, done, total) => {
          this.results = partial;
          this.progress = '搜索中 ' + done + '/' + total;
        });
      this.results = merged;
    } catch (_e) { /* ignore */ }
    this.isSearching = false; this.progress = '';
  }

  goToBookInfo(item: SearchResult): void {
    router.pushUrl({ url: 'pages/BookInfoPage', params: {
      name: item.name, author: item.author, coverUrl: item.coverUrl,
      noteUrl: item.noteUrl, origin: item.origin, originUrl: item.originUrl,
      introduce: item.introduce || '', kind: item.kind || '',
      sourceOrigins: '[]', sourceUrls: '[]', sourceNoteUrls: '[]',
    }});
  }

  build() {
    Column() {
      Row() {
        Button('\u2190').fontSize(18).fontColor(this.isDark ? '#CCC' : '#666')
          .width(36).height(36).backgroundColor('transparent').onClick(() => { router.back(); })
        TextInput({ placeholder: '搜索书名或作者...', text: this.keyword })
          .height(40).layoutWeight(1).margin({ left: 8 })
          .backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
          .borderRadius(20).padding({ left: 16 })
          .onChange((v: string) => { this.keyword = v; })
        Button('搜索').width(56).height(40).fontSize(14)
          .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(20).margin({ left: 8 })
          .onClick(() => { this.doSearch(); })
      }.padding({ left: 12, right: 12, top: 44 }).width('100%')

      if (this.progress) {
        Text(this.progress + ' | ' + this.results.length + '条').fontSize(12)
          .fontColor(this.isDark ? '#AAA' : '#888').padding({ left: 16, top: 8 }).width('100%')
      }

      if (this.hasSearched && this.results.length === 0 && !this.isSearching) {
        Column() {
          Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
          Text('没有找到结果').fontSize(16).fontColor(this.isDark ? '#AAA' : '#888').margin({ top: 8 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else if (this.hasSearched) {
        List() {
          ForEach(this.results, (item: SearchResult) => {
            ListItem() {
              Row() {
                BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 44, coverHeight: 62 })
                  .margin({ right: 12 })
                Column() {
                  Text(item.name).fontSize(15).fontWeight(FontWeight.Bold).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
                  Text(item.author || '未知作者').fontSize(12).fontColor(this.isDark ? '#AAA' : '#888')
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  Text(item.origin).fontSize(11).fontColor('#AAA').alignSelf(ItemAlign.Start)
                }.layoutWeight(1).justifyContent(FlexAlign.Center).height(62)
              }.padding(12).width('100%')
              .onClick(() => { this.goToBookInfo(item); })
            }.border({ width: { bottom: 1 }, color: '#E8E8E8' })
          })
        }.layoutWeight(1).width('100%')
      } else {
        Column() {
          Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
          Text('搜索你想看的书籍').fontSize(16).fontColor('#888').margin({ top: 8 })
          Text('已加载 ' + this.sources.length + ' 个书源').fontSize(12).fontColor('#AAA').margin({ top: 4 })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
