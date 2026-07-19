/**
 * AI 智能导入页面
 * 输入书籍目录页 URL → AI 分析 → 自动下载全书
 */
import { AiBookImporter, ImportProgress, isSafeAiImportUrl } from '../engine/ai/AiBookImporter';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { WebViewEngine } from '../components/WebViewEngine';
import { AppTitleBar } from '../components/common/AppTitleBar';
import { AiImportPreviewDialog, AiImportPreviewResult } from '../components/AiImportPreviewDialog';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { BookChapter } from '../model/BookChapter';

@Entry
@Component
struct AiImportBookPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State importMode: number = 0;
  @State searchKeyword: string = '';
  @State selectedSearchProvider: string = 'jiumo';
  @State url: string = '';
  @State isRunning: boolean = false;
  @State phase: string = '';
  @State progressText: string = '';
  @State progressCurrent: number = 0;
  @State progressTotal: number = 0;
  @State errorText: string = '';
  @State resultText: string = '';
  @State isUrlFocused: boolean = false;
  @State showPreview: boolean = false;
  @State previewUrl: string = '';
  @State showSearchBrowser: boolean = false;
  @State searchBrowserUrl: string = '';
  @State searchBrowserTitle: string = '';
  @State searchInitialScript: string = '';
  @State searchFallbackUrl: string = '';
  @State searchFallbackMessage: string = '';

  private importer_: AiBookImporter | null = null;
  private isActive_: boolean = false;

  aboutToAppear(): void {
    this.isActive_ = true;
    this.importer_ = new AiBookImporter((p: ImportProgress): void => {
      if (!this.isActive_) return;
      this.phase = p.phase;
      this.progressText = p.message;
      this.progressCurrent = p.current;
      this.progressTotal = p.total;
      if (p.phase === 'error') {
        this.errorText = p.message;
        this.isRunning = false;
      }
      if (p.phase === 'done') {
        this.resultText = p.message;
        this.isRunning = false;
      }
    });
  }

  aboutToDisappear(): void {
    this.isActive_ = false;
    this.importer_?.cancel();
  }

  private startImport(): void {
    const trimmed = this.url.trim();
    if (!trimmed) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书籍URL', duration: 1500 });
      return;
    }
    if (!isSafeAiImportUrl(trimmed)) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入有效的公网 HTTP(S) 小说目录页 URL', duration: 2000 });
      return;
    }
    this.previewUrl = trimmed;
    this.showPreview = true;
  }

  private providerName_(provider: string): string {
    switch (provider) {
      case 'jiumo': return '鸠摩搜书';
      case 'panda': return '熊猫搜书';
      case 'google': return 'Google';
      case 'bing': return '必应';
      default: return '在线搜索';
    }
  }

  private selectProvider_(provider: string): void {
    this.selectedSearchProvider = provider;
  }

  private openOnlineSearch_(): void {
    const keyword = this.searchKeyword.trim();
    if (!keyword) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书名', duration: 1500 });
      return;
    }
    const query = `"${keyword}" 小说 在线阅读 目录 -电视剧 -动漫 -漫画`;
    this.searchInitialScript = '';
    this.searchFallbackUrl = '';
    this.searchFallbackMessage = '';
    switch (this.selectedSearchProvider) {
      case 'jiumo':
        this.searchBrowserUrl = 'https://www.jiumodiary.com/?q=' + encodeURIComponent(keyword);
        this.searchFallbackUrl = 'https://cn.bing.com/search?q=' + encodeURIComponent(query);
        this.searchFallbackMessage = '鸠摩搜书当前无法访问，已自动切换到必应代搜。';
        break;
      case 'panda':
        this.searchBrowserUrl = 'https://xmsoushu.com/#book-search';
        this.searchInitialScript = this.buildPandaSearchScript_(keyword);
        this.searchFallbackUrl = 'https://cn.bing.com/search?q=' + encodeURIComponent(query);
        this.searchFallbackMessage = '熊猫搜书导航页加载失败，已自动切换到必应代搜。';
        break;
      case 'google':
        this.searchBrowserUrl = 'https://www.google.com/search?q=' + encodeURIComponent(query);
        break;
      case 'bing':
        this.searchBrowserUrl = 'https://cn.bing.com/search?q=' + encodeURIComponent(query);
        break;
      default:
        return;
    }
    this.searchBrowserTitle = this.providerName_(this.selectedSearchProvider) + ' · ' + keyword;
    this.showSearchBrowser = true;
  }

  /** 熊猫搜书是搜索导航页：选择可用的必应渠道后填入关键词并搜索。 */
  private buildPandaSearchScript_(keyword: string): string {
    const value = JSON.stringify(keyword);
    return `(function(){
      if(location.hostname.indexOf('xmsoushu.com')<0)return false;
      var tries=0;
      window.open=function(url){window.location.href=url;return window;};
      var timer=setInterval(function(){
        try {
          tries++;
          var input=document.querySelector('input[placeholder*="搜索"]');
          if(!input){if(tries>40)clearInterval(timer);return;}
          var buttons=Array.prototype.slice.call(document.querySelectorAll('button'));
          var provider=buttons.find(function(item){return item.textContent.indexOf('鸠摩搜书')>=0;});
          if(provider)provider.click();
          setTimeout(function(){
            var options=Array.prototype.slice.call(document.querySelectorAll('button'));
            var bing=options.find(function(item){return item.textContent.trim()==='必应';});
            if(bing)bing.click();
            setTimeout(function(){
              var target=document.querySelector('input[placeholder*="搜索"]') || input;
              var setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
              setter.call(target,${value});
              target.dispatchEvent(new Event('input',{bubbles:true}));
              setTimeout(function(){
                var form=target.closest('form');
                if(form){
                  if(form.requestSubmit){form.requestSubmit();}
                  else{form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));}
                }
              },300);
            },200);
          },200);
          clearInterval(timer);
        }catch(e){if(tries>40)clearInterval(timer);}
      },250);
      return true;
    })()`;
  }

  private isSearchLandingPage_(url: string): boolean {
    const lower = url.toLowerCase();
    if (lower.includes('google.') && lower.includes('/search')) return true;
    if (lower.includes('bing.com/search')) return true;
    if (lower.includes('xmsoushu.com')) return true;
    if (lower.includes('jiumodiary.com') &&
      (lower.includes('?q=') || lower.includes('searchword=') || /jiumodiary\.com\/?(?:#.*)?$/.test(lower))) return true;
    return false;
  }

  private confirmSearchResult_(result: AiImportPreviewResult): void {
    if (this.isSearchLandingPage_(result.url)) {
      UiUtil.showToast(this.getUIContext(), { message: '请先打开具体小说的详情页或目录页', duration: 2200 });
      return;
    }
    if (!isSafeAiImportUrl(result.url)) {
      UiUtil.showToast(this.getUIContext(), { message: '当前网页不可导入', duration: 1800 });
      return;
    }
    this.showSearchBrowser = false;
    this.url = result.url;
    void this.startConfirmedImport_(result.url, result.html);
  }

  private async startConfirmedImport_(url: string, previewHtml: string): Promise<void> {
    this.isRunning = true;
    this.errorText = '';
    this.resultText = '';

    try {
      if (!this.importer_) return;
      const ok = await this.importer_.init(UiUtil.getHostContext(this.getUIContext()));
      if (!ok) {
        this.errorText = '请先在"AI 配置"中设置 LLM API';
        this.isRunning = false;
        return;
      }
      const result = await this.importer_.import(url, previewHtml);
      this.resultText = `导入成功！已生成 ${result.chapterCount} 章目录`;
      this.isRunning = false;
      this.askBackgroundCache_(result.bookId, result.chapterCount);
    } catch (e) {
      this.errorText = '导入失败: ' + ((e as Error).message || '');
      this.isRunning = false;
    }
  }

  private askBackgroundCache_(bookId: number, chapterCount: number): void {
    UiUtil.showDialog(this.getUIContext(), {
      title: '目录导入完成',
      message: `已生成 ${chapterCount} 章目录。可以在阅读时按需加载，或现在开始后台缓存全书。`,
      buttons: [
        { text: '稍后缓存', color: ThemeColors.secondaryText(this.isDark) },
        { text: '立即后台缓存', color: ThemeColors.primary(this.isDark) }
      ]
    }).then((result): void => {
      if (result.index === 1) void this.startBackgroundCache_(bookId);
    });
  }

  private async startBackgroundCache_(bookId: number): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const book = await new BookTable(db).getBookById(bookId);
      if (!book) throw new Error('书籍不存在');
      const source = await BookSourceResolver.resolve(book);
      if (!source) throw new Error('AI 解析档案不可用');
      const chapters = await new ChapterTable(db).getChaptersByBookId(bookId);
      const items: CacheChapterItem[] = chapters.map((chapter: BookChapter): CacheChapterItem => ({
        index: chapter.index,
        title: chapter.title,
        url: chapter.url,
      }));
      this.resultText = `已在后台缓存《${book.name}》，可在离线缓存页查看进度`;
      const task = BookCacheService.getInstance().cacheBook({
        bookId: book.id,
        bookName: book.name,
        bookUrl: book.bookUrl,
        source: source,
        chapters: items,
        startIndex: 0,
        endIndex: Math.max(0, items.length - 1),
        context: UiUtil.getHostContext(this.getUIContext()),
      });
      task.catch((e: Error): void => {
        console.warn('[AiImport] background cache failed:', e.message);
      });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '启动后台缓存失败：' + (e as Error).message, duration: 2000 });
    }
  }

  private getPhaseLabel(): string {
    switch (this.phase) {
      case 'fetch': return '抓取页面';
      case 'analyze_toc': return '分析目录';
      case 'analyze_content': return '分析正文';
      case 'download': return '下载章节';
      case 'done': return '完成';
      case 'error': return '出错';
      default: return '';
    }
  }

  private getProgressPercent(): number {
    if (this.progressTotal <= 0) return 0;
    return Math.max(0, Math.min(100, this.progressCurrent / this.progressTotal * 100));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      AppTitleBar({
        title: $r('app.string.ui_d919c10f40'),
        onBack: () => { UiUtil.back(this.getUIContext()); }
      })

      Stack() {
        Scroll() {
          Column({ space: 16 }) {
            // 页面说明：先告诉用户需要什么链接，以及 AI 会做什么。
            Column({ space: 6 }) {
              Text(this.importMode === 0 ? '搜索并导入在线小说' : $r('app.string.ai_import_intro_title'))
                .width('100%')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(ThemeColors.onBackground(this.isDark))
              Text(this.importMode === 0 ?
                '输入书名，通过搜书引擎找到小说网页；进入详情页或目录页后确认导入。' :
                $r('app.string.ai_import_intro_desc'))
                .width('100%')
                .fontSize(14)
                .lineHeight(21)
                .fontColor(ThemeColors.secondaryText(this.isDark))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Row() {
              Button('搜索在线书')
                .layoutWeight(1).height(42).fontSize(14)
                .fontColor(this.importMode === 0 ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .backgroundColor(this.importMode === 0 ? ThemeColors.primary(this.isDark) : Color.Transparent)
                .borderRadius(21)
                .onClick((): void => { this.importMode = 0; })
              Button('粘贴网址')
                .layoutWeight(1).height(42).fontSize(14)
                .fontColor(this.importMode === 1 ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .backgroundColor(this.importMode === 1 ? ThemeColors.primary(this.isDark) : Color.Transparent)
                .borderRadius(21)
                .onClick((): void => { this.importMode = 1; })
            }
            .width('100%')
            .padding(3)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(24)

            if (this.importMode === 0) {
              Column({ space: 14 }) {
                Text('搜索书名')
                  .width('100%').fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onSurface(this.isDark))

                TextInput({ text: this.searchKeyword, placeholder: '输入小说名称' })
                  .width('100%').height(52).fontSize(16)
                  .fontColor(ThemeColors.onSurface(this.isDark))
                  .placeholderColor(ThemeColors.secondaryText(this.isDark))
                  .caretColor(ThemeColors.primary(this.isDark))
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                  .borderRadius(14)
                  .padding({ left: 14, right: 14 })
                  .onChange((value: string): void => { this.searchKeyword = value; })
                  .onSubmit((): void => { this.openOnlineSearch_(); })

                Text('选择搜索渠道')
                  .width('100%').fontSize(13)
                  .fontColor(ThemeColors.secondaryText(this.isDark))

                Row({ space: 8 }) {
                  this.SearchProviderButton_('jiumo', '鸠摩搜书')
                  this.SearchProviderButton_('panda', '熊猫搜书')
                }
                .width('100%')

                Row({ space: 8 }) {
                  this.SearchProviderButton_('google', 'Google')
                  this.SearchProviderButton_('bing', '必应')
                }
                .width('100%')

                Button('用 ' + this.providerName_(this.selectedSearchProvider) + ' 搜索')
                  .width('100%').height(48).borderRadius(24)
                  .fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onPrimary(this.isDark))
                  .backgroundColor(ThemeColors.primary(this.isDark))
                  .enabled(this.searchKeyword.trim().length > 0 && !this.isRunning)
                  .onClick((): void => { this.openOnlineSearch_(); })

                Text('搜索结果会在内置浏览器中打开。请进入具体小说详情页或目录页，再点击“导入当前页”。')
                  .width('100%').fontSize(12).lineHeight(18)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
              }
              .width('100%')
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(16)
              .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            }

            // URL 表单卡片
            if (this.importMode === 1) {
              Column({ space: 10 }) {
              Row() {
                Text($r('app.string.ai_import_url_label'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onSurface(this.isDark))
                Blank()
                Text($r('app.string.ai_import_required'))
                  .fontSize(12)
                  .fontColor(ThemeColors.primary(this.isDark))
              }
              .width('100%')

              TextArea({ text: this.url, placeholder: $r('app.string.ui_31450a8073') })
                .width('100%')
                .height(120)
                .fontSize(15)
                .fontColor(ThemeColors.onSurface(this.isDark))
                .placeholderColor(ThemeColors.secondaryText(this.isDark))
                .caretColor(ThemeColors.primary(this.isDark))
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                .borderRadius(12)
                .border({
                  width: this.isUrlFocused ? 2 : 1,
                  color: this.isUrlFocused ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark)
                })
                .padding(14)
                .onFocus(() => { this.isUrlFocused = true; })
                .onBlur(() => { this.isUrlFocused = false; })
                .onChange((v: string) => { this.url = v; })

              Text($r('app.string.ai_import_url_helper'))
                .width('100%')
                .fontSize(12)
                .lineHeight(18)
                .fontColor(ThemeColors.secondaryText(this.isDark))
              }
              .width('100%')
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(16)
              .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            }

            // LLM 配置入口使用完整点击卡片，点击区域不小于 48vp。
            Row({ space: 12 }) {
              Row() {
                Text('AI')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(ThemeColors.onPrimary(this.isDark))
              }
              .width(40)
              .height(40)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(ThemeColors.primary(this.isDark))
              .borderRadius(12)

              Column({ space: 3 }) {
                Text($r('app.string.ai_import_config_title'))
                  .width('100%')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onSurface(this.isDark))
                Text($r('app.string.ai_import_config_desc'))
                  .width('100%')
                  .fontSize(12)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(20)
                .fontColor([ThemeColors.secondaryText(this.isDark)])
            }
            .width('100%')
            .height(72)
            .padding({ left: 14, right: 14 })
            .backgroundColor(ThemeColors.surface(this.isDark))
            .borderRadius(16)
            .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/AiConfigPage' }); })

            if (this.importMode === 1) {
              Button() {
              Row({ space: 8 }) {
                if (this.isRunning) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(ThemeColors.onPrimary(this.isDark))
                }
                Text(this.isRunning ? $r('app.string.ai_import_running') : $r('app.string.ui_3d04880897'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onPrimary(this.isDark))
              }
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            .height(48)
            .borderRadius(24)
            .backgroundColor(ThemeColors.primary(this.isDark))
            .enabled(!this.isRunning && this.url.trim().length > 0)
            .accessibilityText($r('app.string.ui_3d04880897'))
              .onClick(() => { this.startImport(); })
            }

            if (this.isRunning || this.resultText || this.errorText) {
              Column({ space: 12 }) {
                if (this.isRunning) {
                  Row({ space: 10 }) {
                    LoadingProgress().width(24).height(24).color(ThemeColors.primary(this.isDark))
                    Column({ space: 3 }) {
                      Text(this.getPhaseLabel())
                        .width('100%')
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(ThemeColors.onSurface(this.isDark))
                      Text(this.progressText)
                        .width('100%')
                        .fontSize(12)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')

                  if (this.progressTotal > 0) {
                    Column({ space: 5 }) {
                      Row() {
                        Row()
                          .width(this.getProgressPercent() + '%')
                          .height(6)
                          .backgroundColor(ThemeColors.primary(this.isDark))
                          .borderRadius(3)
                      }
                      .width('100%')
                      .height(6)
                      .backgroundColor(ThemeColors.outlineVariant(this.isDark))
                      .borderRadius(3)
                      Text(`${this.progressCurrent} / ${this.progressTotal}`)
                        .width('100%')
                        .textAlign(TextAlign.End)
                        .fontSize(11)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                    }
                    .width('100%')
                  }
                }

                if (this.resultText) {
                  Text(this.resultText)
                    .width('100%')
                    .fontSize(14)
                    .lineHeight(21)
                    .fontColor(ThemeColors.success(this.isDark))
                }

                if (this.errorText) {
                  Text(this.errorText)
                    .width('100%')
                    .fontSize(14)
                    .lineHeight(21)
                    .fontColor(ThemeColors.error(this.isDark))
                }
              }
              .width('100%')
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(16)
              .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            }

            Column({ space: 8 }) {
              Text($r('app.string.ui_15683f6cd3'))
                .width('100%')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemeColors.onSurface(this.isDark))
              Text($r('app.string.ui_4db72f1b92'))
                .width('100%').fontSize(13).lineHeight(20).fontColor(ThemeColors.secondaryText(this.isDark))
              Text($r('app.string.ui_7f122bb1b0'))
                .width('100%').fontSize(13).lineHeight(20).fontColor(ThemeColors.secondaryText(this.isDark))
              Text($r('app.string.ui_e108a94b68'))
                .width('100%').fontSize(13).lineHeight(20).fontColor(ThemeColors.secondaryText(this.isDark))
            }
            .width('100%')
            .padding(16)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(16)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 20, bottom: 32 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 为 HTTP 空壳页、WAF 和 JS 渲染站点提供实际可用的回退抓取能力。
        WebViewEngine()
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))

      if (this.showPreview) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor(ThemeColors.scrim(this.isDark))
          AiImportPreviewDialog({
            initialUrl: this.previewUrl,
            onCancel: (): void => { this.showPreview = false; },
            onConfirm: (result: AiImportPreviewResult): void => {
              if (!isSafeAiImportUrl(result.url)) {
                UiUtil.showToast(this.getUIContext(), { message: '最终打开的网址不可导入', duration: 2000 });
                return;
              }
              this.url = result.url;
              void this.startConfirmedImport_(result.url, result.html);
            }
          })
        }
        .width('100%').height('100%')
      }

      if (this.showSearchBrowser) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor(ThemeColors.scrim(this.isDark))
          AiImportPreviewDialog({
            initialUrl: this.searchBrowserUrl,
            titleText: this.searchBrowserTitle,
            confirmText: '导入当前页',
            helperText: '先在搜索结果中进入小说详情页或目录页，再导入当前网页。',
            dismissBeforeConfirm: false,
            initialScript: this.searchInitialScript,
            fallbackUrl: this.searchFallbackUrl,
            fallbackMessage: this.searchFallbackMessage,
            onCancel: (): void => { this.showSearchBrowser = false; },
            onConfirm: (result: AiImportPreviewResult): void => { this.confirmSearchResult_(result); }
          })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  private SearchProviderButton_(provider: string, label: string) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(this.selectedSearchProvider === provider ?
        ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
      .backgroundColor(this.selectedSearchProvider === provider ?
        ThemeColors.surfaceVariant(this.isDark) : Color.Transparent)
      .border({
        width: 1,
        color: this.selectedSearchProvider === provider ?
          ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark)
      })
      .borderRadius(12)
      .onClick((): void => { this.selectProvider_(provider); })
  }
}
