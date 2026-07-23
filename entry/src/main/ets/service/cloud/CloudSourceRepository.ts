/**
 * 云端来源 Repository
 *
 * 负责来源配置 CRUD、凭证存取、排序与删除编排。
 * 阶段 1 不发起 Provider 连接测试（阶段 2 接入）。
 * 删除来源只删配置 + Binding + 凭证，不动本地 Book。
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { CloudBookBindingTable } from '../../data/database/CloudBookBindingTable';
import { CloudSourceTable } from '../../data/database/CloudSourceTable';
import { CloudCredentialStore } from '../../data/preferences/CloudCredentialStore';
import {
  CloudCredential,
  CloudSource,
  CLOUD_PROVIDER_WEBDAV,
  createDefaultCloudSource,
  createEmptyCloudCredential,
  isLocalFolderProvider,
} from '../../model/CloudSource';
import { CloudPath } from './CloudPath';
import { CloudListPage } from './CloudStorageProvider';
import { CloudProviderRegistry } from './CloudProviderRegistry';
import { ensureCloudProvidersRegistered } from './CloudProviderBootstrap';

export interface CloudSourceSaveInput {
  /** 编辑时传入；新增为 0 或不传。 */
  id?: number;
  name: string;
  providerType?: string;
  endpoint: string;
  rootPath?: string;
  configJson?: string;
  enabled?: boolean;
  sortNumber?: number;
  /** 用户名；编辑时若 password 为空可只更新用户名。 */
  username: string;
  /**
   * 密码/Token。
   * - 新增：可为空（允许先存后填）
   * - 编辑：传 undefined/不改密时保留旧 secret；传 '' 可清空
   */
  secret?: string;
  /** true 表示明确更新 secret（含清空）；false/省略则编辑时保留旧密码。 */
  updateSecret?: boolean;
}

export interface CloudSourceTestResult {
  ok: boolean;
  message: string;
  /** 根目录列举到的条目数（成功时）。 */
  itemCount: number;
  previewNames: string[];
}

export class CloudSourceRepository {
  private sourceTable_: CloudSourceTable;
  private bindingTable_: CloudBookBindingTable;
  private credentialStore_: CloudCredentialStore;

  constructor() {
    const db = AppDatabase.getInstance().rdbStore;
    this.sourceTable_ = new CloudSourceTable(db);
    this.bindingTable_ = new CloudBookBindingTable(db);
    this.credentialStore_ = CloudCredentialStore.getInstance();
  }

  async listAll(): Promise<CloudSource[]> {
    return await this.sourceTable_.listAll();
  }

  async listEnabled(): Promise<CloudSource[]> {
    return await this.sourceTable_.listEnabled();
  }

  async getById(id: number): Promise<CloudSource | null> {
    return await this.sourceTable_.getById(id);
  }

  async getCredential(sourceId: number): Promise<CloudCredential | null> {
    const source = await this.sourceTable_.getById(sourceId);
    if (!source || !source.credentialRef) {
      return null;
    }
    return await this.credentialStore_.getCloudCredential(source.credentialRef);
  }

  async getCredentialByRef(credentialRef: string): Promise<CloudCredential | null> {
    return await this.credentialStore_.getCloudCredential(credentialRef);
  }

  /**
   * 测试连接并列举根目录（不写库、不改凭证）。
   * 失败时旧配置保持可用。
   */
  async testConnection(input: CloudSourceSaveInput): Promise<CloudSourceTestResult> {
    ensureCloudProvidersRegistered();
    try {
      const prepared = await this.prepareTransient_(input);
      const provider = CloudProviderRegistry.getInstance().get(prepared.source.providerType);
      await provider.testConnection(prepared.source, prepared.credential);
      const page: CloudListPage = await provider.list(prepared.source, prepared.credential, '');
      const names: string[] = [];
      const limit = Math.min(page.items.length, 8);
      for (let i = 0; i < limit; i++) {
        const it = page.items[i];
        names.push((it.isDirectory ? '[目录] ' : '') + it.name);
      }
      const result: CloudSourceTestResult = {
        ok: true,
        message: '连接成功，根目录共 ' + page.items.length + ' 项',
        itemCount: page.items.length,
        previewNames: names,
      };
      return result;
    } catch (e) {
      const result: CloudSourceTestResult = {
        ok: false,
        message: (e as Error).message || '连接失败',
        itemCount: 0,
        previewNames: [],
      };
      return result;
    }
  }

  /**
   * 先测试连接 + 列举根目录，成功后再持久化。
   * 失败不写库、不替换旧凭证。
   */
  async saveWithValidation(input: CloudSourceSaveInput): Promise<CloudSource> {
    const test = await this.testConnection(input);
    if (!test.ok) {
      throw new Error(test.message);
    }
    return await this.save(input);
  }

