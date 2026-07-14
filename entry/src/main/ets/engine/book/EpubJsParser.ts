/**
 * EPUB.js 解析器逻辑 — 通过隐藏 WebView 使用 EPUB.js 解析 EPUB
 */
import web_webview from '@ohos.web.webview';
import fileFs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';

/** 目录条目 */
export interface TocItem {
  label: string;
  href: string;
}

/** EPUB.js 元数据 */
export interface EpubJsMeta {
  title: string;
  author: string;
  description: string;
  coverData: ArrayBuffer | null;
}

/** EPUB.js 章节 */
export interface EpubJsChapter {
  index: number;
  title: string;
  href: string;
  content: string;
}

/** 解析结果 */
export interface EpubJsResult {
  meta: EpubJsMeta;
  chapters: EpubJsChapter[];
  toc: TocItem[];
}

let globalController: web_webview.WebviewController | null = null;

/** 设置全局 WebView 控制器（由 EpubParserWebView 组件调用） */
export function setParserController(controller: web_webview.WebviewController): void {
  globalController = controller;
}

export class EpubJsParser {
  private static instance: EpubJsParser;

  static getInstance(): EpubJsParser {
    if (!EpubJsParser.instance) {
      EpubJsParser.instance = new EpubJsParser();
    }
    return EpubJsParser.instance;
  }

  async parse(filePath: string): Promise<EpubJsResult> {
    const controller = globalController;
    if (!controller) {
      throw new Error('EpubParserWebView not initialized');
    }
    return new Promise<EpubJsResult>((resolve, reject) => {
      try {
        const fd = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
        const stat = fileFs.statSync(filePath);
        const buf = new ArrayBuffer(stat.size);
        fileFs.readSync(fd.fd, buf);
        fileFs.closeSync(fd);
        const base64 = this.arrayBufferToBase64_(buf);
        const dataUrl = 'data:application/epub+zip;base64,' + base64;

        const checkReady = () => {
          try {
            controller.runJavaScript('typeof window.parseEpub', (err: BusinessError, exists: string) => {
              if (exists === 'function') {
                controller.runJavaScript('window.parseEpub("' + this.escapeJsStr_(dataUrl) + '")');
                this.pollResult_(controller, 0, resolve, reject);
              } else {
                setTimeout(checkReady, 200);
              }
            });
          } catch (_e) {
            setTimeout(checkReady, 200);
          }
        };
        setTimeout(checkReady, 500);
      } catch (e) {
        reject(e);
      }
    });
  }

  private pollResult_(
    controller: web_webview.WebviewController,
    attempt: number,
    resolve: (result: EpubJsResult) => void,
    reject: (err: Error) => void
  ): void {
    if (attempt > 100) {
      reject(new Error('EPUB.js parse timeout'));
      return;
    }
    setTimeout(() => {
      try {
        controller.runJavaScript('window.__parseDone ? window.__parseResult : null',
          (err: BusinessError, result: string) => {
            if (result && result !== 'null') {
              try {
                const parsed = JSON.parse(result) as Record<string, Object>;
                const metadata = (parsed['metadata'] || {}) as Record<string, Object>;
                const meta: EpubJsMeta = {
                  title: String(metadata['title'] || ''),
                  author: String(metadata['author'] || ''),
                  description: String(metadata['description'] || ''),
                  coverData: null,
                };
                const rawChapters = (parsed['chapters'] || []) as Record<string, Object>[];
                const chapters: EpubJsChapter[] = [];
                for (let i = 0; i < rawChapters.length; i++) {
                  const ch = rawChapters[i];
                  chapters.push({
                    index: (ch['index'] as number) >= 0 ? (ch['index'] as number) : i,
                    title: String(ch['title'] || ''),
                    href: String(ch['href'] || ''),
                    content: String(ch['content'] || ''),
                  });
                }
                const rawToc = (parsed['toc'] || []) as Record<string, Object>[];
                const toc: TocItem[] = [];
                for (let i = 0; i < rawToc.length; i++) {
                  const t = rawToc[i];
                  toc.push({
                    label: String(t['label'] || ''),
                    href: String(t['href'] || ''),
                  });
                }
                resolve({ meta, chapters, toc });
              } catch (e) {
                reject(new Error('Parse result JSON error'));
              }
            } else {
              controller.runJavaScript('window.__parseError || null',
                (err2: BusinessError, errMsg: string) => {
                  if (errMsg && errMsg !== 'null') {
                    reject(new Error(errMsg));
                  } else {
                    this.pollResult_(controller, attempt + 1, resolve, reject);
                  }
                });
            }
          });
      } catch (_e) {
        this.pollResult_(controller, attempt + 1, resolve, reject);
      }
    }, 300);
  }

  private arrayBufferToBase64_(buf: ArrayBuffer): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const bytes = new Uint8Array(buf);
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i];
      const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const triple = (a << 16) | (b << 8) | c;
      result += chars.charAt((triple >> 18) & 63) + chars.charAt((triple >> 12) & 63) +
                chars.charAt((triple >> 6) & 63) + chars.charAt(triple & 63);
    }
    const pad = bytes.length % 3;
    if (pad === 1) return result.slice(0, -2) + '==';
    if (pad === 2) return result.slice(0, -1) + '=';
    return result;
  }

  private escapeJsStr_(s: string): string {
    return s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  }
}
