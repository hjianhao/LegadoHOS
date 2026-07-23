/**
 * 本地目录云存储 Provider（阶段 7）
 *
 * 将应用沙箱 filesDir/cloud_local_folder/<namespace> 暴露为 CloudStorageProvider，
 * 用于验证 CloudProviderRegistry 可扩展性：不修改 Book / LocalBookEngine /
 * WebDAV 协议实现即可接入新来源类型。
 *
 * - endpoint: localfolder://{namespace} 或仅 namespace
 * - credential.username: 访问身份（默认 local）
 * - credential.secret: 可选访问口令（config.requireToken=true 时强制校验）
 * - list 支持 nextCursor 分页
 * - capabilities: 可建目录/删除；无 move / etag / range
 */
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import {
  CloudCredential,
  CLOUD_PROVIDER_LOCAL_FOLDER,
  CloudSource,
  createDefaultLocalFolderCloudConfig,
  LocalFolderCloudConfig,
} from '../../model/CloudSource';
import { AppContextHolder } from '../../util/AppContext';
import { FileUtil } from '../../util/FileUtil';
import { CloudPath } from './CloudPath';
import {
  CloudFile,
  CloudListPage,
  CloudProviderCapabilities,
  CloudStorageProvider,
  createEmptyCloudFile,
  createEmptyCloudListPage,
} from './CloudStorageProvider';

const STORAGE_SUBDIR = 'cloud_local_folder';
const SEED_README = 'README_cloud_demo.txt';
const SEED_BODY =
  'LegadoHOS localfolder Provider demo.\n' +
  'Copy epub/txt/umd books into this directory (or subfolders),\n' +
  'then browse Cloud Bookshelf and download to import.\n' +
  'Path: files/cloud_local_folder/<namespace>/\n';

export class LocalFolderCloudProvider implements CloudStorageProvider {
  readonly type: string = CLOUD_PROVIDER_LOCAL_FOLDER;
  private static encoder_: util.TextEncoder = new util.TextEncoder();

  getCapabilities(): CloudProviderCapabilities {
    return {
      canCreateDirectory: true,
      canDelete: true,
      canMove: false,
      supportsEtag: false,
      supportsRangeDownload: false,
    };
  }

  async testConnection(source: CloudSource, credential: CloudCredential): Promise<void> {
    this.assertAuth_(source, credential);
    const rootAbs = this.sourceRootAbs_(source);
    this.ensureDir_(rootAbs);
    this.seedIfEmpty_(rootAbs);
  }

  async list(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    cursor?: string
  ): Promise<CloudListPage> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    const abs = this.resolveAbs_(source, path);
    if (!FileUtil.exists(abs)) {
      throw new Error('目录不存在: ' + (path || '/'));
    }
    const st = fileFs.statSync(abs);
    if (!st.isDirectory()) {
      throw new Error('不是目录: ' + (path || '/'));
    }

    const cfg = this.readConfig_(source);
    let offset = 0;
    if (cursor && cursor.length > 0) {
      const n = parseInt(cursor, 10);
      if (!isNaN(n) && n >= 0) {
        offset = n;
      }
    }

