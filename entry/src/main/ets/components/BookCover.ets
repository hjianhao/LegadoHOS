/**
 * 书籍封面组件
 * 支持网络封面、本地封面、加密封面解密
 */
import { NetUtil } from '../util/NetUtil';
import { CoverDecoder } from '../util/CoverDecoder';
import { ThemeColors } from '../theme/ThemeColors';
import { extractCoverUrl } from '../util/CoverUrlUtil';

/**
 * 防盗链封面通常需要先下载再转成 data URL。页面切换或列表重建时复用结果，
 * 避免同一张封面反复请求，也避免慢站点被并发请求进一步拖慢。
 */
class BookCoverMemoryCache {
  private static readonly MAX_ENTRIES: number = 40;
  private static readonly data_: Map<string, string> = new Map();

  static get(url: string): string {
    const dataUrl = BookCoverMemoryCache.data_.get(url) || '';
    if (dataUrl) {
      // 刷新插入顺序，作为轻量 LRU。
      BookCoverMemoryCache.data_.delete(url);
      BookCoverMemoryCache.data_.set(url, dataUrl);
    }
    return dataUrl;
  }

  static put(url: string, dataUrl: string): void {
    if (!url || !dataUrl) return;
    BookCoverMemoryCache.data_.delete(url);
    BookCoverMemoryCache.data_.set(url, dataUrl);
    while (BookCoverMemoryCache.data_.size > BookCoverMemoryCache.MAX_ENTRIES) {
      let firstKey: string = '';
      for (const key of BookCoverMemoryCache.data_.keys()) {
        firstKey = key;
        break;
      }
      if (!firstKey) break;
      BookCoverMemoryCache.data_.delete(firstKey);
    }
  }
}

@Component
export struct BookCover {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop name: string = '';
  @Prop @Watch('onCoverUrlChange') coverUrl: string = '';
  /** 搜索结果未提供封面时，用详情页地址延迟提取。 */
  @Prop fallbackUrl: string = '';
  @Prop coverWidth: number = 52;
  @Prop coverHeight: number = 70;
  /** 封面解密 JS 代码（标准 Legado coverDecodeJs 格式） */
  @Prop @Watch('onCoverDecodeJsChange') coverDecodeJs: string = '';
  @State imgFailed: boolean = false;
  @State useNetwork: boolean = false;
  @State isLocalFile: boolean = false;
  @State decryptedDataUrl: string = '';
  @State networkDataUrl: string = '';
  @State isDecoding: boolean = false;
  @State isLoadingFallback: boolean = false;
  private pageCoverTried_: boolean = false;

  aboutToAppear(): void {
    this.applyCoverUrl();
    this.restoreCachedNetworkCover_();
    console.info('[BookCover] init name=' + (this.name || '').substring(0, 10) + ' url=' +
      (this.coverUrl || '').substring(0, 50) + ' decode=' + (this.coverDecodeJs ? 'yes' : 'no'));

    if (!this.coverUrl && this.fallbackUrl) void this.loadPageCover_();

    // 有解密配置时，先下载解密再显示
    if (this.useNetwork && this.coverUrl && this.coverDecodeJs) {
      this.loadAndDecryptCover();
    }
  }

  /** 根据当前 coverUrl 重算展示方式（网络/本地/占位） */
  private applyCoverUrl(): void {
    const isNetwork = /^(https?:\/\/|\/\/|data:)/.test(this.coverUrl);
    this.isLocalFile = !!(this.coverUrl && !isNetwork && this.coverUrl.startsWith('file://'));
    if (!isNetwork && !this.isLocalFile) {
      this.coverUrl = '';
    }
    this.useNetwork = isNetwork;
  }

  /**
   * coverUrl 异步到达时（如详情页先以空封面渲染、随后从详情 HTML 提取到封面）
   * 重新计算展示方式，并复位失败状态让 Image 重新加载。
   */
  onCoverUrlChange(): void {
    this.applyCoverUrl();
    this.imgFailed = false;
    this.decryptedDataUrl = '';
    this.networkDataUrl = '';
    this.restoreCachedNetworkCover_();
    if (this.useNetwork && this.coverUrl && this.coverDecodeJs && !this.decryptedDataUrl && !this.isDecoding) {
      this.loadAndDecryptCover();
    }
    if (!this.coverUrl && this.fallbackUrl) void this.loadPageCover_();
  }

