/**
 * 分享/打开方式 导入服务
 *
 * 部分设备（如缺少 sysPicker/filePicker 组件的平板 ROM）没有系统文件选择器，
 * 用户可通过其他应用的「打开方式 / 分享」把文件交给本应用（module.json5 中
 * MainAbility 已声明 viewData/sendData/sendMultipleData skills）：
 * - .json → 书源导入（MainPage 弹出导入预览对话框）
 * - .txt/.epub/.mobi/.azw/.azw3/.pdf → 本地书籍导入（书架页执行导入流程）
 *
 * MainAbility 在 onCreate / onNewWant 中调用 handleWant()，
 * 解析结果写入 AppStorage('pendingShareImport')，由页面侧消费。
 */
import { Want, common } from '@kit.AbilityKit';

/** 分享导入载荷，写入 AppStorage 供页面消费 */
export interface ShareImportPayload {
  id: number;           // 递增序号，保证同一文件重复分享也能触发 @Watch
  kind: 'json' | 'book' | 'unsupported';
  uris: string[];       // 原始文件 URI（进程存活期间 URI 授权有效，页面侧负责读取/拷贝）
  fileName: string;     // 用于提示展示
}

const BOOK_EXTS: string[] = ['.txt', '.epub', '.mobi', '.azw', '.azw3', '.pdf'];
const APP_STORAGE_KEY = 'pendingShareImport';

export class ShareImportService {
  private static seq: number = 0;

  /** 解析 want 并分发，fire-and-forget（内部已 catch） */
  static handleWant(want: Want, _context: common.UIAbilityContext): void {
    try {
      ShareImportService.dispatch(want);
    } catch (e) {
      console.error('[ShareImport] handleWant failed: ' + (((e as Error) && (e as Error).message) || e));
    }
  }

  private static dispatch(want: Want): void {
    const action = want?.action || '';
    if (action !== 'ohos.want.action.viewData' && action !== 'ohos.want.action.sendData'
      && action !== 'ohos.want.action.sendMultipleData') return;
    const uris = ShareImportService.extractUris(want);
    if (uris.length === 0) {
      console.warn('[ShareImport] no uri in want, action=' + action);
      return;
    }
    const wantType = (want.type || '').toLowerCase();
    console.info('[ShareImport] action=' + action + ', type=' + wantType + ', uris=' + uris.join(','));
    const bookUris: string[] = [];
    for (const uri of uris) {
      const name = ShareImportService.fileNameOf(uri, wantType);
      const lower = name.toLowerCase();
      const inferredExt = ShareImportService.extensionForType(wantType);
      if (lower.endsWith('.json') || inferredExt === '.json') {
        ShareImportService.publish({ id: ++ShareImportService.seq, kind: 'json',
          uris: [uri], fileName: name });
      } else if (BOOK_EXTS.some((ext: string): boolean => lower.endsWith(ext))
        || BOOK_EXTS.indexOf(inferredExt) >= 0) {
        bookUris.push(uri);
      } else {
        ShareImportService.publish({ id: ++ShareImportService.seq, kind: 'unsupported',
          uris: [], fileName: name });
      }
    }
    if (bookUris.length > 0) {
      const first = ShareImportService.fileNameOf(bookUris[0], wantType);
      ShareImportService.publish({
        id: ++ShareImportService.seq, kind: 'book', uris: bookUris,
        fileName: bookUris.length > 1 ? `${first} 等 ${bookUris.length} 个文件` : first
      });
    }
  }

  private static extractUris(want: Want): string[] {
    const out: string[] = [];
    if (want.uri) out.push(want.uri);
    const params = want.parameters || {};
    // 不同系统版本和分享方使用的参数名不同，两个都兼容。
    const streamKeys: string[] = ['ability.params.stream', 'ohos.ability.params.stream'];
    for (const key of streamKeys) {
      const stream = params[key];
      if (Array.isArray(stream)) {
        const streamArr = stream as Object[];
        for (const s of streamArr) {
          if (typeof s === 'string' && s) out.push(s);
        }
      } else if (typeof stream === 'string' && stream) {
        out.push(stream);
      }
    }
    const extra = params['uri'];
    if (typeof extra === 'string' && extra) out.push(extra);
    const dedup: string[] = [];
    for (const u of out) {
      if (dedup.indexOf(u) < 0) dedup.push(u);
    }
    return dedup;
  }

  private static fileNameOf(uri: string, wantType: string = ''): string {
    const tail = (uri.split('?')[0].split('/').pop()) || '';
    let decoded = tail;
    try {
      decoded = decodeURIComponent(tail);
    } catch (_e) { /* keep encoded tail */ }
    const lower = decoded.toLowerCase();
    if (lower.endsWith('.json') || BOOK_EXTS.some((ext: string): boolean => lower.endsWith(ext))) return decoded;
    const ext = ShareImportService.extensionForType(wantType);
    const base = decoded || ('shared_file_' + (ShareImportService.seq + 1));
    return ext ? base + ext : base;
  }

  /** URI 可能是不带后缀的 opaque id，此时按 Want 的 UTD/MIME 补出可解析的文件名。 */
  private static extensionForType(type: string): string {
    switch ((type || '').toLowerCase()) {
      case 'general.json':
      case 'application/json': return '.json';
      case 'general.plain-text':
      case 'text/plain': return '.txt';
      case 'com.adobe.pdf':
      case 'application/pdf': return '.pdf';
      case 'general.epub':
      case 'application/epub+zip': return '.epub';
      case 'com.amazon.mobi':
      case 'application/x-mobipocket-ebook': return '.mobi';
      case 'com.amazon.azw': return '.azw';
      case 'com.amazon.azw3': return '.azw3';
      case 'general.ebook':
      case 'application/vnd.amazon.ebook': return '.azw';
      default: return '';
    }
  }

  private static publish(p: ShareImportPayload): void {
    AppStorage.setOrCreate<ShareImportPayload>(APP_STORAGE_KEY, p);
  }
}
