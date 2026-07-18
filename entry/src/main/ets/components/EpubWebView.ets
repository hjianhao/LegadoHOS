/**
 * EPUB WebView 阅读器组件
 *
 * 使用 WebView + EPUB.js 渲染 EPUB 文件，
 * 支持分页、翻页、目录、字体/主题设置。
 *
 * 通信方式：
 *   ArkTS → JS: controller.runJavaScript('window.loadBook("path")')
 *   JS → ArkTS: controller.runJavaScript('window.pollEvent()') 轮询读取事件
 */
import web_webview from '@ohos.web.webview';
import fileFs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';

/** 目录条目 */
export interface TocItem {
  label: string;
  href: string;
}

/** 定位信息 */
export interface LocationInfo {
  cfi: string;
  chapterIndex: number;
  page: number;
  totalPages: number;
}

/** 元数据 */
export interface EpubMetaInfo {
  title: string;
  author: string;
}

/** 阅读器外部回调 */
export interface EpubReaderCallbacks {
  onReady?: () => void;
  onToc?: (toc: TocItem[]) => void;
  onLocation?: (loc: LocationInfo) => void;
  onMetadata?: (meta: EpubMetaInfo) => void;
}

@Component
export struct EpubWebView {
  /** EPUB 文件在沙箱中的绝对路径 */
  private epubPath: string = '';
  /** WebView 控制器 */
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  /** 外部回调 */
  private callbacks: EpubReaderCallbacks = {};
  /** 事件轮询定时器 */
  private pollTimer_: number | null = null;
  /** 主题配置 */
  @State private bgColor: string = ThemeColors.readingBackgroundDefault();
  @State private textColor: string = ThemeColors.readingTextDefault();
  @State private fontSize: number = 18;
  @State private fontFamily: string = "'PingFang SC', 'Noto Sans SC', serif";
  @State private lineHeight: number = 1.8;

  aboutToDisappear(): void {
    this.stopPoll_();
  }

  /** 加载 EPUB 文件 */
  loadEpub(path: string, callbacks?: EpubReaderCallbacks): void {
    this.epubPath = path;
    if (callbacks) this.callbacks = callbacks;
    this.prepareWebView_(path);
  }

  /** 下一页 */
  nextPage(): void {
    this.runJs_('window.nextPage()');
  }

  /** 上一页 */
  prevPage(): void {
    this.runJs_('window.prevPage()');
  }

  /** 跳转到 CFI */
  goTo(cfi: string): void {
    this.runJs_('window.goTo("' + cfi.replace(/"/g, '\\"') + '")');
  }

  /** 跳转到目录项 */
  goToHref(href: string): void {
    this.runJs_('window.goToHref("' + href.replace(/"/g, '\\"') + '")');
  }

  /** 设置主题 */
  setTheme(bg: string, color: string): void {
    this.bgColor = bg;
    this.textColor = color;
    this.runJs_('window.setTheme(' + JSON.stringify({ backgroundColor: bg, color: color }) + ')');
  }

  /** 设置字体 */
  setFont(size: number, family?: string, lineH?: number): void {
    this.fontSize = size;
    if (family) this.fontFamily = family;
    if (lineH) this.lineHeight = lineH;
    this.runJs_('window.setFont(' + JSON.stringify({
      fontSize: size, fontFamily: this.fontFamily, lineHeight: this.lineHeight
    }) + ')');
  }

  build() {
    Column() {
      Web({ src: '', controller: this.controller })
        .width('100%').height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .onPageEnd(() => {
          if (this.epubPath) {
            this.loadEpubInWebView_(this.epubPath);
          }
        })
    }
    .width('100%').height('100%')
  }

  // ==================== 内部方法 ====================

  private runJs_(code: string): void {
    try {
      this.controller.runJavaScript(code);
    } catch (_e) { /* WebView not ready */ }
  }

  /** 将 rawfile 资源复制到沙箱（WebView 需要同源才能访问 EPUB） */
  private async prepareWebView_(epubPath: string): Promise<void> {
    try {
      const context = globalThis.getContext() as Context;
      const filesDir = context.filesDir || '/data/storage/el2/base/haps/entry/files';
      const epubDir = filesDir + '/epub_web';

      if (!fileFs.accessSync(epubDir)) {
        fileFs.mkdirSync(epubDir, true);
      }

      // 复制文件到沙箱
      const filesToCopy = ['epub.min.js', 'bridge.js', 'epub-reader.html'];
      for (const f of filesToCopy) {
        const destPath = epubDir + '/' + f;
        if (!fileFs.accessSync(destPath)) {
          const content = context.resourceManager.getRawFileContentSync('epub/' + f);
          const destFile = fileFs.openSync(destPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
          fileFs.writeSync(destFile.fd, content.buffer as ArrayBuffer);
          fileFs.closeSync(destFile);
        }
      }

      // 加载 WebView
      this.controller.loadUrl('file://' + epubDir + '/epub-reader.html');
    } catch (e) {
      console.error('[EpubWebView] prepare error:', e);
    }
  }

  /** 在 WebView 中加载 EPUB */
  private loadEpubInWebView_(filePath: string): void {
    const jsPath = 'file://' + filePath;
    this.runJs_('window.loadBook("' + jsPath.replace(/"/g, '\\"') + '")');
    this.startPoll_();
    setTimeout(() => {
      this.setFont(this.fontSize, this.fontFamily, this.lineHeight);
    }, 500);
  }

  /** 启动事件轮询 */
  private startPoll_(): void {
    this.stopPoll_();
    this.pollTimer_ = setInterval(() => {
      try {
        this.controller.runJavaScript('window.pollEvent()', (err: BusinessError, result: string) => {
          if (result && result !== 'null') {
            try {
              const evt: Record<string, Object> = JSON.parse(result) as Record<string, Object>;
              this.handleEvent_(evt);
            } catch (_e) { /* ignore */ }
          }
        });
      } catch (_e) { /* ignore */ }
    }, 300);
  }

  private stopPoll_(): void {
    if (this.pollTimer_ !== null) {
      clearInterval(this.pollTimer_);
      this.pollTimer_ = null;
    }
  }

  private handleEvent_(evt: Record<string, Object>): void {
    try {
      const type: string = evt['type'] as string;
      const data: Object = evt['data'] as Object;
      switch (type) {
        case 'metadata':
          this.callbacks.onMetadata?.(data as EpubMetaInfo);
          break;
        case 'toc':
          this.callbacks.onToc?.(data as TocItem[]);
          break;
        case 'location':
          this.callbacks.onLocation?.(data as LocationInfo);
          break;
        case 'ready':
          this.callbacks.onReady?.();
          break;
      }
    } catch (_e) { /* ignore */ }
  }
}
