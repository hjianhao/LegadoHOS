import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { NetUtil } from '../util/NetUtil';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { MangaImageLoader } from '../util/MangaImageLoader';

import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { UiUtil } from '../util/UiUtil';
import { EpubEngineConfig, EpubEngineType } from '../engine/EpubEngineConfig';

interface SettingItem { icon: string; title: string; key: string; }
interface ReadModeOption { mode: number; label: string; }

@CustomDialog
struct DnsDialog {
  controller: CustomDialogController;
  dnsServers: string = '';
  dnsEnabled: boolean = true;
  onSave: (servers: string, enabled: boolean) => void = () => {};

  build() {
    Column() {
      Text('DNS 设置').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#000000')
        .padding({ bottom: 12 })
      Text('逗号分隔多个 DNS 服务器地址').fontSize(12).fontColor('#666666')
        .padding({ bottom: 8 })
      TextInput({ text: this.dnsServers, placeholder: '如 8.8.8.8,114.114.114.114' })
        .height(36).fontSize(13).width('100%')
        .onChange((v: string) => { this.dnsServers = v; })
      Row() {
        Text('启用').fontSize(14).fontColor('#333333').margin({ right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled })
          .onChange((v: boolean) => { this.dnsEnabled = v; })
      }.margin({ top: 12 })
      Row() {
        Button('取消').fontSize(13).height(32).margin({ right: 8 }).onClick(() => {
          this.controller.close();
        })
        Button('保存').fontSize(13).height(32).onClick(() => {
          this.onSave(this.dnsServers, this.dnsEnabled);
          this.controller.close();
        })
      }.margin({ top: 16 }).justifyContent(FlexAlign.Center).width('100%')
    }.padding(20).width(300)
  }
}

@Entry
@Component
struct SettingsPage {
  @State currentSection: string = 'main';
  @StorageLink('isDark') isDark: boolean = false;
  @StorageLink('isFollowSystem') isFollowSystem: boolean = false;
  @State searchConcurrency: number = 16;
  @State dnsServers: string = '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
  @State dnsEnabled: boolean = true;
  @StorageLink('proxyHost') proxyHost: string = '';
  @StorageLink('proxyPort') proxyPort: string = '';
  @StorageLink('network_timeout') netTimeout: number = 60;
  @State autoCacheSize: number = 10;
  @State epubEngine: string = 'novel';
  @State comicReadMode: number = 0;
  @State comicPreloadNum: number = 3;
  @State comicCacheSize: number = 0;
  @State readFollowTheme: boolean = true;
  @State ttsAzureEndpoint: string = 'https://japaneast.tts.speech.microsoft.com/cognitiveservices/v1';
  @State ttsAzureKey: string = '';
  @State showTtsAzureKey: boolean = false;

	  aboutToAppear(): void {
	    // 从 AppTheme 同步主题模式状态（确保 @StorageLink 获取到正确的初始值）
	    this.isDark = AppTheme.getInstance().isDark;
	    this.isFollowSystem = AppTheme.getInstance().isFollowSystem;
	    this.searchConcurrency = AppStorage.get<number>('searchConcurrency') || 16;
    this.dnsServers = AppStorage.get<string>('dnsServers') || '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
    this.dnsEnabled = AppStorage.get<boolean>('dnsEnabled') !== false;
    NetUtil.setDns(this.dnsServers, this.dnsEnabled);
    if (this.proxyHost && parseInt(this.proxyPort) > 0) {
      NetUtil.setProxy(this.proxyHost, parseInt(this.proxyPort));
    }
    this.syncWebViewNetwork();
    this.loadReadSettings();
    this.loadTtsSettings();
  }

