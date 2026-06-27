/**
 * 书架分组表 (book_groups)
 *
 * 设计：
 * - DB 仅存储自定义分组（id >= BookGroup.CUSTOM = 10）
 * - 系统内置分组（id 0-6）由 BookGroup 模型常量提供
 * - getAllGroups() 将两者合并返回
 */
import relationalStore from '@ohos.data.relationalStore';
import { BookGroupItem, getSystemGroupDefaults, bookMatchesSystemGroup, BOOK_GROUP_TABLE_NAME, BookGroup } from '../../model/BookGroup';

export const BookGroupTableCreate = `
  CREATE TABLE IF NOT EXISTS ${BOOK_GROUP_TABLE_NAME} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    "order" INTEGER DEFAULT 0,
    cover TEXT DEFAULT '',
    enable_refresh INTEGER DEFAULT 1,
    is_show INTEGER DEFAULT 1,
    is_private INTEGER DEFAULT 0,
    book_sort INTEGER DEFAULT -1,
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export class BookGroupTable {
  static readonly TABLE_NAME = BOOK_GROUP_TABLE_NAME;

  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  // ============ 查询 ============

  /** 获取所有分组（系统组 + 自定义组），按 order 排序 */
  async getAllGroups(): Promise<BookGroupItem[]> {
    const systemGroups = getSystemGroupDefaults();
    const customGroups = await this.getCustomGroups();
    // 合并：系统组在前，自定义组在后，各自按 order 排
    systemGroups.sort((a, b) => a.order - b.order);
    customGroups.sort((a, b) => a.order - b.order);
    return [...systemGroups, ...customGroups];
  }

  /** 仅获取自定义分组（来自 DB） */
  async getCustomGroups(): Promise<BookGroupItem[]> {
    const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
    predicates.orderByAsc('"order"');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toItems(rs);
  }

  /** 获取单个分组 */
  async getGroupById(id: number): Promise<BookGroupItem | null> {
    if (id < BookGroup.CUSTOM) {
      // 系统组
      const groups = getSystemGroupDefaults();
      return groups.find(g => g.id === id) || null;
    }
    const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await this.rdbStore.query(predicates, []);
    const items = this.toItems(rs);
    return items.length > 0 ? items[0] : null;
  }

  /** 获取显示在标签栏的分组 */
  async getShownGroups(): Promise<BookGroupItem[]> {
    const all = await this.getAllGroups();
    return all.filter(g => g.show);
  }

  /** 获取分组的书籍数量（所有书，非仅书架） */
  async getGroupBookCount(groupId: number, bookDao: any): Promise<number> {
    if (groupId < BookGroup.CUSTOM) {
      // 系统组：通过条件过滤
      const books = await bookDao.getAllShelfBooks();
      return books.filter((b: any) => bookMatchesSystemGroup(b, groupId)).length;
    }
    // 自定义组：按 group_id 查询
    const predicates = new relationalStore.RdbPredicates('books');
    predicates.equalTo('is_shelf', 1);
    predicates.equalTo('group_id', groupId);
    const rs = await this.rdbStore.query(predicates, ['id']);
    const count = rs.rowCount;
    rs.close();
    return count;
  }

  /** 批量获取分组书籍数量 */
  async getAllGroupBookCounts(bookDao: any): Promise<Record<number, number>> {
    const groups = await this.getAllGroups();
    const counts: Record<number, number> = {};
    for (const g of groups) {
      counts[g.id] = await this.getGroupBookCount(g.id, bookDao);
    }
    return counts;
  }

  // ============ CRUD ============

  /** 创建自定义分组 */
  async insertGroup(name: string): Promise<number> {
    const now = Date.now();
    // 获取最大 order
    const customGroups = await this.getCustomGroups();
    const maxOrder = customGroups.reduce((max, g) => Math.max(max, g.order), 0);
    const row: relationalStore.ValuesBucket = {
      'name': name.trim(),
      '"order"': maxOrder + 1,
      'cover': '',
      'enable_refresh': 1,
      'is_show': 1,
      'is_private': 0,
      'book_sort': -1,
      'create_time': now,
      'update_time': now,
    };
    return await this.rdbStore.insert(BookGroupTable.TABLE_NAME, row);
  }

  /** 更新自定义分组 */
  async updateGroup(item: BookGroupItem): Promise<void> {
    if (item.id < BookGroup.CUSTOM) {
      return; // 系统组不可通过 DB 更新
    }
    const row: relationalStore.ValuesBucket = {
      'name': item.name,
      '"order"': item.order,
      'cover': item.cover || '',
      'enable_refresh': item.enableRefresh ? 1 : 0,
      'is_show': item.show ? 1 : 0,
      'is_private': item.isPrivate ? 1 : 0,
      'book_sort': item.bookSort,
      'update_time': Date.now(),
    };
    const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
    predicates.equalTo('id', item.id);
    await this.rdbStore.update(row, predicates);
  }

  /** 删除自定义分组，并将该分组下所有书籍移回「全部」分组 */
  async deleteGroup(id: number, bookDao?: any): Promise<void> {
    if (id < BookGroup.CUSTOM) {
      return; // 系统组不可删除
    }
    // 将属于该分组的所有书籍重置为 BookGroup.ALL
    if (bookDao) {
      await bookDao.batchUpdateGroupForDelete(id);
    }
    const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.delete(predicates);
  }

  /** 批量更新分组排序 */
  async reorderGroups(ids: number[]): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] >= BookGroup.CUSTOM) {
        const row: relationalStore.ValuesBucket = { '"order"': i, 'update_time': Date.now() };
        const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
        predicates.equalTo('id', ids[i]);
        await this.rdbStore.update(row, predicates);
      }
    }
  }

  /** 重命名自定义分组 */
  async renameGroup(id: number, newName: string): Promise<void> {
    if (id < BookGroup.CUSTOM) {
      return;
    }
    const row: relationalStore.ValuesBucket = { 'name': newName.trim(), 'update_time': Date.now() };
    const predicates = new relationalStore.RdbPredicates(BookGroupTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.update(row, predicates);
  }

  // ============ 工具 ============

  private toItems(rs: relationalStore.ResultSet): BookGroupItem[] {
    const items: BookGroupItem[] = [];
    while (rs.goToNextRow()) {
      items.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')) || '',
        order: rs.getLong(rs.getColumnIndex('"order"')),
        cover: rs.getString(rs.getColumnIndex('cover')) || '',
        isSystem: false,
        enableRefresh: rs.getLong(rs.getColumnIndex('enable_refresh')) === 1,
        show: rs.getLong(rs.getColumnIndex('is_show')) === 1,
        isPrivate: rs.getLong(rs.getColumnIndex('is_private')) === 1,
        bookSort: rs.getLong(rs.getColumnIndex('book_sort')),
      });
    }
    rs.close();
    return items;
  }
}
