/**
 * 导出书籍对话框（TXT）
 * - 显示目录/已缓存统计
 * - 缺失章节可选「下载后导出」或「仅导出已缓存」
 * - 可选包含章节标题、替换净化
 */
import { BookExportService, ExportBookInfo, ExportOptions } from '../service/BookExportService';
import { BookCacheService } from '../service/BookCacheService';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import picker from '@ohos.file.picker';

@Component
export struct ExportBookDialog {
  @StorageLink('isDark') isDark: boolean = false;

  /** 外部传入的书籍信息 */
  bookId: number = 0;
  bookName: string = '';
  bookAuthor: string = '';
  introduce: string = '';
  bookCover: string = '';
  bookUrl: string = '';
  origin: string = '';
  originUrl: string = '';

  onDismiss?: () => void;

  @State statsLoading: boolean = true;
  @State totalChapters: number = 0;
  @State cachedChapters: number = 0;
  /** 导出格式：txt / epub */
  @State exportFormat: string = 'txt';
  /** 缺失章节策略：download = 下载后导出，cachedOnly = 仅导出已缓存 */
  @State missingMode: string = 'download';
  @State includeTitle: boolean = true;
  @State useReplace: boolean = true;
  @State exporting: boolean = false;
  @State progressText: string = '';
  @State progressPercent: number = 0;
  @State resultMsg: string = '';
  @State showResult: boolean = false;

  aboutToAppear(): void {
    this.loadStats();
  }

  private async loadStats(): Promise<void> {
    try {
      const stats = await BookExportService.getCacheStats(this.bookId);
      this.totalChapters = stats.total;
      this.cachedChapters = stats.cached;
    } catch (_e) {
      this.totalChapters = 0;
      this.cachedChapters = 0;
    }
    this.statsLoading = false;
  }

