/**
 * 规则订阅页
 * 对应 Android RuleSubScreen — 管理自动订阅的规则（书源/RSS源/替换规则）
 */
import { AppTheme } from '../theme/AppTheme';
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
  name: string = '';
  url: string = '';
  type: number = 0;
  onSave?: (name: string, url: string, type: number) => void;

  build() {
    Column() {
      Text('编辑规则订阅').fontSize(18).fontWeight(FontWeight.Bold).margin({ bottom: 12 })
      TextInput({ placeholder: '名称', text: this.name })
        .onChange((val: string) => { this.name = val; })
        .width('100%').margin({ bottom: 8 }).height(40).borderRadius(4)
      TextInput({ placeholder: 'URL', text: this.url })
        .onChange((val: string) => { this.url = val; })
        .width('100%').margin({ bottom: 12 }).height(40).borderRadius(4)
      Text('订阅类型').fontSize(14).fontColor('#666').margin({ bottom: 8 })
      Row() {
        ForEach(['书源', 'RSS源', '替换规则', '自动'], (label: string, idx: number) => {
          Column() {
            Text(label).fontSize(12)
              .fontColor(this.type === idx ? '#0078D7' : '#666')
              .padding(8)
              .border({ radius: 4, width: 1, color: this.type === idx ? '#0078D7' : '#CCC' })
          }.onClick(() => { this.type = idx; })
        })
      }
      .width('100%').justifyContent(FlexAlign.SpaceEvenly).margin({ bottom: 16 })
      Row() {
        Button('取消').height(36).fontSize(14)
          .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(8)
          .layoutWeight(1).margin({ right: 6 })
          .onClick(() => { this.controller.close(); })
        Button('保存').height(36).fontSize(14)
          .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(8)
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
      this.items.push({
        id: maxId + 1,
        name: name,
        url: url,
        type: type,
        customOrder: this.items.length + 1,
      });
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
    const labels = ['📚 书源', '📡 RSS 源', '🔄 替换规则', '🤖 自动'];
    return labels[type] || '未知';
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor('#0078D7')
          .onClick(() => UiUtil.back(this.getUIContext()))
        Text('规则订阅').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A1A')
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('重置排序').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.resetOrder())
        Button({ type: ButtonType.Normal }) {
          Text('添加').fontSize(14).fontColor('#0078D7').fontWeight(FontWeight.Bold)
        }
        .backgroundColor('transparent')
        .onClick(() => this.openEdit(null))
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== 列表 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7')
      } else if (this.filteredItems.length === 0) {
        Column() {
          Text(this.searchKey ? '无匹配结果' : '暂无规则订阅')
            .fontSize(14).fontColor(this.isDark ? '#AAA' : '#888')
          Text('点击右上角「添加」新增订阅')
            .fontSize(12).fontColor(this.isDark ? '#888' : '#AAA').margin({ top: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.filteredItems, (item: RuleSub) => {
              Row() {
                Column() {
                  Text(item.name).fontSize(15)
                    .fontColor(this.isDark ? '#E0E0E0' : '#333')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.getTypeLabel(item.type)).fontSize(11)
                    .fontColor('#0078D7').margin({ top: 2 })
                  Text(item.url).fontSize(11)
                    .fontColor(this.isDark ? '#888' : '#AAA')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                Button({ type: ButtonType.Normal }) {
                  Text('编辑').fontSize(12).fontColor('#0078D7')
                }
                .backgroundColor('transparent').margin({ right: 4 })
                .onClick(() => this.openEdit(item))
                Button({ type: ButtonType.Normal }) {
                  Text('删除').fontSize(12).fontColor('#F44336')
                }
                .backgroundColor('transparent')
                .onClick(() => this.deleteItem(item))
              }
              .padding(12)
              .borderRadius(8)
              .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
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
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
