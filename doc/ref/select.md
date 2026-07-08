好消息！鸿蒙原生就支持在系统选择菜单上追加自定义项，完全不需要重新构造。两种API都能做到：

方案A：editMenuOptions — 在系统菜单上追加项（最简单）
这是最直接的方式：系统菜单保留（复制/全选），你只追加"笔记/查询/高亮"等自定义项。

@Component
struct ReaderPageView {
@State pageText: string = '...当前页完整文字内容...';
@State message: string = '';
private textController: TextController = new TextController();

// ===== 第1步：定义菜单扩展逻辑 =====
onCreateMenu(menuItems: Array<TextMenuItem>): Array<TextMenuItem> {
// menuItems 是系统默认菜单项数组（已包含：复制、全选等）
// 直接往里追加自定义项即可，系统菜单不受影响

    // 追加阅读器专用菜单项
    menuItems.push({
      id: TextMenuItemId.of('highlight'),   // 自定义ID
      content: '高亮',                       // 显示文字
      icon: $r('app.media.ic_highlight'),   // 图标
    });
    menuItems.push({
      id: TextMenuItemId.of('note'),
      content: '笔记',
      icon: $r('app.media.ic_note'),
    });
    menuItems.push({
      id: TextMenuItemId.of('search'),
      content: '查询',
      icon: $r('app.media.ic_search'),
    });

    return menuItems;  // ⭐ 返回包含系统菜单+自定义菜单的完整数组
}

// ===== 第2步：处理菜单点击 =====
onMenuItemClick(menuItem: TextMenuItem, textRange: TextRange): boolean {
const selectedText = this.pageText.substring(textRange.start, textRange.end);

    // 自定义菜单项 → 返回 true（拦截，不执行系统逻辑）
    if (menuItem.id.equals(TextMenuItemId.of('highlight'))) {
      this.addHighlight(textRange.start, textRange.end, selectedText);
      return true;
    }
    if (menuItem.id.equals(TextMenuItemId.of('note'))) {
      this.addNote(textRange.start, textRange.end, selectedText);
      return true;
    }
    if (menuItem.id.equals(TextMenuItemId.of('search'))) {
      this.searchText(selectedText);
      return true;
    }

    // 系统菜单项（复制/全选） → 返回 false（不拦截，执行系统默认逻辑）
    // 比如点击"复制"：系统会把选中文字写入剪贴板
    return false;
}

// ===== 第3步：绑定到Text组件 =====
build() {
Text(this.pageText, { controller: this.textController })
.fontSize(20)
.lineHeight(36)
.fontFamily(this.fontFamily)
.padding(this.pagePadding)
// ⭐ 开启选择能力
.copyOption(CopyOptions.LocalDevice)
.textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
// ⭐ 追加自定义菜单
.editMenuOptions({
onCreateMenu: this.onCreateMenu,
onMenuItemClick: this.onMenuItemClick,
})
// ⭐ 选择范围变化回调（可选，用于实时追踪选中区域）
.onTextSelectionChange((start: number, end: number) => {
console.info(`选中范围: ${start} - ${end}`);
})
}

// ===== 业务逻辑 =====
addHighlight(start: number, end: number, text: string) {
// 记录高亮范围 → 渲染时叠加高亮底色
this.highlights.push({ start, end, text, color: '#FFEB3B' });
// 关闭选择菜单
this.textController.closeSelectionMenu();
}

addNote(start: number, end: number, text: string) {
// 弹出笔记编辑弹窗
this.showNoteDialog(text, start, end);
this.textController.closeSelectionMenu();
}

searchText(text: string) {
// 跳转到搜索页
this.navigateToSearch(text);
this.textController.closeSelectionMenu();
}
}
效果示意：

┌──────────────────────────────────────────┐
│  长按选中文字后弹出的菜单：                  │
│                                            │
│  ┌──────────────────────────────────────┐ │
│  │  复制  │  全选  │  高亮 │  笔记 │  查询│ │
│  │────────系统──────│────自定义追加────── │ │
│  └──────────────────────────────────────┘ │
│                                            │
│  系统手柄 ─◆═══════════════════════◆─      │
│           拖拽扩展选中区域                   │
└──────────────────────────────────────────┘
方案B：bindSelectionMenu + SelectionMenu组件 — 更灵活的定制
如果你想让菜单布局更自由（比如编辑图标行+展开更多项），可以用这个方案：

