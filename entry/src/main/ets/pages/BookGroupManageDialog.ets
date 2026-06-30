/**
 * 书架分组管理对话框 — 对标 Android GroupManageDialog
 *
 * 管理 BookGroupTable 中的自定义分组：
 * - 显示所有分组（系统组不可编辑/删除）
 * - 新增自定义分组
 * - 重命名自定义分组
 * - 删除自定义分组（书籍移回"全部"）
 * - 拖拽排序（简化：用上下按钮）
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookGroupTable } from '../data/database/BookGroupTable';
import { BookTable } from '../data/database/BookTable';
import { BookGroupItem, BookGroup } from '../model/BookGroup';
import promptAction from '@ohos.promptAction';

@CustomDialog
export struct BookGroupManageDialog {
  controller: CustomDialogController;
  @State groups: BookGroupItem[] = [];
  @State isLoading: boolean = true;
  @State showAddInput: boolean = false;
  @State addGroupName: string = '';
  @State editingId: number = -1;
  @State editingName: string = '';

  onGroupChanged?: () => void;

  aboutToAppear(): void {
    this.loadGroups();
  }

  async loadGroups(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      this.groups = await groupDao.getAllGroups();
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  async doAddGroup(): Promise<void> {
    const name = this.addGroupName.trim();
    if (!name) { promptAction.showToast({ message: '请输入分组名', duration: 1500 }); return; }
    try {
      await AppDatabase.getInstance().waitForInit();
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      await groupDao.insertGroup(name);
      this.addGroupName = '';
      this.showAddInput = false;
      await this.loadGroups();
      if (this.onGroupChanged) this.onGroupChanged();
      promptAction.showToast({ message: '分组已添加', duration: 1500 });
    } catch (_e) { promptAction.showToast({ message: '添加失败', duration: 1500 }); }
  }

  startRename(g: BookGroupItem): void {
    this.editingId = g.id;
    this.editingName = g.name;
    this.showAddInput = false;
  }

  cancelRename(): void {
    this.editingId = -1;
    this.editingName = '';
  }

  async doRename(): Promise<void> {
    const name = this.editingName.trim();
    if (!name) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      await groupDao.renameGroup(this.editingId, name);
      this.editingId = -1;
      this.editingName = '';
      await this.loadGroups();
      if (this.onGroupChanged) this.onGroupChanged();
    } catch (_e) { promptAction.showToast({ message: '重命名失败', duration: 1500 }); }
  }

  confirmDelete(g: BookGroupItem): void {
    AlertDialog.show({
      title: '删除分组',
      message: `确定删除 "${g.name}"？分组内书籍将移回"全部"`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            await AppDatabase.getInstance().waitForInit();
            const db = AppDatabase.getInstance().rdbStore;
            const groupDao = new BookGroupTable(db);
            const bookDao = new BookTable(db);
            await groupDao.deleteGroup(g.id, bookDao);
            await this.loadGroups();
            if (this.onGroupChanged) this.onGroupChanged();
          } catch (_e) { /* ignore */ }
        }
      }
    });
  }

  // 上移
  async moveUp(g: BookGroupItem, index: number): Promise<void> {
    if (index <= 0) return;
    const prev = this.groups[index - 1];
    const tmp = g.order;
    g.order = prev.order;
    prev.order = tmp;
    try {
      await AppDatabase.getInstance().waitForInit();
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      await groupDao.updateGroup(g);
      await groupDao.updateGroup(prev);
      await this.loadGroups();
    } catch (_e) { /* ignore */ }
  }

  // 下移
  async moveDown(g: BookGroupItem, index: number): Promise<void> {
    if (index >= this.groups.length - 1) return;
    const next = this.groups[index + 1];
    const tmp = g.order;
    g.order = next.order;
    next.order = tmp;
    try {
      await AppDatabase.getInstance().waitForInit();
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      await groupDao.updateGroup(g);
      await groupDao.updateGroup(next);
      await this.loadGroups();
    } catch (_e) { /* ignore */ }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('分组管理').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button() { Text('新增').fontSize(14).fontColor('#FFF') }
          .height(32).backgroundColor('#0078D7').borderRadius(16)
          .padding({ left: 12, right: 12 })
          .onClick(() => { this.addGroupName = ''; this.showAddInput = true; this.editingId = -1; })
        Button() { Text('✕').fontSize(16).fontColor('#888') }
          .width(32).height(32).backgroundColor(Color.Transparent)
          .onClick(() => { this.controller.close(); })
      }.padding({ top: 12, bottom: 8 })

      // 新增输入
      if (this.showAddInput) {
        Row() {
          TextInput({ placeholder: '新分组名', text: this.addGroupName })
            .height(36).fontSize(14).layoutWeight(1).borderRadius(4).padding({ left: 8 })
            .onChange((v: string) => { this.addGroupName = v; })
          Button('添加').fontSize(13).height(36).backgroundColor('#4CAF50').fontColor('#FFF')
            .borderRadius(4).padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.doAddGroup(); })
          Button('取消').fontSize(13).height(36).backgroundColor('#E0E0E0').fontColor('#333')
            .borderRadius(4).padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.showAddInput = false; })
        }.width('100%').margin({ bottom: 8 })
      }

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 40 })
      } else {
        List() {
          ForEach(this.groups, (g: BookGroupItem, idx: number) => {
            ListItem() {
              // 编辑模式
              if (this.editingId === g.id) {
                Row() {
                  TextInput({ text: this.editingName }).height(32).fontSize(14).layoutWeight(1)
                    .borderRadius(4).padding({ left: 8 })
                    .onChange((v: string) => { this.editingName = v; })
                  Button('保存').fontSize(12).height(32).backgroundColor('#4CAF50').fontColor('#FFF')
                    .borderRadius(4).padding({ left: 8, right: 8 }).margin({ left: 4 })
                    .onClick(() => { this.doRename(); })
                  Button('取消').fontSize(12).height(32).backgroundColor('#E0E0E0').fontColor('#333')
                    .borderRadius(4).padding({ left: 8, right: 8 }).margin({ left: 4 })
                    .onClick(() => { this.cancelRename(); })
                }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
              } else {
                Row() {
                  // 系统标记
                  if (g.isSystem) {
                    Text('🔒').fontSize(14).margin({ right: 4 })
                  }
                  Text(g.name).fontSize(15).fontColor(g.isSystem ? '#888' : '#333').layoutWeight(1)

                  if (!g.isSystem) {
                    // 排序
                    Button() { Text('↑').fontSize(12).fontColor('#0078D7') }
                      .width(28).height(28).backgroundColor(Color.Transparent)
                      .onClick(() => { this.moveUp(g, idx); })
                    Button() { Text('↓').fontSize(12).fontColor('#0078D7') }
                      .width(28).height(28).backgroundColor(Color.Transparent)
                      .onClick(() => { this.moveDown(g, idx); })

                    Button() { Text('编辑').fontSize(12).fontColor('#0078D7') }
                      .height(28).backgroundColor(Color.Transparent).borderRadius(4)
                      .padding({ left: 6, right: 6 })
                      .onClick(() => { this.startRename(g); })
                    Button() { Text('删除').fontSize(12).fontColor('#F44336') }
                      .height(28).backgroundColor(Color.Transparent).borderRadius(4)
                      .padding({ left: 6, right: 6 })
                      .onClick(() => { this.confirmDelete(g); })
                  }
                }
                .width('100%').padding({ left: 8, right: 8, top: 10, bottom: 10 })
              }
            }
            .border({ width: { bottom: 0.5 }, color: '#E8E8E8' })
          })
        }.width('100%').layoutWeight(1)
      }

      Button('关闭').height(36).fontSize(14)
        .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(8).width('100%').margin({ top: 8 })
        .onClick(() => { this.controller.close(); })
    }
    .padding({ left: 16, right: 16, top: 0, bottom: 12 })
    .width('100%').height('70%')
    .backgroundColor('#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
