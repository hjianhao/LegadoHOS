/**
 * 书签编辑对话框 — 添加/编辑书签共用
 * 字段：原文（可改）、笔记
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct BookmarkEditDialog {
  @StorageLink('isDark') isDark: boolean = false;

  /** 初始值 */
  initialText: string = '';
  initialNote: string = '';
  title: string = '添加书签';
  /** 编辑已有书签时显示删除按钮 */
  showDelete: boolean = false;

  onSave?: (text: string, note: string) => void;
  onDelete?: () => void;
  onDismiss?: () => void;

  @State text: string = '';
  @State note: string = '';

  aboutToAppear(): void {
    this.text = this.initialText;
    this.note = this.initialNote;
  }

  build() {
    Column() {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ top: 16, left: 16, bottom: 12 }).alignSelf(ItemAlign.Start)

      Text('原文').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, bottom: 4 }).alignSelf(ItemAlign.Start)
      TextArea({ text: this.text, placeholder: '书签原文' })
        .width('100%').height(90).fontSize(14)
        .fontColor(ThemeColors.onSurface(this.isDark))
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .borderRadius(8).padding(8)
        .margin({ left: 16, right: 16, bottom: 12 })
        .onChange((v: string) => { this.text = v; })

      Text('笔记').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, bottom: 4 }).alignSelf(ItemAlign.Start)
      TextArea({ text: this.note, placeholder: '写下你的想法（可留空）' })
        .width('100%').height(70).fontSize(14)
        .fontColor(ThemeColors.onSurface(this.isDark))
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .borderRadius(8).padding(8)
        .margin({ left: 16, right: 16, bottom: 16 })
        .onChange((v: string) => { this.note = v; })

      Row() {
        if (this.showDelete) {
          Button('删除').fontSize(15).fontColor(ThemeColors.error(this.isDark))
            .backgroundColor(Color.Transparent)
            .height(44).layoutWeight(1)
            .onClick(() => { this.onDelete?.(); })
        }
        Button('取消').fontSize(15).fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(Color.Transparent)
          .height(44).layoutWeight(1)
          .onClick(() => { this.onDismiss?.(); })
        Button('保存').fontSize(15).fontColor('#FFF')
          .backgroundColor(ThemeColors.primary(this.isDark))
          .height(44).layoutWeight(1).borderRadius(0)
          .onClick(() => { this.onSave?.(this.text.trim(), this.note.trim()); })
      }.width('100%').height(48)
    }
    .width('100%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
