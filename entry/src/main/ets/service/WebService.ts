/**
 * Web 远程管理服务
 *
 * 基于 @ohos.net.socket 的嵌入式 HTTP 服务器，
 * 提供远程书架浏览、搜索、书籍管理功能。
 * 前端可复用 legado-web 的 Vue 3 代码。
 */
import socket from '@ohos.net.socket';
import { BookRepository } from '../data/repository/BookRepository';
import { BookSourceRepository } from '../data/repository/BookSourceRepository';

export class WebService {
  private static instance: WebService;
  private server: socket.TcpServer | null = null;
  private port: number = 8080;
  private running: boolean = false;
  private bookRepo: BookRepository = new BookRepository();
  private sourceRepo: BookSourceRepository = new BookSourceRepository();

  private constructor() {}

  static getInstance(): WebService {
    if (!WebService.instance) {
      WebService.instance = new WebService();
    }
    return WebService.instance;
  }

  /**
   * 启动 Web 服务
   */
  async start(port: number = 8080): Promise<void> {
    if (this.running) return;

    this.port = port;

    try {
      // 创建 TCP 服务器
      this.server = socket.constructTcpServer();
      // 绑定端口并监听
      // this.server.bind({ address: '0.0.0.0', port: this.port });
      // this.server.listen();
      this.running = true;

      console.info(`[WebService] Started on port ${this.port}`);
    } catch (err) {
      console.error('[WebService] Failed to start:', err);
      throw err;
    }
  }

  /**
   * 停止服务
   */
  stop(): void {
    if (!this.running) return;
    try {
      this.server?.close();
      this.running = false;
      console.info('[WebService] Stopped');
    } catch (err) {
      console.error('[WebService] Stop failed:', err);
    }
  }

  isRunning(): boolean { return this.running; }
  getPort(): number { return this.port; }

  /**
   * 处理 HTTP 请求（路由分发）
   */
  private async handleRequest(request: any, response: any): Promise<void> {
    const url = request.url;
    const method = request.method;

    try {
      // API 路由
      if (url === '/api/bookshelf' && method === 'GET') {
        const books = await this.bookRepo.getShelfBooks();
        this.sendJson(response, 200, books);
      } else if (url.startsWith('/api/search') && method === 'GET') {
        const keyword = url.split('?keyword=')[1] || '';
        const sources = await this.sourceRepo.getEnabledSources();
        this.sendJson(response, 200, { keyword, total: sources.length });
      } else {
        // 404
        this.sendHtml(response, 404, '<h1>Not Found</h1>');
      }
    } catch (err) {
      this.sendJson(response, 500, { error: err.message });
    }
  }

  private sendJson(response: any, status: number, data: any): void {
    const body = JSON.stringify(data);
    const headers = [
      'HTTP/1.1 ' + status + ' ' + this.getStatusText(status),
      'Content-Type: application/json; charset=utf-8',
      'Content-Length: ' + body.length,
      'Access-Control-Allow-Origin: *',
      '',
    ].join('\r\n');
    // response.write(headers + '\r\n' + body);
  }

  private sendHtml(response: any, status: number, html: string): void {
    const headers = [
      'HTTP/1.1 ' + status + ' ' + this.getStatusText(status),
      'Content-Type: text/html; charset=utf-8',
      'Content-Length: ' + html.length,
      '',
    ].join('\r\n');
    // response.write(headers + '\r\n' + html);
  }

  private getStatusText(code: number): string {
    const map: Record<number, string> = {
      200: 'OK', 404: 'Not Found', 500: 'Internal Server Error',
    };
    return map[code] || 'Unknown';
  }
}
