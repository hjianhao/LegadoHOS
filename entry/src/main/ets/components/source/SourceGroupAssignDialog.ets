import { AppDatabase } from '../../data/database/AppDatabase';
import { BookSourceTable } from '../../data/database/BookSourceTable';
import { ThemeColors } from '../../theme/ThemeColors';
import { UiUtil } from '../../util/UiUtil';

@CustomDialog
export struct SourceGroupAssignDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @Prop sourceIds: number[] = [];
  @State groups: string[] = [];
  @State groupName: string = '';
  @State removeMode: boolean = false;
  onChanged?: () => void;

  aboutToAppear(): void { this.loadGroups(); }

  private async loadGroups(): Promise<void> {
    await AppDatabase.getInstance().waitForInit();
    const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
    this.groups = await dao.getAllGroups();
  }

  private async applyGroup(group: string): Promise<void> {
    const value = group.trim();
    if (!value || this.sourceIds.length === 0) return;
    const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
    if (this.removeMode) await dao.removeGroupFromSources(this.sourceIds, value);
    else await dao.addGroupToSources(this.sourceIds, value);
    UiUtil.showToast(this.getUIContext(), {
      message: this.removeMode ? '已移除分组' : '已加入分组', duration: 1500
    });
    if (this.onChanged) this.onChanged();
    this.controller.close();
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_74027a0ec6')).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button($r('app.string.common_close')).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.primary(this.isDark)).onClick(() => { this.controller.close(); })
      }.height(56).width('100%')
      Row() {
        Button($r('app.string.ui_98f81e481a')).height(40).layoutWeight(1).borderRadius(20)
          .backgroundColor(!this.removeMode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
          .fontColor(!this.removeMode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
          .onClick(() => { this.removeMode = false; })
        Button($r('app.string.ui_35c6d23953')).height(40).layoutWeight(1).borderRadius(20).margin({ left: 8 })
          .backgroundColor(this.removeMode ? ThemeColors.error(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
          .fontColor(this.removeMode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
          .onClick(() => { this.removeMode = true; })
      }.width('100%').margin({ bottom: 12 })
      Row() {
        TextInput({ text: this.groupName, placeholder: $r('app.string.ui_f26dbf60c5') })
          .height(48).layoutWeight(1).borderRadius(12)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((value: string) => { this.groupName = value; })
        Button($r('app.string.common_confirm')).height(48).borderRadius(24).margin({ left: 8 })
          .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
          .onClick(() => { this.applyGroup(this.groupName); })
      }.width('100%')
      if (this.groups.length > 0) {
        Text($r('app.string.ui_905ecef313')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').margin({ top: 16, bottom: 6 })
        List({ space: 4 }) {
          ForEach(this.groups, (group: string) => {
            ListItem() {
              Row() {
                Text(group).fontSize(15).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
                Text(this.removeMode ? '移除' : '加入').fontSize(13)
                  .fontColor(this.removeMode ? ThemeColors.error(this.isDark) : ThemeColors.primary(this.isDark))
              }.height(48).padding({ left: 12, right: 12 }).borderRadius(12)
                .backgroundColor(ThemeColors.surface(this.isDark)).onClick(() => { this.applyGroup(group); })
            }
          })
        }.height(220).width('100%')
      }
    }.padding({ left: 16, right: 16, bottom: 20 }).width('100%')
      .backgroundColor(ThemeColors.background(this.isDark))
      .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
