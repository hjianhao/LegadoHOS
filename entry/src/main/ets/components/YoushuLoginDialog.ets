/** 优书网账号登录。仅持久化 Cookie 会话，不保存账号和密码。 */
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import {
  YoushuBooklistService,
  YoushuLoginResult,
} from '../service/YoushuBooklistService';

@CustomDialog
export struct YoushuLoginDialog {
  controller: CustomDialogController;
  onLoginSuccess: () => void = (): void => {};

  @StorageLink('isDark') isDark: boolean = false;
  @State username: string = '';
  @State password: string = '';
  @State checkcode: string = '';
  @State captchaData: string = '';
  @State busy: boolean = false;
  @State captchaLoading: boolean = false;
  @State statusText: string = '';
  private isActive: boolean = false;
  private captchaRequestId: number = 0;
  private submitRequestId: number = 0;

  aboutToAppear(): void {
    this.isActive = true;
    // 清理旧版可能留下的明文凭据；新版只持久化 Cookie 会话。
    void YoushuBooklistService.forgetSavedLogin();
    void this.refreshCaptcha();
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.captchaRequestId++;
    this.submitRequestId++;
  }

  private async refreshCaptcha(): Promise<void> {
    if (this.captchaLoading) return;
    const runId = ++this.captchaRequestId;
    this.captchaLoading = true;
    this.checkcode = '';
    try {
      this.captchaData = await YoushuBooklistService.loadCaptcha();
      if (!this.isActive || runId !== this.captchaRequestId) return;
      this.statusText = '';
    } catch (e) {
      if (!this.isActive || runId !== this.captchaRequestId) return;
      this.statusText = '验证码加载失败：' + ((e as Error).message || '网络错误');
    } finally {
      if (this.isActive && runId === this.captchaRequestId) this.captchaLoading = false;
    }
  }

  private async submit(): Promise<void> {
    if (this.busy) return;
    if (!this.username.trim() || !this.password || !this.checkcode.trim()) {
      this.statusText = '请完整填写账号、密码和验证码';
      return;
    }
    this.busy = true;
    const runId = ++this.submitRequestId;
    this.statusText = '正在登录…';
    try {
      const result: YoushuLoginResult = await YoushuBooklistService.login(
        this.username.trim(), this.password, this.checkcode.trim());
      if (!this.isActive || runId !== this.submitRequestId) return;
      this.statusText = result.message;
      if (result.success) {
        UiUtil.showToast(this.getUIContext(), { message: result.message, duration: 1500 });
        this.onLoginSuccess();
        this.controller.close();
      } else {
        void this.refreshCaptcha();
      }
    } catch (e) {
      if (!this.isActive || runId !== this.submitRequestId) return;
      this.statusText = '登录失败：' + ((e as Error).message || '网络错误');
      void this.refreshCaptcha();
    } finally {
      if (this.isActive && runId === this.submitRequestId) this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column() {
      Row() {
        Text('登录优书网').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button('关闭').fontSize(13).height(44).padding({ left: 10, right: 10 })
          .fontColor(ThemeColors.onBackground(this.isDark)).backgroundColor(Color.Transparent)
          .onClick((): void => { this.controller.close(); })
      }.width('100%').margin({ bottom: 10 })

      TextInput({ placeholder: '用户名 / 邮箱', text: this.username })
        .type(InputType.Normal).width('100%').height(44).fontSize(14)
        .fontColor(ThemeColors.onSurface(this.isDark))
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(9)
        .onChange((value: string): void => { this.username = value; })

      TextInput({ placeholder: '密码', text: this.password })
        .type(InputType.Password).width('100%').height(44).fontSize(14).margin({ top: 10 })
        .fontColor(ThemeColors.onSurface(this.isDark))
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(9)
        .onChange((value: string): void => { this.password = value; })

      Row() {
        TextInput({ placeholder: '验证码', text: this.checkcode })
          .type(InputType.Normal).height(44).fontSize(14).layoutWeight(1)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(9)
          .onChange((value: string): void => { this.checkcode = value; })
        Stack() {
          if (this.captchaLoading) {
            LoadingProgress().width(22).height(22).color(ThemeColors.primary(this.isDark))
          } else if (this.captchaData) {
            Image(this.captchaData).width(92).height(40).objectFit(ImageFit.Contain)
          } else {
            Text('刷新').fontSize(12).fontColor(ThemeColors.primary(this.isDark))
          }
        }.width(100).height(44).margin({ left: 8 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(9)
          .accessibilityText('刷新验证码')
          .onClick((): void => { void this.refreshCaptcha(); })
      }.width('100%').margin({ top: 10 })

      if (this.statusText) {
        Text(this.statusText).width('100%').fontSize(12).margin({ top: 6 })
          .fontColor(this.statusText.includes('成功') || this.statusText.includes('删除') ?
            ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
      }

      Button(this.busy ? '登录中…' : '登录')
        .width('100%').height(44).margin({ top: 12 }).borderRadius(10)
        .fontColor(ThemeColors.onPrimary(this.isDark))
        .backgroundColor(ThemeColors.primary(this.isDark)).enabled(!this.busy)
        .onClick((): void => { void this.submit(); })

      Text('仅在本机保存 Cookie 登录会话，不保存账号和密码。')
        .width('100%').fontSize(11).margin({ top: 10 })
        .fontColor(ThemeColors.secondaryText(this.isDark))
      }.width('100%').padding(18)
    }
    .width('88%').constraintSize({ maxHeight: '90%' }).borderRadius(16)
    .scrollBar(BarState.Auto)
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
