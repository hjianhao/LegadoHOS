/**
 * 导出书籍/漫画对话框
 * - 显示目录/已缓存统计
 * - 缺失章节可选「下载后导出」或「仅导出已缓存」
 * - 可选包含章节标题、替换净化
 */
import { BookExportService, ExportBookInfo, ExportOptions } from '../service/BookExportService';
import { BookCacheService } from '../service/BookCacheService';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';

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
  /** 漫画使用内嵌图片 EPUB 或图片 ZIP 导出。 */
  isManga: boolean = false;

  onDismiss?: () => void;

  @State statsLoading: boolean = true;
  @State totalChapters: number = 0;
  @State cachedChapters: number = 0;
  /** 导出格式：txt / epub / comicZip */
  @State exportFormat: string = 'txt';
  /** 缺失章节策略：download = 下载后导出，cachedOnly = 仅导出已缓存 */
  @State missingMode: string = 'download';
  /** 是否将漫画 EPUB 分卷导出；默认开启，关闭后整本输出一个文件。 */
  @State splitEpub: boolean = true;
  /** 漫画 EPUB 拆分大小：每个文件包含的章节数，默认每 1 章一个文件。 */
  @State epubChapterSizeText: string = '1';
  @State includeTitle: boolean = true;
  @State useReplace: boolean = true;
  @State exporting: boolean = false;
  @State progressText: string = '';
  @State progressPercent: number = 0;
  @State resultMsg: string = '';
  @State showResult: boolean = false;

  aboutToAppear(): void {
    if (this.isManga) this.exportFormat = 'epub';
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
        Text('格式').fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).width(56)
        if (!this.isManga) {
          Radio({ value: 'txt', group: 'exportFormat' })
            .checked(this.exportFormat === 'txt')
            .onChange((checked: boolean) => { if (checked) this.exportFormat = 'txt'; })
          Text($r('app.string.ui_7475c2bd12')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .margin({ left: 6, right: 24 })
            .onClick(() => { this.exportFormat = 'txt'; })
        }
        Radio({ value: 'epub', group: 'exportFormat' })
          .checked(this.exportFormat === 'epub')
          .onChange((checked: boolean) => { if (checked) this.exportFormat = 'epub'; })
        Text(this.isManga ? '漫画 EPUB' : $r('app.string.ui_7f464ff72d'))
          .fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
          .margin({ left: 6, right: this.isManga ? 24 : 0 })
          .onClick(() => { this.exportFormat = 'epub'; })
        if (this.isManga) {
          Radio({ value: 'comicZip', group: 'exportFormat' })
            .checked(this.exportFormat === 'comicZip')
            .onChange((checked: boolean) => { if (checked) this.exportFormat = 'comicZip'; })
          Text('图片 ZIP').fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .margin({ left: 6 })
            .onClick(() => { this.exportFormat = 'comicZip'; })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })

      if (!this.statsLoading && this.totalChapters > 0 && this.cachedChapters < this.totalChapters) {
        this.buildModeOption('download', '下载缺失章节后导出')
        this.buildModeOption('cachedOnly', '仅导出已缓存章节（跳过 ' + (this.totalChapters - this.cachedChapters) + ' 章）')
      }

      if (this.isManga && this.exportFormat === 'epub') {
        this.buildSwitchRow('分卷导出', this.splitEpub, (v: boolean): void => { this.splitEpub = v; })
        if (this.splitEpub) {
          Row() {
            Text('每 N 章（卷）导出一个 EPUB')
              .fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
            TextInput({ text: this.epubChapterSizeText, placeholder: '1' })
              .width(72).height(40).fontSize(14)
              .type(InputType.Number)
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .onChange((value: string): void => { this.epubChapterSizeText = value; })
          }
          .width('100%').padding({ left: 16, right: 16, top: 2, bottom: 2 })
          Text('默认每 1 章一个文件；拆分为多个文件时请选择保存位置，文件名会自动添加序号。')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .padding({ left: 16, right: 16, bottom: 6 }).alignSelf(ItemAlign.Start)
        } else {
          Text('关闭后整本漫画导出为一个 EPUB 文件。')
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .padding({ left: 16, right: 16, bottom: 6 }).alignSelf(ItemAlign.Start)
        }
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
      isManga: this.isManga,
    };
    const isZip = this.exportFormat === 'comicZip';
    const isEpub = this.exportFormat === 'epub';
    const extension = isZip ? '.zip' : (isEpub ? '.epub' : '.txt');
    const fileName = BookExportService.suggestFileName(book, extension);
    const epubChapterSize = this.isManga && isEpub && this.splitEpub ? this.parseEpubChapterSize_() : 0;
    const shouldSplitEpub = this.isManga && isEpub && this.splitEpub &&
      epubChapterSize < Math.max(1, this.totalChapters);

    let uri = '';
    let overwriteExisting = false;
    let epubOutputUris: string[] | undefined;
    try {
      const context = this.getUIContext().getHostContext()!;
      if (shouldSplitEpub) {
        // 让 Picker 直接为每个分卷返回文件 URI。不要先保存临时文件再推导
        // 父目录：Picker 授权的是文件 URI，父目录和同级文件未必可由 fs.mkdir
        // 访问，尤其是 datashare/cloud 等文件提供方。
        const partCount = Math.ceil(Math.max(1, this.totalChapters) / epubChapterSize);
        const partNames: string[] = [];
        for (let i = 1; i <= partCount; i++) {
          partNames.push(BookExportService.suggestSplitFileName(book, extension, i));
        }
        const splitSaveOptions = new picker.DocumentSaveOptions();
        splitSaveOptions.newFileNames = partNames;
        // false 不预创建空文件，但返回的 URI 具备临时创建/删除权限，导出服务
        // 可以直接以 CREATE|WRITE_ONLY|TRUNC 打开，避免留下占位文件。
        splitSaveOptions.autoCreateEmptyFile = false;
        const uris = await new picker.DocumentViewPicker(context).save(splitSaveOptions);
        if (!uris || uris.length === 0) return;
        if (uris.length < partNames.length) {
          throw new Error('当前设备的文件选择器未返回完整的分卷文件位置，请关闭分卷导出后重试');
        }
        epubOutputUris = uris.slice(0, partNames.length);
        uri = epubOutputUris[0];
        const existingPartNames = partNames.filter((name: string, index: number): boolean =>
          this.fileExists_(epubOutputUris![index]));
        if (existingPartNames.length > 0) {
          const overwriteTarget = existingPartNames.length === 1
            ? existingPartNames[0] : '已有 ' + existingPartNames.length + ' 个分卷文件';
          const resultIndex = await this.confirmOverwrite_(overwriteTarget);
          if (resultIndex !== 1) return;
          overwriteExisting = true;
        }
      } else {
        const saveOptions = new picker.DocumentSaveOptions();
        saveOptions.newFileNames = [fileName];
        // 不让 Picker 先创建空文件，否则后续以 CREATE|TRUNC 打开时会被部分
        // 文件提供方误判为“重名文件”。文件由导出服务在确认后创建/截断。
        saveOptions.autoCreateEmptyFile = false;
        try {
          const uris = await new picker.DocumentViewPicker(context).save(saveOptions);
          if (!uris || uris.length === 0) return;
          uri = uris[0];
        } catch (e) {
          if (!this.isDuplicateFileError_(e)) throw e as Error;
          uri = await this.chooseOverwriteFile_(fileName);
          if (!uri) return;
          overwriteExisting = true;
        }

        // autoCreateEmptyFile=false 返回的 URI 既可能指向新文件，也可能指向
        // 已存在的文件；后者必须先取得用户明确的覆盖确认。
        if (!overwriteExisting && this.fileExists_(uri)) {
          const resultIndex = await this.confirmOverwrite_(fileName);
          if (resultIndex !== 1) return;
          overwriteExisting = true;
        }
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '选择保存位置失败：' + String(e), duration: 1800 });
      return;
    }

    this.exporting = true;
    this.progressText = '准备导出...';
    this.progressPercent = 0;

    const options: ExportOptions = {
      includeTitle: this.includeTitle,
      useReplace: this.useReplace,
      downloadMissing: this.missingMode === 'download',
      overwriteExisting: overwriteExisting,
      epubChapterSize: shouldSplitEpub ? epubChapterSize : undefined,
      epubSplitOutput: shouldSplitEpub,
      epubOutputUris: shouldSplitEpub ? epubOutputUris : undefined,
      context: UiUtil.getHostContext(this.getUIContext()),
      onProgress: (phase: 'download' | 'write', done: number, total: number, message: string): void => {
        this.progressPercent = Math.round((done / Math.max(1, total)) * 100);
        this.progressText = (phase === 'download' ? '下载章节 ' : '写入 ') + done + '/' + total + ': ' + message;
      },
    };
    const result = isZip
      ? await BookExportService.exportComicZip(book, uri, options)
      : (isEpub
        ? await BookExportService.exportBookEpub(book, uri, options)
        : await BookExportService.exportBookTxt(book, uri, options));

    this.exporting = false;
    this.showResult = true;
    if (result.success) {
      const fileCount = result.fileNames && result.fileNames.length > 1 ? result.fileNames.length : 1;
      const targetText = fileCount > 1
        ? '已导出 ' + result.exported + ' 章到 ' + fileCount + ' 个 EPUB 文件'
        : '已导出 ' + result.exported + ' 章到「' + result.fileName + '」';
      this.resultMsg = targetText
        + (result.exportedImages && result.exportedImages > 0 ? '（' + result.exportedImages + ' 张图片）' : '')
        + (result.skipped > 0 ? '\n跳过未缓存章节 ' + result.skipped + ' 章' : '');
    } else {
      this.resultMsg = '导出失败：' + (result.error || '未知错误');
    }
  }

  private parseEpubChapterSize_(): number {
    const value = parseInt(this.epubChapterSizeText.trim());
    if (!Number.isFinite(value) || value < 1) return 1;
    return Math.min(value, 99999);
  }

  /** 判断文件 URI 或路径是否已经对应一个文件。 */
  private fileExists_(uri: string): boolean {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      return true;
    } catch (_e) {
      return false;
    } finally {
      if (file) {
        try { fileIo.closeSync(file); } catch (_e) { /* ignore */ }
      }
    }
  }

  /** 对已存在的目标文件进行覆盖确认。 */
  private async confirmOverwrite_(fileName: string): Promise<number> {
    const result = await UiUtil.showDialog(this.getUIContext(), {
      title: '文件已存在',
      message: fileName + ' 已存在，是否覆盖原文件？',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '覆盖', color: ThemeColors.error(this.isDark) },
      ],
    });
    return result.index;
  }

  /** 文件选择器 save() 可能直接以“重名”失败，此时让用户选中要覆盖的原文件。 */
  private async chooseOverwriteFile_(fileName: string): Promise<string> {
    const resultIndex = await this.confirmOverwrite_(fileName);
    if (resultIndex !== 1) return '';
    try {
      const options = new picker.DocumentSelectOptions();
      const extension = fileName.substring(fileName.lastIndexOf('.'));
      if (extension && extension.length <= 12) options.fileSuffixFilters = [extension];
      options.maxSelectNumber = 1;
      const context = this.getUIContext().getHostContext()!;
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (!uris || uris.length === 0) return '';
      const selectedName = this.fileNameFromUri_(uris[0]);
      // datashare URI 在部分设备上不携带真实文件名，因此仅在能可靠解析时校验。
      if (selectedName && /\.[a-z0-9]{1,8}$/i.test(selectedName) && selectedName !== fileName) {
        UiUtil.showToast(this.getUIContext(), {
          message: '请选择同名文件：' + fileName, duration: 2200,
        });
        return '';
      }
      return uris[0];
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '选择覆盖文件失败：' + String(e), duration: 2200 });
      return '';
    }
  }

  /** 兼容不同设备对“文件已存在”错误的 code/message 表达。 */
  private isDuplicateFileError_(error: Error): boolean {
    const raw = error as Object as Record<string, Object>;
    const code = String(raw['code'] || raw['errorCode'] || '');
    const message = [
      error.message || '', String(raw['message'] || ''), String(raw['name'] || ''),
      String(raw['details'] || ''), String(error)
    ].join(' ');
    return code === '13900015' || /\b13900015\b/.test(message) ||
      /(already\s+exists|file\s+exists|same\s+name|duplicate|conflict|重名|同名|已存在)/i.test(message);
  }

  private fileNameFromUri_(uri: string): string {
    const withoutQuery = (uri || '').split(/[?#]/)[0];
    const rawName = withoutQuery.substring(withoutQuery.lastIndexOf('/') + 1);
    try {
      const decoded = decodeURIComponent(rawName);
      return decoded.substring(decoded.lastIndexOf('/') + 1);
    } catch (_e) {
      return rawName;
    }
  }

}
