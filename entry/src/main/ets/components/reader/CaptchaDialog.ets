/**
 * 验证码输入弹窗
 *
 * 当书源搜索需要验证码时（如雨忆文学网），弹出此窗口：
 * 1. 加载验证码图片（从 URL 请求）
 * 2. 用户输入验证码文字
 * 3. 将结果通过 captchaResolve 回调传回
 */
import { ThemeColors } from '../../theme/ThemeColors';
import { NetUtil } from '../../util/NetUtil';
import { image } from '@kit.ImageKit';

@CustomDialog
export struct CaptchaDialog {
  controller: CustomDialogController;
  captchaUrl: string = '';
  /** 通过应用 HTTP 栈（带 Cookie）预取的验证码图片；为空时退回 URL 加载 */
  captchaImage: image.PixelMap | null = null;
  /** 外部传入的 resolve 回调，在用户输入后调用 */
  captchaResolve: ((code: string) => void) | null = null;
  @StorageLink('isDark') isDark: boolean = false;
  @State code: string = '';
  @State imgFailed: boolean = false;
  @State imgLoading: boolean = true;
  @State displayImage: image.PixelMap | null = null;

  aboutToAppear(): void {
    this.displayImage = this.captchaImage;
    this.imgLoading = false;
  }

  /** 刷新验证码：必须走应用 HTTP 栈（带 Cookie），保持与提交同一会话 */
  private refreshImage(): void {
    this.imgFailed = false;
    this.imgLoading = true;
    const sep = this.captchaUrl.includes('?') ? '&' : '?';
    this.captchaUrl = this.captchaUrl.replace(/[?&]t=\d+/g, '') + sep + 't=' + Date.now();
    NetUtil.httpGetBinary(this.captchaUrl).then(async (buf: ArrayBuffer) => {
      try {
        this.displayImage = await image.createImageSource(buf).createPixelMap();
        this.imgFailed = false;
      } catch (_e) {
        this.displayImage = null;
        this.imgFailed = true;
      }
      this.imgLoading = false;
    }).catch((_e: Error) => {
      this.displayImage = null;
      this.imgFailed = true;
      this.imgLoading = false;
    });
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text('输入验证码')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button('刷新')
          .fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark))
          .height(36).padding({ left: 12, right: 12 })
          .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(18)
          .margin({ right: 8 })
          .onClick(() => {
            this.refreshImage();
          })
        Button($r('app.string.common_close'))
          .fontSize(13).fontColor(ThemeColors.onBackground(this.isDark))
          .height(36).padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.doClose(); })
      }
      .width('100%').height(48).padding({ left: 16, right: 8 })
      .backgroundColor(ThemeColors.surface(this.isDark))

      // 验证码图片
      Column() {
        if (this.imgFailed) {
          Column() {
            Text('验证码加载失败')
              .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
            Button('重新加载')
              .fontSize(13).fontColor(ThemeColors.primary(this.isDark))
              .backgroundColor(Color.Transparent).height(36)
              .onClick(() => {
                this.refreshImage();
              })
          }.alignItems(HorizontalAlign.Center)
        } else {
          Stack() {
            if (this.displayImage) {
              Image(this.displayImage)
                .width(200).height(70)
                .objectFit(ImageFit.Contain)
                .borderRadius(6)
            } else {
              Image(this.captchaUrl)
                .width(200).height(70)
                .objectFit(ImageFit.Contain)
                .borderRadius(6)
                .onComplete(() => { this.imgLoading = false; })
                .onError(() => {
                  this.imgLoading = false;
                  this.imgFailed = true;
                })
            }
            if (this.imgLoading) {
              LoadingProgress().color(ThemeColors.primary(this.isDark))
            }
          }
        }
      }
      .width('100%').height(100)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

      // 输入框
      TextInput({ placeholder: '请输入图片中的验证码', text: this.code })
        .width('80%').height(44)
        .fontSize(16).textAlign(TextAlign.Center)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(8)
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .caretColor(ThemeColors.primary(this.isDark))
        .maxLength(10)
        .onChange((v: string) => { this.code = v.trim(); })

      // 确认按钮
      Button('确认')
        .width('80%').height(44)
        .fontSize(16).fontColor(ThemeColors.onPrimary(this.isDark))
        .backgroundColor(this.code ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark))
        .borderRadius(22).margin({ top: 16, bottom: 20 })
        .enabled(!!this.code)
        .onClick(() => {
          if (this.code) {
            if (this.captchaResolve) {
              this.captchaResolve(this.code);
              this.captchaResolve = null;
            }
            this.controller.close();
          }
        })
    }
    .width('90%').constraintSize({ maxWidth: 400 })
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }

  doClose(): void {
    // 关闭时如果未确认，传空串
    if (this.captchaResolve) {
      this.captchaResolve('');
      this.captchaResolve = null;
    }
    this.controller.close();
  }
}
