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
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct GroupManageDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
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
      UiUtil.showToast(this.getUIContext(), { message: '请输入分组名称', duration: 1500 });
      return;
    }
    if (this.groups.includes(name)) {
      UiUtil.showToast(this.getUIContext(), { message: '分组已存在', duration: 1500 });
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
      UiUtil.showToast(this.getUIContext(), { message: '已添加分组 ' + name, duration: 1500 });
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
      UiUtil.showToast(this.getUIContext(), { message: '分组名称不能为空', duration: 1500 });
      return;
    }
    if (newName === this.editingGroup) {
      this.showEditInput = false;
      return;
    }
    if (this.groups.includes(newName) && newName !== this.editingGroup) {
      UiUtil.showToast(this.getUIContext(), { message: '分组名已存在', duration: 1500 });
      return;
    }
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      await dao.renameGroup(this.editingGroup, newName);
      this.showEditInput = false;
      await this.loadGroups();
      if (this.onGroupChanged) this.onGroupChanged();
      UiUtil.showToast(this.getUIContext(), { message: '已重命名', duration: 1500 });
    } catch (_e) { /* ignore */ }
  }

  private confirmDeleteGroup(group: string): void {
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '删除分组',
      message: '确定将分组 "' + group + '" 从所有书源中移除？',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '删除', fontColor: ThemeColors.error(this.isDark),
        action: async (): Promise<void> => {
          try {
            const db = AppDatabase.getInstance().rdbStore;
            const dao = new BookSourceTable(db);
            await dao.deleteGroup(group);
            await this.loadGroups();
            if (this.onGroupChanged) this.onGroupChanged();
            UiUtil.showToast(this.getUIContext(), { message: '已删除分组', duration: 1500 });
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
        Text($r('app.string.ui_e900b55ce7')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button() { Text($r('app.string.ui_2cd9e6ce81')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark)) }
          .height(40).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(20)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.addGroupName = '';
            this.showAddInput = true;
            this.showEditInput = false;
          })
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }.padding({ top: 12, bottom: 8 })

      // ===== 新增输入框 =====
      if (this.showAddInput) {
        Row() {
          TextInput({ placeholder: $r('app.string.ui_7fcdc76296'), text: this.addGroupName })
            .height(48).fontSize(14).layoutWeight(1).borderRadius(12)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .padding({ left: 8 })
            .onChange((v: string) => { this.addGroupName = v; })
          Button($r('app.string.common_add')).fontSize(13).height(48)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(24)
            .padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.onAddGroup(); })
          Button($r('app.string.common_cancel')).fontSize(13).height(48)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(24)
            .padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.showAddInput = false; })
        }.width('100%').margin({ bottom: 8 })
      }

      // ===== 编辑输入框 =====
      if (this.showEditInput) {
        Row() {
          TextInput({ placeholder: $r('app.string.ui_7c6286bb83'), text: this.editGroupName })
            .height(48).fontSize(14).layoutWeight(1).borderRadius(12)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .padding({ left: 8 })
            .onChange((v: string) => { this.editGroupName = v; })
          Button($r('app.string.common_save')).fontSize(13).height(48)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(24)
            .padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.onSaveEdit(); })
          Button($r('app.string.common_cancel')).fontSize(13).height(48)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(24)
            .padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.showEditInput = false; })
        }.width('100%').margin({ bottom: 8 })
      }

      // ===== 分组列表 =====
      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 40 })
      } else if (this.groups.length === 0) {
        Column() {
          Text($r('app.string.ui_06913109ef')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 40 })
          Text($r('app.string.ui_7b138e3773')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.width('100%').alignItems(HorizontalAlign.Center).layoutWeight(1)
      } else {
        List() {
          ForEach(this.groups, (group: string) => {
            ListItem() {
              Row() {
                Text(group).fontSize(15).layoutWeight(1)
                Button() { Text($r('app.string.common_edit')).fontSize(12).fontColor(ThemeColors.primary(this.isDark)) }
                  .height(40).backgroundColor(ThemeColors.transparent()).borderRadius(20)
                  .onClick(() => { this.onEditGroup(group); })
                Button() { Text($r('app.string.common_delete')).fontSize(12).fontColor(ThemeColors.error(this.isDark)) }
                  .height(40).backgroundColor(ThemeColors.transparent()).borderRadius(20)
                  .margin({ left: 4 })
                  .onClick(() => { this.confirmDeleteGroup(group); })
              }
              .padding({ left: 8, right: 8, top: 10, bottom: 10 })
              .width('100%')
            }
            .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
          })
        }
        .width('100%').layoutWeight(1)
      }

      // ===== 底部关闭 =====
      Button($r('app.string.common_close')).height(48).fontSize(14)
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark)).borderRadius(24).width('100%').margin({ top: 8 })
        .onClick(() => { this.controller.close(); })
    }
    .padding({ left: 16, right: 16, top: 0, bottom: 12 })
    .width('100%').height('70%').constraintSize({ maxWidth: 640, maxHeight: 720 })
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
