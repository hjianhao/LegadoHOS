/**
 * 百度网盘 OAuth2 客户端
 *
 * - 授权码换 Token / Refresh Token
 * - 调用前自动刷新（距过期 < 5 分钟）
 * - Token 请求禁用 Cookie / 浏览器 UA，避免 WebView 登录态干扰
 * - 日志脱敏，不输出 token 明文
 */
import {
  BaiduNetdiskConfig,
  CloudSource,
  createEmptyOAuth2Credential,
  OAuth2Credential,
  parseBaiduNetdiskConfig,
} from '../../model/CloudSource';
import { CloudCredentialStore } from '../../data/preferences/CloudCredentialStore';
import { NetUtil } from '../../util/NetUtil';
import util from '@ohos.util';

const AUTH_BASE = 'https://openapi.baidu.com/oauth/2.0';
const REFRESH_SKEW_MS = 5 * 60 * 1000;

export interface BaiduTokenResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  scope: string;
}

export class BaiduNetdiskOAuthClient {
  static buildAuthorizeUrl(cfg: BaiduNetdiskConfig, state: string): string {
    const appKey = (cfg.appKey || '').trim();
    const redirect = (cfg.redirectUri || '').trim();
    // 授权页 scope：空格转逗号亦可；统一用空格编码
    let scope = (cfg.scope || 'basic netdisk').trim();
    if (scope.indexOf(',') >= 0 && scope.indexOf(' ') < 0) {
      scope = scope.replace(new RegExp(',', 'g'), ' ');
    }
    if (!appKey) {
      throw new Error('AppKey 不能为空');
    }
    if (!redirect) {
      throw new Error('回调 URI 不能为空');
    }
    return AUTH_BASE + '/authorize'
      + '?response_type=code'
      + '&client_id=' + encodeURIComponent(appKey)
      + '&redirect_uri=' + encodeURIComponent(redirect)
      + '&scope=' + encodeURIComponent(scope)
      + '&display=mobile'
      + '&state=' + encodeURIComponent(state || '');
  }

  static async exchangeCode(
    cfg: BaiduNetdiskConfig,
    clientSecret: string,
    code: string
  ): Promise<BaiduTokenResponse> {
    const appKey = (cfg.appKey || '').trim();
    const secret = BaiduNetdiskOAuthClient.normalizeSecret_(clientSecret);
    const redirect = (cfg.redirectUri || '').trim();
    const authCode = (code || '').trim();
    if (!appKey) {
      throw new Error('AppKey 不能为空');
    }
    if (!secret) {
      throw new Error('AppSecret 不能为空');
    }
    if (!authCode) {
      throw new Error('授权码为空');
    }
    if (!redirect) {
      throw new Error('回调 URI 不能为空');
    }
    console.info('[BaiduOAuth] exchange codeLen=', authCode.length,
      ' appKeyLen=', appKey.length, ' secretLen=', secret.length,
      ' redirect=', redirect);

    const body = 'grant_type=authorization_code'
      + '&code=' + encodeURIComponent(authCode)
      + '&client_id=' + encodeURIComponent(appKey)
      + '&client_secret=' + encodeURIComponent(secret)
      + '&redirect_uri=' + encodeURIComponent(redirect);

    // 1) 表单 body 认证（官方常用）
    try {
      const raw = await BaiduNetdiskOAuthClient.postToken_(body);
      return BaiduNetdiskOAuthClient.parseTokenResponse_(raw);
    } catch (e1) {
      const msg1 = (e1 as Error).message || '';
      // invalid_client 时再试 Basic 认证（部分应用类型要求）
      if (msg1.indexOf('invalid_client') >= 0 || msg1.indexOf('401') >= 0) {
        console.warn('[BaiduOAuth] form auth failed, try Basic:',
          BaiduNetdiskOAuthClient.sanitize_(msg1));
        try {
          const body2 = 'grant_type=authorization_code'
            + '&code=' + encodeURIComponent(authCode)
            + '&redirect_uri=' + encodeURIComponent(redirect);
          const raw2 = await BaiduNetdiskOAuthClient.postToken_(body2, appKey, secret);
          return BaiduNetdiskOAuthClient.parseTokenResponse_(raw2);
        } catch (e2) {
          throw BaiduNetdiskOAuthClient.wrapClientError_(e2 as Error, appKey, secret);
        }
      }
      throw BaiduNetdiskOAuthClient.wrapClientError_(e1 as Error, appKey, secret);
    }
  }

