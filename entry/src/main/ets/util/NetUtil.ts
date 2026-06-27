/**
 * 网络工具 — 基于 RCP（支持 DNS/代理）
 * 替代 @ohos.net.http，修复 DNS 无法解析问题
 */
import rcp from '@hms.collaboration.rcp';
import util from '@ohos.util';

export class NetUtil {
  // ========== DNS 配置 ==========

  /** 自定义 DNS 服务器列表（逗号分隔的 IP），为空则使用系统 DNS */
  private static dnsServers: string = '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
  /** 是否启用自定义 DNS */
  private static dnsEnabled: boolean = true;

  // ========== 代理配置 ==========

  private static proxyHost: string = '';
  private static proxyPort: number = 0;

  // ========== 公共配置方法 ==========

  static setDns(servers: string, enabled: boolean = true): void {
    NetUtil.dnsServers = servers;
    NetUtil.dnsEnabled = enabled;
    console.info('[NetUtil] DNS set:', servers, 'enabled:', enabled);
  }

  static setProxy(host: string, port: number): void {
    NetUtil.proxyHost = host;
    NetUtil.proxyPort = port;
    console.info('[NetUtil] Proxy set:', host, port);
  }

  static clearProxy(): void {
    NetUtil.proxyHost = '';
    NetUtil.proxyPort = 0;
  }

  // ========== HTTP 请求 ==========

  static async httpGet(url: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    return NetUtil.httpRequest('GET', url, undefined, headers, timeout);
  }

  static async httpPost(url: string, body: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    const h = NetUtil.buildHeaders(headers);
    if (!h['Content-Type'] && !h['content-type']) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return NetUtil.httpRequest('POST', url, body, h, timeout);
  }

  static async httpPut(url: string, body: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    return NetUtil.httpRequest('PUT', url, body, NetUtil.buildHeaders(headers), timeout);
  }

  // ========== 内部实现 ==========

  private static session_: rcp.Session | null = null;

  private static getSession(timeout: number): rcp.Session {
    if (!NetUtil.session_) {
      const cfg: rcp.SessionConfiguration = {
        requestConfiguration: {
          transfer: {
            timeout: { connectMs: timeout, transferMs: timeout }
          }
        }
      };
      NetUtil.session_ = rcp.createSession(cfg);
      console.info('[NetUtil] Session created');
    }
    return NetUtil.session_;
  }

  private static async httpRequest(method: string, url: string, body?: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    try {
      const h = NetUtil.buildHeaders(headers);
      const reqHeaders = h as rcp.RequestHeaders;
      const request = new rcp.Request(url, method.toUpperCase() as rcp.HttpMethod, reqHeaders, body || '');
      const session = NetUtil.getSession(timeout);
      const response = await session.fetch(request);
      if (response.body === undefined || response.body === null) return '';
      const uint8 = new Uint8Array(response.body);
      const decoder = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>);
      const text = decoder.decodeToString(uint8);
      if (response.statusCode >= 200 && response.statusCode < 400) return text;
      throw new Error(`HTTP ${response.statusCode}: ${text.substring(0, 200)}`);
    } catch (e) {
      throw new Error((e as Error).message || String(e));
    }
  }

  private static buildHeaders(headers?: Record<string, string>): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/json,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ...(headers || {}),
    };
  }
}
