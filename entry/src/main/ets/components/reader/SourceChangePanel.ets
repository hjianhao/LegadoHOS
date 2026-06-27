/**
 * 换源面板 — 与 ChangeSourceSheet 功能相同，但作为 @Component 嵌入
 * （而非 @CustomDialog，避免 CustomDialogController 生命周期问题）
 */
import { SearchResult, createSearchResult } from '../../model/SearchResult';
import { BookSource } from '../../model/BookSource';
import { AppDatabase } from '../../data/database/AppDatabase';
import { BookSourceTable } from '../../data/database/BookSourceTable';
import { globalSourceExecutor } from '../../engine/source/SourceExecutor';
import promptAction from '@ohos.promptAction';

@Component
export struct SourceChangePanel {
  @StorageLink('isDark') isDark: boolean = false;
  bookName: string = '';
  bookAuthor: string = '';
  currentOriginUrl: string = '';
  onReplace?: (result: SearchResult) => void;
  onDismiss?: () => void;

  @State keyword: string = '';
  @State results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State searchProgress: string = '';
  private initialized: boolean = false;

  aboutToAppear(): void {
    if (this.initialized) return;
    this.initialized = true;
    this.keyword = this.bookName;
    this.searchSources();
  }

  async searchSources(): Promise<void> {
    if (!this.keyword.trim()) return;
    this.isSearching = true;
    this.searchProgress = '';
    this.results = [];

    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const sources = await dao.getEnabledSources();
      const enabled: BookSource[] = [];
      for (const s of sources) {
        if (s.enabled && s.ruleSearchUrl) {
          enabled.push(s);
        }
      }
      if (enabled.length === 0) {
        promptAction.showToast({ message: '没有启用的书源', duration: 2000 });
        this.isSearching = false;
        return;
      }

      const rawResults = await globalSourceExecutor.search(
        this.keyword.trim(), enabled,
        (merged: SearchResult[], processed: number, total: number) => {
          this.searchProgress = '已搜 ' + processed + '/' + total + ' 个源';
        }
      );

      const targetName = this.bookName.replace(/\s/g, '');
      const filtered = rawResults.filter(r => {
        const rname = (r.name || '').replace(/\s/g, '');
        return rname && (rname === targetName || rname.includes(targetName) || targetName.includes(rname));
      });

      this.results = filtered.sort((a: SearchResult, b: SearchResult) => {
        let sa = 0, sb = 0;
        if (a.originUrl === this.currentOriginUrl) sa -= 1000;
        if (b.originUrl === this.currentOriginUrl) sb -= 1000;
        return sb - sa;
      });
    } catch (err) {
      console.error('[SourcePanel] search failed:', (err as Error).message);
    }
    this.isSearching = false;
    this.searchProgress = '';
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('更换书源').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A2E').layoutWeight(1)
        Button('✕').fontSize(16).fontColor(this.isDark ? '#AAA' : '#888')
          .backgroundColor('transparent').onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 16, right: 8, top: 12, bottom: 4 })

      // 搜索栏
      Row() {
        TextInput({ text: this.keyword, placeholder: '搜索书名' })
          .layoutWeight(1).height(36).fontSize(13)
          .borderRadius(18).backgroundColor(this.isDark ? '#444' : '#F5F5F5')
          .padding({ left: 12, right: 12 })
          .onChange((v: string) => { this.keyword = v; })
        Button('搜索').fontSize(13).height(36).width(56).margin({ left: 6 })
          .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
          .onClick(() => { this.searchSources(); })
        Button('刷新').fontSize(13).height(36).width(56).margin({ left: 4 })
          .backgroundColor(this.isDark ? '#555' : '#E0E0E0')
          .fontColor(this.isDark ? '#FFF' : '#333').borderRadius(18)
          .onClick(() => { this.searchSources(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 4 })

      if (this.searchProgress) {
        Text(this.searchProgress).fontSize(11).fontColor(this.isDark ? '#AAA' : '#999')
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }

      if (this.isSearching) {
        Column() {
          LoadingProgress().width(40).height(40).margin({ top: 30 })
          Text('搜索中...').fontSize(13).fontColor(this.isDark ? '#AAA' : '#999')
        }.width('100%').layoutWeight(1)
      } else if (this.results.length === 0) {
        Column() {
          Text('没有找到其他书源').fontSize(14).fontColor(this.isDark ? '#AAA' : '#999').margin({ top: 30 })
          Text('点击搜索或修改书名').fontSize(12).fontColor(this.isDark ? '#888' : '#CCC')
        }.width('100%').layoutWeight(1)
      } else {
        Scroll() {
          Column() {
            ForEach(this.results, (item: SearchResult) => {
              Column() {
                Row() {
                  Column() {
                    Text(item.name || '未知').fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(this.isDark ? '#E0E0E0' : '#333')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.author || '').fontSize(12).fontColor(this.isDark ? '#AAA' : '#888').margin({ top: 2 })
                    Row() {
                      Text(item.origin || '未知').fontSize(11)
                        .fontColor(item.originUrl === this.currentOriginUrl ? '#4CAF50' : '#0078D7')
                      if (item.wordCount) {
                        Text(' · ' + item.wordCount).fontSize(11).fontColor(this.isDark ? '#888' : '#AAA')
                      }
                    }.margin({ top: 2 })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  if (item.originUrl === this.currentOriginUrl) {
                    Text('当前').fontSize(11).fontColor('#4CAF50').margin({ left: 8 })
                  }
                }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }
              .width('100%')
              .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#EEE' })
              .onClick(() => {
                this.onReplace?.(item);
                this.onDismiss?.();
              })
            })
          }
        }.layoutWeight(1).width('100%')
      }
    }
    .width('100%').height('70%')
    .backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
