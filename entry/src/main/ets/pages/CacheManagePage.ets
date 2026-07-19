/**
 * 缓存管理页 — 查看与清理书籍章节内容缓存
 * - 顶部：总占用大小 + 清理全部
 * - 列表：每本书的已缓存章节数与占用大小，可单书清理
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { CacheManager, BookCacheStat } from '../engine/cache/CacheManager';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { AppTitleBar } from '../components/common/AppTitleBar';

@Entry
@Component
struct CacheManagePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State totalSize: number = 0;
  @State stats: BookCacheStat[] = [];
  @State isLoading: boolean = true;

  aboutToAppear(): void {
    this.loadStats();
  }

  private async loadStats(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const cm = CacheManager.getInstance();
      this.totalSize = await cm.getCacheSize();
      this.stats = await cm.getBookCacheStats();
    } catch (e) {
      console.warn('[CacheManage] load fail:', (e as Error).message);
    }
    this.isLoading = false;
  }

  private clearBook(stat: BookCacheStat): void {
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '清理缓存',
      message: '删除《' + stat.name + '》的全部章节缓存？（保留目录和阅读进度）',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          await CacheManager.getInstance().clearBookCache(stat.bookId);
          UiUtil.showToast(this.getUIContext(), { message: '已清理《' + stat.name + '》', duration: 1500 });
          this.loadStats();
        }
      }
    });
  }

  private clearAll(): void {
    if (this.stats.length === 0) return;
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '清理全部缓存',
      message: '将删除所有书籍的章节内容缓存（保留目录和阅读进度），确定继续？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '全部删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          await CacheManager.getInstance().clearAll();
          UiUtil.showToast(this.getUIContext(), { message: '已清理全部缓存', duration: 1500 });
          this.loadStats();
        }
      }
    });
  }

  build() {
    Column() {
      AppTitleBar({ title: '缓存管理', onBack: () => { UiUtil.back(this.getUIContext()); } })

      // 总览卡片
      Row() {
        Column() {
          Text('章节内容缓存').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          Text(CacheManager.formatSize(this.totalSize)).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)

        Button('清理全部').fontSize(13).fontColor('#FFF')
          .backgroundColor(this.stats.length > 0
            ? ThemeColors.error(this.isDark) : ThemeColors.outlineVariant(this.isDark))
          .enabled(this.stats.length > 0)
          .height(34).borderRadius(17).padding({ left: 16, right: 16 })
          .onClick(() => { this.clearAll(); })
      }
      .width('calc(100% - 24)').margin({ left: 12, right: 12, top: 12, bottom: 8 })
      .padding(16).borderRadius(12)
      .backgroundColor(ThemeColors.surface(this.isDark))

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 40 })
      } else if (this.stats.length === 0) {
        Text('暂无章节缓存')
          .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
          .margin({ top: 60 })
      } else {
        List() {
          ForEach(this.stats, (stat: BookCacheStat) => {
            ListItem() {
              Row() {
                Column() {
                  Text(stat.name).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColors.onBackground(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  Text('已缓存 ' + stat.chapters + ' 章 · ' + CacheManager.formatSize(stat.size))
                    .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                    .margin({ top: 4 })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                Button('清理').fontSize(13)
                  .fontColor(ThemeColors.error(this.isDark))
                  .backgroundColor(Color.Transparent)
                  .height(34).padding({ left: 8, right: 8 })
                  .onClick((): void => { this.clearBook(stat); })
              }
              .width('100%').padding({ left: 16, right: 8, top: 10, bottom: 10 })
            }
            .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
          }, (stat: BookCacheStat): string => { return String(stat.bookId); })
        }.width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
