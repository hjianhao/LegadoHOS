/**
 * 书籍封面组件
 * 支持网络封面、本地封面、加密封面解密
 */
import { NetUtil } from '../util/NetUtil';
import { CoverDecoder } from '../util/CoverDecoder';

@Component
export struct BookCover {
  @Prop name: string = '';
  @Prop coverUrl: string = '';
  @Prop coverWidth: number = 52;
  @Prop coverHeight: number = 70;
  /** 封面解密 JS 代码（标准 Legado coverDecodeJs 格式） */
  @Prop @Watch('onCoverDecodeJsChange') coverDecodeJs: string = '';
  @State imgFailed: boolean = false;
  @State useNetwork: boolean = false;
  @State isLocalFile: boolean = false;
  @State decryptedDataUrl: string = '';
  @State isDecoding: boolean = false;

  aboutToAppear(): void {
    const isNetwork = /^(https?:\/\/|\/\/|data:)/.test(this.coverUrl);
    this.isLocalFile = !!(this.coverUrl && !isNetwork && this.coverUrl.startsWith('file://'));
    if (!isNetwork && !this.isLocalFile) {
      this.coverUrl = '';
    }
    this.useNetwork = isNetwork;
    console.info('[BookCover] init name=' + (this.name || '').substring(0, 10) + ' url=' +
      (this.coverUrl || '').substring(0, 50) + ' decode=' + (this.coverDecodeJs ? 'yes' : 'no'));

    // 有解密配置时，先下载解密再显示
    if (isNetwork && this.coverUrl && this.coverDecodeJs) {
      this.loadAndDecryptCover();
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

  /**
   * 下载加密封面并用 coverDecodeJs 解密
   * 如果请求被取消（如 Image 组件冲突导致连接中断），自动重试一次
   */
  private async loadAndDecryptCover(): Promise<void> {
    this.isDecoding = true;
    this.imgFailed = false; // 清空上一次的失败状态
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const headers: Record<string, string> = {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'no-referrer'
        };
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
        Text(this.name ? this.name.charAt(0) : '?')
          .fontSize(this.coverWidth > 50 ? 22 : 18)
          .fontColor('#FFF').fontWeight(FontWeight.Bold)
      }
      .width(this.coverWidth).height(this.coverHeight)
      .backgroundColor(this.getCoverColor(this.name))
      .borderRadius(6)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

      // 解密后的封面（data URL）— 优先显示，不受 imgFailed 影响
      if (this.decryptedDataUrl) {
        Image(this.decryptedDataUrl)
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] decrypted img failed err=' + (err?.message || ''));
            this.imgFailed = true;
          })
      }

      // 网络封面（无解密时直接加载，或有解密但还在解码中时作为兜底）
      if (this.useNetwork && this.coverUrl && !this.imgFailed && !this.decryptedDataUrl) {
        Image(this.coverUrl)
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] img failed url=' + (this.coverUrl || '').substring(0, 50) + ' err=' + (err?.message || ''));
            this.imgFailed = true;
          })
      }

      // 本地封面
      if (this.isLocalFile && this.coverUrl && !this.imgFailed) {
        Image(this.coverUrl)
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
    const colors = ['#455A64', '#5C6BC0', '#26A69A', '#EC407A', '#AB47BC',
      '#42A5F5', '#66BB6A', '#FF7043', '#8D6E63', '#78909C', '#7E57C2', '#29B6F6'];
    if (!name) return colors[0];
    return colors[name.charCodeAt(0) % colors.length];
  }
}
