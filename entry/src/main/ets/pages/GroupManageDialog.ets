/**
 * 分组管理对话框
 *
 * 功能：
 * - 显示所有分组列表
 * - 新增分组
 * - 编辑分组名（重命名）
 * - 删除分组（从所有书源移除该分组名）
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import promptAction from '@ohos.promptAction';

@CustomDialog
export struct GroupManageDialog {
  controller: CustomDialogController;
  @State groups: string[] = [];
  @State isLoading: boolean = true;
  @State editGroupName: string = '';
  @State showAddInput: boolean = false;
  @State showEditInput: boolean = false;
  @State editingGroup: string = '';
  @State addGroupName: string = '';

  onGroupChanged?: () => void;

  aboutToAppear(): void {
    this.loadGroups();
  }

  async loadGroups(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      this.groups = await dao.getAllGroups();
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  private async onAddGroup(): Promise<void> {
    const name = this.addGroupName.trim();
    if (!name) {
      promptAction.showToast({ message: '请输入分组名称', duration: 1500 });
      return;
    }
    if (this.groups.includes(name)) {
      promptAction.showToast({ message: '分组已存在', duration: 1500 });
      return;
    }
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      await dao.addGroupToNoGroupSources(name);
      this.addGroupName = '';
      this.showAddInput = false;
      await this.loadGroups();
      if (this.onGroupChanged) this.onGroupChanged();
      promptAction.showToast({ message: '已添加分组 ' + name, duration: 1500 });
    } catch (_e) { /* ignore */ }
  }

  private onEditGroup(group: string): void {
    this.editingGroup = group;
    this.editGroupName = group;
    this.showEditInput = true;
  }

  private async onSaveEdit(): Promise<void> {
    const newName = this.editGroupName.trim();
    if (!newName) {
      promptAction.showToast({ message: '分组名称不能为空', duration: 1500 });
      return;
    }
    if (newName === this.editingGroup) {
      this.showEditInput = false;
      return;
    }
    if (this.groups.includes(newName) && newName !== this.editingGroup) {
      promptAction.showToast({ message: '分组名已存在', duration: 1500 });
      return;
    }
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      await dao.renameGroup(this.editingGroup, newName);
      this.showEditInput = false;
      await this.loadGroups();
      if (this.onGroupChanged) this.onGroupChanged();
      promptAction.showToast({ message: '已重命名', duration: 1500 });
    } catch (_e) { /* ignore */ }
  }

  private confirmDeleteGroup(group: string): void {
    AlertDialog.show({
      title: '删除分组',
      message: '确定将分组 "' + group + '" 从所有书源中移除？',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            const db = AppDatabase.getInstance().rdbStore;
            const dao = new BookSourceTable(db);
            await dao.deleteGroup(group);
            await this.loadGroups();
            if (this.onGroupChanged) this.onGroupChanged();
            promptAction.showToast({ message: '已删除分组', duration: 1500 });
          } catch (_e) { /* ignore */ }
        }
      },
      cancel: (): void => {}
    });
  }

  build() {
    Column() {
      // ===== 标题栏 =====
      Row() {
        Text('分组管理').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button() { Text('新增').fontSize(14).fontColor('#FFF') }
          .height(32).backgroundColor('#0078D7').borderRadius(16)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.addGroupName = '';
            this.showAddInput = true;
            this.showEditInput = false;
          })
        Button() { Text('✕').fontSize(16).fontColor('#888') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }.padding({ top: 12, bottom: 8 })

      // ===== 新增输入框 =====
      if (this.showAddInput) {
        Row() {
          TextInput({ placeholder: '输入新分组名称', text: this.addGroupName })
            .height(36).fontSize(14).layoutWeight(1).borderRadius(4)
            .padding({ left: 8 })
            .onChange((v: string) => { this.addGroupName = v; })
          Button('添加').fontSize(13).height(36)
            .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.onAddGroup(); })
          Button('取消').fontSize(13).height(36)
            .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.showAddInput = false; })
        }.width('100%').margin({ bottom: 8 })
      }

      // ===== 编辑输入框 =====
      if (this.showEditInput) {
        Row() {
          TextInput({ placeholder: '输入新名称', text: this.editGroupName })
            .height(36).fontSize(14).layoutWeight(1).borderRadius(4)
            .padding({ left: 8 })
            .onChange((v: string) => { this.editGroupName = v; })
          Button('保存').fontSize(13).height(36)
            .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.onSaveEdit(); })
          Button('取消').fontSize(13).height(36)
            .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.showEditInput = false; })
        }.width('100%').margin({ bottom: 8 })
      }

      // ===== 分组列表 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 40 })
      } else if (this.groups.length === 0) {
        Column() {
          Text('还没有分组').fontSize(16).fontColor('#888').margin({ top: 40 })
          Text('点击"新增"创建分组').fontSize(13).fontColor('#AAA').margin({ top: 4 })
        }.width('100%').alignItems(HorizontalAlign.Center).layoutWeight(1)
      } else {
        List() {
          ForEach(this.groups, (group: string) => {
            ListItem() {
              Row() {
                Text(group).fontSize(15).layoutWeight(1)
                Button() { Text('编辑').fontSize(12).fontColor('#0078D7') }
                  .height(30).backgroundColor('transparent').borderRadius(4)
                  .onClick(() => { this.onEditGroup(group); })
                Button() { Text('删除').fontSize(12).fontColor('#F44336') }
                  .height(30).backgroundColor('transparent').borderRadius(4)
                  .margin({ left: 4 })
                  .onClick(() => { this.confirmDeleteGroup(group); })
              }
              .padding({ left: 8, right: 8, top: 10, bottom: 10 })
              .width('100%')
            }
            .border({ width: { bottom: 0.5 }, color: '#E8E8E8' })
          })
        }
        .width('100%').layoutWeight(1)
      }

      // ===== 底部关闭 =====
      Button('关闭').height(36).fontSize(14)
        .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(8).width('100%').margin({ top: 8 })
        .onClick(() => { this.controller.close(); })
    }
    .padding({ left: 16, right: 16, top: 0, bottom: 12 })
    .width('100%').height('70%')
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