  static async refresh(
    cfg: BaiduNetdiskConfig,
    clientSecret: string,
    refreshToken: string
  ): Promise<BaiduTokenResponse> {
    const appKey = (cfg.appKey || '').trim();
    const secret = BaiduNetdiskOAuthClient.normalizeSecret_(clientSecret);
    const body = 'grant_type=refresh_token'
      + '&refresh_token=' + encodeURIComponent(refreshToken)
      + '&client_id=' + encodeURIComponent(appKey)
      + '&client_secret=' + encodeURIComponent(secret);
    const raw = await BaiduNetdiskOAuthClient.postToken_(body);
    return BaiduNetdiskOAuthClient.parseTokenResponse_(raw);
  }

  /**
   * Token 专用 POST：禁用 Cookie、使用非浏览器 UA，走系统 HTTP 栈（更贴近官方 curl）。
   */
  private static async postToken_(
    body: string,
    basicUser?: string,
    basicPass?: string
  ): Promise<string> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
      'User-Agent': 'LegadoHOS-BaiduOAuth/1.0',
      // 显式空 Cookie，阻止 NetUtil 注入 WebView 登录 Cookie
      'Cookie': '',
    };
    if (basicUser && basicPass) {
      const raw = basicUser + ':' + basicPass;
      const b64 = BaiduNetdiskOAuthClient.base64_(raw);
      headers['Authorization'] = 'Basic ' + b64;
    }
    // 优先系统 HTTP，避免 RCP 附加行为
    try {
      return await NetUtil.httpPostSystem(AUTH_BASE + '/token', body, headers, 30000);
    } catch (e) {
      console.warn('[BaiduOAuth] system POST failed, fallback RCP:',
        BaiduNetdiskOAuthClient.sanitize_((e as Error).message || ''));
      return await NetUtil.httpPost(AUTH_BASE + '/token', body, headers, 30000);
    }
  }

  private static base64_(text: string): string {
    const encoder = new util.TextEncoder();
    const bytes = encoder.encodeInto(text);
    // 简易 base64
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    const len = bytes.length;
    for (let i = 0; i < len; i += 3) {
      const a = bytes[i];
      const b = i + 1 < len ? bytes[i + 1] : 0;
      const c = i + 2 < len ? bytes[i + 2] : 0;
      const triple = (a << 16) | (b << 8) | c;
      out += chars[(triple >> 18) & 63];
      out += chars[(triple >> 12) & 63];
      out += i + 1 < len ? chars[(triple >> 6) & 63] : '=';
      out += i + 2 < len ? chars[triple & 63] : '=';
    }
    return out;
  }

  private static normalizeSecret_(secret: string): string {
    let s = (secret || '').trim();
    // 去除全角空格与零宽字符
    s = s.replace(new RegExp('[\u3000\u200b\u200c\u200d\ufeff]', 'g'), '');
    return s;
  }

  private static wrapClientError_(err: Error, appKey: string, secret: string): Error {
    const msg = err.message || String(err);
    if (msg.indexOf('invalid_client') >= 0 || msg.indexOf('Client authentication failed') >= 0) {
      return new Error(
        '百度应用凭证校验失败（invalid_client）。请到开放平台核对 AppKey/AppSecret 是否匹配、Secret 是否被重置；'
        + '当前 AppKey 长度=' + appKey.length + '，Secret 长度=' + secret.length
        + '。回调 URI 须与登记完全一致（默认 aireader://auth）。'
      );
    }
    return new Error(BaiduNetdiskOAuthClient.sanitize_(msg));
  }

  /**
   * 确保证件有效；必要时刷新并写回 store。
   * @returns 可用的 accessToken
   */
  static async ensureAccessToken(
    source: CloudSource,
    credentialRef: string
  ): Promise<string> {
    const store = CloudCredentialStore.getInstance();
    if (!store.isReady()) {
      throw new Error('凭证存储未就绪');
    }
    const ref = (credentialRef || source.credentialRef || '').trim();
    if (!ref) {
      throw new Error('缺少凭证引用，请先完成授权');
    }
    let oauth = await store.getOAuth2Credential(ref);
    if (!oauth || !oauth.accessToken) {
      throw new Error('未授权百度网盘，请先登录授权');
    }
    const now = Date.now();
    if (oauth.accessTokenExpiresAt > 0 && oauth.accessTokenExpiresAt - now > REFRESH_SKEW_MS) {
      return oauth.accessToken;
    }
    if (!oauth.refreshToken) {
      throw new Error('Access Token 已过期且无 Refresh Token，请重新授权');
    }
    const cfg = parseBaiduNetdiskConfig(source.configJson || '{}');
    try {
      console.info('[BaiduOAuth] refreshing token for', source.name || source.id);
      const resp = await BaiduNetdiskOAuthClient.refresh(cfg, oauth.clientSecret, oauth.refreshToken);
      const next = createEmptyOAuth2Credential();
      next.clientSecret = oauth.clientSecret;
      next.accessToken = resp.accessToken;
      next.refreshToken = resp.refreshToken || oauth.refreshToken;
      next.accessTokenExpiresAt = Date.now() + Math.max(60, resp.expiresIn) * 1000;
      next.tokenScope = resp.scope || oauth.tokenScope;
      await store.setOAuth2Credential(ref, next);
      return next.accessToken;
    } catch (e) {
      const msg = (e as Error).message || String(e);
      console.warn('[BaiduOAuth] refresh failed:', BaiduNetdiskOAuthClient.sanitize_(msg));
      throw new Error('Token 刷新失败，请重新授权: ' + BaiduNetdiskOAuthClient.sanitize_(msg));
    }
  }

  static toOAuth2Credential(
    clientSecret: string,
    resp: BaiduTokenResponse
  ): OAuth2Credential {
    const o = createEmptyOAuth2Credential();
    o.clientSecret = BaiduNetdiskOAuthClient.normalizeSecret_(clientSecret);
    o.accessToken = resp.accessToken;
    o.refreshToken = resp.refreshToken;
    o.accessTokenExpiresAt = Date.now() + Math.max(60, resp.expiresIn) * 1000;
    o.tokenScope = resp.scope || '';
    return o;
  }

  private static parseTokenResponse_(raw: string): BaiduTokenResponse {
    let obj: Record<string, Object> = {};
    try {
      obj = JSON.parse(raw) as Record<string, Object>;
    } catch (_e) {
      throw new Error('Token 响应非 JSON: ' + BaiduNetdiskOAuthClient.sanitize_(raw.substring(0, 120)));
    }
    if (obj['error'] || obj['error_description']) {
      const desc = String(obj['error_description'] || obj['error'] || '授权失败');
      throw new Error(BaiduNetdiskOAuthClient.sanitize_(desc) + ' (' + String(obj['error'] || '') + ')');
    }
    const access = String(obj['access_token'] || '');
    if (!access) {
      throw new Error('Token 响应缺少 access_token');
    }
    const expiresIn = typeof obj['expires_in'] === 'number'
      ? obj['expires_in'] as number
      : parseInt(String(obj['expires_in'] || '2592000'), 10) || 2592000;
    const result: BaiduTokenResponse = {
      accessToken: access,
      refreshToken: String(obj['refresh_token'] || ''),
      expiresIn: expiresIn,
      scope: String(obj['scope'] || ''),
    };
    return result;
  }

  static sanitize_(text: string): string {
    let s = text || '';
    s = s.replace(new RegExp('access_token=[^&\\s"\']+', 'gi'), 'access_token=***');
    s = s.replace(new RegExp('refresh_token=[^&\\s"\']+', 'gi'), 'refresh_token=***');
    s = s.replace(new RegExp('client_secret=[^&\\s"\']+', 'gi'), 'client_secret=***');
    return s;
  }
}
