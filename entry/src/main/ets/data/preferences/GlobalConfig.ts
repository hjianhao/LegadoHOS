/**
 * 全局配置单例
 * 所有页面通过 GlobalConfig.instance 读写配置，底层持久化到 AppStorage + preferences
 */
import { SettingsStore } from './SettingsStore';

export class GlobalConfig {
  private static instance_: GlobalConfig;

  // 书架布局
  groupStyle: number = 0;       // 0=Tab, 1=隐藏, 2=文件夹
  sortMode: number = 0;         // 0=最后阅读, 1=书名, 2=更新时间, 3=手动
  sortOrder: number = 0;        // 0=降序, 1=升序
  layoutMode: number = 0;       // 0=列表, 1=网格
  gridColumns: number = 3;      // 网格列数
  gridStyle: number = 0;        // 0=标准, 1=紧凑, 2=仅封面
  showDivider: boolean = true;  // 列表分隔线
  coverWidth: number = 84;      // 封面宽度
  isCompact: boolean = false;   // 精简详情
  titleMaxLines: number = 2;    // 书名最大行数
  coverShadow: boolean = false; // 封面阴影
  showUnread: boolean = true;   // 显示未读
  showTip: boolean = true;      // 显示类型标签
  showLastUpdateTime: boolean = true;
  showBookIntro: boolean = true; // 显示更多信息
  showLatestChapter: boolean = true;
  showTag: boolean = true;
  introMaxLines: number = 2;    // 简介行数
  refreshLimit: number = 0;     // 刷新上限, 0=不限制

  private constructor() {}

  static getInstance(): GlobalConfig {
    if (!GlobalConfig.instance_) {
      GlobalConfig.instance_ = new GlobalConfig();
    }
    return GlobalConfig.instance_;
  }

  /** 从持久化加载 */
  async load(): Promise<void> {
    const s = SettingsStore.getInstance();
    this.groupStyle = await s.getBookGroupStyle();
    this.sortMode = await s.getBookshelfSortMode();
    this.sortOrder = await s.getBookshelfSortOrder();
    this.layoutMode = await s.getBookshelfLayoutMode();
    this.gridColumns = await s.getBookshelfLayoutGrid();
    this.gridStyle = await s.getBookshelfGridStyle();
    this.showDivider = await s.getBookshelfShowDivider();
    this.coverWidth = await s.getBookshelfCoverWidth();
    this.isCompact = await s.getBookshelfCompact();
    this.coverShadow = await s.getBookshelfCoverShadow();
    this.showUnread = await s.getShowUnread();
    this.showTip = await s.getBookshelfShowTip();
    this.showBookIntro = await s.getShowBookIntro();
    this.showTag = await s.getBookshelfShowTag();
    this.showLatestChapter = await s.getBookshelfShowLatestChapter();
    this.introMaxLines = await s.getBookshelfIntroMaxLines();
    this.titleMaxLines = await s.getBookshelfTitleMaxLines();
    this.showLastUpdateTime = await s.getShowLastUpdateTime();
    this.refreshLimit = await s.getBookshelfRefreshLimit();
    // 同步到 AppStorage（触发 @StorageLink）
    this.syncToAppStorage();
  }

  /** 保存到持久化 */
  async save(): Promise<void> {
    const s = SettingsStore.getInstance();
    await s.setBookGroupStyle(this.groupStyle);
    await s.setBookshelfSortMode(this.sortMode);
    await s.setBookshelfSortOrder(this.sortOrder);
    await s.setBookshelfLayoutMode(this.layoutMode);
    await s.setBookshelfLayoutGrid(this.gridColumns);
    await s.setBookshelfGridStyle(this.gridStyle);
    await s.setBookshelfShowDivider(this.showDivider);
    await s.setBookshelfCoverWidth(this.coverWidth);
    await s.setBookshelfCompact(this.isCompact);
    await s.setBookshelfCoverShadow(this.coverShadow);
    await s.setShowUnread(this.showUnread);
    await s.setBookshelfShowTip(this.showTip);
    await s.setShowBookIntro(this.showBookIntro);
    await s.setBookshelfShowTag(this.showTag);
    await s.setBookshelfShowLatestChapter(this.showLatestChapter);
    await s.setBookshelfIntroMaxLines(this.introMaxLines);
    await s.setBookshelfTitleMaxLines(this.titleMaxLines);
    await s.setShowLastUpdateTime(this.showLastUpdateTime);
    await s.setBookshelfRefreshLimit(this.refreshLimit);
    // 同步到 AppStorage
    this.syncToAppStorage();
  }

  /** 同步当前值到 AppStorage（触发 UI 刷新） */
  syncToAppStorage(): void {
    AppStorage.setOrCreate<number>('gc_layoutMode', this.layoutMode);
    AppStorage.setOrCreate<number>('gc_groupStyle', this.groupStyle);
    AppStorage.setOrCreate<number>('gc_sortMode', this.sortMode);
    AppStorage.setOrCreate<number>('gc_sortOrder', this.sortOrder);
    AppStorage.setOrCreate<number>('gc_gridColumns', this.gridColumns);
    AppStorage.setOrCreate<number>('gc_gridStyle', this.gridStyle);
    AppStorage.setOrCreate<boolean>('gc_showUnread', this.showUnread);
    AppStorage.setOrCreate<boolean>('gc_showTip', this.showTip);
    AppStorage.setOrCreate<boolean>('gc_showBookIntro', this.showBookIntro);
    AppStorage.setOrCreate<boolean>('gc_showTag', this.showTag);
    AppStorage.setOrCreate<boolean>('gc_showLatest', this.showLatestChapter);
    AppStorage.setOrCreate<number>('gc_introLines', this.introMaxLines);
    AppStorage.setOrCreate<number>('gc_titleLines', this.titleMaxLines);
    AppStorage.setOrCreate<boolean>('gc_showLastUpd', this.showLastUpdateTime);
    AppStorage.setOrCreate<number>('gc_coverWidth', this.coverWidth);
    AppStorage.setOrCreate<boolean>('gc_showDivider', this.showDivider);
    AppStorage.setOrCreate<boolean>('gc_isCompact', this.isCompact);
    AppStorage.setOrCreate<boolean>('gc_coverShadow', this.coverShadow);
    AppStorage.setOrCreate<number>('gc_refreshLimit', this.refreshLimit);
  }
}