    const names: string[] = fileFs.listFileSync(abs) || [];
    const files: CloudFile[] = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (!name || name === '.' || name === '..') {
        continue;
      }
      try {
        const childAbs = abs + '/' + name;
        const childSt = fileFs.statSync(childAbs);
        const remote = path ? CloudPath.join(path, name) : name;
        files.push(this.statToCloudFile_(childAbs, remote, name, childSt));
      } catch (_e) {
        // skip inaccessible
      }
    }
    files.sort((a: CloudFile, b: CloudFile): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });

    const pageSize = cfg.pageSize > 0 ? cfg.pageSize : 50;
    const slice = files.slice(offset, offset + pageSize);
    const page = createEmptyCloudListPage();
    page.items = slice;
    const next = offset + pageSize;
    page.nextCursor = next < files.length ? String(next) : '';
    console.info('[LocalFolderCloud] list path=', path || '/', 'total=', files.length,
      'offset=', offset, 'page=', slice.length);
    return page;
  }

  async stat(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<CloudFile | null> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    if (!path) {
      const rootAbs = this.sourceRootAbs_(source);
      if (!FileUtil.exists(rootAbs)) {
        return null;
      }
      const st = fileFs.statSync(rootAbs);
      return this.statToCloudFile_(rootAbs, '', '', st);
    }
    const abs = this.resolveAbs_(source, path);
    if (!FileUtil.exists(abs)) {
      return null;
    }
    const st = fileFs.statSync(abs);
    return this.statToCloudFile_(abs, path, CloudPath.basename(path), st);
  }

  async downloadToFile(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    tempPath: string,
    onProgress?: (received: number, total: number) => void
  ): Promise<void> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('不能下载根目录');
    }
    const abs = this.resolveAbs_(source, path);
    if (!FileUtil.exists(abs)) {
      throw new Error('文件不存在: ' + path);
    }
    const st = fileFs.statSync(abs);
    if (st.isDirectory()) {
      throw new Error('不能下载目录');
    }
    this.ensureParentDir_(tempPath);
    try {
      if (FileUtil.exists(tempPath)) {
        fileFs.unlinkSync(tempPath);
      }
    } catch (_e) { /* ok */ }
    fileFs.copyFileSync(abs, tempPath);
    if (onProgress) {
      onProgress(st.size, st.size);
    }
    console.info('[LocalFolderCloud] downloaded', st.size, 'bytes from', path);
  }

  async uploadFile(
    source: CloudSource,
    credential: CloudCredential,
    localPath: string,
    remotePath: string,
    onProgress?: (sent: number, total: number) => void
  ): Promise<CloudFile> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('上传路径不能为空');
    }
    if (!FileUtil.exists(localPath)) {
      throw new Error('本地文件不存在');
    }
    const abs = this.resolveAbs_(source, path);
    this.ensureParentDir_(abs);
    try {
      if (FileUtil.exists(abs)) {
        fileFs.unlinkSync(abs);
      }
    } catch (_e) { /* ok */ }
    fileFs.copyFileSync(localPath, abs);
    const st = fileFs.statSync(abs);
    if (onProgress) {
      onProgress(st.size, st.size);
    }
    return this.statToCloudFile_(abs, path, CloudPath.basename(path), st);
  }

  async createDirectory(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('目录路径不能为空');
    }
    const abs = this.resolveAbs_(source, path);
    this.ensureDir_(abs);
  }

  async delete(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void> {
    this.assertAuth_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('不能删除根目录');
    }
    const abs = this.resolveAbs_(source, path);
    if (!FileUtil.exists(abs)) {
      return;
    }
    const st = fileFs.statSync(abs);
    if (st.isDirectory()) {
      FileUtil.removeDirRecursive(abs);
    } else {
      fileFs.unlinkSync(abs);
    }
  }

  // ---- private ----

  private assertAuth_(source: CloudSource, credential: CloudCredential): void {
    if (!source) {
      throw new Error('来源无效');
    }
    const ns = this.namespace_(source);
    if (!ns) {
      throw new Error('本地目录命名空间不能为空（endpoint）');
    }
    if (!credential || !(credential.username || '').trim()) {
      throw new Error('未配置访问身份');
    }
    const cfg = this.readConfig_(source);
    if (cfg.requireToken) {
      const token = (credential.secret || '').trim();
      if (!token || token === 'local' || token === '__open__') {
        throw new Error('此来源要求访问口令，请在编辑页填写');
      }
    }
  }

  private readConfig_(source: CloudSource): LocalFolderCloudConfig {
    const defaults = createDefaultLocalFolderCloudConfig();
    if (!source.configJson) {
      return defaults;
    }
    try {
      const obj = JSON.parse(source.configJson) as Record<string, number | boolean>;
      if (typeof obj['pageSize'] === 'number' && (obj['pageSize'] as number) > 0) {
        defaults.pageSize = obj['pageSize'] as number;
      }
      if (typeof obj['requireToken'] === 'boolean') {
        defaults.requireToken = obj['requireToken'] as boolean;
      }
    } catch (_e) {
      // ignore
    }
    return defaults;
  }

  /** 从 endpoint 解析命名空间：localfolder://demo → demo；demo → demo */
  private namespace_(source: CloudSource): string {
    let ep = (source.endpoint || '').trim();
    if (!ep) {
      return '';
    }
    const lower = ep.toLowerCase();
    if (lower.startsWith('localfolder://')) {
      ep = ep.substring('localfolder://'.length);
    } else if (lower.startsWith('local://')) {
      ep = ep.substring('local://'.length);
    }
    ep = ep.replace(new RegExp('^/+'), '').replace(new RegExp('/+$'), '');
    if (ep.indexOf('/') >= 0) {
      ep = ep.split('/')[0];
    }
    ep = ep.replace(new RegExp('[^a-zA-Z0-9_\\-\\u4e00-\\u9fff]', 'g'), '_');
    if (!ep || ep === '.' || ep === '..') {
      return '';
    }
    return ep;
  }

  private filesRoot_(): string {
    const ctx = AppContextHolder.get();
    if (!ctx || !ctx.filesDir) {
      throw new Error('缺少应用 Context，无法访问本地目录');
    }
    return ctx.filesDir;
  }

  private namespaceAbs_(source: CloudSource): string {
    return this.filesRoot_() + '/' + STORAGE_SUBDIR + '/' + this.namespace_(source);
  }

  private sourceRootAbs_(source: CloudSource): string {
    const base = this.namespaceAbs_(source);
    const root = CloudPath.normalizeRootPath(source.rootPath || '');
    if (!root) {
      return base;
    }
    return base + '/' + root;
  }

  private resolveAbs_(source: CloudSource, remotePath: string): string {
    const base = this.sourceRootAbs_(source);
    this.ensureDir_(base);
    const rel = CloudPath.normalizeRemotePath(remotePath || '');
    if (!rel) {
      return base;
    }
    const full = base + '/' + rel;
    if (!this.isUnderBase_(full, base)) {
      throw new Error('非法路径: ' + rel);
    }
    return full;
  }

  private isUnderBase_(full: string, base: string): boolean {
    const f = full.replace(new RegExp('/+', 'g'), '/');
    const b = base.replace(new RegExp('/+', 'g'), '/');
    return f === b || f.startsWith(b + '/');
  }

  private ensureDir_(abs: string): void {
    if (!abs) {
      return;
    }
    try {
      if (!FileUtil.exists(abs)) {
        fileFs.mkdirSync(abs, true);
      }
    } catch (e) {
      throw new Error('创建目录失败: ' + ((e as Error).message || String(e)));
    }
  }

  private ensureParentDir_(filePath: string): void {
    const slash = filePath.lastIndexOf('/');
    if (slash > 0) {
      this.ensureDir_(filePath.substring(0, slash));
    }
  }

  private seedIfEmpty_(rootAbs: string): void {
    try {
      const names: string[] = fileFs.listFileSync(rootAbs) || [];
      if (names.length > 0) {
        return;
      }
      const seedPath = rootAbs + '/' + SEED_README;
      const bytes = LocalFolderCloudProvider.encoder_.encodeInto(SEED_BODY);
      let file: fileFs.File | null = null;
      try {
        file = fileFs.openSync(seedPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
        fileFs.writeSync(file.fd, bytes.buffer);
      } finally {
        if (file) {
          try {
            fileFs.closeSync(file);
          } catch (_c) { /* ignore */ }
        }
      }
      console.info('[LocalFolderCloud] seeded README at', seedPath);
    } catch (e) {
      console.warn('[LocalFolderCloud] seed failed:', (e as Error).message);
    }
  }

  private statToCloudFile_(
    abs: string,
    remotePath: string,
    name: string,
    st: fileFs.Stat
  ): CloudFile {
    const file = createEmptyCloudFile();
    file.remotePath = remotePath;
    file.name = name || CloudPath.basename(remotePath) || abs;
    file.isDirectory = st.isDirectory();
    file.size = st.isDirectory() ? 0 : st.size;
    file.modifiedAt = st.mtime ? st.mtime * 1000 : 0;
    file.etag = '';
    file.contentType = '';
    file.remoteId = abs;
    return file;
  }
}
