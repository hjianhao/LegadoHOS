/**
 * EPUB 本地 HTTP 服务器。
 *
 * 虚拟根:
 *   /book/*   -> 当前书籍解压目录(book.tocUrl)
 *   /reader/* -> rawfile/epub 下的 Web 阅读器资源
 */
import { socket } from '@kit.NetworkKit';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';

interface EpubHttpResponse {
  status: number;
  mime: string;
  body: ArrayBuffer;
  contentLength?: number;
  extraHeaders?: string[];
}

interface EpubHttpRequest {
  method: string;
  path: string;
}

interface EpubByteRange {
  start: number;
  end: number;
}

export interface EpubFontResource {
  familyName: string;
  filePath: string;
}

export class EpubServer {
  private server_: socket.TCPSocketServer | null = null;
  private port_: number = 0;
  private bookRoot_: string = '';
  private running_: boolean = false;
  private context_: Context | null = null;
  private fontFiles_: Map<string, string> = new Map<string, string>();

  get port(): number { return this.port_; }

  async start(bookRoot: string, context: Context, preferredPort: number = 0): Promise<number> {
    this.stop();
    this.bookRoot_ = this.trimTrailingSlash_(bookRoot);
    this.context_ = context;
    this.server_ = socket.constructTCPSocketServerInstance();
    this.server_.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnection_(conn);
    });
    const listenAddress: socket.NetAddress = {
      address: '127.0.0.1',
      port: preferredPort,
      family: 1,
    };
    try {
      await this.server_.listen(listenAddress);
      const localAddress = await this.server_.getLocalAddress();
      this.port_ = localAddress.port || preferredPort;
      this.running_ = true;
      console.info(`[EpubServer] started port=${this.port_} root=${this.bookRoot_}`);
      return this.port_;
    } catch (err) {
      this.stop();
      throw new Error('[EpubServer] start failed: ' + (err as Error).message);
    }
  }

  setFontFiles(fonts: EpubFontResource[]): void {
    const map = new Map<string, string>();
    for (const font of fonts) {
      if (font.familyName && font.filePath) {
        map.set(font.familyName, font.filePath);
      }
    }
    this.fontFiles_ = map;
  }

  stop(): void {
    this.running_ = false;
    this.port_ = 0;
    if (this.server_) {
      try { this.server_.close().catch(() => {}); } catch (_e) {}
      this.server_ = null;
    }
  }

  private handleConnection_(conn: socket.TCPSocketConnection): void {
    conn.on('message', async (info: socket.SocketMessageInfo) => {
      if (!info || !info.message) {
        this.closeConn_(conn);
        return;
      }

      try {
        const request = this.bytesToString_(new Uint8Array(info.message));
          const response = await this.route_(request);
          this.logRequest_(request, response);
          const payload = this.buildResponse_(request, response);
          conn.send({ data: payload }).then(() => this.closeConn_(conn)).catch(() => this.closeConn_(conn));
      } catch (_e) {
        const body = this.stringToBytes_('Internal Server Error').buffer as ArrayBuffer;
        const payload = this.buildResponse_(requestFromMethod_('GET'), { status: 500, mime: 'text/plain; charset=utf-8', body });
        conn.send({ data: payload }).then(() => this.closeConn_(conn)).catch(() => this.closeConn_(conn));
      }
    });
  }

  private async route_(request: string): Promise<EpubHttpResponse> {
    const req = this.parseRequest_(request);
    if (!req) {
      return this.text_(400, 'Bad Request');
    }
    if (req.method === 'OPTIONS') {
      return { status: 204, mime: 'text/plain; charset=utf-8', body: new ArrayBuffer(0) };
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return this.text_(405, 'Method Not Allowed');
    }

    const urlPath = this.stripQuery_(req.path);
    if (urlPath === '/' || urlPath === '/reader' || urlPath === '/reader/') {
      return this.serveReader_('/epub-reader.html');
    }
    if (urlPath.startsWith('/reader/')) {
      return this.serveReader_(urlPath.substring('/reader'.length));
    }
    if (urlPath === '/foliate' || urlPath === '/foliate/') {
      return this.serveRawFile_('foliate/foliate-reader.html');
    }
    if (urlPath.startsWith('/foliate/')) {
      const safePath = this.normalizeVirtualPath_(urlPath.substring('/foliate'.length));
      if (safePath === null) return this.text_(403, 'Forbidden');
      return this.serveRawFile_('foliate' + safePath);
    }
    if (urlPath === '/book' || urlPath === '/book/') {
      return this.serveBook_('/', request);
    }
    if (urlPath.startsWith('/book/')) {
      return this.serveBook_(urlPath.substring('/book'.length), request);
    }
    if (urlPath.startsWith('/font/')) {
      return this.serveFont_(urlPath.substring('/font/'.length));
    }
    return this.text_(404, 'Not Found');
  }

  private serveBook_(virtualPath: string, request: string): EpubHttpResponse {
    const safePath = this.normalizeVirtualPath_(virtualPath);
    if (safePath === null) {
      return this.text_(403, 'Forbidden');
    }
    let filePath = this.bookRoot_ + safePath;
    if (safePath === '/') {
      filePath = this.bookRoot_ + '/META-INF/container.xml';
    }
    try {
      if (!fileFs.accessSync(filePath)) {
        return this.text_(404, 'Not Found');
      }
      const stat = fileFs.statSync(filePath);
      const req = this.parseRequest_(request);
      const commonHeaders = ['Accept-Ranges: bytes'];
      if (req?.method === 'HEAD') {
        return {
          status: 200, mime: this.getMimeType_(filePath), body: new ArrayBuffer(0),
          contentLength: stat.size, extraHeaders: commonHeaders,
        };
      }
      const range = this.parseRange_(request, stat.size);
      if (range) {
        const body = this.readFileRange_(filePath, range.start, range.end - range.start + 1);
        return {
          status: 206, mime: this.getMimeType_(filePath), body,
          contentLength: body.byteLength,
          extraHeaders: commonHeaders.concat([`Content-Range: bytes ${range.start}-${range.end}/${stat.size}`]),
        };
      }
      const body = this.readFile_(filePath);
      return {
        status: 200, mime: this.getMimeType_(filePath), body,
        contentLength: body.byteLength, extraHeaders: commonHeaders,
      };
    } catch (_e) {
      return this.text_(404, 'Not Found');
    }
  }

  private async serveReader_(virtualPath: string): Promise<EpubHttpResponse> {
    const safePath = this.normalizeVirtualPath_(virtualPath);
    if (safePath === null) {
      return this.text_(403, 'Forbidden');
    }
    const name = safePath === '/' ? '/epub-reader.html' : safePath;
    const rawPath = 'epub' + name;
    try {
        const content = this.context_!.resourceManager.getRawFileContentSync(rawPath);
        const body = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength) as ArrayBuffer;
        return { status: 200, mime: this.getMimeType_(rawPath), body };
      } catch (_e) {
        return this.text_(404, 'Not Found');
      }
  }

  private serveRawFile_(rawPath: string): EpubHttpResponse {
    try {
      const content = this.context_!.resourceManager.getRawFileContentSync(rawPath);
      const body = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength) as ArrayBuffer;
      return { status: 200, mime: this.getMimeType_(rawPath), body };
    } catch (_e) {
      return this.text_(404, 'Not Found');
    }
  }

  private serveFont_(encodedFamily: string): EpubHttpResponse {
    const familyName = this.decodeUrl_(encodedFamily);
    const filePath = this.fontFiles_.get(familyName);
    if (!filePath) {
      return this.text_(404, 'Not Found');
    }
    try {
      if (!fileFs.accessSync(filePath)) {
        return this.text_(404, 'Not Found');
      }
      const body = this.readFile_(filePath);
      return { status: 200, mime: this.getMimeType_(filePath), body };
    } catch (_e) {
      return this.text_(404, 'Not Found');
    }
  }

  private readFile_(filePath: string): ArrayBuffer {
    let fd: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(filePath);
      const content = new ArrayBuffer(stat.size);
      fd = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(fd.fd, content);
      return content;
    } catch (err) {
      throw new Error(`Read EPUB server file failed: ${filePath}: ${(err as Error).message}`);
    } finally {
      if (fd) {
        try {
          fileFs.closeSync(fd);
        } catch (err) {
          console.warn('[EpubServer] close file failed:', (err as Error).message);
        }
      }
    }
  }

  private readFileRange_(filePath: string, offset: number, length: number): ArrayBuffer {
    let file: fileFs.File | null = null;
    try {
      const body = new ArrayBuffer(length);
      file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
      const readLength = fileFs.readSync(file.fd, body, { offset, length });
      return readLength === length ? body : body.slice(0, Math.max(0, readLength));
    } finally {
      if (file) fileFs.closeSync(file);
    }
  }

  private parseRange_(request: string, fileSize: number): EpubByteRange | null {
    const match = request.match(/\r\nRange:\s*bytes=(\d+)-(\d*)/i);
    if (!match) return null;
    const start = Number(match[1]);
    let end = match[2] ? Number(match[2]) : fileSize - 1;
    if (!Number.isFinite(start) || start < 0 || start >= fileSize) return null;
    if (!Number.isFinite(end) || end < start) return null;
    end = Math.min(end, fileSize - 1);
    return { start, end };
  }

  private parseRequest_(request: string): EpubHttpRequest | null {
    const firstLine = request.split('\r\n')[0] || '';
    const parts = firstLine.split(' ');
    if (parts.length < 2) return null;
    return { method: parts[0].toUpperCase(), path: this.decodeUrl_(parts[1]) };
  }

  private buildResponse_(request: string, response: EpubHttpResponse): ArrayBuffer {
    const req = this.parseRequest_(request);
    const isHead = req?.method === 'HEAD';
    const headers =
      `HTTP/1.1 ${response.status} ${this.statusText_(response.status)}\r\n` +
      `Content-Type: ${response.mime}\r\n` +
      `Content-Length: ${response.contentLength ?? response.body.byteLength}\r\n` +
      `Access-Control-Allow-Origin: *\r\n` +
      `Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n` +
      `Access-Control-Allow-Headers: *\r\n` +
      `Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n` +
      (response.extraHeaders && response.extraHeaders.length > 0 ? response.extraHeaders.join('\r\n') + '\r\n' : '') +
      `Content-Security-Policy: default-src 'self' blob: data:; script-src 'self'; style-src 'self' 'unsafe-inline' blob:; img-src 'self' blob: data:; font-src 'self' blob: data:; connect-src 'self'; object-src 'none'; frame-src blob:;\r\n` +
      `X-Content-Type-Options: nosniff\r\n` +
      `Cache-Control: max-age=3600\r\n` +
      `Connection: close\r\n\r\n`;
    const header = this.stringToBytes_(headers);
    if (isHead) {
      return header.buffer as ArrayBuffer;
    }
    const result = new Uint8Array(header.length + response.body.byteLength);
    result.set(header, 0);
    result.set(new Uint8Array(response.body), header.length);
    return result.buffer as ArrayBuffer;
  }

  private text_(status: number, text: string): EpubHttpResponse {
    return { status, mime: 'text/plain; charset=utf-8', body: this.stringToBytes_(text).buffer as ArrayBuffer };
  }

  private normalizeVirtualPath_(path: string): string | null {
    const raw = this.stripQuery_(path || '/');
    const parts = raw.split('/');
    const safe: string[] = [];
    for (const part of parts) {
      if (!part || part === '.') continue;
      if (part === '..') return null;
      safe.push(part);
    }
    return '/' + safe.join('/');
  }

  private stripQuery_(path: string): string {
    const q = path.indexOf('?');
    return q >= 0 ? path.substring(0, q) : path;
  }

  private decodeUrl_(path: string): string {
    try {
      return decodeURIComponent(path.replace(/\+/g, '%20'));
    } catch (_e) {
      return path;
    }
  }

  private getMimeType_(path: string): string {
    if (/\.(html)$/i.test(path)) return 'text/html; charset=utf-8';
      if (/\.xhtml$/i.test(path)) return 'application/xhtml+xml; charset=utf-8';
      if (/\.xml$/i.test(path)) return 'application/xml; charset=utf-8';
    if (/\.css$/i.test(path)) return 'text/css; charset=utf-8';
    if (/\.(?:js|mjs)$/i.test(path)) return 'application/javascript; charset=utf-8';
    if (/\.jpe?g$/i.test(path)) return 'image/jpeg';
    if (/\.png$/i.test(path)) return 'image/png';
    if (/\.webp$/i.test(path)) return 'image/webp';
    if (/\.gif$/i.test(path)) return 'image/gif';
    if (/\.svg$/i.test(path)) return 'image/svg+xml';
    if (/\.pdf$/i.test(path)) return 'application/pdf';
    if (/\.woff2$/i.test(path)) return 'font/woff2';
    if (/\.woff$/i.test(path)) return 'font/woff';
    if (/\.ttf$/i.test(path)) return 'font/ttf';
    if (/\.otf$/i.test(path)) return 'font/otf';
    if (/\.opf$/i.test(path)) return 'application/oebps-package+xml; charset=utf-8';
    if (/\.ncx$/i.test(path)) return 'application/x-dtbncx+xml; charset=utf-8';
    return 'application/octet-stream';
  }

  private statusText_(code: number): string {
    switch (code) {
      case 200: return 'OK';
      case 204: return 'No Content';
      case 206: return 'Partial Content';
      case 400: return 'Bad Request';
      case 403: return 'Forbidden';
      case 404: return 'Not Found';
      case 405: return 'Method Not Allowed';
      case 500: return 'Internal Server Error';
      default: return 'OK';
    }
  }

    private bytesToString_(bytes: Uint8Array): string {
      const decoder = new util.TextDecoder('utf-8', { fatal: false });
      return decoder.decodeToString(bytes);
    }

    private logRequest_(request: string, response: EpubHttpResponse): void {
      const req = this.parseRequest_(request);
      if (!req) {
        console.warn(`[EpubServer] bad request -> ${response.status}`);
        return;
      }
      console.info(`[EpubServer] ${req.method} ${req.path} -> ${response.status} ${response.body.byteLength}`);
    }

  private stringToBytes_(str: string): Uint8Array {
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(str);
  }

  private trimTrailingSlash_(path: string): string {
    let result = path;
    while (result.length > 1 && result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  private closeConn_(conn: socket.TCPSocketConnection): void {
    try { conn.close().catch(() => {}); } catch (_e) {}
  }
}

function requestFromMethod_(method: string): string {
  return method + ' / HTTP/1.1\r\n\r\n';
}