  build() {
    Column() {
      if (this.showResult) {
        this.buildResultPanel()
      } else if (this.exporting) {
        this.buildProgressPanel()
      } else {
        this.buildOptionPanel()
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 640, maxHeight: '92%' })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  buildOptionPanel() {
    Column() {
      Text($r('app.string.ui_a9bb68aec3')).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 4 }).alignSelf(ItemAlign.Start)

      Text(this.bookName)
        .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      Text(this.statsLoading
        ? '正在统计章节...'
        : '共 ' + this.totalChapters + ' 章 · 已缓存 ' + this.cachedChapters + ' 章').fontColor(ThemeColors.onSurface(this.isDark))
        .fontSize(13)
        .fontColor(this.totalChapters === 0 && !this.statsLoading
          ? ThemeColors.error(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      // 导出格式
      Row() {
        Text($r('app.string.ui_9d2601c843')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(80)
        Radio({ value: 'txt', group: 'exportFormat' })
          .checked(this.exportFormat === 'txt')
          .onChange((checked: boolean) => { if (checked) this.exportFormat = 'txt'; })
        Text($r('app.string.ui_7475c2bd12')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
          .margin({ left: 6, right: 24 })
          .onClick(() => { this.exportFormat = 'txt'; })
        Radio({ value: 'epub', group: 'exportFormat' })
          .checked(this.exportFormat === 'epub')
          .onChange((checked: boolean) => { if (checked) this.exportFormat = 'epub'; })
        Text($r('app.string.ui_7f464ff72d')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
          .margin({ left: 6 })
          .onClick(() => { this.exportFormat = 'epub'; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })

      if (!this.statsLoading && this.totalChapters > 0 && this.cachedChapters < this.totalChapters) {
        this.buildModeOption('download', '下载缺失章节后导出')
        this.buildModeOption('cachedOnly', '仅导出已缓存章节（跳过 ' + (this.totalChapters - this.cachedChapters) + ' 章）')
      }

      if (this.exportFormat === 'txt') {
        this.buildSwitchRow('包含章节标题', this.includeTitle, (v: boolean): void => { this.includeTitle = v; })
      }
      this.buildSwitchRow('替换净化', this.useReplace, (v: boolean): void => { this.useReplace = v; })

      Row() {
        Button($r('app.string.common_cancel')).fontSize(15).fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(Color.Transparent)
          .height(44).layoutWeight(1)
          .onClick(() => { this.onDismiss?.(); })
        Button($r('app.string.common_export')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(this.totalChapters > 0 ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark))
          .enabled(this.totalChapters > 0 && !this.statsLoading)
          .height(44).layoutWeight(1).borderRadius(0)
          .onClick(() => { this.startExport(); })
      }.width('100%').height(48).margin({ top: 8 })
    }
  }

  @Builder
  buildModeOption(value: string, label: string) {
    Row() {
      Radio({ value: value, group: 'exportMissingMode' })
        .checked(this.missingMode === value)
        .onChange((checked: boolean) => { if (checked) this.missingMode = value; })
      Text(label).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .onClick(() => { this.missingMode = value; })
  }

  @Builder
  buildSwitchRow(label: string, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .onChange((v: boolean) => { onChange(v); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  @Builder
  buildProgressPanel() {
    Column() {
      Text($r('app.string.ui_3d67f2697e')).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      Text(this.progressText)
        .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      Row() {
        Column().width(this.progressPercent + '%').height(6).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(3)
          .alignSelf(ItemAlign.Start)
      }.width('100%').height(6).backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(3)

      Row() {
        Button($r('app.string.common_cancel')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.error(this.isDark)).height(40).layoutWeight(1).margin({ right: 4 })
          .onClick(() => { this.cancelExport(); })
        Button($r('app.string.ui_d8478a3802')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark)).height(40).layoutWeight(1).margin({ left: 4 })
          .onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
  }

  @Builder
  buildResultPanel() {
    Column() {
      Text($r('app.string.ui_d733ad3e85')).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 8 }).alignSelf(ItemAlign.Start)

      Text(this.resultMsg)
        .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, bottom: 16 }).alignSelf(ItemAlign.Start)

      Row() {
        Button($r('app.string.common_done')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark))
          .height(48).width('100%').borderRadius(24)
          .onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
    }
  }

  private cancelExport(): void {
    // 仅取消下载阶段；写入阶段很快，等待完成即可
    BookCacheService.getInstance().cancel(this.bookId);
  }

  private async startExport(): Promise<void> {
    const book: ExportBookInfo = {
      id: this.bookId,
      name: this.bookName,
      author: this.bookAuthor,
      introduce: this.introduce,
      coverUrl: this.bookCover,
      bookUrl: this.bookUrl,
      origin: this.origin,
      originUrl: this.originUrl,
    };
    const isEpub = this.exportFormat === 'epub';
    const fileName = BookExportService.suggestFileName(book, isEpub ? '.epub' : '.txt');

    let uri = '';
    try {
      const context = this.getUIContext().getHostContext()!;
      const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [fileName] });
      if (!uris || uris.length === 0) return;
      uri = uris[0];
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '选择保存位置失败', duration: 1500 });
      return;
    }

    this.exporting = true;
    this.progressText = '准备导出...';
    this.progressPercent = 0;

    const options: ExportOptions = {
      includeTitle: this.includeTitle,
      useReplace: this.useReplace,
      downloadMissing: this.missingMode === 'download',
      context: UiUtil.getHostContext(this.getUIContext()),
      onProgress: (phase: 'download' | 'write', done: number, total: number, message: string): void => {
        this.progressPercent = Math.round((done / Math.max(1, total)) * 100);
        this.progressText = (phase === 'download' ? '下载章节 ' : '写入 ') + done + '/' + total + ': ' + message;
      },
    };
    const result = isEpub
      ? await BookExportService.exportBookEpub(book, uri, options)
      : await BookExportService.exportBookTxt(book, uri, options);

    this.exporting = false;
    this.showResult = true;
    if (result.success) {
      this.resultMsg = '已导出 ' + result.exported + ' 章到「' + result.fileName + '」'
        + (result.skipped > 0 ? '\n跳过未缓存章节 ' + result.skipped + ' 章' : '');
    } else {
      this.resultMsg = '导出失败：' + (result.error || '未知错误');
    }
  }
}
