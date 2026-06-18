/**
 * Web 远程管理服务器（增强版）
 *
 * 基于 @ohos.net.socket.TcpServer 的嵌入式 HTTP 服务器。
 * 提供:
 * - RESTful API: 书架/书源/搜索/状态
 * - 静态文件服务: 内嵌管理页面 (rawfile/admin/)
 *
 * 响应路径:
 *   / 或 /index.html → 内嵌管理页面
 *   /api/* → REST API
 *   其他 → 404
 */
import socket from '@ohos.net.socket';
import { BookRepository } from '../../data/repository/BookRepository';
import { BookSourceRepository } from '../../data/repository/BookSourceRepository';
import { globalSourceExecutor } from '../source/SourceExecutor';

export class WebServer {
  private server: socket.TcpServer | null = null;
  private port: number = 8080;
  private running: boolean = false;
  private startTime: number = 0;
  private bookRepo: BookRepository = new BookRepository();
  private sourceRepo: BookSourceRepository = new BookSourceRepository();

  async start(port: number = 8080): Promise<void> {
    if (this.running) return;
    this.port = port;
    this.startTime = Date.now();

    try {
      this.server = socket.constructTcpServer();
      this.server.on('connect', (client: socket.TcpConnection) => {
        this.handleClient(client).catch(err => {
          console.error('[WebServer] Client error:', err);
        });
      });
      // await this.server.listen({ address: '0.0.0.0', port: this.port });
      this.running = true;
      console.info(`[WebServer] Running on :${this.port}`);
    } catch (err) {
      console.error('[WebServer] Start failed:', err);
    }
  }

  stop(): void {
    if (!this.running) return;
    try {
      this.server?.close();
      this.running = false;
      console.info('[WebServer] Stopped');
    } catch (err) {
      console.error('[WebServer] Stop failed:', err);
    }
  }

  isRunning(): boolean { return this.running; }
  getPort(): number { return this.port; }

  private async handleClient(client: socket.TcpConnection): Promise<void> {
    try {
      const buffer = new ArrayBuffer(16384);
      const readResult = await client.send({ data: buffer });
      const requestStr = String.fromCharCode(
        ...new Uint8Array(buffer.slice(0, readResult.bytesWritten))
      );

      const lines = requestStr.split('\r\n');
      const requestLine = lines[0];
      if (!requestLine) return;
      const [method, path] = requestLine.split(' ');

      const response = await this.route(method, path);
      this.sendResponse(client, response);
      client.close();
    } catch (err) {
      console.error('[WebServer] Handle error:', err);
    }
  }

  private async route(method: string, path: string): Promise<HttpResponse> {
    // CORS
    if (method === 'OPTIONS') {
      return { status: 204, contentType: 'text/plain', body: '', headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': '*' } };
    }

    const url = path.split('?')[0];
    const query = path.includes('?') ? path.split('?')[1] : '';
    const params = new URLSearchParams(query);

    try {
      // API 路由
      if (url === '/api/bookshelf') {
        const books = await this.bookRepo.getShelfBooks();
        return this.json(200, books);
      }
      if (url === '/api/sources') {
        const sources = await this.sourceRepo.getAllSources();
        return this.json(200, sources);
      }
      if (url === '/api/status') {
        return this.json(200, {
          status: 'running',
          port: this.port,
          uptime: (Date.now() - this.startTime) / 1000,
        });
      }
      if (url === '/api/search') {
        const keyword = params.get('keyword') || '';
        if (keyword) {
          const sources = await this.sourceRepo.getEnabledSources();
          const results = await globalSourceExecutor.search(keyword, sources);
          return this.json(200, { keyword, total: results.length, results });
        }
        return this.json(400, { error: 'keyword required' });
      }

      // 静态文件：内嵌管理页面
      if (url === '/' || url === '/index.html') {
        return this.serveStatic('admin/index.html', 'text/html');
      }

      return { status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'Not Found' }) };
    } catch (err) {
      return { status: 500, contentType: 'application/json', body: JSON.stringify({ error: err.message }) };
    }
  }

  private async serveStatic(path: string, mime: string): Promise<HttpResponse> {
    try {
      const context = globalThis.ApplicationContext;
      if (context && context.resourceManager) {
        const data = await context.resourceManager.getRawFileContent(path);
        if (data) {
          const body = String.fromCharCode(...new Uint8Array(data));
          return { status: 200, contentType: mime, body };
        }
      }
      return { status: 404, contentType: 'text/plain', body: 'Not Found' };
    } catch {
      return { status: 404, contentType: 'text/plain', body: 'Not Found' };
    }
  }

  private json(status: number, data: any): HttpResponse {
    return {
      status,
      contentType: 'application/json',
      body: JSON.stringify(data, null, 2),
      headers: { 'Access-Control-Allow-Origin': '*' },
    };
  }

  private async sendResponse(client: socket.TcpConnection, resp: HttpResponse): Promise<void> {
    const headerLines = [
      `HTTP/1.1 ${resp.status} ${this.statusText(resp.status)}`,
      `Content-Type: ${resp.contentType}; charset=utf-8`,
      `Content-Length: ${Buffer.byteLength(resp.body, 'utf-8')}`,
      'Connection: close',
      resp.headers?.['Access-Control-Allow-Origin'] ? 'Access-Control-Allow-Origin: *' : '',
      resp.headers?.['Access-Control-Allow-Methods'] || '',
      resp.headers?.['Access-Control-Allow-Headers'] || '',
      '',
    ].filter(Boolean).join('\r\n');

    const responseBuf = new ArrayBuffer(headerLines.length + resp.body.length);
    const view = new Uint8Array(responseBuf);
    let offset = 0;
    for (let i = 0; i < headerLines.length; i++) view[offset++] = headerLines.charCodeAt(i);
    for (let i = 0; i < resp.body.length; i++) view[offset++] = resp.body.charCodeAt(i);

    await client.send({ data: responseBuf });
  }

  private statusText(code: number): string {
    return { 200: 'OK', 201: 'Created', 204: 'No Content', 400: 'Bad Request', 404: 'Not Found', 500: 'Internal Server Error' }[code] || 'Unknown';
  }
}

interface HttpResponse {
  status: number;
  contentType: string;
  body: string;
  headers?: Record<string, string>;
}