  /**
   * 保存来源（新增或更新），不强制网络校验。
   * UI 保存请优先用 saveWithValidation。
   */
  async save(input: CloudSourceSaveInput): Promise<CloudSource> {
    const name = (input.name || '').trim();
    if (!name) {
      throw new Error('来源名称不能为空');
    }
    const providerType = (input.providerType || CLOUD_PROVIDER_WEBDAV).trim() || CLOUD_PROVIDER_WEBDAV;
    const endpoint = CloudSourceRepository.normalizeEndpoint_(input.endpoint, providerType);
    if (!endpoint) {
      throw new Error(isLocalFolderProvider(providerType)
        ? '目录命名空间不能为空'
        : '服务器地址不能为空');
    }
    let rootPath = '';
    try {
      rootPath = CloudPath.normalizeRootPath(input.rootPath || '');
    } catch (e) {
      throw new Error('根目录非法: ' + ((e as Error).message || String(e)));
    }
    const now = Date.now();
    const editId = input.id && input.id > 0 ? input.id : 0;

    if (editId > 0) {
      return await this.updateExisting_(editId, input, name, endpoint, rootPath, providerType, now);
    }
    return await this.insertNew_(input, name, endpoint, rootPath, providerType, now);
  }

  /**
   * 删除来源：Binding + 来源记录 + 凭证。
   * 不删除任何本地 Book / Chapter / 文件。
   */
  async deleteSource(id: number): Promise<void> {
    if (id <= 0) {
      return;
    }
    const source = await this.sourceTable_.getById(id);
    if (!source) {
      return;
    }
    await this.bindingTable_.deleteBySource(id);
    await this.sourceTable_.delete(id);
    if (source.credentialRef) {
      try {
        await this.credentialStore_.deleteCloudCredential(source.credentialRef);
      } catch (e) {
        console.warn('[CloudSourceRepository] delete credential failed, sourceId=', id,
          (e as Error).message);
      }
    }
    console.info('[CloudSourceRepository] deleted source id=', id, 'name=', source.name);
  }

  async updateSort(idsInOrder: number[]): Promise<void> {
    await this.sourceTable_.updateSort(idsInOrder);
  }

  /** 仅切换启用状态，绝不改写凭证。 */
  async setEnabled(id: number, enabled: boolean): Promise<void> {
    if (id <= 0) {
      return;
    }
    await this.sourceTable_.updateEnabled(id, enabled);
  }

  private async insertNew_(
    input: CloudSourceSaveInput,
    name: string,
    endpoint: string,
    rootPath: string,
    providerType: string,
    now: number
  ): Promise<CloudSource> {
    if (!this.credentialStore_.isReady()) {
      throw new Error('凭证存储未就绪，请重启应用后重试');
    }
    const credPair = CloudSourceRepository.resolveCredentialForSave_(providerType, input, null);
    const username = credPair.username;
    const secret = credPair.secret;

    const credentialRef = this.credentialStore_.generateCredentialRef();
    const credential = createEmptyCloudCredential();
    credential.username = username;
    credential.secret = secret;

    await this.credentialStore_.setCloudCredential(credentialRef, credential);

    const source = createDefaultCloudSource();
    source.name = name;
    source.providerType = providerType;
    source.endpoint = endpoint;
    source.rootPath = rootPath;
    source.configJson = input.configJson || '{}';
    source.credentialRef = credentialRef;
    source.enabled = input.enabled !== undefined ? !!input.enabled : true;
    source.sortNumber = input.sortNumber !== undefined ? input.sortNumber : await this.nextSortNumber_();
    source.createdAt = now;
    source.updatedAt = now;

    try {
      const id = await this.sourceTable_.insert(source);
      source.id = id;
      // 回读校验，避免“假成功”
      const verify = await this.credentialStore_.getCloudCredential(credentialRef);
      if (!verify || !verify.username || !verify.secret) {
        throw new Error('凭证写入后校验失败，请重试');
      }
      console.info('[CloudSourceRepository] inserted source id=', id, 'type=', providerType,
        ' rootPath=', rootPath, ' ref=', credentialRef);
      return source;
    } catch (e) {
      // 补偿：删除刚写入的凭证
      try {
        await this.credentialStore_.deleteCloudCredential(credentialRef);
      } catch (_cleanup) { /* ignore */ }
      throw e;
    }
  }

