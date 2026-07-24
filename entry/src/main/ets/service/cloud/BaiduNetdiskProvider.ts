/**
 * 百度网盘 CloudStorageProvider
 *
 * - list / stat / downloadToFile / uploadFile
 * - 建目录/删除：首期 capabilities 关闭
 * - 凭证：OAuth2，经 BaiduNetdiskOAuthClient 自动刷新
 */
import fileFs from '@ohos.file.fs';
import rcp from '@hms.collaboration.rcp';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  BaiduNetdiskConfig,
  BAIDU_NETDISK_ENDPOINT,
  CLOUD_PROVIDER_BAIDU_NETDISK,
  CloudCredential,
  CloudSource,
  parseBaiduNetdiskConfig,
} from '../../model/CloudSource';
import { CloudCredentialStore } from '../../data/preferences/CloudCredentialStore';
import { NetUtil } from '../../util/NetUtil';
import { FileUtil } from '../../util/FileUtil';
import { CloudPath } from './CloudPath';
import { BaiduNetdiskOAuthClient } from './BaiduNetdiskOAuthClient';
import {
  CloudFile,
  CloudListPage,
  CloudProviderCapabilities,
  CloudStorageProvider,
  createEmptyCloudFile,
  createEmptyCloudListPage,
} from './CloudStorageProvider';

/** 百度分片默认 4MB（官方常见取值）。 */
const UPLOAD_BLOCK_SIZE = 4 * 1024 * 1024;
const UA_PAN = 'pan.baidu.com';

export class BaiduNetdiskProvider implements CloudStorageProvider {
  readonly type: string = CLOUD_PROVIDER_BAIDU_NETDISK;

  getCapabilities(): CloudProviderCapabilities {
    return {
      canCreateDirectory: false,
      canDelete: false,
      canMove: false,
      supportsEtag: true,
      supportsRangeDownload: false,
    };
  }

  async testConnection(source: CloudSource, _credential: CloudCredential): Promise<void> {
    await this.list(source, _credential, '', undefined);
  }