  private async loadReadSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      this.autoCacheSize = await s.getAutoCacheSize();
      this.comicReadMode = await s.getComicReadMode();
      this.comicPreloadNum = await s.getComicPreloadNum();
      this.readFollowTheme = await s.getReadFollowTheme();
      // EPUB 引擎
      const engine = await EpubEngineConfig.getEngine();
      this.epubEngine = engine === EpubEngineType.FOLIATE ? 'foliate' :
        (engine === EpubEngineType.EPUB_JS ? 'epub_js' : 'novel');
    } catch (_e) { /* ignore */ }
    // 加载漫画缓存大小
    this.loadComicCacheSize();
  }

	  private async loadComicCacheSize(): Promise<void> {
    try {
      this.comicCacheSize = await MangaImageLoader.getCacheSize();
    } catch (_) { /* ignore */ }
	  }

  private async loadTtsSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      this.ttsAzureEndpoint = await s.getTtsAzureEndpoint();
      this.ttsAzureKey = await s.getTtsAzureKey();
    } catch (_e) { /* ignore */ }
  }

  private async saveTtsSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      await s.setTtsAzureEndpoint(this.ttsAzureEndpoint.trim());
      await s.setTtsAzureKey(this.ttsAzureKey.trim());
      UiUtil.showToast(this.getUIContext(), { message: '语音设置已保存', duration: 1500 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '保存失败: ' + (e as Error).message, duration: 1800 });
    }
  }

  private formatCacheSize(bytes: number): string {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  private syncWebViewNetwork(): void {
    const proxyUrl = this.proxyHost && this.proxyPort ? 'http://' + this.proxyHost + ':' + this.proxyPort : '';
    WebViewFetcher.configureNetwork(this.dnsEnabled ? this.dnsServers : '', proxyUrl);
    // 同步到 JS 求值 Worker（java.ajax 使用的 RCP session）
    JsExpressionEvaluator.syncNetworkConfigToWorker();
  }

  build() {
    Column() {
      Row() {
        if (this.currentSection !== 'main') {
          Text('< 返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark)).padding({ right: 12 })
            .onClick(() => { this.currentSection = 'main'; })
        }
        Text('设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
      }.padding(16).width('100%')

      if (this.currentSection === 'main') {
        this.buildMainMenu();
      } else if (this.currentSection === 'read') {
        this.buildReadSettings();
      } else if (this.currentSection === 'comic') {
        this.buildComicSettings();
      } else if (this.currentSection === 'search') {
      } else if (this.currentSection === 'theme') {
        this.buildThemeSettings();
      } else if (this.currentSection === 'backup') {
        // backup 入口通过 click handler 直接导航，这里留空
        Column() {}.width('100%').height('100%')
      } else if (this.currentSection === 'network') {
        this.buildNetSettings();
      } else if (this.currentSection === 'tts') {
        this.buildTtsSettings();
      } else if (this.currentSection === 'about') {
        this.buildAboutPage();
      }
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  buildMainMenu() {
    List() {
      ForEach([
	        { icon: '\uD83D\uDCD6', title: '阅读设置', key: 'read' },
	        { icon: '\uD83C\uDFA7', title: '语音朗读设置', key: 'tts' },
	        { icon: '\uD83D\uDCDA', title: '漫画设置', key: 'comic' },
        { icon: '\uD83D\uDD0D', title: '搜索设置', key: 'search' },
        { icon: '\uD83C\uDF10', title: '网络设置', key: 'network' },
        { icon: '\uD83C\uDFA8', title: '主题设置', key: 'theme' },
	        { icon: '\uD83D\uDD04', title: '备份与恢复', key: 'backup' },
	        { icon: '\u2699\uFE0F', title: 'Worker测试', key: 'worker_test' },
	        { icon: '\u2139\uFE0F', title: '关于', key: 'about' },
	      ] as SettingItem[], (item: SettingItem) => {
        ListItem() {
          Row() {
            Text(item.icon).fontSize(22).margin({ right: 14 }).fontColor(ThemeColors.onBackground(this.isDark))
            Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark))
            Blank()
            Text('>').fontSize(18).fontColor(ThemeColors.onBackground(this.isDark))
          }.padding(16).width('100%')
        }
        .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
		        .onClick(() => {
		          if (item.key === 'backup') {
		            this.getUIContext().getRouter().pushUrl({ url: 'pages/BackupSettingsPage' }).catch(() => {});
		          } else if (item.key === 'worker_test') {
		            this.getUIContext().getRouter().pushUrl({ url: 'pages/WorkerTestPage' }).catch(() => {});
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
        Text('\uD83D\uDD0D 并发搜索数').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Text(String(this.searchConcurrency)).fontSize(16).fontColor(ThemeColors.primary(this.isDark))
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
        .fontSize(12).fontColor(ThemeColors.onBackground(this.isDark)).padding({ left: 16, right: 16, top: 4 })

      // 分组：默认启用
      Row() {
        Text('\uD83D\uDCC2 搜索时启用全部源').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Toggle({ type: ToggleType.Switch, isOn: true })
      }.padding(16).width('100%')
      .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })

      Text('关闭后仅使用已启用的书源搜索')
        .fontSize(12).fontColor(ThemeColors.onBackground(this.isDark)).padding({ left: 16, right: 16, bottom: 8 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildReadSettings() {
    Column() {
      Text('📖 阅读设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // 自动缓存章节数
      Text('自动缓存').fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
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
        Text(String(this.autoCacheSize) + ' 章').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
      }.width('100%').margin({ top: 4 })
        .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })

	      Text('阅读时自动缓存当前章节前后 ±N 章（0 = 不自动缓存）').fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
	        .padding({ left: 16, right: 16, top: 4, bottom: 12 })

	      // EPUB 阅读引擎
	      Text('EPUB 阅读引擎').fontSize(15).fontWeight(FontWeight.Bold)
	        .padding({ left: 16, top: 12, bottom: 4 }).fontColor(ThemeColors.onBackground(this.isDark))
	      Row() {
	        Text('小说阅读').fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
	        Radio({ value: 'novel', group: 'epubEngine' })
	          .checked(this.epubEngine === 'novel')
	          .onChange(() => { this.setEpubEngine_('novel'); })
	      }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')
	      Row() {
		        Text('图文混排1').fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
		        Radio({ value: 'epub_js', group: 'epubEngine' })
		          .checked(this.epubEngine === 'epub_js')
		          .onChange(() => { this.setEpubEngine_('epub_js'); })
		      }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')
	      Row() {
		        Text('图文混排2').fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
		        Radio({ value: 'foliate', group: 'epubEngine' })
		          .checked(this.epubEngine === 'foliate')
		          .onChange(() => { this.setEpubEngine_('foliate'); })
		      }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')
		      .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
	    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildTtsSettings() {
    Scroll() {
      Column() {
        Text('语音朗读设置').fontSize(16).fontWeight(FontWeight.Medium)
          .padding({ left: 16, right: 16, top: 16, bottom: 8 })
          .alignSelf(ItemAlign.Start)
          .fontColor(ThemeColors.onBackground(this.isDark))

        Text('微软 Azure 语音服务').fontSize(15).fontWeight(FontWeight.Bold)
          .padding({ left: 16, right: 16, top: 12, bottom: 4 })
          .alignSelf(ItemAlign.Start)
          .fontColor(ThemeColors.onBackground(this.isDark))

        Text('端点').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })
          .alignSelf(ItemAlign.Start)
        Column() {
          TextInput({ text: this.ttsAzureEndpoint, placeholder: 'https://japaneast.tts.speech.microsoft.com/cognitiveservices/v1' })
            .fontSize(13)
            .height(42)
            .width('100%')
            .onChange((v: string) => { this.ttsAzureEndpoint = v; })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        Text('可填写完整 TTS 合成地址；也可填写 Portal 里的 https://<region>.api.cognitive.microsoft.com，应用会自动转换')
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })

        Text('密钥').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })
          .alignSelf(ItemAlign.Start)
        Row() {
          TextInput({ text: this.ttsAzureKey, placeholder: 'Azure Speech Key' })
            .fontSize(13)
            .layoutWeight(1)
            .type(this.showTtsAzureKey ? InputType.Normal : InputType.Password)
            .onChange((v: string) => { this.ttsAzureKey = v; })
          Button(this.showTtsAzureKey ? '隐藏' : '显示')
            .fontSize(12)
            .height(34)
            .padding({ left: 10, right: 10 })
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark))
            .margin({ left: 8 })
            .onClick(() => { this.showTtsAzureKey = !this.showTtsAzureKey; })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Text('微软语音的音色在阅读页朗读面板中选择，首次默认使用第一个中文音色。')
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 16, right: 16, top: 16, bottom: 12 })

        Column() {
          Button('保存微软语音设置')
            .fontSize(14)
            .height(44)
            .width('100%')
            .backgroundColor(ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { this.saveTtsSettings(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })

        Text('保存后，在阅读页朗读面板的“引擎”里选择“微软语音”。文本会发送到 Azure 进行在线合成。')
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 16, right: 16, bottom: 16 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  buildComicSettings() {
    Column() {
      Text('\uD83D\uDCDA 漫画设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // 阅读方向
      Text('阅读方向').fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Row() {
        ForEach([
          { mode: 0, label: '条漫' } as ReadModeOption,
          { mode: 1, label: '左->右' } as ReadModeOption,
          { mode: 2, label: '右->左' } as ReadModeOption,
        ], (item: ReadModeOption) => {
          Text(item.label)
            .fontSize(14).padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .fontColor(this.comicReadMode === item.mode ? ThemeColors.primary(this.isDark) : ThemeColors.onBackground(this.isDark))
            .borderRadius(8)
            .backgroundColor(this.comicReadMode === item.mode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
            .margin({ right: 8 })
            .onClick(async () => {
              this.comicReadMode = item.mode;
              try {
                const s = SettingsStore.getInstance();
                await s.init(UiUtil.getHostContext(this.getUIContext()));
                await s.setComicReadMode(item.mode);
              } catch (_e) { /* ignore */ }
            })
        }, (item: ReadModeOption) => item.mode.toString())
      }.padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })

      // 预加载数量
      Text('图片预加载数量').fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Row() {
        Slider({ value: this.comicPreloadNum, min: 1, max: 20, step: 1 })
          .width('60%').margin({ left: 16 })
          .onChange(async (v: number) => {
            this.comicPreloadNum = Math.round(v);
            try {
              const s = SettingsStore.getInstance();
              await s.init(UiUtil.getHostContext(this.getUIContext()));
              await s.setComicPreloadNum(this.comicPreloadNum);
            } catch (_e) { /* ignore */ }
          })
        Text(this.comicPreloadNum + ' 张').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
      }.width('100%').margin({ top: 4 })
        .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
      Text('预先下载当前章节前 N 张图片到本地缓存').fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })

      // 缓存管理
      Text('图片缓存管理').fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Row() {
        Text('当前缓存').fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Text(this.formatCacheSize(this.comicCacheSize)).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ right: 8 })
        Button('清理').fontSize(13).height(32).onClick(async () => {
          try {
            await MangaImageLoader.clearAllCache();
            await this.loadComicCacheSize();
            UiUtil.showToast(this.getUIContext(), { message: '缓存已清理', duration: 1500 });
          } catch (e) {
            UiUtil.showToast(this.getUIContext(), { message: '清理失败', duration: 1500 });
          }
        })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildThemeSettings() {
    Column() {
      Text('\uD83C\uDFA8 主题设置').fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

	      Row() {
	        Text('跟随系统').fontSize(16).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
	        Toggle({ type: ToggleType.Switch, isOn: this.isFollowSystem })
	          .onChange((v: boolean) => {
	            if (v) {
	              AppTheme.getInstance().setFollowSystem();
	              this.isDark = AppTheme.getInstance().isDark;
	            } else {
	              AppTheme.getInstance().setDarkMode(this.isDark);
	            }
	            // 确保模式保存持久化
	            (async () => {
	              try {
	                const s = SettingsStore.getInstance();
	                await s.init(UiUtil.getHostContext(this.getUIContext()));
	                await s.setThemeMode(v ? 'system' : (AppTheme.getInstance().isDark ? 'dark' : 'light'));
	              } catch (_e) { /* ignore */ }
	            })();
	          })
      }.padding({ left: 16, right: 16, top: 12, bottom: 4 }).width('100%')

      Row() {
        Text('深色模式').fontSize(16).fontColor(this.isFollowSystem ? ThemeColors.secondaryText(this.isDark) : ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.isDark })
          .onChange((v: boolean) => {
            if (v) {
              // 开启深色时自动退出跟随系统
              this.isFollowSystem = false;
              AppTheme.getInstance().setDarkMode(true);
            } else {
              AppTheme.getInstance().setDarkMode(false);
            }
            this.isDark = v;
          })
      }.padding({ left: 16, right: 16, top: 4, bottom: 12 }).width('100%')

      Row() {
        Text('阅读界面随主题切换').fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Toggle({ type: ToggleType.Switch, isOn: this.readFollowTheme })
          .onChange((v: boolean) => {
            this.readFollowTheme = v;
            (async () => {
              try {
                const s = SettingsStore.getInstance();
                await s.init(UiUtil.getHostContext(this.getUIContext()));
                s.setReadFollowTheme(v).catch(() => {});
              } catch (_e) { /* ignore */ }
            })();
          })
      }.padding({ left: 16, right: 16, top: 4, bottom: 12 }).width('100%')
      Text('开启后切换应用主题时，阅读界面自动切换日间/夜间模式').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, bottom: 12 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildNetSettings() {
    Column() {
      Text('\uD83C\uDF10 网络设置').fontSize(16).fontWeight(FontWeight.Medium).padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // DNS 开关
      Row() { Text('启用自定义 DNS').fontSize(15).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled }).onChange((v: boolean) => {
          this.dnsEnabled = v; AppStorage.set<boolean>('dnsEnabled', v);
          NetUtil.setDns(this.dnsServers, v);
          this.syncWebViewNetwork();
        })
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')

      // DNS 服务器（紧凑：一行显示当前值 + 设置按钮）
      Row() {
        Text('DNS 服务器').fontSize(15).fontColor(ThemeColors.onBackground(this.isDark)).margin({ right: 8 })
        Text(this.dnsServers).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('设置').fontSize(12).height(28).onClick(() => {
          const dlg = new CustomDialogController({
            builder: DnsDialog({
              dnsServers: this.dnsServers,
              dnsEnabled: this.dnsEnabled,
              onSave: (servers: string, enabled: boolean) => {
                this.dnsServers = servers;
                this.dnsEnabled = enabled;
                AppStorage.set<string>('dnsServers', servers);
                AppStorage.set<boolean>('dnsEnabled', enabled);
                NetUtil.setDns(servers, enabled);
                this.syncWebViewNetwork();
                UiUtil.showToast(this.getUIContext(), { message: 'DNS 已保存', duration: 1500 });
              }
            })
          });
          dlg.open();
        })
      }.padding({ left: 16, right: 16 }).width('100%').margin({ top: 4, bottom: 8 })

      // 网络超时
      Row() { Text('网络超时').fontSize(15).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        TextInput({ text: String(this.netTimeout), placeholder: '60' })
          .height(36).fontSize(13).width(60).type(InputType.Number)
          .onChange((v: string) => {
            const val = parseInt(v);
            if (val && val > 0) {
              this.netTimeout = val;
              AppStorage.set<number>('network_timeout', val);
            }
          })
        Text('秒').fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 4 })
      }.padding({ left: 16, right: 16 }).width('100%')
      Row() {
        Text('默认60秒，影响目录加载、搜索等操作，修改后即时生效').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).padding({ left: 16 })
      }.width('100%').margin({ bottom: 8 })

      Divider().margin({ top: 8, bottom: 8 })
      Text('HTTP 代理').fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 4, bottom: 4 }).fontColor(ThemeColors.onBackground(this.isDark))

      // 代理地址和端口（@StorageLink 自动同步，无需手动保存）
      Row() {
        TextInput({ text: this.proxyHost, placeholder: '代理地址 如 127.0.0.1' })
          .height(36).fontSize(13).layoutWeight(1).margin({ left: 16 })
          .onChange((v: string) => { this.proxyHost = v; this.applyProxy_(); })
        TextInput({ text: this.proxyPort, placeholder: '端口' })
          .height(36).fontSize(13).width(80).type(InputType.Number).margin({ left: 8, right: 16 })
          .onChange((v: string) => { this.proxyPort = v; this.applyProxy_(); })
      }.width('100%').margin({ top: 4 })

      Row() {
        Button('清除代理').fontSize(12).height(28).margin({ left: 16 }).backgroundColor('#FF5722').fontColor('#FFF').onClick(() => {
          this.proxyHost = ''; this.proxyPort = '';
          NetUtil.clearProxy();
          this.syncWebViewNetwork();
          UiUtil.showToast(this.getUIContext(), { message: '代理已清除', duration: 1500 });
        })
      }.margin({ top: 4 })

      Text('设置 DNS 可解决部分书源无法解析域名的问题。默认配置了 4 个公共 DNS。').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).padding(16)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  private applyProxy_(): void {
    const port = parseInt(this.proxyPort);
    if (this.proxyHost && port > 0) {
      NetUtil.setProxy(this.proxyHost, port);
    } else if (!this.proxyHost) {
      NetUtil.clearProxy();
    }
    this.syncWebViewNetwork();
  }

  @Builder
  buildAboutPage() {
    Column() {
      Text('LegadoHOS').fontSize(24).fontWeight(FontWeight.Bold).margin({ top: 40 }).fontColor(ThemeColors.onBackground(this.isDark))
      Text('v1.0.0').fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
      Text('鸿蒙原生阅读APP').fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 2 })
      Text('基于 legado-with-MD3 重构').fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 16 })
    }
    .width('100%').alignItems(HorizontalAlign.Center)
  }

  private setEpubEngine_(val: string): void {
    this.epubEngine = val;
    const type = val === 'foliate' ? EpubEngineType.FOLIATE :
      (val === 'epub_js' ? EpubEngineType.EPUB_JS : EpubEngineType.NOVEL);
    EpubEngineConfig.setEngine(type);
  }
}