  private async updateExisting_(
    id: number,
    input: CloudSourceSaveInput,
    name: string,
    endpoint: string,
    rootPath: string,
    providerType: string,
    now: number
  ): Promise<CloudSource> {
    if (!this.credentialStore_.isReady()) {
      throw new Error('凭证存储未就绪，请重启应用后重试');
    }
    const existing = await this.sourceTable_.getById(id);
    if (!existing) {
      throw new Error('来源不存在: ' + id);
    }

    let credentialRef = existing.credentialRef || '';
    if (!credentialRef) {
      credentialRef = this.credentialStore_.generateCredentialRef();
    }
    const oldCred = await this.credentialStore_.getCloudCredential(credentialRef);
    const resolved = CloudSourceRepository.resolveCredentialForUpdate_(
      providerType, input, oldCred
    );
    const finalUser = resolved.username;
    const finalSecret = resolved.secret;
    const shouldWriteCredential = resolved.shouldWrite;

    if (shouldWriteCredential) {
      const credential = createEmptyCloudCredential();
      credential.username = finalUser;
      credential.secret = finalSecret;
      await this.credentialStore_.setCloudCredential(credentialRef, credential);
      const verify = await this.credentialStore_.getCloudCredential(credentialRef);
      if (!verify || verify.username !== finalUser || !verify.secret) {
        throw new Error('凭证更新后校验失败，请重试');
      }
    }

    existing.name = name;
    existing.providerType = providerType;
    existing.endpoint = endpoint;
    existing.rootPath = rootPath;
    if (input.configJson !== undefined) {
      existing.configJson = input.configJson || '{}';
    }
    existing.credentialRef = credentialRef;
    if (input.enabled !== undefined) {
      existing.enabled = !!input.enabled;
    }
    if (input.sortNumber !== undefined) {
      existing.sortNumber = input.sortNumber;
    }
    existing.updatedAt = now;

    await this.sourceTable_.update(existing);
    console.info('[CloudSourceRepository] updated source id=', id, 'rootPath=', rootPath,
      ' credWritten=', shouldWriteCredential);
    return existing;
  }

  private async nextSortNumber_(): Promise<number> {
    const all = await this.sourceTable_.listAll();
    let max = -1;
    for (let i = 0; i < all.length; i++) {
      if (all[i].sortNumber > max) {
        max = all[i].sortNumber;
      }
    }
    return max + 1;
  }

  /**
   * 构造未持久化的 source + credential，用于连接测试。
   * 编辑时若未改密，从旧 credentialRef 读取 secret。
   */
  private async prepareTransient_(
    input: CloudSourceSaveInput
  ): Promise<CloudSourcePrepareResult> {
    const name = (input.name || '').trim() || '未命名';
    const providerType = (input.providerType || CLOUD_PROVIDER_WEBDAV).trim() || CLOUD_PROVIDER_WEBDAV;
    const endpoint = CloudSourceRepository.normalizeEndpoint_(input.endpoint, providerType);
    if (!endpoint) {
      throw new Error(isLocalFolderProvider(providerType)
        ? '目录命名空间不能为空'
        : '服务器地址不能为空');
    }
    const rootPath = CloudPath.normalizeRootPath(input.rootPath || '');

    let oldCred: CloudCredential | null = null;
    if (input.id && input.id > 0) {
      const existing = await this.sourceTable_.getById(input.id);
      if (existing && existing.credentialRef) {
        oldCred = await this.credentialStore_.getCloudCredential(existing.credentialRef);
      }
    }
    const credPair = CloudSourceRepository.resolveCredentialForSave_(providerType, input, oldCred);

    const source = createDefaultCloudSource();
    source.id = input.id && input.id > 0 ? input.id : 0;
    source.name = name;
    source.providerType = providerType;
    source.endpoint = endpoint;
    source.rootPath = rootPath;
    source.configJson = input.configJson || '{}';
    source.enabled = input.enabled !== undefined ? !!input.enabled : true;

    const credential = createEmptyCloudCredential();
    credential.username = credPair.username;
    credential.secret = credPair.secret;

    const prepared: CloudSourcePrepareResult = {
      source: source,
      credential: credential,
    };
    return prepared;
  }

