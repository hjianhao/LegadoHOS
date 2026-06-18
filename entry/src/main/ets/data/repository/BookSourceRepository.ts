/**
 * 书源仓库
 */
import { AppDatabase } from '../database/AppDatabase';
import { BookSourceTable } from '../database/BookSourceTable';
import { BookSource } from '../../model/BookSource';

export class BookSourceRepository {
  private table: BookSourceTable;

  constructor() {
    this.table = new BookSourceTable(AppDatabase.getInstance().rdbStore);
  }

  async getEnabledSources(): Promise<BookSource[]> {
    return await this.table.getEnabledSources();
  }

  async getAllSources(): Promise<BookSource[]> {
    return await this.table.getAllSources();
  }

  async importSources(json: string): Promise<number> {
    return await this.table.importSources(json);
  }

  async exportSources(): Promise<string> {
    return await this.table.exportSources();
  }

  async toggleEnabled(id: number, enabled: boolean): Promise<void> {
    await this.table.toggleEnabled(id, enabled);
  }

  async deleteSource(id: number): Promise<void> {
    await this.table.deleteSource(id);
  }
}
