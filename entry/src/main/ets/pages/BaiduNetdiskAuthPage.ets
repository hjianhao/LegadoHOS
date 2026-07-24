/**
 * 百度网盘 OAuth2 授权页
 *
 * Web 打开授权页 → 拦截 aireader://auth?code=...&state=...
 * → 换 Token → 写入 CloudCredentialStore → 保存来源 → 返回
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { AppDatabase } from '../data/database/AppDatabase';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import {
  BAIDU_DEFAULT_APP_KEY,
  BAIDU_DEFAULT_APP_SECRET,
  BAIDU_DEFAULT_REDIRECT_URI,
  BAIDU_NETDISK_ENDPOINT,
  CLOUD_PROVIDER_BAIDU_NETDISK,
  createDefaultBaiduNetdiskConfig,
  stringifyBaiduNetdiskConfig,
} from '../model/CloudSource';
import { BaiduNetdiskOAuthClient } from '../service/cloud/BaiduNetdiskOAuthClient';
import { CloudSourceRepository, CloudSourceSaveInput } from '../service/cloud/CloudSourceRepository';
import { ensureCloudProvidersRegistered } from '../service/cloud/CloudProviderBootstrap';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
struct BaiduNetdiskAuthPage {
  @StorageLink('isDark') isDark: boolean = false;

  @State authUrl: string = '';
  @State statusText: string = '正在打开授权页…';
  @State statusOk: boolean = false;
  @State isBusy: boolean = false;
  @State done: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private sourceId: number = 0;
  private name: string = '';
  private appKey: string = BAIDU_DEFAULT_APP_KEY;
  private appSecret: string = '';
  private redirectUri: string = BAIDU_DEFAULT_REDIRECT_URI;
  private rootPath: string = '';
  private sourceEnabled: boolean = true;
  private oauthState: string = '';
  private handledCode_: boolean = false;

  aboutToAppear(): void {
    this.bootstrap_();
  }

  private async bootstrap_(): Promise<void> {
    try {
      ensureCloudProvidersRegistered();
      await AppDatabase.getInstance().waitForInit();
      const ctx = this.getUIContext().getHostContext() as common.Context;
      if (ctx) {
        await SettingsStore.getInstance().init(ctx);
        await CloudCredentialStore.getInstance().init(ctx);
      } else if (!CloudCredentialStore.getInstance().isReady()) {
        throw new Error('Context 不可用，凭证存储未就绪');
      }

      const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
      if (params) {
        this.sourceId = this.readNum_(params['sourceId']);
        this.name = this.readStr_(params['name']) || '百度网盘';
        this.appKey = this.readStr_(params['appKey']) || BAIDU_DEFAULT_APP_KEY;
        this.appSecret = this.readStr_(params['appSecret']);
        this.redirectUri = this.readStr_(params['redirectUri']) || BAIDU_DEFAULT_REDIRECT_URI;
        this.rootPath = this.readStr_(params['rootPath']);
        if (params['enabled'] !== undefined) {
          this.sourceEnabled = !!params['enabled'];
        }
      }
      // 优先 AppStorage 传递的密钥（避免 router 编码问题）
      try {
        const pendingSecret = AppStorage.get<string>('baidu_oauth_pending_secret') || '';
        if (pendingSecret) {
          this.appSecret = pendingSecret;
        }
        const pendingKey = AppStorage.get<string>('baidu_oauth_pending_appkey') || '';
        if (pendingKey) {
          this.appKey = pendingKey;
        }
        const pendingRedirect = AppStorage.get<string>('baidu_oauth_pending_redirect') || '';
        if (pendingRedirect) {
          this.redirectUri = pendingRedirect;
        }
      } catch (_e) { /* ignore */ }
      if (!this.appKey) {
        this.appKey = BAIDU_DEFAULT_APP_KEY;
      }
      if (!this.appSecret && this.appKey === BAIDU_DEFAULT_APP_KEY) {
        this.appSecret = BAIDU_DEFAULT_APP_SECRET;
      }
      this.appKey = this.appKey.trim();
      this.appSecret = this.appSecret.trim();
      this.redirectUri = this.redirectUri.trim();
      if (!this.appKey) {
        throw new Error('AppKey 不能为空');
      }
      if (!this.appSecret) {
        throw new Error('AppSecret 不能为空');
      }
      if (!this.redirectUri) {
        throw new Error('回调 URI 不能为空');
      }

      this.oauthState = this.randomState_();
      const cfg = createDefaultBaiduNetdiskConfig();
      cfg.appKey = this.appKey;
      cfg.redirectUri = this.redirectUri;
      this.authUrl = BaiduNetdiskOAuthClient.buildAuthorizeUrl(cfg, this.oauthState);
      this.statusText = '请在下方完成百度账号登录与授权';
      this.statusOk = true;
      console.info('[BaiduAuth] open authorize appKeyLen=', this.appKey.length,
        ' secretLen=', this.appSecret.length, ' redirect=', this.redirectUri);
    } catch (e) {
      this.statusOk = false;
      this.statusText = (e as Error).message || '初始化失败';
      this.done = true;
    }
  }

  private readStr_(v: Object | undefined): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return String(v);
    }
    return '';
  }

  private readNum_(v: Object | undefined): number {
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      return parseInt(v as string, 10) || 0;
    }
    return 0;
  }

  private randomState_(): string {
    const t = Date.now().toString(36);
    const r = Math.floor(Math.random() * 1e9).toString(36);
    return t + r;
  }

  private isCallbackUrl_(url: string): boolean {
    const u = (url || '').trim();
    if (!u) {
      return false;
    }
    const redirect = (this.redirectUri || '').trim();
    if (!redirect) {
      return false;
    }
    // 完整 URI 前缀匹配（scheme://host/path）
    if (u.indexOf(redirect) === 0) {
      return true;
    }
    // 兼容 aireader://auth 与 aireader://auth/
    if (redirect.endsWith('/') && u.indexOf(redirect.substring(0, redirect.length - 1)) === 0) {
      return true;
    }
    return false;
  }

  private parseQuery_(url: string): Record<string, string> {
    const out: Record<string, string> = {};
    const qIdx = url.indexOf('?');
    if (qIdx < 0) {
      return out;
    }
    const q = url.substring(qIdx + 1);
    const hashIdx = q.indexOf('#');
    const query = hashIdx >= 0 ? q.substring(0, hashIdx) : q;
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      const eq = p.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const k = decodeURIComponent(p.substring(0, eq));
      let v = p.substring(eq + 1);
      try {
        v = decodeURIComponent(v);
      } catch (_e) { /* keep */ }
      out[k] = v;
    }
    return out;
  }

  private async onCallbackUrl_(url: string): Promise<void> {
    if (this.handledCode_ || this.isBusy) {
      return;
    }
    this.handledCode_ = true;
    this.isBusy = true;
    this.statusText = '正在换取授权…';
    this.statusOk = false;
    try {
      const q = this.parseQuery_(url);
      if (q['error']) {
        throw new Error(q['error_description'] || q['error'] || '用户拒绝授权');
      }
      const state = q['state'] || '';
      if (this.oauthState && state && state !== this.oauthState) {
        throw new Error('授权 state 不匹配，请重试');
      }
      const code = q['code'] || '';
      if (!code) {
        throw new Error('回调缺少授权码');
      }

      const cfg = createDefaultBaiduNetdiskConfig();
      cfg.appKey = this.appKey;
      cfg.redirectUri = this.redirectUri;
      console.info('[BaiduAuth] exchange start codeLen=', code.length,
        ' appKeyLen=', this.appKey.length, ' secretLen=', this.appSecret.length);
      const tokenResp = await BaiduNetdiskOAuthClient.exchangeCode(cfg, this.appSecret, code);
      const oauth = BaiduNetdiskOAuthClient.toOAuth2Credential(this.appSecret, tokenResp);
      // 清理暂存密钥
      try {
        AppStorage.setOrCreate<string>('baidu_oauth_pending_secret', '');
        AppStorage.setOrCreate<string>('baidu_oauth_pending_appkey', '');
        AppStorage.setOrCreate<string>('baidu_oauth_pending_redirect', '');
      } catch (_c) { /* ignore */ }

      const store = CloudCredentialStore.getInstance();
      let credentialRef = '';
      // 编辑：复用旧 ref
      if (this.sourceId > 0) {
        const repo = new CloudSourceRepository();
        const existing = await repo.getById(this.sourceId);
        if (existing && existing.credentialRef) {
          credentialRef = existing.credentialRef;
        }
      }
      if (!credentialRef) {
        credentialRef = store.generateCredentialRef();
      }
      await store.setOAuth2Credential(credentialRef, oauth);

      const input: CloudSourceSaveInput = {
        id: this.sourceId,
        name: this.name,
        providerType: CLOUD_PROVIDER_BAIDU_NETDISK,
        endpoint: BAIDU_NETDISK_ENDPOINT,
        rootPath: this.rootPath,
        configJson: stringifyBaiduNetdiskConfig(cfg),
        enabled: this.sourceEnabled,
        username: 'oauth2',
        secret: 'oauth2',
        updateSecret: true,
      };
      const repo = new CloudSourceRepository();
      const saved = await repo.saveBaiduAuthorized(input, credentialRef);
      this.statusOk = true;
      this.statusText = '授权成功，已保存来源 id=' + saved.id;
      this.done = true;
      UiUtil.showToast(this.getUIContext(), { message: '百度网盘授权成功', duration: 1500 });
      setTimeout(() => {
        // Auth ← Edit ← Manage：连退两层回到管理列表
        UiUtil.back(this.getUIContext());
        setTimeout(() => {
          UiUtil.back(this.getUIContext());
        }, 80);
      }, 400);
    } catch (e) {
      this.statusOk = false;
      this.statusText = BaiduNetdiskOAuthClient.sanitize_((e as Error).message || '授权失败');
      this.handledCode_ = false;
      this.done = false;
      UiUtil.showToast(this.getUIContext(), { message: this.statusText, duration: 2500 });
    } finally {
      this.isBusy = false;
    }
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('取消').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          UiUtil.back(this.getUIContext());
        })

        Text('百度网盘授权')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 8, bottom: 8 })

      if (this.statusText) {
        Text(this.statusText)
          .fontSize(13)
          .fontColor(this.statusOk ? ThemeColors.success(this.isDark) : ThemeColors.error(this.isDark))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.authUrl && !this.done) {
        Web({ src: this.authUrl, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onLoadIntercept((event) => {
            try {
              const url = event.data.getRequestUrl();
              if (this.isCallbackUrl_(url)) {
                this.onCallbackUrl_(url);
                return true; // 拦截，不真正导航到自定义 scheme
              }
            } catch (_e) { /* ignore */ }
            return false;
          })
      } else {
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
