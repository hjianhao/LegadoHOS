/**
 * 通用 ArkUI 懒加载数组数据源。
 * 页面在筛选、排序或刷新后调用 reset，LazyForEach 会收到一次原子重载通知。
 */
export class ArrayDataSource<T> implements IDataSource {
  private items_: T[] = [];
  private listeners_: DataChangeListener[] = [];

  totalCount(): number {
    return this.items_.length;
  }

  getData(index: number): T {
    return this.items_[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners_.includes(listener)) this.listeners_.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners_ = this.listeners_.filter((item: DataChangeListener): boolean => item !== listener);
  }

  reset(items: T[]): void {
    this.items_ = [...items];
    for (const listener of this.listeners_) listener.onDataReloaded();
  }
}
