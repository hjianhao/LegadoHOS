/**
 * 百度网盘 OAuth 客户端。
 *
 * App 不持有 AppSecret：授权码换取和 Refresh Token 刷新均经由 CFC
 * 令牌中转服务完成；网盘文件 API 仍由 BaiduNetdiskProvider 直连。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { CloudCredentialStore } from '../../data/preferences/CloudCredentialStore';
import {
  CloudSource,
  createEmptyOAuth2Credential,
  OAuth2Credential,
} from '../../model/CloudSource';
import { NetUtil } from '../../util/NetUtil';

/** CFC HTTP 触发器模板。{action} 会替换为 start / exchange / refresh。 */
const BROKER_ACTION_URL =
  'https://c6ew80ey2rz1m.cfc-execute.bj.baidubce.com/v1/baidu/oauth/{action}';
const REFRESH_SKEW_MS = 5 * 60 * 1000;
const BROKER_TIMEOUT_MS = 30000;

export interface BaiduTokenResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  scope: string;
}

export interface BaiduAuthorizationSession {
  authUrl: string;
  state: string;
  proof: string;
  installationHash: string;
}

interface BrokerStartResponse {
  state: string;
  authorizeUrl: string;
}

export class BaiduNetdiskOAuthClient {
  private static refreshTasks_: Map<string, Promise<string>> = new Map();

  /** 创建与当前设备绑定的一次性授权会话。 */
  static async startAuthorization(): Promise<BaiduAuthorizationSession> {
    const proof = BaiduNetdiskOAuthClient.randomHex_(32);
    const installationHash = await BaiduNetdiskOAuthClient.installationHash_();
    const raw = await BaiduNetdiskOAuthClient.postBroker_('start', {
      installationHash: installationHash,
      proofHash: await BaiduNetdiskOAuthClient.sha256Hex_(proof),
    });
    const response = BaiduNetdiskOAuthClient.parseBrokerStart_(raw);
    return {
      authUrl: response.authorizeUrl,
      state: response.state,
      proof: proof,
      installationHash: installationHash,
    };
  }

  /** 将回调授权码交给 CFC 换取 Token。 */
  static async exchangeCode(
    session: BaiduAuthorizationSession,
    code: string
  ): Promise<BaiduTokenResponse> {
    const raw = await BaiduNetdiskOAuthClient.postBroker_('exchange', {
      code: (code || '').trim(),
      state: session.state,
      proof: session.proof,
      installationHash: session.installationHash,
    });
    return BaiduNetdiskOAuthClient.parseTokenResponse_(raw);
  }

  /** Refresh Token 同样只能经由 CFC 使用 AppSecret 完成刷新。 */
  static async refresh(refreshToken: string): Promise<BaiduTokenResponse> {
    const raw = await BaiduNetdiskOAuthClient.postBroker_('refresh', {
      refreshToken: (refreshToken || '').trim(),
    });
    return BaiduNetdiskOAuthClient.parseTokenResponse_(raw);
  }

  /**
   * 确保证件有效；同一来源并发访问时只刷新一次，避免 Refresh Token 竞争覆盖。
   */
  static async ensureAccessToken(source: CloudSource, credentialRef: string): Promise<string> {
    const store = CloudCredentialStore.getInstance();
    if (!store.isReady()) {
      throw new Error('凭证存储未就绪');
    }
    const ref = (credentialRef || source.credentialRef || '').trim();
    if (!ref) {
      throw new Error('缺少凭证引用，请先完成授权');
    }
    const oauth = await store.getOAuth2Credential(ref);
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

    const running = BaiduNetdiskOAuthClient.refreshTasks_.get(ref);
    if (running) {
      return await running;
    }
    const task = BaiduNetdiskOAuthClient.refreshAndSave_(ref, oauth);
    BaiduNetdiskOAuthClient.refreshTasks_.set(ref, task);
    try {
      return await task;
    } finally {
      BaiduNetdiskOAuthClient.refreshTasks_.delete(ref);
    }
  }

  static toOAuth2Credential(resp: BaiduTokenResponse): OAuth2Credential {
    const o = createEmptyOAuth2Credential();
    o.accessToken = resp.accessToken;
    o.refreshToken = resp.refreshToken;
    o.accessTokenExpiresAt = Date.now() + Math.max(60, resp.expiresIn) * 1000;
    o.tokenScope = resp.scope || '';
    return o;
  }

  static sanitize_(text: string): string {
    let s = text || '';
    s = s.replace(new RegExp("access_token[=:\\s\"']+[^&\\s\"']+", 'gi'), 'access_token=***');
    s = s.replace(new RegExp("refresh_token[=:\\s\"']+[^&\\s\"']+", 'gi'), 'refresh_token=***');
    s = s.replace(new RegExp('"accessToken"\\s*:\\s*"[^"]+"', 'gi'), '"accessToken":"***"');
    s = s.replace(new RegExp('"refreshToken"\\s*:\\s*"[^"]+"', 'gi'), '"refreshToken":"***"');
    return s;
  }