import { SelectionMenu, ExpandedMenuOptions, SelectionMenuOptions } from '@kit.ArkUI';

@Component
struct ReaderPageView {
private textController: TextController = new TextController();
private richEditorController: RichEditorController = new RichEditorController();

// ===== 扩展菜单项（折叠在"更多"按钮里） =====
private expandedMenuItems: Array<ExpandedMenuOptions> = [
{
startIcon: $r('app.media.ic_highlight'),
content: '高亮',
action: () => { this.handleHighlight(); }
},
{
startIcon: $r('app.media.ic_note'),
content: '笔记',
action: () => { this.handleNote(); }
},
{
startIcon: $r('app.media.ic_search'),
content: '查询',
action: () => { this.handleSearch(); }
},
];

// ===== 自定义菜单Builder =====
@Builder
readerSelectionMenu() {
Column() {
// ⭐ SelectionMenu组件：保留系统菜单 + 添加扩展项
SelectionMenu({
editorMenuOptions: this.editorMenuOptions,      // 图标行（可选）
expandedMenuOptions: this.expandedMenuItems,    // 更多按钮里的扩展项
controller: this.richEditorController,          // ⭐ 传入controller → 系统菜单显示
onCopy: (event?: EditorEventInfo) => {
// 自定义复制逻辑（可选，不写就用系统默认）
// 如果写了，系统默认复制失效，改为调用你的函数
this.handleCopy();
},
onSelectAll: (event?: EditorEventInfo) => {
this.handleSelectAll();
}
})
}
.width(256)
.backgroundColor(Color.Transparent)
}

// ===== 编辑菜单图标行（可选） =====
private editorMenuOptions: EditorMenuOptions = {
// 可以放图标按钮（如加粗/斜体），阅读器一般不需要
};

// ===== 绑定到Text =====
build() {
Text(this.pageText, { controller: this.textController })
.copyOption(CopyOptions.LocalDevice)
.textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
// ⭐ bindSelectionMenu：指定长按触发
.bindSelectionMenu(
TextSpanType.DEFAULT,
this.readerSelectionMenu,
TextResponseType.LONG_PRESS,
{
onAppear: () => { console.info('选择菜单出现'); },
onDisappear: () => { console.info('选择菜单消失'); }
}
)
}
}
效果示意：

┌──────────────────────────────────────────────┐
│  长按选中文字后弹出的菜单：                      │
│                                                │
│  ┌────────────────────────────────────────┐   │
│  │  复制 │ 全选 │ ··· 更多▼                │   │
│  │  ────系统菜单─── │ ──点击展开──          │   │
│  ├────────────────────────────────────────┤   │
│  │  ··· 更多▼ 展开后：                     │   │
│  │    🔖 高亮                              │   │
│  │    📝 笔记                              │   │
│  │    🔍 查询                              │   │
│  └────────────────────────────────────────┘   │
│                                                │
│  系统手柄 ─◆═══════════════════════◆─          │
└──────────────────────────────────────────────┘
两个方案的对比
维度	方案A：editMenuOptions	方案B：bindSelectionMenu + SelectionMenu
系统菜单（复制/全选）	✅ 自动保留	✅ 通过controller保留
系统选择手柄	✅ 自动保留	✅ 自动保留
系统选中高亮	✅ 自动保留	✅ 自动保留
追加自定义项	✅ menuItems.push()	✅ expandedMenuOptions
菜单布局控制	❌ 只能追加到末尾/开头	✅ 可自定义Builder布局
"更多"折叠菜单	❌ 不支持	✅ expandedMenuOptions自动折叠
获取选中文字	✅ textRange.start/end	✅ onCopy/onSelectAll回调
开发量	极低（~20行）	低（~50行）
适用场景	菜单项少（3-5个）	菜单项多，需要折叠
手势冲突	⚠️ 存在（Text消费点击）	⚠️ 存在（Text消费点击）
