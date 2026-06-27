/**
 * 书架布局配置面板
 *
 * 底部弹窗，配置书架的各种显示和排序选项
 */
import { SettingsStore } from '../data/preferences/SettingsStore';
import promptAction from '@ohos.promptAction';

@CustomDialog
export struct BookshelfConfigDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;

  onConfigChanged?: () => void;

  /** 当前配置值（从 SettingsStore 加载） */
  @State groupStyle: number = 0;
  @State sortMode: number = 0;
  @State sortOrder: number = 0;
  @State layoutMode: number = 1;
  @State gridColumns: number = 3;
  @State autoUpdate: boolean = true;

  private groupStyleLabels: string[] = ['Tab 标签', '隐藏 Tab', '文件夹'];
  private sortLabels: string[] = ['最后阅读', '书名', '更新时间', '手动排序'];
  private layoutLabels: string[] = ['列表', '网格'];

  aboutToAppear(): void {
    this.loadConfig();
  }

  async loadConfig(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      this.groupStyle = await store.getBookGroupStyle();
      this.sortMode = await store.getBookshelfSortMode();
      this.sortOrder = await store.getBookshelfSortOrder();
      this.layoutMode = await store.getBookshelfLayoutMode();
      this.gridColumns = await store.getBookshelfLayoutGrid();
      this.autoUpdate = await store.getAutoUpdate();
    } catch (_e) { /* 使用默认值 */ }
  }

  async saveConfig(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      await store.setBookGroupStyle(this.groupStyle);
      await store.setBookshelfSortMode(this.sortMode);
      await store.setBookshelfSortOrder(this.sortOrder);
      await store.setBookshelfLayoutMode(this.layoutMode);
      await store.setBookshelfLayoutGrid(this.gridColumns);
      await store.setAutoUpdate(this.autoUpdate);
    } catch (_e) { /* ignore */ }
  }

  private cycleValue(current: number, max: number): number {
    return (current + 1) % max;
  }

  private onSettingChange(): void {
    this.saveConfig();
    if (this.onConfigChanged) this.onConfigChanged();
  }

  build() {
    Column() {
      // ===== 标题栏 =====
      Row() {
        Text('书架布局设置').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button() { Text('✕').fontSize(16).fontColor('#888') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }.padding({ top: 12, bottom: 12 }).width('100%')

      Scroll() {
        Column() {
          // ===== 分组样式 =====
          this.buildSettingRow('分组样式', () => {
            this.groupStyle = this.cycleValue(this.groupStyle, 3);
            this.onSettingChange();
          }, this.groupStyleLabels[this.groupStyle])

          // ===== 排序方式 =====
          this.buildSettingRow('排序方式', () => {
            this.sortMode = this.cycleValue(this.sortMode, 4);
            this.onSettingChange();
          }, this.sortLabels[this.sortMode])

          // ===== 排序顺序 =====
          this.buildSettingRow('排序顺序', () => {
            this.sortOrder = this.sortOrder === 0 ? 1 : 0;
            this.onSettingChange();
          }, this.sortOrder === 0 ? '降序 ↓' : '升序 ↑')

          // ===== 布局模式 =====
          this.buildSettingRow('布局模式', () => {
            this.layoutMode = this.layoutMode === 0 ? 1 : 0;
            this.onSettingChange();
          }, this.layoutLabels[this.layoutMode])

          // ===== 网格列数 =====
          if (this.layoutMode === 1) {
            Row() {
              Text('网格列数').fontSize(14).fontColor(this.isDark ? '#CCC' : '#333')
              Text(String(this.gridColumns)).fontSize(14).fontColor('#0078D7').margin({ left: 8 })
              Slider({
                value: this.gridColumns,
                min: 2,
                max: 7,
                step: 1,
              })
              .width('50%').margin({ left: 8 })
              .onChange((v: number) => {
                this.gridColumns = v;
                this.onSettingChange();
              })
            }
            .width('100%').padding({ top: 8, bottom: 8 })
            .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#E8E8E8' })
          }

          // ===== 自动刷新 =====
          Row() {
            Text('启动时自动刷新').fontSize(14).fontColor(this.isDark ? '#CCC' : '#333').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
              .onChange((v: boolean) => {
                this.autoUpdate = v;
                this.onSettingChange();
              })
          }
          .width('100%').padding({ top: 8, bottom: 8 })
          .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#E8E8E8' })

        }.width('100%').padding({ left: 8, right: 8 })
      }
      .layoutWeight(1).width('100%')

      // ===== 底部关闭 =====
      Button('关闭').height(36).fontSize(14)
        .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(8).width('100%').margin({ top: 8 })
        .onClick(() => { this.controller.close(); })
    }
    .padding({ left: 16, right: 16, top: 0, bottom: 12 })
    .width('100%').height('55%')
    .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  buildSettingRow(title: string, onClick: () => void, valueText: string) {
    Row() {
      Text(title).fontSize(14).fontColor(this.isDark ? '#CCC' : '#333').layoutWeight(1)
      Text(valueText).fontSize(13).fontColor('#0078D7')
      Text('›').fontSize(16).fontColor('#AAA').margin({ left: 4 })
    }
    .width('100%').padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#E8E8E8' })
    .onClick(() => { onClick(); })
  }
}
