/**
 * 网络工具 — 基于 RCP（支持 DNS/代理）
 * 替代 @ohos.net.http，修复 DNS 无法解析问题
 */
import rcp from '@hms.collaboration.rcp';
import util from '@ohos.util';
import zlib from '@ohos.zlib';

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

  /**
   * 发送自定义 HTTP 请求方法（PROPFIND / MKCOL / DELETE 等）
   */
  static async httpCustomMethod(method: string, url: string, body?: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    return NetUtil.httpRequest(method, url, body || '', NetUtil.buildHeaders(headers), timeout);
  }

  // ========== 内部实现 ==========

  private static session_: rcp.Session | null = null;

  private static getSession(timeout: number): rcp.Session {
    try {
      if (!NetUtil.session_) {
        const secCfg: rcp.SecurityConfiguration = {
          remoteValidation: 'system',
          tlsRange: {
            min: 'TlsV1.0' as rcp.TlsVersion,
            max: 'TlsV1.3' as rcp.TlsVersion
          }
        };
        const cfg: rcp.SessionConfiguration = {
          requestConfiguration: {
            transfer: {
              timeout: { connectMs: timeout, transferMs: timeout }
            },
            security: secCfg
          }
        };
        NetUtil.session_ = rcp.createSession(cfg);
        console.info('[NetUtil] Session created');
      }
      return NetUtil.session_;
    } catch (err) {
      throw err;
    }
  }

  private static async httpRequest(method: string, url: string, body?: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    const startMs: number = Date.now();
    try {
      const h = NetUtil.buildHeaders(headers);
      const reqHeaders = h as rcp.RequestHeaders;
      const request = new rcp.Request(url, method.toUpperCase() as rcp.HttpMethod, reqHeaders, body || '');
      const session = NetUtil.getSession(timeout);
      const response = await session.fetch(request);
      console.info('[NetUtil]', method, url, '→', response.statusCode, '(' + (Date.now() - startMs) + 'ms)');
      if (response.statusCode < 200 || response.statusCode >= 400) {
        let errorText = '';
        if (response.body !== undefined && response.body !== null) {
          const errorBytes = new Uint8Array(response.body);
          errorText = await NetUtil.decodeBody(errorBytes, url);
        }
        throw new Error(`HTTP ${response.statusCode}: ${errorText.substring(0, 200)}`);
      }
      if (response.body === undefined || response.body === null) return '';
      const uint8 = new Uint8Array(response.body);
      const text = await NetUtil.decodeBody(uint8, url);
      return text;
    } catch (e) {
      const elapsedMs: number = Date.now() - startMs;
      const errMsg: string = (e as Error).message || String(e);
      console.error('[NetUtil]', method, url, 'FAILED (' + elapsedMs + 'ms):', errMsg);
      throw new Error(errMsg);
    }
  }

  private static buildHeaders(headers?: Record<string, string>): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/json,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Encoding': 'identity',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ...(headers || {}),
    };
  }

  private static async decodeBody(bytes: Uint8Array, url: string): Promise<string> {
    let bodyBytes = bytes;
    if (NetUtil.looksCompressed(bytes)) {
      try {
        bodyBytes = await NetUtil.inflateBytes(bytes);
        console.info('[NetUtil] gzip/zlib decompressed:', url, bytes.length, '→', bodyBytes.length);
      } catch (e) {
        const errMsg: string = (e as Error).message || String(e);
        console.warn('[NetUtil] gzip/zlib decompress failed:', url, errMsg);
      }
    }
    const decoder = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>);
    return decoder.decodeToString(bodyBytes);
  }

  private static looksCompressed(bytes: Uint8Array): boolean {
    if (bytes.length < 2) return false;
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) return true;
    return bytes[0] === 0x78;
  }

  private static async inflateBytes(bytes: Uint8Array): Promise<Uint8Array> {
    try {
      let outputSize: number = Math.max(bytes.length * 8, 64 * 1024);
      for (let attempt = 0; attempt < 5; attempt++) {
        const zip = await zlib.createZip();
        const input = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        const output = new ArrayBuffer(outputSize);
        const strm: zlib.ZStream = {
          nextIn: input,
          availableIn: bytes.byteLength,
          nextOut: output,
          availableOut: outputSize
        };
        const initStatus = await zip.inflateInit2(strm, 47);
        if (initStatus !== zlib.ReturnStatus.OK) {
          throw new Error('inflateInit2 status ' + initStatus);
        }

        const status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
        await zip.inflateEnd(strm);
        if (status === zlib.ReturnStatus.STREAM_END || status === zlib.ReturnStatus.OK) {
          const totalOut = strm.totalOut || 0;
          return new Uint8Array(output.slice(0, totalOut));
        }
        if (status === zlib.ReturnStatus.BUF_ERROR) {
          outputSize *= 2;
          continue;
        }
        throw new Error('inflate status ' + status);
      }
      throw new Error('inflate output buffer too small');
    } catch (err) {
      throw err;
    }
  }
}
