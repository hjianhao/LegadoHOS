/**
 * 聚合源登录弹窗
 * 调用 /login_api 获取 qttoken，存入 AppStorage
 */
import { ThemeColors } from '../../theme/ThemeColors';
import { NetUtil } from '../../util/NetUtil';
import { UiUtil } from '../../util/UiUtil';

@CustomDialog
export struct LoginDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State email: string = '';
  @State password: string = '';
  @State isLoading: boolean = false;
  @State statusText: string = '';
  host: string = 'https://v1.gyks.cf';

  build() {
    Column() {
      Text('登录光遇看书').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 20, bottom: 8 })
      Text('登录后可使用完整功能').fontSize(13)
        .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ bottom: 16 })

      TextInput({ placeholder: '邮箱', text: this.email })
        .type(InputType.Email)
        .width('100%').height(44).margin({ bottom: 12 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(8).fontSize(15)
        .onChange((v: string) => { this.email = v; })

      TextInput({ placeholder: '密码', text: this.password })
        .type(InputType.Password)
        .width('100%').height(44).margin({ bottom: 16 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(8).fontSize(15)
        .onChange((v: string) => { this.password = v; })

      if (this.statusText) {
        Text(this.statusText).fontSize(13)
          .fontColor(this.statusText.includes('成功') ? '#4CAF50' : ThemeColors.error(this.isDark))
          .margin({ bottom: 12 })
      }

      Row() {
        Button('取消').fontSize(14).fontColor(ThemeColors.onBackground(this.isDark))
          .height(40).layoutWeight(1)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
          .onClick(() => { this.controller.close(); })

        Button(this.isLoading ? '登录中...' : '登录').fontSize(14).fontColor('#FFF')
          .height(40).layoutWeight(1).margin({ left: 12 })
          .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(8)
          .enabled(!this.isLoading)
          .onClick(() => { this.doLogin(); })
      }.width('100%').margin({ bottom: 20 })
    }
    .width('80%').padding(20)
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }

  private async doLogin(): Promise<void> {
    if (!this.email || !this.password) {
      this.statusText = '请输入邮箱和密码';
      return;
    }
    if (!this.email.includes('@')) {
      this.statusText = '请输入正确的邮箱格式';
      return;
    }
    this.isLoading = true;
    this.statusText = '';
    try {
      const body = JSON.stringify({ register_email: this.email, password: this.password });
      const resp = await NetUtil.httpPost(`${this.host}/login_api`, body, {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0',
      }, 15000);
      const data = JSON.parse(resp) as Record<string, Object>;
      if (data['code'] === 0 && data['key']) {
        const token = data['key'] as string;
        AppStorage.setOrCreate<string>('gy_qttoken', token);
        this.statusText = '登录成功！';
        UiUtil.showToast(this.getUIContext(), { message: '登录成功', duration: 2000 });
        setTimeout(() => { this.controller.close(); }, 800);
      } else {
        this.statusText = (data['msg'] as string) || '登录失败';
      }
    } catch (e) {
      this.statusText = '网络错误：' + (e as Error).message;
    }
    this.isLoading = false;
  }
}