  /**
   * 按 Provider 类型解析新增/测试时的凭证。
   * - webdav: 用户名+密码必填
   * - localfolder: 身份默认 local；口令可空时写入占位 secret，保证下游非空校验通过
   */
  private static resolveCredentialForSave_(
    providerType: string,
    input: CloudSourceSaveInput,
    oldCred: CloudCredential | null
  ): CloudCredentialPair {
    if (isLocalFolderProvider(providerType)) {
      let username = (input.username || '').trim();
      if (!username && oldCred) {
        username = oldCred.username || '';
      }
      if (!username) {
        username = 'local';
      }
      let secret = '';
      if (input.updateSecret === true) {
        secret = input.secret !== undefined ? input.secret : '';
      } else if (input.secret !== undefined && input.secret.length > 0) {
        secret = input.secret;
      } else if (oldCred && oldCred.secret) {
        secret = oldCred.secret;
      } else if (input.secret !== undefined) {
        secret = input.secret;
      }
      if (!secret) {
        secret = 'local';
      }
      const pair: CloudCredentialPair = { username: username, secret: secret };
      return pair;
    }

    // webdav 及其他：严格要求账号密码
    let username = (input.username || '').trim();
    if (!username && oldCred) {
      username = oldCred.username || '';
    }
    if (!username) {
      throw new Error('用户名不能为空');
    }
    let secret = '';
    if (input.updateSecret === true) {
      secret = input.secret !== undefined ? input.secret : '';
    } else if (input.secret !== undefined && input.secret.length > 0) {
      secret = input.secret;
    } else if (oldCred && oldCred.secret) {
      secret = oldCred.secret;
    } else if (input.secret !== undefined) {
      secret = input.secret;
    }
    if (!secret) {
      throw new Error('密码不能为空');
    }
    const pair: CloudCredentialPair = { username: username, secret: secret };
    return pair;
  }

  private static resolveCredentialForUpdate_(
    providerType: string,
    input: CloudSourceSaveInput,
    oldCred: CloudCredential | null
  ): CloudCredentialUpdatePair {
    if (isLocalFolderProvider(providerType)) {
      let finalUser = (input.username || '').trim();
      if (!finalUser && oldCred) {
        finalUser = oldCred.username || '';
      }
      if (!finalUser) {
        finalUser = 'local';
      }
      let finalSecret = '';
      let shouldWrite = true;
      if (input.updateSecret === true) {
        finalSecret = (input.secret !== undefined && input.secret.length > 0)
          ? input.secret
          : 'local';
      } else if (input.secret !== undefined && input.secret.length > 0) {
        finalSecret = input.secret;
      } else if (oldCred && oldCred.secret) {
        finalSecret = oldCred.secret;
        if (finalUser === oldCred.username) {
          shouldWrite = false;
        }
      } else {
        finalSecret = 'local';
      }
      const pair: CloudCredentialUpdatePair = {
        username: finalUser,
        secret: finalSecret,
        shouldWrite: shouldWrite,
      };
      return pair;
    }

    let finalUser = (input.username || '').trim();
    if (!finalUser && oldCred) {
      finalUser = oldCred.username || '';
    }
    if (!finalUser) {
      throw new Error('用户名不能为空');
    }
    let finalSecret = '';
    let shouldWriteCredential = true;
    if (input.updateSecret === true) {
      finalSecret = input.secret !== undefined ? input.secret : '';
      if (!finalSecret) {
        throw new Error('密码不能为空');
      }
    } else if (input.secret !== undefined && input.secret.length > 0) {
      finalSecret = input.secret;
    } else if (oldCred && oldCred.secret) {
      finalSecret = oldCred.secret;
      if (finalUser === oldCred.username) {
        shouldWriteCredential = false;
      }
    } else {
      throw new Error('未找到已保存密码，请重新填写密码后保存');
    }
    const pair: CloudCredentialUpdatePair = {
      username: finalUser,
      secret: finalSecret,
      shouldWrite: shouldWriteCredential,
    };
    return pair;
  }

  private static normalizeEndpoint_(raw: string, providerType?: string): string {
    let s = (raw || '').trim();
    if (!s) {
      return '';
    }
    if (isLocalFolderProvider(providerType || '')) {
      // 统一为 localfolder://namespace
      let ns = s;
      const lower = ns.toLowerCase();
      if (lower.startsWith('localfolder://')) {
        ns = ns.substring('localfolder://'.length);
      } else if (lower.startsWith('local://')) {
        ns = ns.substring('local://'.length);
      } else if (new RegExp('^https?://', 'i').test(ns)) {
        // 误填 http 时剥离协议
        ns = ns.replace(new RegExp('^https?://', 'i'), '');
      }
      ns = ns.replace(new RegExp('^/+'), '').replace(new RegExp('/+$'), '');
      if (ns.indexOf('/') >= 0) {
        ns = ns.split('/')[0];
      }
      ns = ns.replace(new RegExp('[^a-zA-Z0-9_\\-\\u4e00-\\u9fff]', 'g'), '_');
      if (!ns || ns === '.' || ns === '..') {
        return '';
      }
      return 'localfolder://' + ns;
    }

    // WebDAV 等 HTTP 协议
    while (s.length > 8 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (!new RegExp('^https?://', 'i').test(s)) {
      s = 'https://' + s;
    }
    return s;
  }
}

interface CloudSourcePrepareResult {
  source: CloudSource;
  credential: CloudCredential;
}

interface CloudCredentialPair {
  username: string;
  secret: string;
}

interface CloudCredentialUpdatePair {
  username: string;
  secret: string;
  shouldWrite: boolean;
}
