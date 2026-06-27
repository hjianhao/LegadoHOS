/**
 * 书架分组管理弹窗
 *
 * 管理所有分组（系统组 + 自定义组）：
 * - 查看分组列表及书籍数量
 * - 系统组：可切换显示/隐藏，不可删除
 * - 自定义组：新增、重命名、删除
 * - 按顺序排列
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
  @State groupBookCounts: Record<number, number> = {};
  @State isLoading: boolean = true;
  @State showAddInput: boolean = false;
  @State addGroupName: string = '';
  @State isDark: boolean = false;

  onGroupChanged?: () => void;

  aboutToAppear(): void {
    this.loadData();
  }

  async loadData(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const groupDao = new BookGroupTable(db);
      const bookDao = new BookTable(db);
      this.groups = await groupDao.getAllGroups();
      this.groupBookCounts = await groupDao.getAllGroupBookCounts(bookDao);
    } catch (e) {
      console.warn('[GroupManage] load error:', (e as Error).message);
    }
    this.isLoading = false;
  }

  private async onAddGroup(): Promise<void> {
    const name = this.addGroupName.trim();
    if (!name) {
      promptAction.showToast({ message: '请输入分组名称', duration: 1500 });
      return;
    }
    // 检查重名（含系统组）
    const exists = this.groups.some(g => g.name === name);
    if (exists) {
      promptAction.showToast({ message: '分组名称已存在', duration: 1500 });
      return;
    }
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookGroupTable(db);
      const newId = await dao.insertGroup(name);
      if (newId > 0) {
        this.addGroupName = '';
        this.showAddInput = false;
        await this.loadData();
        if (this.onGroupChanged) this.onGroupChanged();
        promptAction.showToast({ message: '已添加分组「' + name + '」', duration: 1500 });
      }
    } catch (e) {
      console.warn('[GroupManage] add error:', (e as Error).message);
    }
  }

  private async toggleGroupShow(group: BookGroupItem): Promise<void> {
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookGroupTable(db);
      group.show = !group.show;
      await dao.updateGroup(group);
      // 强制刷新
      this.groups = [...this.groups];
      if (this.onGroupChanged) this.onGroupChanged();
    } catch (e) {
      console.warn('[GroupManage] toggle show error:', (e as Error).message);
    }
  }

  private async renameGroup(group: BookGroupItem): Promise<void> {
    // 使用 promptAction 输入新名称
    promptAction.showDialog({
      title: '重命名分组',
      message: '输入新名称：',
      buttons: [
        { text: '取消', color: '#888' },
        { text: '确定', color: '#0078D7' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        // 获取输入——因 promptAction 不支持输入框，改用 AlertDialog 配合 TextInput
        // 此处简化：直接使用默认输入框
        this.showRenameInput(group);
      }
    }).catch(() => {});
  }

  // 由于 promptAction 无输入框，我们使用条件渲染的自定义输入区域
  @State renameTarget: BookGroupItem | null = null;
  @State renameValue: string = '';

  private showRenameInput(group: BookGroupItem): void {
    this.renameTarget = group;
    this.renameValue = group.name;
    this.showAddInput = false;
  }

  private async onSaveRename(): Promise<void> {
    const target = this.renameTarget;
    if (!target) return;
    const newName = this.renameValue.trim();
    if (!newName) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    if (newName === target.name) {
      this.renameTarget = null;
      return;
    }
    const exists = this.groups.some(g => g.name === newName && g.id !== target.id);
    if (exists) {
      promptAction.showToast({ message: '分组名称已存在', duration: 1500 });
      return;
    }
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookGroupTable(db);
      if (target.isSystem) {
        // 系统组暂不支持重命名
        promptAction.showToast({ message: '系统分组不支持重命名', duration: 1500 });
      } else {
        await dao.renameGroup(target.id, newName);
      }
      this.renameTarget = null;
      await this.loadData();
      if (this.onGroupChanged) this.onGroupChanged();
      promptAction.showToast({ message: '已重命名', duration: 1500 });
    } catch (e) {
      console.warn('[GroupManage] rename error:', (e as Error).message);
    }
  }

  private confirmDeleteGroup(group: BookGroupItem): void {
    if (group.isSystem) {
      promptAction.showToast({ message: '系统分组不可删除', duration: 1500 });
      return;
    }
    AlertDialog.show({
      title: '删除分组',
      message: '确定删除分组「' + group.name + '」吗？\n该分组下的书籍将移回「全部」分组。',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            const db = AppDatabase.getInstance().rdbStore;
            const dao = new BookGroupTable(db);
            const bookDao = new BookTable(db);
            await dao.deleteGroup(group.id, bookDao);
            await this.loadData();
            if (this.onGroupChanged) this.onGroupChanged();
            promptAction.showToast({ message: '已删除分组', duration: 1500 });
          } catch (e) {
            console.warn('[GroupManage] delete error:', (e as Error).message);
          }
        }
      },
      cancel: (): void => {}
    });
  }

  async moveGroupUp(index: number): Promise<void> {
    if (index <= 0) return;
    this.swapGroups(index, index - 1);
  }

  async moveGroupDown(index: number): Promise<void> {
    if (index >= this.groups.length - 1) return;
    this.swapGroups(index, index + 1);
  }

  private async swapGroups(i: number, j: number): Promise<void> {
    const ids = this.groups.map(g => g.id);
    const temp = ids[i];
    ids[i] = ids[j];
    ids[j] = temp;
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookGroupTable(db);
      await dao.reorderGroups(ids);
      await this.loadData();
      if (this.onGroupChanged) this.onGroupChanged();
    } catch (e) {
      console.warn('[GroupManage] reorder error:', (e as Error).message);
    }
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
            this.renameTarget = null;
          })
        Button() { Text('✕').fontSize(16).fontColor('#888') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }.padding({ top: 12, bottom: 8 }).width('100%')

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

      // ===== 重命名输入框 =====
      if (this.renameTarget) {
        Row() {
          TextInput({ placeholder: '输入新名称', text: this.renameValue })
            .height(36).fontSize(14).layoutWeight(1).borderRadius(4)
            .padding({ left: 8 })
            .onChange((v: string) => { this.renameValue = v; })
          Button('保存').fontSize(13).height(36)
            .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 6 })
            .onClick(() => { this.onSaveRename(); })
          Button('取消').fontSize(13).height(36)
            .backgroundColor('#E0E0E0').fontColor('#333').borderRadius(4)
            .padding({ left: 12, right: 12 }).margin({ left: 4 })
            .onClick(() => { this.renameTarget = null; })
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
          ForEach(this.groups, (group: BookGroupItem, index: number) => {
            ListItem() {
              this.buildGroupItem(group, index)
            }
            .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#E8E8E8' })
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
    .width('100%').height('75%')
    .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  buildGroupItem(group: BookGroupItem, index: number) {
    Row() {
      // 分组名 + 书籍数量
      Column() {
        Row() {
          Text(group.name).fontSize(15).fontWeight(FontWeight.Medium)
          if (group.isSystem) {
            Text('系统').fontSize(10).fontColor('#888')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor(this.isDark ? '#333' : '#F0F0F0')
              .borderRadius(4).margin({ left: 6 })
          }
        }
        Text((this.groupBookCounts[group.id] || 0) + ' 本书')
          .fontSize(11).fontColor(this.isDark ? '#AAA' : '#888').margin({ top: 2 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)

      // 操作按钮
      if (group.id !== BookGroup.ALL) {
        // 显示/隐藏开关
        Button() {
          Text(group.show ? '显示' : '隐藏').fontSize(11)
            .fontColor(group.show ? '#0078D7' : '#AAA')
        }
        .height(28).backgroundColor('transparent').borderRadius(4)
        .padding({ left: 6, right: 6 })
        .onClick(() => { this.toggleGroupShow(group); })
      }

      // 上移 / 下移
      Button() { Text('↑').fontSize(13).fontColor('#888') }
        .width(28).height(28).backgroundColor('transparent')
        .enabled(index > 0)
        .onClick(() => { this.moveGroupUp(index); })
      Button() { Text('↓').fontSize(13).fontColor('#888') }
        .width(28).height(28).backgroundColor('transparent')
        .enabled(index < this.groups.length - 1)
        .onClick(() => { this.moveGroupDown(index); })

      if (!group.isSystem) {
        // 重命名（仅自定义）
        Button() { Text('编辑').fontSize(11).fontColor('#0078D7') }
          .height(28).backgroundColor('transparent').borderRadius(4)
          .padding({ left: 6, right: 6 })
          .onClick(() => { this.showRenameInput(group); })
        // 删除（仅自定义）
        Button() { Text('删除').fontSize(11).fontColor('#F44336') }
          .height(28).backgroundColor('transparent').borderRadius(4)
          .padding({ left: 6, right: 6 })
          .onClick(() => { this.confirmDeleteGroup(group); })
      }
    }
    .padding({ left: 8, right: 4, top: 10, bottom: 10 })
    .width('100%')
  }
}