  private async loadPageCover_(): Promise<void> {
    if (this.pageCoverTried_ || !/^https?:\/\//i.test(this.fallbackUrl) || this.coverUrl) return;
    this.pageCoverTried_ = true;
    try {
      const html = await NetUtil.httpGet(this.fallbackUrl, this.coverRequestHeaders_(this.fallbackUrl));
      const url = extractCoverUrl(html, this.fallbackUrl);
      if (url && !this.coverUrl) {
        this.coverUrl = url;
        console.info('[BookCover] page cover extracted url=' + url.substring(0, 80));
      }
    } catch (e) {
      console.warn('[BookCover] page cover fallback failed url=' +
        this.fallbackUrl.substring(0, 80) + ' err=' + (e as Error).message);
    }
  }

  private restoreCachedNetworkCover_(): void {
    if (!this.coverDecodeJs && /^https?:\/\//i.test(this.coverUrl)) {
      this.networkDataUrl = BookCoverMemoryCache.get(this.coverUrl);
    }
  }

  /**
   * 当 coverDecodeJs 属性被外部更新时触发（如 BookInfoPage 异步加载书源后）
   */
  onCoverDecodeJsChange(): void {
    if (this.useNetwork && this.coverUrl && this.coverDecodeJs && !this.decryptedDataUrl && !this.isDecoding) {
      console.info('[BookCover] coverDecodeJs changed, starting decrypt');
      this.loadAndDecryptCover();
    }
  }

  /** 图片站常用来源校验；没有详情页上下文时，同站首页是最稳定的 Referer。 */
  private coverReferer_(url: string): string {
    const match = (url || '').match(/^(https?:\/\/[^/?#]+)/i);
    return match && match.length > 1 ? match[1] + '/' : '';
  }

  private coverRequestHeaders_(url: string): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Referer': this.coverReferer_(url)
    };
  }

  /**
   * ArkUI Image 不支持为普通网络图统一附加来源头。直接加载失败后，
   * 携带浏览器 UA 和同站 Referer 下载二进制，再转成 data URL 展示。
   */
  private async loadNetworkCoverFallback(): Promise<void> {
    if (this.isLoadingFallback || !/^https?:\/\//i.test(this.coverUrl)) return;
    const requestUrl = this.coverUrl;
    this.isLoadingFallback = true;
    try {
      const response = await NetUtil.httpGetBinary(
        requestUrl, this.coverRequestHeaders_(requestUrl), NetUtil.getDefaultTimeout());
      if (!response || response.byteLength < 32 || this.coverUrl !== requestUrl) return;
      const bytes = new Uint8Array(response);
      const mimeType = this.getImageMimeType(bytes);
      this.networkDataUrl = this.bytesToDataUrl(bytes, mimeType);
      BookCoverMemoryCache.put(requestUrl, this.networkDataUrl);
      this.imgFailed = false;
      console.info('[BookCover] protected cover fallback OK, size=' + bytes.length);
    } catch (e) {
      console.warn('[BookCover] protected cover fallback failed url=' +
        requestUrl.substring(0, 80) + ' err=' + (e as Error).message);
    } finally {
      this.isLoadingFallback = false;
    }
  }

  /**
   * 下载加密封面并用 coverDecodeJs 解密
   * 如果请求被取消（如 Image 组件冲突导致连接中断），自动重试一次
   */
  private async loadAndDecryptCover(): Promise<void> {
    this.isDecoding = true;
    this.imgFailed = false; // 清空上一次的失败状态
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const headers = this.coverRequestHeaders_(this.coverUrl);
        const response = await NetUtil.httpGetBinary(this.coverUrl, headers);
        if (!response || response.byteLength < 32) {
          console.warn('[BookCover] Encrypted cover download failed or too small');
          this.isDecoding = false;
          return;
        }

        const encryptedData = new Uint8Array(response);

        // 用 CoverDecoder 解密（正则匹配优先 + JS 兜底）
        const decrypted = await CoverDecoder.decrypt(encryptedData, this.coverDecodeJs, this.coverUrl);
        if (!decrypted || decrypted.length === 0) {
          console.warn('[BookCover] Cover decrypt returned empty');
          this.isDecoding = false;
          return;
        }

        // 转为 data URL 供 Image 组件显示
        const mimeType = this.getImageMimeType(decrypted);
        this.decryptedDataUrl = this.bytesToDataUrl(decrypted, mimeType);
        console.info('[BookCover] Cover decrypted OK, size=' + decrypted.length + ' type=' + mimeType);
        this.isDecoding = false;
        return; // 成功
      } catch (err) {
        const msg = (err as Error).message;
        console.warn('[BookCover] Cover decrypt attempt ' + (attempt + 1) + ' failed:', msg);
        if (attempt === 0 && msg.includes('cancel')) {
          // 请求被取消，等一帧让 ArkUI 完成渲染再重试
          await new Promise<void>((resolve: Function) => setTimeout(resolve, 100));
          continue;
        }
        break; // 非取消错误或已重试一次，不再重试
      }
    }
    this.isDecoding = false;
  }

  /** 根据魔数判断图片 MIME 类型 */
  private getImageMimeType(bytes: Uint8Array): string {
    if (bytes.length >= 4 && bytes[0] === 0x52 && bytes[1] === 0x49 &&
      bytes[2] === 0x46 && bytes[3] === 0x46) return 'image/webp';
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xD8) return 'image/jpeg';
    if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50) return 'image/png';
    if (bytes.length >= 2 && bytes[0] === 0x47 && bytes[1] === 0x49) return 'image/gif';
    return 'image/jpeg';
  }

  /** Uint8Array 转 data URL (base64) */
  private bytesToDataUrl(bytes: Uint8Array, mimeType: string): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    let base64 = '';
    for (let i = 0; i < binary.length; i += 3) {
      const a = binary.charCodeAt(i);
      const b = i + 1 < binary.length ? binary.charCodeAt(i + 1) : 0;
      const c = i + 2 < binary.length ? binary.charCodeAt(i + 2) : 0;
      const triple = (a << 16) | (b << 8) | c;
      base64 += chars.charAt((triple >> 18) & 0x3F);
      base64 += chars.charAt((triple >> 12) & 0x3F);
      base64 += i + 1 < binary.length ? chars.charAt((triple >> 6) & 0x3F) : '=';
      base64 += i + 2 < binary.length ? chars.charAt(triple & 0x3F) : '=';
    }
    return `data:${mimeType};base64,${base64}`;
  }

  build() {
    Stack() {
      // 降级色块
      Column() {
        Text(this.name ? Array.from(this.name)[0] : '?')
          .fontSize(this.coverWidth > 50 ? 22 : 18)
          .fontColor(ThemeColors.onPrimary(this.isDark)).fontWeight(FontWeight.Bold)
      }
      .width(this.coverWidth).height(this.coverHeight)
      .backgroundColor(this.getCoverColor(this.name))
      .borderRadius(6)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

      // 二进制下载后的封面（解密或防盗链回退）优先显示，不受 imgFailed 影响。
      if (this.decryptedDataUrl || this.networkDataUrl) {
        Image(this.decryptedDataUrl || this.networkDataUrl)
          .accessibilityText((this.name || '书籍') + '封面')
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] data img failed err=' + (err?.message || ''));
            this.imgFailed = true;
          })
      }

      // 网络封面（无解密时直接加载，或有解密但还在解码中时作为兜底）
      if (this.useNetwork && this.coverUrl && !this.imgFailed &&
        !this.decryptedDataUrl && !this.networkDataUrl) {
        Image(this.coverUrl)
          .accessibilityText((this.name || '书籍') + '封面')
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] img failed url=' + (this.coverUrl || '').substring(0, 50) + ' err=' + (err?.message || ''));
            this.imgFailed = true;
            if (!this.coverDecodeJs) void this.loadNetworkCoverFallback();
          })
      }

      // 本地封面
      if (this.isLocalFile && this.coverUrl && !this.imgFailed) {
        Image(this.coverUrl)
          .accessibilityText((this.name || '书籍') + '封面')
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] local img failed path=' + (this.coverUrl || '').substring(0, 50));
            this.imgFailed = true;
          })
      }
    }
    .width(this.coverWidth).height(this.coverHeight)
  }

  private getCoverColor(name: string): string {
    const colors = ThemeColors.coverPlaceholderPalette();
    if (!name) return colors[0];
    return colors[name.charCodeAt(0) % colors.length];
  }
}
