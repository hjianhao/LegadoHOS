/**
 * 阅读底部菜单 — 按钮栏（含回调）
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ReadBottomMenu {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop isLocalBook: boolean = false;
  onToc?: () => void;
  onReadAloud?: () => void;
  onBookmark?: () => void;
  onStyle?: () => void;
  onFont?: () => void;
  onSettings?: () => void;
  onSearch?: () => void;
  onSource?: () => void;
  onCache?: () => void;
  onRefresh?: () => void;

  build() {
    Row() {
      Column() {
        Text('📖').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('目录').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 目录 click'); this.onToc?.(); })
      Column() {
        Text('🔊').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('朗读').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 朗读 click'); this.onReadAloud?.(); })
      Column() {
        Text('🔖').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('书签').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.onClick(() => { this.onBookmark?.() })
      Column() {
        Text('🎨').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('风格').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.onClick(() => { this.onStyle?.() })
      Column() {
        Text('⚙️').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('设置').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.onClick(() => { this.onSettings?.() })
      Column() {
        Text('🔎').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text('搜索').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.onClick(() => { this.onSearch?.() })
      if (!this.isLocalBook) {
        Column() {
          Text('🔄').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text('换源').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }.onClick(() => { this.onSource?.() })
        Column() {
          Text('📥').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text('缓存').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }.onClick(() => { this.onCache?.() })
        Column() {
          Text('🔄').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text('刷新').fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }.onClick(() => { this.onRefresh?.() })
      }
    }.width('100%').justifyContent(FlexAlign.SpaceEvenly)
    .padding({top: 12, bottom: 16, left: 8, right: 8})
    .backgroundColor(ThemeColors.surface(this.isDark))
  }
}
