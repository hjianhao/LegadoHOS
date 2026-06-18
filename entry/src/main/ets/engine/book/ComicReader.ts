/**
 * 漫画阅读器引擎 — 完整版
 *
 * 支持:
 * - 单页/双页/滚动模式
 * - 适应宽度/适应高度/原尺寸
 * - 预加载 + LRU 图片缓存
 * - 目录导航 + 进度保存
 * - 左右滑动 / 键盘翻页
 */
import { NetUtil } from '../../util/NetUtil';

export enum ComicPageMode {
  SINGLE = 'single',
  DOUBLE = 'double',
  SCROLL = 'scroll',
}

export enum ComicScaleMode {
  FIT_WIDTH = 'fit_width',
  FIT_HEIGHT = 'fit_height',
  ORIGINAL = 'original',
}

export interface ComicChapter {
  index: number;
  title: string;
  pages: string[];       // 图片 URL 列表
}

export class ComicReader {
  private chapters_: ComicChapter[] = [];
  private currentChapterIndex_: number = 0;
  private currentPageIndex_: number = 0;

  private pageMode_: ComicPageMode = ComicPageMode.SINGLE;
  private scaleMode_: ComicScaleMode = ComicScaleMode.FIT_WIDTH;

  // LRU 图片缓存 (最多 20 张)
  private imageCache_: Map<string, string> = new Map();
  private static MAX_CACHE = 20;

  // 预加载
  private preloadCount_: number = 4;

  // 回调
  private onPageChange_: ((chapter: number, page: number) => void) | null = null;
  private onChapterChange_: ((index: number) => void) | null = null;

  get chapters(): ComicChapter[] { return this.chapters_; }
  get currentChapterIndex(): number { return this.currentChapterIndex_; }
  get currentPageIndex(): number { return this.currentPageIndex_; }

  get currentChapter(): ComicChapter | null {
    return this.chapters_[this.currentChapterIndex_] || null;
  }

  get totalPages(): number {
    return this.currentChapter?.pages.length || 0;
  }

  get totalChapters(): number {
    return this.chapters_.length;
  }

  get progress(): number {
    if (this.totalChapters === 0) return 0;
    return (this.currentChapterIndex_ + this.currentPageIndex_ / Math.max(1, this.totalPages)) / this.totalChapters;
  }

  set onPageChange(cb: (chapter: number, page: number) => void) { this.onPageChange_ = cb; }
  set onChapterChange(cb: (index: number) => void) { this.onChapterChange_ = cb; }

  loadChapters(chapters: ComicChapter[]): void {
    this.chapters_ = chapters;
    this.currentChapterIndex_ = 0;
    this.currentPageIndex_ = 0;
    this.imageCache_.clear();
  }

  /**
   * 从书源数据解析漫画页面 URL
   */
  parsePagesFromUrl(sourceData: string): string[] {
    try {
      const parsed = JSON.parse(sourceData);
      if (Array.isArray(parsed)) {
        return parsed.filter((u: string) => {
          if (typeof u !== 'string') return false;
          const ext = u.split('?')[0].toLowerCase();
          return ext.endsWith('.jpg') || ext.endsWith('.jpeg')
            || ext.endsWith('.png') || ext.endsWith('.webp')
            || ext.endsWith('.gif') || ext.endsWith('.bmp')
            || !ext.match(/\.\w+$/);
        });
      }
    } catch { /* 不是 JSON */ }
    return [sourceData];
  }

  /**
   * 获取当前显示的页面 URL 列表（考虑双页模式）
   */
  getVisiblePages(): string[] {
    const chapter = this.currentChapter;
    if (!chapter || chapter.pages.length === 0) return [];

    if (this.pageMode_ === ComicPageMode.DOUBLE) {
      const pages: string[] = [chapter.pages[this.currentPageIndex_]];
      if (this.currentPageIndex_ + 1 < chapter.pages.length) {
        pages.push(chapter.pages[this.currentPageIndex_ + 1]);
      }
      return pages;
    }

    if (this.pageMode_ === ComicPageMode.SCROLL) {
      return chapter.pages;
    }

    return [chapter.pages[this.currentPageIndex_]];
  }

