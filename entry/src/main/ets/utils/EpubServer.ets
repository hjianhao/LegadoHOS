/**
 * 本地 HTTP 服务器 — 为 EPUB.js 提供文件访问
 *
 * 解压 EPUB 后，通过 HTTP 暴露目录结构，
 * EPUB.js 通过 http://127.0.0.1:port/OEBPS/package.opf 加载书籍。
 */
import { socket } from '@kit.NetworkKit';
import fileFs from '@ohos.file.fs';

export class EpubServer {
  private server_: socket.TCPSocketServer | null = null;
  private port_: number = 0;
  private rootDir_: string = '';
  private running_: boolean = false;

  get port(): number { return this.port_; }

  async start(rootDir: string, preferredPort: number = 0): Promise<number> {
    this.rootDir_ = rootDir;
    this.server_ = socket.constructTCPSocketServer();
    // 绑定并监听
    this.server_.listen({ address: { address: '127.0.0.1' }, port: preferredPort, family: 1 }, (err: BusinessError) => {
      if (err) throw err;
      const addr = this.server_.getLocalAddress();
      this.port_ = addr.port;
      this.running_ = true;
      this.acceptLoop_();
    });
    return new Promise<number>((resolve) => {
      // 等待端口分配
      setTimeout(() => resolve(this.port_), 100);
    });
  }

  stop(): void {
    this.running_ = false;
    if (this.server_) {
      try { this.server_.close(); } catch (_e) {}
      this.server_ = null;
    }
  }

  private acceptLoop_(): void {
    if (!this.server_ || !this.running_) return;
    this.server_.accept((err: BusinessError, conn: socket.TCPSocketConnection) => {
      if (!err && conn) {
        this.handleConnection_(conn);
      }
      if (this.running_) {
        this.acceptLoop_();
      }
    });
  }

  private handleConnection_(conn: socket.TCPSocketConnection): void {
    const buf = new ArrayBuffer(8192);
    conn.receive({ buffer: buf }, (recvErr: BusinessError, recvData: socket.SocketRequestInfo) => {
      if (recvErr || !recvData) {
        try { conn.close(); } catch (_e) {}
        return;
      }
      const request = this.bytesToString_(new Uint8Array(buf, 0, recvData.bytesRead));
      const path = this.parsePath_(request);
      const filePath = this.rootDir_ + path;

      try {
        if (fileFs.accessSync(filePath)) {
          const stat = fileFs.statSync(filePath);
          const content = new ArrayBuffer(stat.size);
          const fd = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
          fileFs.readSync(fd.fd, content);
          fileFs.closeSync(fd);
          const mime = this.getMimeType_(path);
          const response = this.buildResponse_(200, mime, content);
          conn.send({ data: response }, () => { try { conn.close(); } catch (_e) {} });
        } else {
          const notFound = this.stringToBytes_('Not Found');
          const response = this.buildResponse_(404, 'text/plain', notFound.buffer as ArrayBuffer);
          conn.send({ data: response }, () => { try { conn.close(); } catch (_e) {} });
        }
      } catch (_e) {
        try { conn.close(); } catch (_e) {}
      }
    });
  }

  private parsePath_(request: string): string {
    const match = request.match(/GET\s+(.+?)\s+HTTP/i);
    if (!match) return '/';
    let path = decodeURIComponent(match[1]);
    // 默认: 返回 index.html / reader.html
    if (path === '/' || path === '') {
      if (fileFs.accessSync(this.rootDir_ + '/reader.html')) return '/reader.html';
      return '/';
    }
    return path;
  }

  private buildResponse_(status: number, mime: string, content: ArrayBuffer): ArrayBuffer {
    const header = `HTTP/1.1 ${status} OK\r\nContent-Type: ${mime}\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: ${content.byteLength}\r\nConnection: close\r\n\r\n`;
    const headerBuf = this.stringToBytes_(header);
    const result = new Uint8Array(headerBuf.length + content.byteLength);
    result.set(headerBuf, 0);
    result.set(new Uint8Array(content), headerBuf.length);
    return result.buffer as ArrayBuffer;
  }

  private getMimeType_(path: string): string {
    if (/\.(html|xhtml)$/i.test(path)) return 'application/xhtml+xml';
    if (/\.css$/i.test(path)) return 'text/css';
    if (/\.js$/i.test(path)) return 'application/javascript';
    if (/\.jpe?g$/i.test(path)) return 'image/jpeg';
    if (/\.png$/i.test(path)) return 'image/png';
    if (/\.gif$/i.test(path)) return 'image/gif';
    if (/\.svg$/i.test(path)) return 'image/svg+xml';
    if (/\.woff2?$/i.test(path)) return 'font/woff';
    if (/\.opf$/i.test(path)) return 'application/oebps-package+xml';
    if (/\.ncx$/i.test(path)) return 'application/x-dtbncx+xml';
    return 'application/octet-stream';
  }

  private bytesToString_(bytes: Uint8Array): string {
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    return decoder.decodeToString(bytes.buffer as ArrayBuffer);
  }

  private stringToBytes_(str: string): Uint8Array {
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(str);
  }
}
