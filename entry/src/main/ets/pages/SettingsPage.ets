import promptAction from '@ohos.promptAction';
import { AppTheme } from '../theme/AppTheme';

interface SettingItem { icon: string; title: string; key: string; }

@Entry
@Component
export struct SettingsPage {
  @State currentSection: string = 'main';
  @State isDark: boolean = false;
  @State searchConcurrency: number = 16;

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.searchConcurrency = AppStorage.get<number>('searchConcurrency') || 16;
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        if (this.currentSection !== 'main') {
          Text('< 返回').fontSize(16).fontColor('#0078D7').padding({ right: 12 })
            .onClick(() => { this.currentSection = 'main'; })
        }
        Text('设置').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
      }.padding(16).width('100%')

      if (this.currentSection === 'main') {
        this.buildMainMenu();
      } else if (this.currentSection === 'search') {
        this.buildSearchSettings();
      } else if (this.currentSection === 'read') {
        this.buildReadSettings();
      } else if (this.currentSection === 'theme') {
        this.buildThemeSettings();
      } else if (this.currentSection === 'about') {
        this.buildAboutPage();
      }
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  @Builder
  buildMainMenu() {
    List() {
      ForEach([
        { icon: '\uD83D\uDCD6', title: '阅读设置', key: 'read' },
        { icon: '\uD83D\uDD0D', title: '搜索设置', key: 'search' },
        { icon: '\uD83C\uDFA8', title: '主题设置', key: 'theme' },
        { icon: '\u2139\uFE0F', title: '关于', key: 'about' },
      ] as SettingItem[], (item: SettingItem) => {
        ListItem() {
          Row() {
            Text(item.icon).fontSize(22).margin({ right: 14 })
            Text(item.title).fontSize(16).fontWeight(FontWeight.Medium)
            Blank()
            Text('>').fontSize(18).fontColor('#888')
          }.padding(16).width('100%')
        }
        .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
        .onClick(() => { this.currentSection = item.key; })
      })
    }.width('100%')
  }

  @Builder
  buildSearchSettings() {
    Column() {
      // 并发搜索数配置
      Row() {
        Text('\uD83D\uDD0D 并发搜索数').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(String(this.searchConcurrency)).fontSize(16).fontColor('#0078D7')
          .width(40).textAlign(TextAlign.End)
      }.padding({ left: 16, right: 16, top: 16, bottom: 8 }).width('100%')

      Slider({
        value: this.searchConcurrency,
        min: 1, max: 50, step: 1
      })
      .width('calc(100% - 32)').margin({ left: 16, right: 16 })
      .onChange((val: number) => {
        this.searchConcurrency = val;
        AppStorage.set<number>('searchConcurrency', val);
      })

      Text('同时搜索的书源数量，值越大搜索越快但网络负载越高')
        .fontSize(12).fontColor('#888').padding({ left: 16, right: 16, top: 4 })

      // 分组：默认启用
      Row() {
        Text('\uD83D\uDCC2 搜索时启用全部源').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: true })
      }.padding(16).width('100%')
      .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })

      Text('关闭后仅使用已启用的书源搜索')
        .fontSize(12).fontColor('#888').padding({ left: 16, right: 16, bottom: 8 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildReadSettings() {
    Column() {
      Text('\uD83D\uDCD6 阅读设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start)

      Text('阅读字号、行距等设置在阅读页面中调整')
        .fontSize(14).fontColor('#888').padding({ left: 16, right: 16 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildThemeSettings() {
    Column() {
      Text('\uD83C\uDFA8 主题设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start)

      Row() {
        Text('深色模式').fontSize(16).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.isDark })
          .onChange((v: boolean) => {
            this.isDark = v;
            AppTheme.getInstance().setDarkMode(v);
          })
      }.padding(16).width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildAboutPage() {
    Column() {
      Text('LegadoHOS').fontSize(24).fontWeight(FontWeight.Bold).margin({ top: 40 })
      Text('v1.0.0').fontSize(14).fontColor('#888').margin({ top: 4 })
      Text('鸿蒙原生阅读APP').fontSize(14).fontColor('#888').margin({ top: 2 })
      Text('基于 legado-with-MD3 重构').fontSize(13).fontColor('#AAA').margin({ top: 16 })
    }
    .width('100%').alignItems(HorizontalAlign.Center)
  }
}
