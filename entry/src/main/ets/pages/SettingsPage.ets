import promptAction from '@ohos.promptAction';
import { AppTheme } from '../theme/AppTheme';
import { ThemeMode } from '../theme/ThemeMode';
import { NetUtil } from '../util/NetUtil';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { UiUtil } from '../util/UiUtil';
import router from '@ohos.router';

interface SettingItem { icon: string; title: string; key: string; }

@Entry
@Component
struct SettingsPage {
  @State currentSection: string = 'main';
  @State isDark: boolean = false;
  @State searchConcurrency: number = 16;
  @State dnsServers: string = '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
  @State dnsEnabled: boolean = true;
  @State proxyHost: string = '';
  @State proxyPort: string = '';
  @State netTimeout: string = '60';
  @State pageMode: boolean = true;
  @State autoCacheSize: number = 10;

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.searchConcurrency = AppStorage.get<number>('searchConcurrency') || 16;
    this.dnsServers = AppStorage.get<string>('dnsServers') || '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
    this.dnsEnabled = AppStorage.get<boolean>('dnsEnabled') !== false;
    this.proxyHost = AppStorage.get<string>('proxyHost') || '';
    this.proxyPort = AppStorage.get<string>('proxyPort') || '';
    NetUtil.setDns(this.dnsServers, this.dnsEnabled);
    this.netTimeout = String(AppStorage.get<number>('network_timeout') || 60);
    if (this.proxyHost && this.proxyPort) {
      NetUtil.setProxy(this.proxyHost, parseInt(this.proxyPort));
    }
    this.syncWebViewNetwork();
    this.loadReadSettings();
  }

  private async loadReadSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      this.pageMode = (await s.getPageMode()) !== 0;
      this.autoCacheSize = await s.getAutoCacheSize();
    } catch (_e) { /* ignore */ }
  }

  private syncWebViewNetwork(): void {
    const proxyUrl = this.proxyHost && this.proxyPort ? 'http://' + this.proxyHost + ':' + this.proxyPort : '';
    WebViewFetcher.configureNetwork(this.dnsEnabled ? this.dnsServers : '', proxyUrl);
  }

  build() {
    Column() {
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
      } else if (this.currentSection === 'backup') {
        // backup 入口通过 click handler 直接导航，这里留空
        Column() {}.width('100%').height('100%')
      } else if (this.currentSection === 'network') {
        this.buildNetSettings();
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
        { icon: '\uD83C\uDF10', title: '网络设置', key: 'network' },
        { icon: '\uD83C\uDFA8', title: '主题设置', key: 'theme' },
        { icon: '\uD83D\uDD04', title: '备份与恢复', key: 'backup' },
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
        .onClick(() => {
          if (item.key === 'backup') {
            router.pushUrl({ url: 'pages/BackupSettingsPage' });
          } else {
            this.currentSection = item.key;
          }
        })
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
      Text('📖 阅读设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start)

      // 翻页模式
      Row() {
        Text('翻页模式').fontSize(15).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.pageMode }).onChange(async (v: boolean) => {
          this.pageMode = v;
          try {
            const s = SettingsStore.getInstance();
            await s.init(UiUtil.getHostContext(this.getUIContext()));
            s.setPageMode(v ? 1 : 0).catch(() => {});
          } catch (_e) { /* ignore */ }
        })
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
        .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })

      Text('关闭后使用滚动模式阅读').fontSize(12).fontColor('#888').padding({ left: 16, right: 16, bottom: 12 })

      // 自动缓存章节数
      Text('自动缓存').fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 8 })
      Row() {
        Slider({ value: this.autoCacheSize, min: 0, max: 50, step: 1 })
          .width('60%').margin({ left: 16 })
          .onChange(async (v: number) => {
            this.autoCacheSize = v;
            try {
              const s = SettingsStore.getInstance();
              await s.init(UiUtil.getHostContext(this.getUIContext()));
              s.setAutoCacheSize(v).catch(() => {});
            } catch (_e) { /* ignore */ }
          })
        Text(String(this.autoCacheSize) + ' 章').fontSize(14).fontColor('#0078D7').margin({ left: 8 })
      }.width('100%').margin({ top: 4 })
        .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })

      Text('阅读时自动缓存当前章节前后 ±N 章（0 = 不自动缓存）').fontSize(12).fontColor('#888')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildThemeSettings() {
    Column() {
      Text('\uD83C\uDFA8 主题设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start)

      Row() { Text('浅色模式').fontSize(15).layoutWeight(1)
        Radio({ value: 'light', group: 'themeMode' }).checked(AppTheme.getInstance().mode === ThemeMode.LIGHT)
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
      .onClick(() => { AppTheme.getInstance().setMode(ThemeMode.LIGHT); })

      Row() { Text('深色模式').fontSize(15).layoutWeight(1)
        Radio({ value: 'dark', group: 'themeMode' }).checked(AppTheme.getInstance().mode === ThemeMode.DARK)
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
      .onClick(() => { AppTheme.getInstance().setMode(ThemeMode.DARK); })

      Row() { Text('跟随系统').fontSize(15).layoutWeight(1)
        Radio({ value: 'system', group: 'themeMode' }).checked(AppTheme.getInstance().mode === ThemeMode.SYSTEM)
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
      .onClick(() => { AppTheme.getInstance().setMode(ThemeMode.SYSTEM); })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildNetSettings() {
    Column() {
      Text('\uD83C\uDF10 网络设置').fontSize(16).fontWeight(FontWeight.Medium).padding(16).alignSelf(ItemAlign.Start)

      // DNS 开关
      Row() { Text('启用自定义 DNS').fontSize(15).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled }).onChange((v: boolean) => {
          this.dnsEnabled = v; AppStorage.set<boolean>('dnsEnabled', v);
          NetUtil.setDns(this.dnsServers, v);
          this.syncWebViewNetwork();
        })
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')

      // 网络超时
      Row() { Text('网络超时').fontSize(15).layoutWeight(1)
        TextInput({ text: this.netTimeout, placeholder: '60' })
          .height(36).fontSize(13).width(60).type(InputType.Number)
          .onChange((v: string) => { this.netTimeout = v; })
      }.padding({ left: 16, right: 16 }).width('100%')
      Row() {
        Text('秒（默认60秒，影响目录加载、搜索等操作）').fontSize(11).fontColor('#999').padding({ left: 16 })
      }.width('100%')
      Button('保存超时').fontSize(12).height(28).margin({ left: 16, top: 4 }).onClick(() => {
        const val = parseInt(this.netTimeout);
        if (val && val > 0) {
          AppStorage.set<number>('network_timeout', val);
          UiUtil.showToast(this.getUIContext(), { message: '超时已保存为 ' + val + ' 秒', duration: 1500 });
        }
      })

      // DNS 服务器
      TextInput({ text: this.dnsServers, placeholder: '逗号分隔多个 DNS，如 8.8.8.8,114.114.114.114' })
        .height(36).fontSize(13).layoutWeight(1).margin({ left: 16, right: 16 })
        .onChange((v: string) => { this.dnsServers = v; })
      Button('保存 DNS').fontSize(12).height(28).margin({ left: 16, top: 4 }).onClick(() => {
        AppStorage.set<string>('dnsServers', this.dnsServers);
        NetUtil.setDns(this.dnsServers, this.dnsEnabled);
        this.syncWebViewNetwork();
        UiUtil.showToast(this.getUIContext(), { message: 'DNS 已保存', duration: 1500 });
      })

      // 代理
      Divider().margin({ top: 16 })
      Text('HTTP 代理').fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 12, bottom: 4 })

      Row() {
        TextInput({ text: this.proxyHost, placeholder: '代理地址 如 127.0.0.1' })
          .height(36).fontSize(13).layoutWeight(1).margin({ left: 16 })
          .onChange((v: string) => { this.proxyHost = v; })
        TextInput({ text: this.proxyPort, placeholder: '端口' })
          .height(36).fontSize(13).width(80).type(InputType.Number).margin({ left: 8, right: 16 })
          .onChange((v: string) => { this.proxyPort = v; })
      }.width('100%').margin({ top: 4 })

      Row() {
        Button('保存代理').fontSize(12).height(28).margin({ left: 16 }).onClick(() => {
          AppStorage.set<string>('proxyHost', this.proxyHost);
          AppStorage.set<string>('proxyPort', this.proxyPort);
          const port = parseInt(this.proxyPort);
          if (this.proxyHost && port > 0) NetUtil.setProxy(this.proxyHost, port);
          else NetUtil.clearProxy();
          this.syncWebViewNetwork();
          UiUtil.showToast(this.getUIContext(), { message: '代理已保存', duration: 1500 });
        })
        Button('清除').fontSize(12).height(28).margin({ left: 8 }).backgroundColor('#FF5722').fontColor('#FFF').onClick(() => {
          this.proxyHost = ''; this.proxyPort = '';
          AppStorage.set<string>('proxyHost', '');
          AppStorage.set<string>('proxyPort', '');
          NetUtil.clearProxy();
          this.syncWebViewNetwork();
          UiUtil.showToast(this.getUIContext(), { message: '代理已清除', duration: 1500 });
        })
      }.margin({ top: 4 })

      Text('设置 DNS 可解决部分书源无法解析域名的问题。默认配置了 4 个公共 DNS。').fontSize(12).fontColor('#888').padding(16)
    }.width('100%').alignItems(HorizontalAlign.Start)
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
