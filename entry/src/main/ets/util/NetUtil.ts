/**
 * 网络工具 — 封装 @ohos.net.http
 * 提供书源引擎需要的 HTTP 请求能力
 */
import http from '@ohos.net.http';

export class NetUtil {
  private static httpClient: http.HttpRequest;

  /**
   * GET 请求
   * @param url 请求 URL
   * @param headers 请求头
   * @param timeout 超时时间（毫秒）
   * @returns 响应体文本
   */
  static async httpGet(url: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: this.buildHeaders(headers),
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING,
      });

      if (response.responseCode === 200 || response.responseCode === 304) {
        return response.result as string;
      }
      throw new Error(`HTTP ${response.responseCode}: ${response.result}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * POST 请求
   */
  static async httpPost(
    url: string,
    body: string,
    headers?: Record<string, string>,
    timeout: number = 30000
  ): Promise<string> {
    const request = http.createHttp();
    try {
      const extraHeaders = this.buildHeaders(headers);
      // 默认 content-type
      if (!extraHeaders['Content-Type'] && !extraHeaders['content-type']) {
        extraHeaders['Content-Type'] = 'application/x-www-form-urlencoded';
      }

      const response = await request.request(url, {
        method: http.RequestMethod.POST,
        header: extraHeaders,
        extraData: body,
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING,
      });

      if (response.responseCode === 200 || response.responseCode === 304) {
        return response.result as string;
      }
      throw new Error(`HTTP ${response.responseCode}: ${response.result}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * PUT 请求（用于 WebDAV）
   */
  static async httpPut(
    url: string,
    body: string,
    headers?: Record<string, string>,
    timeout: number = 30000
  ): Promise<string> {
    const request = http.createHttp();
    try {
      const extraHeaders = this.buildHeaders(headers || {});
      const response = await request.request(url, {
        method: http.RequestMethod.PUT,
        header: extraHeaders,
        extraData: body,
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING,
      });

      if (response.responseCode === 200 || response.responseCode === 201
          || response.responseCode === 204 || response.responseCode === 304) {
        return (response.result as string) || '';
      }
      throw new Error(`HTTP ${response.responseCode}: ${response.result}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * 检测内容编码
   */
  static detectEncoding(html: string): string {
    const match = html.match(/charset\\s*=\\s*["']?([^"'\\s;]+)/i);
    if (match) return match[1].toLowerCase();

    const xmlMatch = html.match(/<\\?xml\\s+[^>]*encoding\\s*=\\s*["']([^"']+)["']/i);
    if (xmlMatch) return xmlMatch[1].toLowerCase();

    return 'utf-8';
  }

  /**
   * 构建请求头
   */
  private static buildHeaders(headers?: Record<string, string>): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (HarmonyOS; Legado-HOS/1.0)',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      ...(headers || {}),
    };
  }
}
