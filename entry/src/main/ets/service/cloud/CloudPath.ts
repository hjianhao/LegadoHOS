/**
 * 云端路径规范化与安全校验
 *
 * rootPath / remotePath 均为相对路径语义：
 * - 去首尾斜杠
 * - 折叠重复斜杠
 * - 拒绝 `.` / `..` / 空段 / 反斜杠
 * - 不负责 URL 编码（由 Provider 处理）
 */

export class CloudPath {
  /** 规范化来源根目录；空字符串合法。 */
  static normalizeRootPath(raw: string): string {
    return CloudPath.normalizeRelative_(raw, true);
  }

  /** 规范化相对 rootPath 的远端路径；根目录自身为 ''。 */
  static normalizeRemotePath(raw: string): string {
    return CloudPath.normalizeRelative_(raw, true);
  }

  /**
   * 拼接父路径与子名。
   * parent='' + name='foo' → 'foo'
   * parent='a/b' + name='c' → 'a/b/c'
   */
  static join(parent: string, name: string): string {
    const p = CloudPath.normalizeRemotePath(parent);
    const n = CloudPath.sanitizeName_(name);
    if (!n) {
      throw new Error('非法路径段: 空名称');
    }
    if (!p) {
      return n;
    }
    return p + '/' + n;
  }

  /** 取路径最后一段；根返回 ''。 */
  static basename(remotePath: string): string {
    const p = CloudPath.normalizeRemotePath(remotePath);
    if (!p) {
      return '';
    }
    const idx = p.lastIndexOf('/');
    return idx >= 0 ? p.substring(idx + 1) : p;
  }

  /** 取父路径；已在根则返回 ''。 */
  static parent(remotePath: string): string {
    const p = CloudPath.normalizeRemotePath(remotePath);
    if (!p) {
      return '';
    }
    const idx = p.lastIndexOf('/');
    return idx >= 0 ? p.substring(0, idx) : '';
  }

  /**
   * 生成面包屑：[{ name, path }]，不含虚拟根。
   * 'a/b/c' → [{a,a},{b,a/b},{c,a/b/c}]
   */
  static breadcrumbs(remotePath: string): Array<CloudPathCrumb> {
    const p = CloudPath.normalizeRemotePath(remotePath);
    const result: CloudPathCrumb[] = [];
    if (!p) {
      return result;
    }
    const parts = p.split('/');
    let built = '';
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i];
      built = built ? built + '/' + seg : seg;
      const crumb: CloudPathCrumb = { name: seg, path: built };
      result.push(crumb);
    }
    return result;
  }

  /**
   * 将 endpoint 与 rootPath / remotePath 拼成完整 URL（未做百分号编码）。
   * 仅用于预览与调试；真实请求由 Provider 负责编码。
   */
  static previewUrl(endpoint: string, rootPath: string, remotePath: string = ''): string {
    let base = (endpoint || '').trim().replace(new RegExp('/+$'), '');
    const root = CloudPath.normalizeRootPath(rootPath);
    const remote = CloudPath.normalizeRemotePath(remotePath);
    if (root) {
      base = base + '/' + root;
    }
    if (remote) {
      base = base + '/' + remote;
    }
    return base;
  }

  /** 校验路径是否在安全相对路径集合内（已规范化则恒 true）。 */
  static isSafeRelativePath(raw: string): boolean {
    try {
      CloudPath.normalizeRelative_(raw, true);
      return true;
    } catch (_e) {
      return false;
    }
  }

  private static sanitizeName_(name: string): string {
    const n = (name || '').trim();
    if (!n) {
      return '';
    }
    if (n.indexOf('/') >= 0 || n.indexOf('\\') >= 0) {
      throw new Error('路径段不能包含斜杠: ' + n);
    }
    if (n === '.' || n === '..') {
      throw new Error('非法路径段: ' + n);
    }
    return n;
  }

  private static normalizeRelative_(raw: string, allowEmpty: boolean): string {
    if (raw === null || raw === undefined) {
      if (allowEmpty) {
        return '';
      }
      throw new Error('路径不能为空');
    }
    let s = String(raw).trim();
    if (!s) {
      if (allowEmpty) {
        return '';
      }
      throw new Error('路径不能为空');
    }
    // 拒绝反斜杠与盘符式绝对路径
    if (s.indexOf('\\') >= 0) {
      throw new Error('路径不允许反斜杠');
    }
    // 去掉开头 file:/ http(s): 等，相对路径不应带协议
    if (new RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*:').test(s)) {
      throw new Error('相对路径不能包含协议: ' + s);
    }
    // 统一为正斜杠并去掉首尾 /
    s = s.replace(new RegExp('/+', 'g'), '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (!s) {
      if (allowEmpty) {
        return '';
      }
      throw new Error('路径不能为空');
    }
    const parts = s.split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (!part || part === '.') {
        throw new Error('路径包含非法空段或当前目录引用');
      }
      if (part === '..') {
        throw new Error('路径不允许上级目录引用 (..)');
      }
      out.push(part);
    }
    return out.join('/');
  }
}

export interface CloudPathCrumb {
  name: string;
  path: string;
}
