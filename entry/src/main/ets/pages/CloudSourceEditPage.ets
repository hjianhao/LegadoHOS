/**
 * 云端书库 · 来源编辑页
 *
 * 字段随 providerType 适配：
 * - webdav: 服务器地址 / 用户名 / 密码 / 根目录
 * - localfolder: 目录命名空间 / 访问身份 / 可选口令 / 根目录
 * 保存前 testConnection + list(root)；失败不覆盖旧配置。
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import {
  CLOUD_PROVIDER_WEBDAV,
  cloudProviderDisplayName,
  isLocalFolderProvider,
  isWebDavProvider,
  listSupportedCloudProviderTypes,
} from '../model/CloudSource';
import {
  CloudSourceRepository,
  CloudSourceSaveInput,
  CloudSourceTestResult,
} from '../service/cloud/CloudSourceRepository';
import { CloudPath } from '../service/cloud/CloudPath';
import { ensureCloudProvidersRegistered } from '../service/cloud/CloudProviderBootstrap';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct CloudSourceEditPage {
  @StorageLink('isDark') isDark: boolean = false;

  @State name: string = '';
  @State providerType: string = CLOUD_PROVIDER_WEBDAV;
  @State endpoint: string = '';
  @State username: string = '';
  @State password: string = '';
  @State rootPath: string = '';
  @State sourceEnabled: boolean = true;
  @State previewUrl: string = '';
  @State statusText: string = '';
  @State statusOk: boolean = false;
  @State previewNames: string[] = [];
  @State isBusy: boolean = false;
  @State isEdit: boolean = false;
  @State passwordHint: string = '密码 / 应用专用密码';
  @State hasSavedPassword: boolean = false;
  @State providerOptions: string[] = listSupportedCloudProviderTypes();

  private sourceId: number = 0;
  private passwordDirty: boolean = false;

  aboutToAppear(): void {
    this.bootstrap_();
  }

  private async ensureStores_(): Promise<void> {
    ensureCloudProvidersRegistered();
    await AppDatabase.getInstance().waitForInit();
    const ctx = this.getUIContext().getHostContext() as common.Context;
    if (ctx) {
      await SettingsStore.getInstance().init(ctx);
      await CloudCredentialStore.getInstance().init(ctx);
    } else if (!CloudCredentialStore.getInstance().isReady()) {
      throw new Error('无法获取 Context，凭证存储未就绪');
    }
  }

  private async bootstrap_(): Promise<void> {
    try {
      await this.ensureStores_();

      const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
      let id = 0;
      if (params) {
        const raw = params['sourceId'];
        if (typeof raw === 'number') {
          id = raw as number;
        } else if (typeof raw === 'string') {
          id = parseInt(raw as string, 10) || 0;
        }
      }
      this.sourceId = id;
      this.isEdit = id > 0;

      if (this.isEdit) {
        const repo = new CloudSourceRepository();
        const source = await repo.getById(id);
        if (!source) {
          this.statusText = '来源不存在';
          this.statusOk = false;
          return;
        }
        this.name = source.name;
        this.providerType = source.providerType || CLOUD_PROVIDER_WEBDAV;
        this.endpoint = this.endpointForDisplay_(source.endpoint, this.providerType);
        this.rootPath = source.rootPath;
        this.sourceEnabled = source.enabled;
        const cred = await repo.getCredential(id);
        this.username = cred ? cred.username : '';
        this.password = '';
        this.passwordDirty = false;
        this.hasSavedPassword = !!(cred && cred.secret && cred.secret.length > 0);
        this.applyPasswordHint_();
        if (!this.hasSavedPassword && isWebDavProvider(this.providerType)) {
          this.statusText = '未找到已保存凭证，请重新填写用户名和密码后保存';
          this.statusOk = false;
        }
        if (!this.username && cred) {
          this.username = cred.username;
        }
        if (!this.username && isLocalFolderProvider(this.providerType)) {
          this.username = 'local';
        }
        this.refreshPreview_();
      } else {
        this.name = '';
        this.providerType = CLOUD_PROVIDER_WEBDAV;
        this.applyNewDefaultsForProvider_();
        this.sourceEnabled = true;
        this.passwordDirty = false;
        this.hasSavedPassword = false;
        this.applyPasswordHint_();
        this.refreshPreview_();
      }
    } catch (e) {
      this.statusText = (e as Error).message || '初始化失败';
      this.statusOk = false;
    }
  }

  /** 编辑展示：localfolder 只显示 namespace，webdav 原样 */
  private endpointForDisplay_(endpoint: string, type: string): string {
    const ep = (endpoint || '').trim();
    if (!isLocalFolderProvider(type)) {
      return ep;
    }
    const lower = ep.toLowerCase();
    if (lower.startsWith('localfolder://')) {
      return ep.substring('localfolder://'.length);
    }
    if (lower.startsWith('local://')) {
      return ep.substring('local://'.length);
    }
    return ep;
  }

  private applyNewDefaultsForProvider_(): void {
    if (isLocalFolderProvider(this.providerType)) {
      this.endpoint = 'demo';
      this.username = 'local';
      this.password = '';
      this.rootPath = '';
    } else {
      this.endpoint = 'https://dav.jianguoyun.com/dav/';
      this.username = '';
      this.password = '';
      this.rootPath = '';
    }
  }

  private applyPasswordHint_(): void {
    if (isLocalFolderProvider(this.providerType)) {
      if (this.hasSavedPassword) {
        this.passwordHint = '已保存口令（留空表示不修改；可空表示开放访问）';
      } else {
        this.passwordHint = '可选访问口令（留空=开放访问）';
      }
    } else {
      if (this.hasSavedPassword) {
        this.passwordHint = '已保存密码（留空表示不修改）';
      } else {
        this.passwordHint = '密码 / 应用专用密码';
      }
    }
  }

  private onProviderTypeChange_(type: string): void {
    if (this.isEdit) {
      // 编辑时不允许切换类型，避免凭证语义混乱
      return;
    }
    if (this.providerType === type) {
      return;
    }
    this.providerType = type;
    this.applyNewDefaultsForProvider_();
    this.applyPasswordHint_();
    this.refreshPreview_();
    this.statusText = '';
    this.previewNames = [];
  }

  private refreshPreview_(): void {
    try {
      if (isLocalFolderProvider(this.providerType)) {
        const ns = this.endpoint.trim() || 'demo';
        const root = this.rootPath.trim();
        this.previewUrl = 'localfolder://' + ns + (root ? ('/' + root) : '');
      } else {
        this.previewUrl = CloudPath.previewUrl(this.endpoint.trim(), this.rootPath.trim(), '');
      }
    } catch (_e) {
      this.previewUrl = '';
    }
  }

  private buildInput_(): CloudSourceSaveInput {
    let username = this.username.trim();
    if (isLocalFolderProvider(this.providerType) && !username) {
      username = 'local';
    }
    const input: CloudSourceSaveInput = {
      id: this.isEdit ? this.sourceId : 0,
      name: this.name.trim(),
      providerType: this.providerType || CLOUD_PROVIDER_WEBDAV,
      endpoint: this.endpoint.trim(),
      rootPath: this.rootPath.trim(),
      enabled: this.sourceEnabled,
      username: username,
      secret: this.password,
      updateSecret: this.isEdit ? this.passwordDirty : true,
    };
    return input;
  }

  private async onTest_(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.statusText = '正在测试连接…';
    this.statusOk = false;
    this.previewNames = [];
    try {
      await this.ensureStores_();
      if (isWebDavProvider(this.providerType)) {
        if (this.isEdit && !this.passwordDirty && !this.hasSavedPassword && !this.password) {
          throw new Error('请先填写密码');
        }
      }
      const repo = new CloudSourceRepository();
      const result: CloudSourceTestResult = await repo.testConnection(this.buildInput_());
      this.statusOk = result.ok;
      this.statusText = result.message;
      this.previewNames = result.previewNames.slice();
    } catch (e) {
      this.statusOk = false;
      this.statusText = (e as Error).message || '测试失败';
      this.previewNames = [];
    } finally {
      this.isBusy = false;
    }
  }

  private async onSave_(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    if (!this.name.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请填写名称', duration: 1500 });
      return;
    }
    if (!this.endpoint.trim()) {
      const tip = isLocalFolderProvider(this.providerType) ? '请填写目录命名空间' : '请填写服务器地址';
      UiUtil.showToast(this.getUIContext(), { message: tip, duration: 1500 });
      return;
    }
    if (isWebDavProvider(this.providerType)) {
      if (!this.username.trim()) {
        UiUtil.showToast(this.getUIContext(), { message: '请填写用户名', duration: 1500 });
        return;
      }
      if (!this.isEdit && !this.password) {
        UiUtil.showToast(this.getUIContext(), { message: '请填写密码', duration: 1500 });
        return;
      }
      if (this.isEdit && !this.hasSavedPassword && !this.password) {
        UiUtil.showToast(this.getUIContext(), { message: '请填写密码', duration: 1500 });
        return;
      }
    }

    this.isBusy = true;
    this.statusText = '正在校验连接并保存…';
    this.statusOk = false;
    try {
      await this.ensureStores_();
      try {
        CloudPath.normalizeRootPath(this.rootPath.trim());
      } catch (pe) {
        throw new Error('根目录非法: ' + ((pe as Error).message || ''));
      }

      const repo = new CloudSourceRepository();
      const saved = await repo.saveWithValidation(this.buildInput_());
      const cred = await repo.getCredential(saved.id);
      if (!cred || !cred.username || !cred.secret) {
        throw new Error('保存成功但凭证回读失败，请重试');
      }
      this.hasSavedPassword = true;
      this.passwordDirty = false;
      this.password = '';
      this.applyPasswordHint_();
      this.statusOk = true;
      this.statusText = '已保存（id=' + saved.id + '，类型=' +
        cloudProviderDisplayName(saved.providerType) + '）';
      UiUtil.showToast(this.getUIContext(), { message: '保存成功', duration: 1500 });
      setTimeout(() => {
        UiUtil.back(this.getUIContext());
      }, 400);
    } catch (e) {
      this.statusOk = false;
      this.statusText = (e as Error).message || '保存失败';
      UiUtil.showToast(this.getUIContext(), {
        message: this.statusText,
        duration: 2500,
      });
    } finally {
      this.isBusy = false;
    }
  }

  @Builder
  fieldLabel_(title: string, hint: string) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%')
      if (hint) {
        Text(hint)
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%')
          .margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 4 })
  }

  @Builder
  providerTypePicker_() {
    Column() {
      this.fieldLabel_('来源类型', this.isEdit ? '编辑时不可切换类型' : '决定连接协议与表单字段')
      Row() {
        ForEach(this.providerOptions, (t: string) => {
          Button(cloudProviderDisplayName(t))
            .fontSize(13)
            .height(34)
            .padding({ left: 12, right: 12 })
            .fontColor(this.providerType === t
              ? ThemeColors.onPrimary(this.isDark)
              : ThemeColors.primary(this.isDark))
            .backgroundColor(this.providerType === t
              ? ThemeColors.primary(this.isDark)
              : ThemeColors.outlineVariant(this.isDark))
            .enabled(!this.isEdit || this.providerType === t)
            .margin({ right: 8 })
            .onClick(() => {
              this.onProviderTypeChange_(t);
            })
        }, (t: string) => t)
      }
      .width('100%')
      .margin({ bottom: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          UiUtil.back(this.getUIContext());
        })

        Text(this.isEdit ? '编辑来源' : '新增来源')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
          .layoutWeight(1)

        Button(this.isBusy ? '…' : '保存')
          .fontSize(14)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark))
          .enabled(!this.isBusy)
          .onClick(() => {
            this.onSave_();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 8, bottom: 8 })

      Scroll() {
        Column() {
          this.fieldLabel_('名称', '')
          TextInput({ text: this.name, placeholder: isLocalFolderProvider(this.providerType)
            ? '例如：演示书库'
            : '例如：坚果云-书库' })
            .onChange((v: string) => {
              this.name = v;
            })
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .margin({ bottom: 12 })

          this.providerTypePicker_()

          if (isLocalFolderProvider(this.providerType)) {
            this.fieldLabel_('目录命名空间',
              '应用沙箱路径 files/cloud_local_folder/<命名空间>/，仅字母数字与下划线')
            TextInput({ text: this.endpoint, placeholder: '例如：demo' })
              .onChange((v: string) => {
                this.endpoint = v;
                this.refreshPreview_();
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })

            this.fieldLabel_('访问身份', '默认 local，一般无需修改')
            TextInput({ text: this.username, placeholder: 'local' })
              .onChange((v: string) => {
                this.username = v;
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })

            this.fieldLabel_('访问口令', this.passwordHint)
            TextInput({ text: this.password, placeholder: this.passwordHint })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.password = v;
                this.passwordDirty = true;
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })
          } else {
            this.fieldLabel_('服务器地址', 'WebDAV endpoint，不含根目录子路径')
            TextInput({ text: this.endpoint, placeholder: 'https://dav.jianguoyun.com/dav/' })
              .onChange((v: string) => {
                this.endpoint = v;
                this.refreshPreview_();
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })

            this.fieldLabel_('用户名', '')
            TextInput({ text: this.username, placeholder: '账号 / 邮箱' })
              .onChange((v: string) => {
                this.username = v;
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })

            this.fieldLabel_('密码', this.passwordHint)
            TextInput({ text: this.password, placeholder: this.passwordHint })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.password = v;
                this.passwordDirty = true;
              })
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ bottom: 12 })
          }

          this.fieldLabel_(
            '根目录',
            isLocalFolderProvider(this.providerType)
              ? '相对命名空间的子目录；留空表示命名空间根。不会自动创建。'
              : '进入此来源时直接显示该目录内容；留空表示服务器根目录。不会自动创建。'
          )
          TextInput({ text: this.rootPath, placeholder: '例如：LegadoBooks 或 Reading' })
            .onChange((v: string) => {
              this.rootPath = v;
              this.refreshPreview_();
            })
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .margin({ bottom: 8 })

          if (this.previewUrl) {
            Text((isLocalFolderProvider(this.providerType) ? '预览路径：' : '预览 URL：') +
              this.previewUrl)
              .fontSize(11)
              .fontColor(ThemeColors.secondaryText(this.isDark))
              .width('100%')
              .margin({ bottom: 12 })
          }

          Row() {
            Text('启用此来源')
              .fontSize(14)
              .fontColor(ThemeColors.onSurface(this.isDark))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.sourceEnabled })
              .selectedColor(ThemeColors.primary(this.isDark))
              .onChange((isOn: boolean) => {
                this.sourceEnabled = isOn;
              })
          }
          .width('100%')
          .margin({ bottom: 16 })

          if (isWebDavProvider(this.providerType) &&
            !this.endpoint.trim().toLowerCase().startsWith('https://') &&
            this.endpoint.trim().length > 0) {
            Text('当前地址未使用 HTTPS，凭证可能被明文传输，请确认风险。')
              .fontSize(12)
              .fontColor(ThemeColors.warning(this.isDark))
              .width('100%')
              .margin({ bottom: 12 })
          }

          if (isLocalFolderProvider(this.providerType)) {
            Text('本地演示目录用于验证 Provider 扩展：数据仅存应用沙箱，不经过网络。' +
              '可将书籍文件放入对应目录后在云端书库浏览下载。')
              .fontSize(12)
              .fontColor(ThemeColors.secondaryText(this.isDark))
              .width('100%')
              .margin({ bottom: 12 })
          }

          Button(this.isBusy ? '请稍候…' : '测试连接')
            .width('100%')
            .height(42)
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .fontColor(ThemeColors.primary(this.isDark))
            .enabled(!this.isBusy)
            .onClick(() => {
              this.onTest_();
            })
            .margin({ bottom: 12 })

          if (this.statusText) {
            Text(this.statusText)
              .fontSize(13)
              .fontColor(this.statusOk ? ThemeColors.success(this.isDark) : ThemeColors.error(this.isDark))
              .width('100%')
              .margin({ bottom: 8 })
          }

          if (this.previewNames.length > 0) {
            Text('根目录预览：')
              .fontSize(12)
              .fontColor(ThemeColors.secondaryText(this.isDark))
              .width('100%')
              .margin({ bottom: 4 })
            ForEach(this.previewNames, (n: string) => {
              Text('· ' + n)
                .fontSize(12)
                .fontColor(ThemeColors.onSurface(this.isDark))
                .width('100%')
                .margin({ bottom: 2 })
            }, (n: string) => n)
          }

          Text('保存时会再次测试连接并列举根目录；失败不会覆盖已有可用配置。')
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .width('100%')
            .margin({ top: 16, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