  async list(
    source: CloudSource,
    _credential: CloudCredential,
    remotePath: string,
    cursor?: string
  ): Promise<CloudListPage> {
    const token = await this.token_(source);
    const cfg = parseBaiduNetdiskConfig(source.configJson || '{}');
    const dir = this.absPath_(source, remotePath);
    let start = 0;
    if (cursor && cursor.length > 0) {
      const n = parseInt(cursor, 10);
      if (!isNaN(n) && n >= 0) {
        start = n;
      }
    }
    const limit = cfg.pageSize > 0 ? cfg.pageSize : 100;
    const url = BAIDU_NETDISK_ENDPOINT + '/file'
      + '?method=list'
      + '&access_token=' + encodeURIComponent(token)
      + '&dir=' + encodeURIComponent(dir)
      + '&order=name'
      + '&start=' + start
      + '&limit=' + limit
      + '&web=web';
    const raw = await NetUtil.httpGet(url, { 'User-Agent': UA_PAN, 'Accept': 'application/json' }, 30000);
    const obj = this.parseJson_(raw);
    this.assertApiOk_(obj);
    const list = obj['list'];
    const page = createEmptyCloudListPage();
    const items: CloudFile[] = [];
    if (Array.isArray(list)) {
      const rows = list as Object[];
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i] as Record<string, Object>;
        const f = this.rowToCloudFile_(source, row);
        if (f) {
          items.push(f);
        }
      }
    }
    items.sort((a: CloudFile, b: CloudFile): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    page.items = items;
    // 百度 list 若返回满页，推测可能有下一页
    page.nextCursor = items.length >= limit ? String(start + limit) : '';
    console.info('[BaiduNetdisk] list dir=', dir, 'count=', items.length, 'start=', start);
    return page;
  }

  async stat(
    source: CloudSource,
    _credential: CloudCredential,
    remotePath: string
  ): Promise<CloudFile | null> {
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    if (!path) {
      // 根目录：构造虚拟目录项
      const root = createEmptyCloudFile();
      root.remotePath = '';
      root.name = '';
      root.isDirectory = true;
      return root;
    }
    // 列举父目录精确匹配（无 path 直接查 filemetas 需要 fs_id）
    const parent = CloudPath.parent(path);
    const base = CloudPath.basename(path);
    const page = await this.list(source, _credential, parent, undefined);
    for (let i = 0; i < page.items.length; i++) {
      if (page.items[i].name === base || page.items[i].remotePath === path) {
        return page.items[i];
      }
    }
    return null;
  }

  async downloadToFile(
    source: CloudSource,
    _credential: CloudCredential,
    remotePath: string,
    tempPath: string,
    onProgress?: (received: number, total: number) => void
  ): Promise<void> {
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('不能下载根目录');
    }
    const meta = await this.stat(source, _credential, path);
    if (!meta) {
      throw new Error('文件不存在: ' + path);
    }
    if (meta.isDirectory) {
      throw new Error('不能下载目录');
    }
    const token = await this.token_(source);
    let dlink = '';
    if (meta.remoteId) {
      dlink = await this.fetchDlink_(token, meta.remoteId);
    }
    if (!dlink) {
      throw new Error('无法获取下载链接');
    }
    // dlink 需附带 access_token
    const dlUrl = dlink.indexOf('access_token=') >= 0
      ? dlink
      : (dlink + (dlink.indexOf('?') >= 0 ? '&' : '?') + 'access_token=' + encodeURIComponent(token));
    const data = await NetUtil.httpGetBinary(dlUrl, {
      'User-Agent': UA_PAN,
    }, 120000);
    this.ensureParentDir_(tempPath);
    try {
      if (FileUtil.exists(tempPath)) {
        fileFs.unlinkSync(tempPath);
      }
    } catch (_e) { /* ok */ }
    let file: fileFs.File | null = null;
    try {
      file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      fileFs.writeSync(file.fd, data);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (_c) { /* ignore */ }
      }
    }
    if (onProgress) {
      onProgress(data.byteLength, data.byteLength);
    }
    console.info('[BaiduNetdisk] downloaded', data.byteLength, 'bytes path=', path);
  }

  async uploadFile(
    source: CloudSource,
    _credential: CloudCredential,
    localPath: string,
    remotePath: string,
    onProgress?: (sent: number, total: number) => void
  ): Promise<CloudFile> {
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('上传路径不能为空');
    }
    if (!FileUtil.exists(localPath)) {
      throw new Error('本地文件不存在');
    }
    const token = await this.token_(source);
    const abs = this.absPath_(source, path);
    const st = fileFs.statSync(localPath);
    const size = st.size;
    // 分块读 MD5
    const blockList: string[] = [];
    let offset = 0;
    let fd: fileFs.File | null = null;
    try {
      fd = fileFs.openSync(localPath, fileFs.OpenMode.READ_ONLY);
      while (offset < size) {
        const chunkLen = Math.min(UPLOAD_BLOCK_SIZE, size - offset);
        const buf = new ArrayBuffer(chunkLen);
        fileFs.readSync(fd.fd, buf, { offset: offset });
        blockList.push(await this.md5Hex_(buf));
        offset += chunkLen;
      }
    } finally {
      if (fd) {
        try {
          fileFs.closeSync(fd);
        } catch (_e) { /* ignore */ }
      }
    }

    // precreate
    const preBody = 'path=' + encodeURIComponent(abs)
      + '&size=' + size
      + '&isdir=0'
      + '&autoinit=1'
      + '&rtype=1'
      + '&block_list=' + encodeURIComponent(JSON.stringify(blockList));
    const preUrl = BAIDU_NETDISK_ENDPOINT + '/file?method=precreate&access_token='
      + encodeURIComponent(token);
    const preRaw = await NetUtil.httpPost(preUrl, preBody, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA_PAN,
    }, 60000);
    const pre = this.parseJson_(preRaw);
    this.assertApiOk_(pre);
    const uploadid = String(pre['uploadid'] || '');
    let blockSeq: number[] = [];
    if (Array.isArray(pre['block_list'])) {
      const arr = pre['block_list'] as Object[];
      for (let i = 0; i < arr.length; i++) {
        blockSeq.push(Number(arr[i]));
      }
    } else {
      for (let i = 0; i < blockList.length; i++) {
        blockSeq.push(i);
      }
    }

    // superfile2 分片上传
    let uploaded = 0;
    for (let bi = 0; bi < blockSeq.length; bi++) {
      const partseq = blockSeq[bi];
      const start = partseq * UPLOAD_BLOCK_SIZE;
      const chunkLen = Math.min(UPLOAD_BLOCK_SIZE, size - start);
      if (chunkLen <= 0) {
        continue;
      }
      const buf = new ArrayBuffer(chunkLen);
      let rf: fileFs.File | null = null;
      try {
        rf = fileFs.openSync(localPath, fileFs.OpenMode.READ_ONLY);
        fileFs.readSync(rf.fd, buf, { offset: start });
      } finally {
        if (rf) {
          try {
            fileFs.closeSync(rf);
          } catch (_e) { /* ignore */ }
        }
      }
      await this.uploadPart_(token, abs, uploadid, partseq, buf);
      uploaded += chunkLen;
      if (onProgress) {
        onProgress(uploaded, size);
      }
    }

    // create
    const createBody = 'path=' + encodeURIComponent(abs)
      + '&size=' + size
      + '&isdir=0'
      + '&rtype=1'
      + '&uploadid=' + encodeURIComponent(uploadid)
      + '&block_list=' + encodeURIComponent(JSON.stringify(blockList));
    const createUrl = BAIDU_NETDISK_ENDPOINT + '/file?method=create&access_token='
      + encodeURIComponent(token);
    const createRaw = await NetUtil.httpPost(createUrl, createBody, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA_PAN,
    }, 60000);
    const created = this.parseJson_(createRaw);
    this.assertApiOk_(created);

    const st2 = await this.stat(source, _credential, path);
    if (st2) {
      return st2;
    }
    const fallback = createEmptyCloudFile();
    fallback.remotePath = path;
    fallback.name = CloudPath.basename(path);
    fallback.isDirectory = false;
    fallback.size = size;
    fallback.remoteId = String(created['fs_id'] || '');
    fallback.etag = String(created['md5'] || '');
    return fallback;
  }

  // ---- private ----

  private async token_(source: CloudSource): Promise<string> {
    const ref = (source.credentialRef || '').trim();
    if (!ref) {
      throw new Error('缺少凭证，请先授权百度网盘');
    }
    return await BaiduNetdiskOAuthClient.ensureAccessToken(source, ref);
  }

  /** rootPath + remotePath → 以 / 开头的网盘绝对路径 */
  private absPath_(source: CloudSource, remotePath: string): string {
    const root = CloudPath.normalizeRootPath(source.rootPath || '');
    const rel = CloudPath.normalizeRemotePath(remotePath || '');
    let full = '';
    if (root && rel) {
      full = root + '/' + rel;
    } else if (root) {
      full = root;
    } else if (rel) {
      full = rel;
    } else {
      full = '';
    }
    if (!full) {
      return '/';
    }
    return full.startsWith('/') ? full : ('/' + full);
  }

  /** 百度 path 转相对 rootPath 的 remotePath */
  private toRemotePath_(source: CloudSource, panPath: string): string {
    let p = (panPath || '').replace(new RegExp('\\\\', 'g'), '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    const root = CloudPath.normalizeRootPath(source.rootPath || '');
    if (root) {
      const lowerP = p.toLowerCase();
      const lowerR = root.toLowerCase();
      if (lowerP === lowerR) {
        return '';
      }
      if (lowerP.indexOf(lowerR + '/') === 0) {
        p = p.substring(root.length + 1);
      }
    }
    return CloudPath.normalizeRemotePath(p);
  }

  private rowToCloudFile_(source: CloudSource, row: Record<string, Object>): CloudFile | null {
    const panPath = String(row['path'] || '');
    if (!panPath) {
      return null;
    }
    const remote = this.toRemotePath_(source, panPath);
    const file = createEmptyCloudFile();
    file.remotePath = remote;
    file.name = String(row['server_filename'] || CloudPath.basename(remote) || '');
    // isdir: 1 目录 0 文件
    const isdir = Number(row['isdir'] ?? 0);
    file.isDirectory = isdir === 1;
    file.size = Number(row['size'] ?? 0);
    // server_mtime 秒
    const mtime = Number(row['server_mtime'] ?? row['server_ctime'] ?? 0);
    file.modifiedAt = mtime > 0 ? mtime * 1000 : 0;
    file.etag = String(row['md5'] || '');
    file.remoteId = String(row['fs_id'] || '');
    file.contentType = '';
    return file;
  }

  private async fetchDlink_(token: string, fsId: string): Promise<string> {
    const url = BAIDU_NETDISK_ENDPOINT + '/multimedia'
      + '?method=filemetas'
      + '&access_token=' + encodeURIComponent(token)
      + '&fsids=' + encodeURIComponent('[' + fsId + ']')
      + '&dlink=1';
    const raw = await NetUtil.httpGet(url, { 'User-Agent': UA_PAN, 'Accept': 'application/json' }, 30000);
    const obj = this.parseJson_(raw);
    this.assertApiOk_(obj);
    const list = obj['list'];
    if (Array.isArray(list) && list.length > 0) {
      const first = list[0] as Record<string, Object>;
      return String(first['dlink'] || '');
    }
    return '';
  }

  private async uploadPart_(
    token: string,
    panPath: string,
    uploadid: string,
    partseq: number,
    data: ArrayBuffer
  ): Promise<void> {
    const url = 'https://d.pcs.baidu.com/rest/2.0/pcs/superfile2'
      + '?method=upload'
      + '&access_token=' + encodeURIComponent(token)
      + '&type=tmpfile'
      + '&path=' + encodeURIComponent(panPath)
      + '&uploadid=' + encodeURIComponent(uploadid)
      + '&partseq=' + partseq;
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession({
        requestConfiguration: {
          transfer: { timeout: { connectMs: 30000, transferMs: 120000 } },
        },
      });
      const headers: rcp.RequestHeaders = {
        'User-Agent': UA_PAN,
        'Content-Type': 'application/octet-stream',
      };
      const request = new rcp.Request(url, 'POST' as rcp.HttpMethod, headers, data);
      const response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw new Error('分片上传 HTTP ' + response.statusCode);
      }
    } catch (e) {
      throw new Error(BaiduNetdiskOAuthClient.sanitize_((e as Error).message || '分片上传失败'));
    } finally {
      if (session) {
        try {
          session.close();
        } catch (_e) { /* ignore */ }
      }
    }
  }

  private async md5Hex_(buf: ArrayBuffer): Promise<string> {
    const md = cryptoFramework.createMd('MD5');
    await md.update({ data: new Uint8Array(buf) });
    const dig = await md.digest();
    const bytes = dig.data;
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      const h = bytes[i].toString(16);
      hex += h.length === 1 ? '0' + h : h;
    }
    return hex;
  }

  private parseJson_(raw: string): Record<string, Object> {
    try {
      return JSON.parse(raw) as Record<string, Object>;
    } catch (_e) {
      throw new Error('百度网盘响应非 JSON');
    }
  }

  private assertApiOk_(obj: Record<string, Object>): void {
    const errno = Number(obj['errno'] ?? 0);
    if (errno === 0) {
      return;
    }
    // -6 认证失败
    const msg = String(obj['errmsg'] || obj['error_msg'] || ('errno=' + errno));
    if (errno === -6 || errno === 111 || errno === 110) {
      throw new Error('授权已失效，请重新登录百度网盘');
    }
    throw new Error('百度网盘错误: ' + BaiduNetdiskOAuthClient.sanitize_(msg));
  }

  private ensureParentDir_(filePath: string): void {
    const slash = filePath.lastIndexOf('/');
    if (slash > 0) {
      const dir = filePath.substring(0, slash);
      try {
        if (!FileUtil.exists(dir)) {
          fileFs.mkdirSync(dir, true);
        }
      } catch (_e) { /* ignore */ }
    }
  }
}
