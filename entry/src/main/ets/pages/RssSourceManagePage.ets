/**
 * RSS 源管理页
 * 对应 Android RssSourceScreen（管理模式）
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource } from '../model/RSSSource';
import { RssImportDialog } from './RssImportDialog';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
export struct RssSourceManagePage {
  @StorageProp('isDark') isDark: boolean = false;
  @State sources: RSSSource[] = [];
  @State isLoading: boolean = true;
  @State selectedIds: string[] = [];
  @State searchKey: string = '';
  private importDialogController: CustomDialogController = new CustomDialogController({
    builder: RssImportDialog({ onImportSuccess: () => { this.loadData(); } }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    customStyle: true,
    cornerRadius: 16,
  });

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    this.loadData();
  }

  async loadData() {
    this.isLoading = true;
    try {
      await this.db.waitForInit();
      const all = await this.db.rssSourceTable.getAll();
      this.sources = all;
    } catch (e) {
      console.error('[RssSourceManagePage] loadData failed: ' + e);
    } finally {
      this.isLoading = false;
      // 通知 RssMainPage 刷新
      AppStorage.setOrCreate('rssRefreshKey', Date.now());
    }
  }

  toggleSelect(sourceUrl: string) {
    const idx = this.selectedIds.indexOf(sourceUrl);
    if (idx !== -1) {
      // STATE-002: replace entire array instead of in-place splice
      const next: string[] = [];
      for (let i = 0; i < this.selectedIds.length; i++) {
        if (i !== idx) next.push(this.selectedIds[i]);
      }
      this.selectedIds = next;
    } else {
      this.selectedIds = [...this.selectedIds, sourceUrl];
    }
  }

  async enableSelection(enabled: boolean) {
    for (let i = 0; i < this.selectedIds.length; i++) {
      await this.db.rssSourceTable.setEnabled(this.selectedIds[i], enabled);
    }
    UiUtil.showToast(this.getUIContext(), { message: enabled ? '已启用' : '已禁用' });
    this.loadData();
  }

  async deleteSelected() {
    try {
      for (let i = 0; i < this.selectedIds.length; i++) {
        await this.db.rssSourceTable.delete(this.selectedIds[i]);
      }
      this.selectedIds = [];
      UiUtil.showToast(this.getUIContext(), { message: '删除成功' });
      this.loadData();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '删除失败: ' + e });
    }
  }

  async onDeleteSingle(sourceUrl: string) {
    try {
      await this.db.rssSourceTable.delete(sourceUrl);
      UiUtil.showToast(this.getUIContext(), { message: '已删除' });
      this.loadData();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '删除失败' });
    }
  }

  getFiltered(): RSSSource[] {
    let list = this.sources;
    const key = this.searchKey.toLowerCase();
    if (key) {
      list = list.filter(s =>
        s.sourceName.toLowerCase().includes(key) ||
        s.sourceUrl.toLowerCase().includes(key)
      );
    }
    return list;
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text($r('app.string.ui_4968e7f610')).fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text($r('app.string.ui_02e2c453fc')).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text($r('app.string.common_import')).fontSize(14).fontColor(ThemeColors.warning(this.isDark)).fontWeight(FontWeight.Bold)
        }
        .backgroundColor(ThemeColors.transparent()).margin({ right: 8 })
        .onClick(() => {
          this.importDialogController.open();
        })
        Button({ type: ButtonType.Normal }) {
          Text($r('app.string.common_add')).fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          UiUtil.pushUrl(this.getUIContext(), { url: 'pages/RssSourceEditPage' });
        })
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      Search({ placeholder: $r('app.string.ui_6846e924de'), value: this.searchKey })
        .onSubmit((val: string) => { this.searchKey = val; })
        .onChange((val: string) => { if (!val) this.searchKey = ''; })
        .width('100%').padding({ left: 12, right: 12, bottom: 8 })

      if (this.selectedIds.length > 0) {
        Row() {
          Text('已选 ' + this.selectedIds.length + ' 项')
            .fontSize(13).fontColor(ThemeColors.primary(this.isDark))
          Blank()
          Button({ type: ButtonType.Normal }) {
            Text($r('app.string.ui_d4e9ca3dd4')).fontSize(13).fontColor(ThemeColors.success(this.isDark))
          }.backgroundColor(ThemeColors.transparent()).onClick(() => this.enableSelection(true))
          Button({ type: ButtonType.Normal }) {
            Text($r('app.string.ui_be70be5a2e')).fontSize(13).fontColor(ThemeColors.error(this.isDark))
          }.backgroundColor(ThemeColors.transparent()).onClick(() => this.enableSelection(false))
          Button({ type: ButtonType.Normal }) {
            Text($r('app.string.common_delete')).fontSize(13).fontColor(ThemeColors.error(this.isDark))
          }.backgroundColor(ThemeColors.transparent()).onClick(() => this.deleteSelected())
        }
        .width('100%').padding({ left: 12, right: 12, bottom: 4 })
      }

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark))
      } else if (this.getFiltered().length === 0) {
        Column() {
          Text($r('app.string.ui_f0ca898ae3')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
          Text($r('app.string.ui_3b2cc3b570'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.getFiltered(), (source: RSSSource) => {
              Row() {
                Toggle({ type: ToggleType.Checkbox, isOn: this.selectedIds.indexOf(source.sourceUrl) !== -1 })
                  .onChange(() => this.toggleSelect(source.sourceUrl))

                Column() {
                  Text(source.sourceName).fontSize(15)
                    .fontColor(ThemeColors.onBackground(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(source.sourceUrl).fontSize(11)
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                  Row() {
                    if (source.sourceGroup) {
                      Text(source.sourceGroup).fontSize(10).fontColor(ThemeColors.primary(this.isDark))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .border({ radius: 4 }).borderColor(ThemeColors.primary(this.isDark)).borderWidth(0.5)
                    }
                    if (!source.enabled) {
                      Text($r('app.string.ui_0fe5a98e9f')).fontSize(10).fontColor(ThemeColors.error(this.isDark))
                        .margin({ left: 6 })
                    }
                  }.margin({ top: 4 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 8 })

                Button({ type: ButtonType.Normal }) {
                  Text($r('app.string.common_edit')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
                }
                .backgroundColor(ThemeColors.transparent()).margin({ right: 4 })
                .onClick(() => {
                  UiUtil.pushUrl(this.getUIContext(), { url: 'pages/RssSourceEditPage', params: { sourceUrl: source.sourceUrl } });
                })
                Button({ type: ButtonType.Normal }) {
                  Text($r('app.string.common_delete')).fontSize(12).fontColor(ThemeColors.error(this.isDark))
                }
                .backgroundColor(ThemeColors.transparent())
                .onClick(() => {
                  UiUtil.showAlertDialog(this.getUIContext(), {
                    title: '删除确认',
                    message: '确定要删除此 RSS 源？',
                    primaryButton: { value: '取消', action: () => {} },
                    secondaryButton: {
                      value: '删除',
                      action: () => { this.onDeleteSingle(source.sourceUrl); }
                    },
                    cancel: () => {}
                  });
                })
              }
              .padding(12).borderRadius(8)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .margin({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
            })
          }.width('100%')
        }.layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
