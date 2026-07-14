import relationalStore from '@ohos.data.relationalStore';

export class RdbUtil {
  static async getRdbStore(
    context: Context,
    config: relationalStore.StoreConfig
  ): Promise<relationalStore.RdbStore> {
    try {
      return await relationalStore.getRdbStore(context, config);
    } catch (err) {
      throw err;
    }
  }

  static async query(
    store: relationalStore.RdbStore,
    predicates: relationalStore.RdbPredicates,
    columns: Array<string> = []
  ): Promise<relationalStore.ResultSet> {
    try {
      return await store.query(predicates, columns);
    } catch (err) {
      throw err;
    }
  }

  static async querySql(
    store: relationalStore.RdbStore,
    sql: string,
    args: Array<relationalStore.ValueType> = []
  ): Promise<relationalStore.ResultSet> {
    try {
      return await store.querySql(sql, args);
    } catch (err) {
      throw err;
    }
  }

  static async insert(
    store: relationalStore.RdbStore,
    table: string,
    values: relationalStore.ValuesBucket
  ): Promise<number> {
    try {
      return await store.insert(table, values);
    } catch (err) {
      throw err;
    }
  }

  static async batchInsert(
    store: relationalStore.RdbStore,
    table: string,
    values: Array<relationalStore.ValuesBucket>
  ): Promise<number> {
    try {
      return await store.batchInsert(table, values);
    } catch (err) {
      throw err;
    }
  }

  static async update(
    store: relationalStore.RdbStore,
    values: relationalStore.ValuesBucket,
    predicates: relationalStore.RdbPredicates
  ): Promise<number> {
    try {
      return await store.update(values, predicates);
    } catch (err) {
      throw err;
    }
  }

  static async delete(
    store: relationalStore.RdbStore,
    predicates: relationalStore.RdbPredicates
  ): Promise<number> {
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw err;
    }
  }

  static async executeSql(store: relationalStore.RdbStore, sql: string): Promise<void> {
    try {
      await store.executeSql(sql);
    } catch (err) {
      throw err;
    }
  }

  static first(rs: relationalStore.ResultSet): boolean {
    try {
      return rs.goToFirstRow();
    } catch (_e) {
      return false;
    }
  }

  static next(rs: relationalStore.ResultSet): boolean {
    try {
      return rs.goToNextRow();
    } catch (_e) {
      return false;
    }
  }

  static close(rs: relationalStore.ResultSet): void {
    try {
      rs.close();
    } catch (_e) {
      /* ignore */
    }
  }

  static long(rs: relationalStore.ResultSet, column: string): number {
    try {
      return rs.getLong(rs.getColumnIndex(column));
    } catch (_e) {
      return 0;
    }
  }

  static longAt(rs: relationalStore.ResultSet, index: number): number {
    try {
      return rs.getLong(index);
    } catch (_e) {
      return 0;
    }
  }

  static double(rs: relationalStore.ResultSet, column: string): number {
    try {
      return rs.getDouble(rs.getColumnIndex(column));
    } catch (_e) {
      return 0;
    }
  }

  static string(rs: relationalStore.ResultSet, column: string): string {
    try {
      return rs.getString(rs.getColumnIndex(column)) || '';
    } catch (_e) {
      return '';
    }
  }

  static stringAt(rs: relationalStore.ResultSet, index: number): string {
    try {
      return rs.getString(index) || '';
    } catch (_e) {
      return '';
    }
  }
}