  /**
   * 获取需要预加载的 URL 列表
   */
  getPreloadUrls(): string[] {
    const chapter = this.currentChapter;
    if (!chapter) return [];

    const urls: string[] = [];
    const start = Math.max(0, this.currentPageIndex_ - this.preloadCount_);
    const end = Math.min(chapter.pages.length, this.currentPageIndex_ + this.preloadCount_ + 1);

    for (let i = start; i < end; i++) {
      if (!this.imageCache_.has(chapter.pages[i])) {
        urls.push(chapter.pages[i]);
      }
    }
    return urls;
  }

  /**
   * 缓存图片（下载后转 base64）
   */
  async cacheImage(url: string): Promise<string> {
    const cached = this.imageCache_.get(url);
    if (cached) return cached;

    try {
      const data = await NetUtil.httpGet(url);
      const base64 = this.arrayBufferToBase64(data);
      const mime = url.match(/\.(\w+)(?:\?|$)/)?.[1] || 'jpeg';
      const dataUrl = `data:image/${mime};base64,${base64}`;

      // LRU: 如果满了删除最早使用的
      if (this.imageCache_.size >= ComicReader.MAX_CACHE) {
        const firstKey = this.imageCache_.keys().next().value;
        if (firstKey) this.imageCache_.delete(firstKey);
      }
      this.imageCache_.set(url, dataUrl);
      return dataUrl;
    } catch {
      return url; // 无法缓存，返回原始 URL
    }
  }

  /**
   * 清除缓存
   */
  clearCache(): void {
    this.imageCache_.clear();
  }

  prevPage(): boolean {
    if (this.currentPageIndex_ > 0) {
      this.currentPageIndex_--;
      this.onPageChange_?.(this.currentChapterIndex_, this.currentPageIndex_);
      return true;
    }
    if (this.currentChapterIndex_ > 0) {
      this.currentChapterIndex_--;
      this.currentPageIndex_ = (this.currentChapter?.pages.length || 1) - 1;
      this.onChapterChange_?.(this.currentChapterIndex_);
      return true;
    }
    return false;
  }

  nextPage(): boolean {
    const max = this.totalPages;
    const step = this.pageMode_ === ComicPageMode.DOUBLE ? 2 : 1;

    if (this.currentPageIndex_ + step < max) {
      this.currentPageIndex_ += step;
      this.onPageChange_?.(this.currentChapterIndex_, this.currentPageIndex_);
      return true;
    }
    if (this.currentChapterIndex_ + 1 < this.chapters_.length) {
      this.currentChapterIndex_++;
      this.currentPageIndex_ = 0;
      this.onChapterChange_?.(this.currentChapterIndex_);
      return true;
    }
    return false;
  }

  goTo(chapterIndex: number, pageIndex: number): void {
    if (chapterIndex >= 0 && chapterIndex < this.chapters_.length) {
      this.currentChapterIndex_ = chapterIndex;
      const maxPage = this.currentChapter?.pages.length || 1;
      this.currentPageIndex_ = Math.min(pageIndex, maxPage - 1);
    }
  }

  setPageMode(mode: ComicPageMode): void { this.pageMode_ = mode; }
  setScaleMode(mode: ComicScaleMode): void { this.scaleMode_ = mode; }
  getPageMode(): ComicPageMode { return this.pageMode_; }
  getScaleMode(): ComicScaleMode { return this.scaleMode_; }

  private arrayBufferToBase64(data: string): string {
    try {
      return Buffer.from(data).toString('base64');
    } catch {
      // ArkTS 环境用 Base64 encode
      const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const bytes = new Uint8Array(data.split('').map(c => c.charCodeAt(0)));
      let result = '';
      for (let i = 0; i < bytes.length; i += 3) {
        const b0 = bytes[i], b1 = bytes[i + 1] || 0, b2 = bytes[i + 2] || 0;
        result += b64[b0 >> 2];
        result += b64[((b0 & 3) << 4) | (b1 >> 4)];
        result += (i + 1 < bytes.length) ? b64[((b1 & 0xF) << 2) | (b2 >> 6)] : '=';
        result += (i + 2 < bytes.length) ? b64[b2 & 0x3F] : '=';
      }
      return result;
    }
  }
}
