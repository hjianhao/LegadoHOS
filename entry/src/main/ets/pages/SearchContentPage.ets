/**
 * 书内搜索页 — 对标 Android SearchContentScreen
 */
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { AppDatabase } from '../data/database/AppDatabase';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ContentReplaceEngine } from '../engine/book/ContentReplace';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookChapter } from '../model/BookChapter';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { ChapterCache } from '../util/ChapterCache';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

interface ContentSearchResult {
  chapterIndex: number;
  chapterTitle: string;
  snippet: string;
  count: number;
  isCurrent: boolean;
}

@Entry
@Component
struct SearchContentPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State bookId: number = -1;
  @State bookName: string = '';
  @State bookUrl: string = '';
  @State originUrl: string = '';
  @State currentIndex: number = 0;
  @State keyword: string = '';
  @State results: ContentSearchResult[] = [];
  @State history: string[] = [];
  @State isSearching: boolean = false;
  @State processed: number = 0;
  @State total: number = 0;
  @State onlyThisBookHistory: boolean = true;
  @State replaceEnabled: boolean = false;
  @State regexEnabled: boolean = false;
  @State errorText: string = '';

  private chapters_: BookChapter[] = [];
  private source_: BookSource | null = null;
  private replaceEngine_: ContentReplaceEngine = new ContentReplaceEngine();
  private searchRunId_: number = 0;
  private debounceTimer_: number = -1;

  aboutToAppear(): void {
    this.initPage();
  }

  aboutToDisappear(): void {
    this.searchRunId_++;
    if (this.debounceTimer_ >= 0) {
      clearTimeout(this.debounceTimer_);
      this.debounceTimer_ = -1;
    }
  }

  private async initPage(): Promise<void> {
    const p = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    this.bookId = Number(p['bookId'] ?? -1);
    this.bookName = String(p['bookName'] || p['name'] || '');
    this.bookUrl = String(p['bookUrl'] || '');
    this.originUrl = String(p['originUrl'] || '');
    this.currentIndex = Number(p['currentIndex'] ?? p['durChapterIndex'] ?? 0);

    await this.loadChapters();
    await this.loadReplaceRules();
    await this.loadHistory();
  }

  private async loadChapters(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      if (this.bookId >= 0) {
        const table = new ChapterTable(AppDatabase.getInstance().rdbStore);
        this.chapters_ = await table.getChaptersByBookId(this.bookId);
      }
      if (this.originUrl) {
        const sourceTable = new BookSourceTable(AppDatabase.getInstance().rdbStore);
        this.source_ = await sourceTable.getSourceByUrl(this.originUrl);
      }
      if (this.chapters_.length === 0 && ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
        this.chapters_ = this.fromChapterCache(ChapterCache.chapters);
      }
      this.total = this.chapters_.length;
    } catch (e) {
      console.error('[SearchContent] loadChapters failed:', (e as Error).message);
      this.errorText = '章节列表加载失败';
    }
  }

  private fromChapterCache(chapters: BookSourceChapter[]): BookChapter[] {
    const list: BookChapter[] = [];
    for (let i = 0; i < chapters.length; i++) {
      const ch = chapters[i];
      list.push({
        id: 0,
        bookId: this.bookId,
        index: ch.index,
        volumeIndex: 0,
        title: ch.title,
        url: ch.url,
        content: '',
        contentLength: 0,
        isRead: false,
        isDownloaded: false,
        isCached: false,
        duration: 0,
        audioUrl: '',
        createTime: 0,
        updateTime: 0,
      });
    }
    return list;
  }

  private async loadReplaceRules(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const ruleTable = new ReplaceRuleTable(AppDatabase.getInstance().rdbStore);
      await this.replaceEngine_.loadRules(ruleTable);
    } catch (e) {
      console.warn('[SearchContent] replace rules unavailable:', (e as Error).message);
    }
  }

  private historyKey(): string {
    return this.onlyThisBookHistory ? `search_content_history_${this.bookId}` : 'search_content_history_global';
  }

  private async loadHistory(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      this.history = await store.get<string[]>(this.historyKey(), []);
    } catch (_e) {
      this.history = [];
    }
  }

  private async saveHistory(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      await store.put(this.historyKey(), this.history);
    } catch (_e) {
      /* ignore */
    }
  }

  private async addHistory(word: string): Promise<void> {
    const key = word.trim();
    if (!key) return;
    const list = [key];
    for (const item of this.history) {
      if (item !== key && list.length < 20) list.push(item);
    }
    this.history = list;
    await this.saveHistory();
  }

  private async clearHistory(): Promise<void> {
    this.history = [];
    await this.saveHistory();
  }

  private onQueryChanged(v: string): void {
    this.keyword = v;
    if (this.debounceTimer_ >= 0) clearTimeout(this.debounceTimer_);
    this.debounceTimer_ = setTimeout(() => {
      this.debounceTimer_ = -1;
      this.startSearch();
    }, 160);
  }

  private async startSearch(): Promise<void> {
    const key = this.keyword.trim();
    this.searchRunId_++;
    const runId = this.searchRunId_;
    this.results = [];
    this.processed = 0;
    this.errorText = '';
    if (!key) {
      this.isSearching = false;
      return;
    }

    let regex: RegExp | null = null;
    if (this.regexEnabled) {
      try {
        regex = new RegExp(key, 'gi');
      } catch (_e) {
        this.errorText = '正则表达式无效';
        this.isSearching = false;
        return;
      }
    }

    await this.addHistory(key);
    this.isSearching = true;
    const found: ContentSearchResult[] = [];
    for (let i = 0; i < this.chapters_.length; i++) {
      if (runId !== this.searchRunId_) return;
      const ch = this.chapters_[i];
      const title = ch.title || '';
      let content = ch.content || '';
      if (!content && this.source_ && ch.url) {
        content = await this.fetchAndCacheChapter(ch);
        if (runId !== this.searchRunId_) return;
      }
      if (this.replaceEnabled) {
        content = this.replaceEngine_.apply(content, this.originUrl, this.bookUrl);
      }
      const count = this.matchCount(`${title}\n${content}`, key, regex);
      if (count > 0) {
        found.push({
          chapterIndex: ch.index,
          chapterTitle: title || `第${ch.index + 1}章`,
          snippet: this.makeSnippet(content || title, key, regex),
          count,
          isCurrent: ch.index === this.currentIndex,
        });
      }
      this.processed = i + 1;
      if (found.length !== this.results.length) {
        this.results = [...found];
      }
      if (i % 32 === 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    }
    if (runId === this.searchRunId_) {
      this.results = found;
      this.isSearching = false;
    }
  }

  private async fetchAndCacheChapter(ch: BookChapter): Promise<string> {
    if (!this.source_) return '';
    try {
      const content = await globalSourceExecutor.getContent(this.source_, ch.url || this.bookUrl, this.bookUrl);
      if (!content || content.length <= 0) return '';
      if (this.bookId >= 0 && ch.id > 0) {
        ch.content = content;
        ch.contentLength = content.length;
        ch.isCached = content.length > 50;
        ch.updateTime = Date.now();
        const table = new ChapterTable(AppDatabase.getInstance().rdbStore);
        await table.updateChapter(ch);
      }
      return content;
    } catch (e) {
      console.warn('[SearchContent] fetch chapter failed:', ch.index, (e as Error).message);
      return '';
    }
  }

  private stopSearch(): void {
    this.searchRunId_++;
    this.isSearching = false;
    UiUtil.showToast(this.getUIContext(), { message: '已停止搜索', duration: 1200 });
  }

  private matchCount(text: string, key: string, regex: RegExp | null): number {
    if (!text || !key) return 0;
    if (regex) {
      let count = 0;
      const r = new RegExp(regex.source, regex.flags);
      let m: RegExpExecArray | null = r.exec(text);
      while (m !== null) {
        count++;
        if (m[0].length === 0) r.lastIndex++;
        m = r.exec(text);
      }
      return count;
    }
    const lowerText = text.toLowerCase();
    const lowerKey = key.toLowerCase();
    let count = 0;
    let pos = lowerText.indexOf(lowerKey);
    while (pos >= 0) {
      count++;
      pos = lowerText.indexOf(lowerKey, pos + Math.max(lowerKey.length, 1));
    }
    return count;
  }

  private makeSnippet(text: string, key: string, regex: RegExp | null): string {
    const source = text || '';
    if (!source) return '仅标题命中';
    let idx = -1;
    let len = key.length;
    if (regex) {
      const r = new RegExp(regex.source, regex.flags);
      const m = r.exec(source);
      if (m) {
        idx = m.index;
        len = m[0].length;
      }
    } else {
      idx = source.toLowerCase().indexOf(key.toLowerCase());
    }
    if (idx < 0) idx = 0;
    const start = Math.max(0, idx - 40);
    const end = Math.min(source.length, idx + len + 80);
    const prefix = start > 0 ? '...' : '';
    const suffix = end < source.length ? '...' : '';
    const rawBody = source.substring(start, end);
    const relStart = Math.max(0, idx - start);
    const relEnd = Math.min(rawBody.length, relStart + Math.max(len, 1));
    const body = (rawBody.substring(0, relStart) + '【' + rawBody.substring(relStart, relEnd) + '】' + rawBody.substring(relEnd))
      .replace(/\s+/g, ' ');
    return `${prefix}${body}${suffix}`;
  }

  private jumpToChapter(index: number): void {
    ChapterCache.targetIndex = index;
    if (ChapterCache.bookUrl !== this.bookUrl) {
      ChapterCache.bookUrl = this.bookUrl;
    }
    UiUtil.back(this.getUIContext(), { url: 'pages/ReadPage', params: { durChapterIndex: index } });
  }

  private jumpToCurrentResult(): void {
    if (this.results.length === 0) return;
    let target = this.results[0].chapterIndex;
    for (const item of this.results) {
      if (item.chapterIndex >= this.currentIndex) {
        target = item.chapterIndex;
        break;
      }
    }
    this.jumpToChapter(target);
  }

  private async toggleHistoryScope(): Promise<void> {
    this.onlyThisBookHistory = !this.onlyThisBookHistory;
    await this.loadHistory();
  }

  private async removeHistory(item: string): Promise<void> {
    this.history = this.history.filter(v => v !== item);
    await this.saveHistory();
  }

  private bgColor(): ResourceColor {
    return ThemeColors.background(this.isDark);
  }

  private surfaceColor(): ResourceColor {
    return ThemeColors.surface(this.isDark);
  }

  private textColor(): ResourceColor {
    return ThemeColors.onBackground(this.isDark);
  }

  private subTextColor(): ResourceColor {
    return ThemeColors.secondaryText(this.isDark);
  }

  @Builder
  private optionChip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(active ? '#FFFFFF' : this.textColor())
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(active ? '#0078D7' : (ThemeColors.surfaceVariant(this.isDark)))
      .borderRadius(16)
      .onClick(onTap)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Row() {
          Text('<')
            .fontSize(24)
            .fontColor(this.textColor())
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => { UiUtil.back(this.getUIContext()); })
          Column() {
            Text(this.bookName || '书内搜索')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.isSearching ? `${this.processed}/${this.total}` : `${this.results.length} 个结果`)
              .fontSize(11)
              .fontColor(this.subTextColor())
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button(this.isSearching ? '停止' : '搜索')
            .height(34)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.isSearching ? '#D64545' : '#0078D7')
            .onClick(() => {
              if (this.isSearching) this.stopSearch(); else this.startSearch();
            })
        }
        .height(56)
        .padding({ left: 8, right: 12 })
        .backgroundColor(this.surfaceColor())

        Row() {
          TextInput({ placeholder: '搜索章节内容', text: this.keyword })
            .height(42)
            .defaultFocus(true)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontSize(15)
            .fontColor(this.textColor())
            .placeholderColor(this.subTextColor())
            .padding({ left: 12 })
            .onChange((v: string) => { this.onQueryChanged(v); })
            .onSubmit(() => { this.startSearch(); })
          if (this.keyword) {
            Text('x')
              .fontSize(16)
              .fontColor(this.subTextColor())
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.keyword = '';
                this.results = [];
                this.errorText = '';
                this.searchRunId_++;
                this.isSearching = false;
              })
          }
        }
        .height(42)
        .margin({ left: 16, right: 16, top: 10 })
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .borderRadius(21)

        Row({ space: 8 }) {
          this.optionChip('替换', this.replaceEnabled, () => {
            this.replaceEnabled = !this.replaceEnabled;
            if (this.keyword.trim()) this.startSearch();
          })
          this.optionChip('正则', this.regexEnabled, () => {
            this.regexEnabled = !this.regexEnabled;
            if (this.keyword.trim()) this.startSearch();
          })
          this.optionChip(this.onlyThisBookHistory ? '本书历史' : '全部历史', true, () => {
            this.toggleHistoryScope();
          })
          if (this.history.length > 0 && !this.keyword) {
            Text('清空')
              .fontSize(13)
              .fontColor('#D64545')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .onClick(() => { this.clearHistory(); })
          }
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 8 })

        if (this.errorText) {
          Text(this.errorText)
            .fontSize(13)
            .fontColor('#D64545')
            .padding({ left: 18, right: 18, bottom: 8 })
        }

        if (!this.keyword && this.history.length > 0) {
          List() {
            ForEach(this.history, (item: string) => {
              ListItem() {
                Row() {
                  Text(item)
                    .fontSize(15)
                    .fontColor(this.textColor())
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('x')
                    .fontSize(14)
                    .fontColor(this.subTextColor())
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .onClick(() => { this.removeHistory(item); })
                }
                .height(48)
                .padding({ left: 18, right: 12 })
                .backgroundColor(this.surfaceColor())
                .onClick(() => {
                  this.keyword = item;
                  this.startSearch();
                })
              }
            }, (item: string) => item)
          }
          .divider({ strokeWidth: 0.5, color: ThemeColors.outlineVariant(this.isDark) })
          .layoutWeight(1)
        } else if (this.keyword && this.results.length === 0 && !this.isSearching) {
          Column() {
            Text(this.errorText ? '' : '没有找到匹配内容')
              .fontSize(15)
              .fontColor(this.subTextColor())
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.results, (item: ContentSearchResult) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(item.chapterTitle)
                      .fontSize(15)
                      .fontWeight(item.isCurrent ? FontWeight.Bold : FontWeight.Medium)
                      .fontColor(item.isCurrent ? '#0078D7' : this.textColor())
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${item.count}`)
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                      .backgroundColor(item.isCurrent ? '#0078D7' : '#88929C')
                      .borderRadius(10)
                  }
                  Text(item.snippet)
                    .fontSize(13)
                    .fontColor(this.subTextColor())
                    .lineHeight(20)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 6 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(this.surfaceColor())
                .onClick(() => { this.jumpToChapter(item.chapterIndex); })
              }
            }, (item: ContentSearchResult) => `${item.chapterIndex}_${item.count}_${item.chapterTitle}`)
          }
          .divider({ strokeWidth: 0.5, color: ThemeColors.outlineVariant(this.isDark) })
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.bgColor())

      if (this.results.length > 0) {
        Button('当前')
          .height(44)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#0078D7')
          .margin({ right: 18, bottom: 24 })
          .onClick(() => { this.jumpToCurrentResult(); })
      }
    }
    .width('100%')
    .height('100%')
  }
}