  private static async refreshAndSave_(ref: string, oauth: OAuth2Credential): Promise<string> {
    try {
      console.info('[BaiduOAuth] refreshing token for ref=', ref.substring(0, 16));
      const response = await BaiduNetdiskOAuthClient.refresh(oauth.refreshToken);
      const next = BaiduNetdiskOAuthClient.toOAuth2Credential(response);
      // 少数服务端响应不返回新的 refresh_token 时保留旧值。
      next.refreshToken = response.refreshToken || oauth.refreshToken;
      next.tokenScope = response.scope || oauth.tokenScope;
      await CloudCredentialStore.getInstance().setOAuth2Credential(ref, next);
      return next.accessToken;
    } catch (e) {
      const message = BaiduNetdiskOAuthClient.sanitize_((e as Error).message || String(e));
      console.warn('[BaiduOAuth] refresh failed:', message);
      throw new Error('Token 刷新失败，请重新授权: ' + message);
    }
  }

  private static async postBroker_(action: string, body: Record<string, string>): Promise<string> {
    const url = BROKER_ACTION_URL.replace('{action}', encodeURIComponent(action));
    try {
      return await NetUtil.httpPostSystem(url, JSON.stringify(body), {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        'Cookie': '',
        'User-Agent': 'AIReader-BaiduOAuth/1.0',
      }, BROKER_TIMEOUT_MS);
    } catch (e) {
      throw new Error(BaiduNetdiskOAuthClient.sanitize_((e as Error).message || '令牌服务不可用'));
    }
  }

  private static parseBrokerStart_(raw: string): BrokerStartResponse {
    let obj: Record<string, Object> = {};
    try {
      obj = JSON.parse(raw) as Record<string, Object>;
    } catch (_e) {
      throw new Error('令牌服务响应非 JSON，请确认云函数已部署 OAuth Broker 代码');
    }
    BaiduNetdiskOAuthClient.throwBrokerError_(obj);
    const state = String(obj['state'] || '');
    const authorizeUrl = String(obj['authorizeUrl'] || '');
    if (!state || !authorizeUrl || !authorizeUrl.startsWith('https://')) {
      throw new Error('令牌服务返回的授权地址无效');
    }
    return { state: state, authorizeUrl: authorizeUrl };
  }

  private static parseTokenResponse_(raw: string): BaiduTokenResponse {
    let obj: Record<string, Object> = {};
    try {
      obj = JSON.parse(raw) as Record<string, Object>;
    } catch (_e) {
      throw new Error('令牌服务响应非 JSON，请确认云函数已部署 OAuth Broker 代码');
    }
    BaiduNetdiskOAuthClient.throwBrokerError_(obj);
    const access = String(obj['accessToken'] || '');
    if (!access) {
      throw new Error('令牌服务响应缺少 accessToken');
    }
    const expires = Number(obj['expiresIn'] || 2592000);
    return {
      accessToken: access,
      refreshToken: String(obj['refreshToken'] || ''),
      expiresIn: isNaN(expires) ? 2592000 : expires,
      scope: String(obj['scope'] || ''),
    };
  }

  private static throwBrokerError_(obj: Record<string, Object>): void {
    const error = obj['error'];
    if (!error) {
      return;
    }
    const row = error as Record<string, Object>;
    const code = typeof row['code'] === 'string' ? row['code'] as string : 'BROKER_ERROR';
    if (code === 'REAUTHORIZE_REQUIRED') {
      throw new Error('百度授权已失效，请重新授权');
    }
    throw new Error('令牌服务错误: ' + code);
  }

  private static async installationHash_(): Promise<string> {
    const settings = SettingsStore.getInstance();
    let id = await settings.getSecret('baidu_oauth_install_id');
    if (!id) {
      id = BaiduNetdiskOAuthClient.randomHex_(32);
      await settings.putSecret('baidu_oauth_install_id', id);
    }
    return await BaiduNetdiskOAuthClient.sha256Hex_(id);
  }

  private static randomHex_(byteLength: number): string {
    const bytes = cryptoFramework.createRandom().generateRandomSync(byteLength).data;
    return BaiduNetdiskOAuthClient.bytesToHex_(bytes);
  }

  private static async sha256Hex_(text: string): Promise<string> {
    const encoder = new util.TextEncoder();
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: encoder.encodeInto(text) });
    const result = await md.digest();
    return BaiduNetdiskOAuthClient.bytesToHex_(result.data);
  }

  private static bytesToHex_(bytes: Uint8Array): string {
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      const text = bytes[i].toString(16);
      hex += text.length === 1 ? '0' + text : text;
    }
    return hex;
  }
}
