import { AppTheme } from '../theme/AppTheme';
import promptAction from '@ohos.promptAction';

@Entry
@Component
export struct SearchPage {
  @State keyword: string = '';
  @State isDark: boolean = false;

  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Row() {
        TextInput({ placeholder: '搜索书名或作者...', text: this.keyword })
          .height(44).backgroundColor(this.isDark ? '#2A2A2A' : '#F0F0F0')
          .borderRadius(22).padding({ left: 20 }).layoutWeight(1)
          .onChange((v: string) => { this.keyword = v; })
        Button('搜索').margin({ left: 8 }).fontSize(14)
          .onClick(() => { promptAction.showToast({message:'书源引擎未加载',duration:1500}); })
      }.padding(12).width('100%')
      Column() {
        Text('\uD83D\uDD0D').fontSize(48).margin({ top: 80 })
        Text('搜索功能').fontSize(16).fontColor('#888').margin({ top: 8 })
      }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
