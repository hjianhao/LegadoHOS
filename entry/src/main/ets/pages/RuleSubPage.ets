/**
 * 规则订阅页
 * 对应 Android RuleSubScreen — 管理自动订阅的规则（书源/RSS源/替换规则）
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';

interface RuleSub {
  id: number;
  name: string;
  url: string;
  type: number; // 0=书源, 1=RSS源, 2=替换规则, 3=自动
  customOrder: number;
}

@CustomDialog
struct RuleSubEditDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  name: string = '';
  url: string = '';
  type: number = 0;
  onSave?: (name: string, url: string, type: number) => void;

  build() {
    Column() {
      Text($r('app.string.ui_715a993b09')).fontSize(18).fontWeight(FontWeight.Bold).margin({ bottom: 12 })
      TextInput({ placeholder: $r('app.string.ui_1be7ae4fc2'), text: this.name })
        .onChange((val: string) => { this.name = val; })
        .width('100%').margin({ bottom: 8 }).height(40).borderRadius(4)
      TextInput({ placeholder: $r('app.string.ui_0e2d9b0777'), text: this.url })
        .onChange((val: string) => { this.url = val; })
        .width('100%').margin({ bottom: 12 }).height(40).borderRadius(4)
      Text($r('app.string.ui_0edb3ace51')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ bottom: 8 })
      Row() {
        ForEach(['书源', 'RSS源', '替换规则', '自动'], (label: string, idx: number) => {
          Column() {
            Text(label).fontSize(12)
              .fontColor(this.type === idx ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
              .padding(8)
              .border({ radius: 4, width: 1, color: this.type === idx ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark) })
          }.onClick(() => { this.type = idx; })
        })
      }
      .width('100%').justifyContent(FlexAlign.SpaceEvenly).margin({ bottom: 16 })
      Row() {
        Button($r('app.string.common_cancel')).height(40).fontSize(14)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(8)
          .layoutWeight(1).margin({ right: 6 })
          .onClick(() => { this.controller.close(); })
        Button($r('app.string.common_save')).height(40).fontSize(14)
          .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            if (this.onSave) this.onSave(this.name, this.url, this.type);
            this.controller.close();
          })
      }.width('100%')
    }.padding(16).width('100%')
  }
}

@Entry
@Component
export struct RuleSubPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State items: RuleSub[] = [];
  @State isLoading: boolean = true;
  @State searchKey: string = '';
  @State isSearch: boolean = false;
  @State selectedIds: Set<number> = new Set();
  @State showEditDialog: boolean = false;
  @State editItem: RuleSub | null = null;
  @State editName: string = '';
  @State editUrl: string = '';
  @State editType: number = 0;

  private dialogController: CustomDialogController | null = null;

  // 本地存储
  private storageKey: string = 'rule_sub_items';

  aboutToAppear() {
    this.loadFromStorage();
  }

  loadFromStorage() {
    try {
      const stored = AppStorage.get<string>(this.storageKey);
      if (stored) {
        this.items = JSON.parse(stored) as RuleSub[];
      }
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  saveToStorage() {
    AppStorage.set<string>(this.storageKey, JSON.stringify(this.items));
  }

  get filteredItems(): RuleSub[] {
    if (!this.searchKey) return this.items;
    const key = this.searchKey.toLowerCase();
    return this.items.filter(i =>
      i.name.toLowerCase().includes(key) || i.url.toLowerCase().includes(key)
    );
  }

  openEdit(item: RuleSub | null) {
    this.editItem = item;
    this.editName = item?.name || '';
    this.editUrl = item?.url || '';
    this.editType = item?.type || 0;
    this.dialogController = new CustomDialogController({
      builder: RuleSubEditDialog({
        name: this.editName,
        url: this.editUrl,
        type: this.editType,
        onSave: (name: string, url: string, type: number): void => {
          this.doEditSave(name, url, type);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.dialogController.open();
  }

  doEditSave(name: string, url: string, type: number) {
    if (!name || !url) {
      UiUtil.showToast(this.getUIContext(), { message: '名称和 URL 不能为空' });
      return;
    }
    if (this.editItem) {
      // 更新
      const idx = this.items.findIndex(i => i.id === this.editItem!.id);
      if (idx >= 0) {
        const updatedItem: RuleSub = {
          id: this.items[idx].id,
          name: name,
          url: url,
          type: type,
          customOrder: this.items[idx].customOrder,
        };
        this.items[idx] = updatedItem;
      }
    } else {
      // 新增
      let maxId = 0;
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].id > maxId) maxId = this.items[i].id;
      }
      this.items = [...this.items, {
        id: maxId + 1,
        name: name,
        url: url,
        type: type,
        customOrder: this.items.length + 1,
      }];
    }
    this.saveToStorage();
    UiUtil.showToast(this.getUIContext(), { message: '已保存' });
  }

  deleteItem(item: RuleSub) {
    const arr: RuleSub[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id !== item.id) arr.push(this.items[i]);
    }
    this.items = arr;
    this.saveToStorage();
    UiUtil.showToast(this.getUIContext(), { message: '已删除' });
  }

  deleteSelected() {
    const arr: RuleSub[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (!this.selectedIds.has(this.items[i].id)) arr.push(this.items[i]);
    }
    this.items = arr;
    this.selectedIds = new Set();
    this.saveToStorage();
    UiUtil.showToast(this.getUIContext(), { message: '已删除选中项' });
  }

  resetOrder() {
    const arr: RuleSub[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      arr.push({
        id: item.id, name: item.name, url: item.url,
        type: item.type, customOrder: i + 1
      });
    }
    this.items = arr;
    this.saveToStorage();
    UiUtil.showToast(this.getUIContext(), { message: '已重置排序' });
  }

  getTypeLabel(type: number): string {
    const labels = ['书源', 'RSS 源', '替换规则', '自动'];
    return labels[type] || '未知';
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text($r('app.string.ui_8179643cdc')).fontSize(22).fontColor(ThemeColors.primary(this.isDark))
          .accessibilityText($r('app.string.common_back')).onClick(() => UiUtil.back(this.getUIContext()))
        Text($r('app.string.ui_88de0b0f86')).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text($r('app.string.ui_ef855b4789')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent()).margin({ right: 4 })
        .onClick(() => this.resetOrder())
        Button({ type: ButtonType.Normal }) {
          Text($r('app.string.common_add')).fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => this.openEdit(null))
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== 列表 =====
      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark))
      } else if (this.filteredItems.length === 0) {
        Column() {
          Text(this.searchKey ? '无匹配结果' : '暂无规则订阅')
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
          Text($r('app.string.ui_df32b300bf'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.filteredItems, (item: RuleSub) => {
              Row() {
                Column() {
                  Text(item.name).fontSize(15)
                    .fontColor(ThemeColors.onBackground(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.getTypeLabel(item.type)).fontSize(11)
                    .fontColor(ThemeColors.primary(this.isDark)).margin({ top: 2 })
                  Text(item.url).fontSize(11)
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                Button({ type: ButtonType.Normal }) {
                  Text($r('app.string.common_edit')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
                }
                .backgroundColor(ThemeColors.transparent()).margin({ right: 4 })
                .onClick(() => this.openEdit(item))
                Button({ type: ButtonType.Normal }) {
                  Text($r('app.string.common_delete')).fontSize(12).fontColor(ThemeColors.error(this.isDark))
                }
                .backgroundColor(ThemeColors.transparent())
                .onClick(() => this.deleteItem(item))
              }
              .padding(12)
              .borderRadius(8)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .margin({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
            })
          }
          .width('100%')
        }
        .layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
