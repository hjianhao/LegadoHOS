/** 书源数据变更通知：让常驻页签重新读取数据库，避免继续展示组件内存中的旧列表。 */
export class BookSourceChangeNotifier {
  static readonly STORAGE_KEY: string = 'bookSourceRevision';

  static notify(): void {
    const revision = AppStorage.get<number>(BookSourceChangeNotifier.STORAGE_KEY) || 0;
    AppStorage.setOrCreate<number>(BookSourceChangeNotifier.STORAGE_KEY, revision + 1);
  }
}
