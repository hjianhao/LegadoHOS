/**
 * cloud_sources 表 DAO
 */
import relationalStore from '@ohos.data.relationalStore';
import { CloudSource, createDefaultCloudSource } from '../../model/CloudSource';
import { RdbUtil } from './RdbUtil';

export const CLOUD_SOURCES_TABLE = 'cloud_sources';

export const CloudSourceTableCreate = `
  CREATE TABLE IF NOT EXISTS cloud_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    provider_type TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    root_path TEXT NOT NULL DEFAULT '',
    config_json TEXT NOT NULL DEFAULT '{}',
    credential_ref TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    sort_number INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
`;

export class CloudSourceTable {
  static readonly TABLE_NAME = CLOUD_SOURCES_TABLE;
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async listEnabled(): Promise<CloudSource[]> {
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.equalTo('enabled', 1);
    predicates.orderByAsc('sort_number');
    predicates.orderByAsc('id');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toList_(rs);
  }

  async listAll(): Promise<CloudSource[]> {
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.orderByAsc('sort_number');
    predicates.orderByAsc('id');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toList_(rs);
  }

  async getById(id: number): Promise<CloudSource | null> {
    if (id <= 0) {
      return null;
    }
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const list = this.toList_(rs);
    return list.length > 0 ? list[0] : null;
  }

  async insert(source: CloudSource): Promise<number> {
    const row = this.toRow_(source);
    return await RdbUtil.insert(this.rdbStore, CloudSourceTable.TABLE_NAME, row);
  }

  async update(source: CloudSource): Promise<void> {
    if (source.id <= 0) {
      throw new Error('CloudSource.update 需要有效 id');
    }
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.equalTo('id', source.id);
    await RdbUtil.update(this.rdbStore, this.toRow_(source), predicates);
  }

  /** 仅更新启用状态，不触碰凭证。 */
  async updateEnabled(id: number, enabled: boolean): Promise<void> {
    if (id <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.rdbStore, {
      'enabled': enabled ? 1 : 0,
      'updated_at': Date.now(),
    }, predicates);
  }

  async delete(id: number): Promise<void> {
    if (id <= 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  /** 按给定 id 顺序重写 sort_number（0..n-1）。 */
  async updateSort(idsInOrder: number[]): Promise<void> {
    if (!idsInOrder || idsInOrder.length === 0) {
      return;
    }
    const now = Date.now();
    for (let i = 0; i < idsInOrder.length; i++) {
      const id = idsInOrder[i];
      if (id <= 0) {
        continue;
      }
      const predicates = new relationalStore.RdbPredicates(CloudSourceTable.TABLE_NAME);
      predicates.equalTo('id', id);
      await RdbUtil.update(this.rdbStore, {
        'sort_number': i,
        'updated_at': now,
      }, predicates);
    }
  }

  private toRow_(source: CloudSource): relationalStore.ValuesBucket {
    return {
      'name': source.name,
      'provider_type': source.providerType,
      'endpoint': source.endpoint,
      'root_path': source.rootPath || '',
      'config_json': source.configJson || '{}',
      'credential_ref': source.credentialRef,
      'enabled': source.enabled ? 1 : 0,
      'sort_number': source.sortNumber,
      'created_at': source.createdAt,
      'updated_at': source.updatedAt,
    };
  }

  private toList_(rs: relationalStore.ResultSet): CloudSource[] {
    const list: CloudSource[] = [];
    while (RdbUtil.next(rs)) {
      const item = createDefaultCloudSource();
      item.id = RdbUtil.long(rs, 'id');
      item.name = RdbUtil.string(rs, 'name') || '';
      item.providerType = RdbUtil.string(rs, 'provider_type') || 'webdav';
      item.endpoint = RdbUtil.string(rs, 'endpoint') || '';
      item.rootPath = RdbUtil.string(rs, 'root_path') || '';
      item.configJson = RdbUtil.string(rs, 'config_json') || '{}';
      item.credentialRef = RdbUtil.string(rs, 'credential_ref') || '';
      item.enabled = RdbUtil.long(rs, 'enabled') !== 0;
      item.sortNumber = RdbUtil.long(rs, 'sort_number');
      item.createdAt = RdbUtil.long(rs, 'created_at');
      item.updatedAt = RdbUtil.long(rs, 'updated_at');
      list.push(item);
    }
    RdbUtil.close(rs);
    return list;
  }
}
