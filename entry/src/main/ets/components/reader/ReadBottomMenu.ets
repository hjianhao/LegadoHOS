/**
 * 阅读底部菜单 — 按钮栏（含回调）
 */
@Component
export struct ReadBottomMenu {
  @StorageLink('isDark') isDark: boolean = false;
  onToc?: () => void;
  onReadAloud?: () => void;
  onBookmark?: () => void;
  onStyle?: () => void;
  onFont?: () => void;
  onSettings?: () => void;
  onSource?: () => void;
  onCache?: () => void;
  onRefresh?: () => void;

  build() {
    Row() {
      Column() {
        Text('📖').fontSize(20)
        Text('目录').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 目录 click'); this.onToc?.(); })
      Column() {
        Text('🔊').fontSize(20)
        Text('朗读').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 朗读 click'); this.onReadAloud?.(); })
      Column() {
        Text('🔖').fontSize(20)
        Text('书签').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onBookmark?.() })
      Column() {
        Text('🎨').fontSize(20)
        Text('风格').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onStyle?.() })
      Column() {
        Text('⚙️').fontSize(20)
        Text('设置').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onSettings?.() })
      Column() {
        Text('🔄').fontSize(20)
        Text('换源').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onSource?.() })
      Column() {
        Text('📥').fontSize(20)
        Text('缓存').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onCache?.() })
      Column() {
        Text('🔄').fontSize(20)
        Text('刷新').fontSize(10).fontColor(this.isDark ? '#CCCCCC' : '#666').margin({top: 2})
      }.onClick(() => { this.onRefresh?.() })
    }.width('100%').justifyContent(FlexAlign.SpaceEvenly)
    .padding({top: 12, bottom: 16, left: 8, right: 8})
    .backgroundColor(Color.White)
  }
}
