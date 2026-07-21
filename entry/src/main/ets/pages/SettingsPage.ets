import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { NetUtil } from '../util/NetUtil';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { WindowSizeClass } from '../util/WindowLayout';
import { ContentMaxWidth } from '../components/common/ResponsiveLayout';

import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { UiUtil } from '../util/UiUtil';
import { EpubEngineConfig, EpubEngineType } from '../engine/EpubEngineConfig';
import { AppBackButton } from '../components/common/AppTitleBar';

interface ReadModeOption { mode: number; label: string; }

/** 设置分类（内嵌详情页；page 非空时跳转子页面） */
interface SettingCategory {
  icon: string;
  title: string;
  key: string;
  /** 独立子页面路由，空字符串表示内嵌 section */
  page: string;
}

@CustomDialog
struct DnsDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  dnsServers: string = '';
  dnsEnabled: boolean = true;
  onSave: (servers: string, enabled: boolean) => void = () => {};

  build() {
    Column() {
      Text($r('app.string.ui_508aad2848')).fontSize(16).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onSurface(this.isDark))
        .padding({ bottom: 12 })
      Text($r('app.string.ui_2ef24aca64')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ bottom: 8 })
      TextInput({ text: this.dnsServers, placeholder: $r('app.string.ui_94a1fb04e2') })
        .height(40).fontSize(13).width('100%')
        .onChange((v: string) => { this.dnsServers = v; })
      Row() {
        Text($r('app.string.ui_d4e9ca3dd4')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).margin({ right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled })
          .onChange((v: boolean) => { this.dnsEnabled = v; })
      }.margin({ top: 12 })
      Row() {
        Button($r('app.string.common_cancel')).fontSize(13).height(40).margin({ right: 8 }).onClick(() => {
          this.controller.close();
        })
        Button($r('app.string.common_save')).fontSize(13).height(40).onClick(() => {
          this.onSave(this.dnsServers, this.dnsEnabled);
          this.controller.close();
        })
      }.margin({ top: 16 }).justifyContent(FlexAlign.Center).width('100%')
    }
    .padding(20)
    .width('90%')
    .constraintSize({ maxWidth: 400 })
    .backgroundColor(ThemeColors.surface(this.isDark))
  }
}

@Entry
@Component
export struct SettingsPage {
  @State currentSection: string = 'main';
  @StorageLink('isDark') isDark: boolean = false;
  @StorageLink('isFollowSystem') isFollowSystem: boolean = false;
  @StorageProp('windowSizeClass') sizeClassNum: number = 0;
  @StorageProp('windowIsWide') isWideFlag: boolean = false;
  @StorageProp('windowWidthVp') windowWidthVp: number = 360;
  @State localWidthVp: number = 0;
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

  private readonly categories: SettingCategory[] = [
    { icon: '读', title: '阅读设置', key: 'read', page: '' },
    { icon: '声', title: '语音朗读设置', key: 'tts', page: '' },
    { icon: '漫', title: '漫画设置', key: 'comic', page: '' },
    { icon: '搜', title: '搜索设置', key: 'search', page: '' },
    { icon: 'AI', title: '大模型配置', key: 'ai', page: 'pages/AiConfigPage' },
    { icon: '网', title: '网络设置', key: 'network', page: '' },
    { icon: '题', title: '主题设置', key: 'theme', page: '' },
    { icon: '存', title: '缓存管理', key: 'cacheManage', page: 'pages/CacheManagePage' },
    { icon: '备', title: '备份与恢复', key: 'backup', page: 'pages/BackupSettingsPage' },
    { icon: '关', title: '关于', key: 'about', page: '' },
  ];

  private get sizeClass(): WindowSizeClass {
    if (this.localWidthVp >= 1200 || this.windowWidthVp >= 1200) {
      return WindowSizeClass.LARGE;
    }
    if (this.localWidthVp >= 840 || this.windowWidthVp >= 840) {
      return WindowSizeClass.EXPANDED;
    }
    if (this.localWidthVp >= 600 || this.windowWidthVp >= 600 ||
      this.isWideFlag || this.sizeClassNum >= WindowSizeClass.MEDIUM) {
      return WindowSizeClass.MEDIUM;
    }
    return WindowSizeClass.COMPACT;
  }

  /**
   * 宽屏双栏：左分类 + 右配置。
   * 已嵌在「我的」右侧时仍启用（形成 我的菜单 | 设置分类 | 配置）。
   */
  private get isSettingsSplit(): boolean {
    return this.sizeClass >= WindowSizeClass.MEDIUM;
  }

  /**
   * 实际展示的分类 key。
   * 宽屏下若仍是 main（sizeClass 晚到），回退到 read，避免右侧空白。
   */
  private get activeSection(): string {
    if (this.isSettingsSplit && (this.currentSection === 'main' || this.currentSection.length === 0)) {
      return 'read';
    }
    return this.currentSection;
  }

  /** 当前分类标题 */
  private sectionTitle(): string {
    const key = this.activeSection;
    for (let i = 0; i < this.categories.length; i++) {
      if (this.categories[i].key === key) {
        return this.categories[i].title;
      }
    }
    return '设置';
  }

  aboutToAppear(): void {
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
      // 顶栏
      Row() {
        // 嵌在「我的」右侧时仍显示返回（清空右侧）；双栏下不进入子 section 返回逻辑
        AppBackButton({ onBack: () => {
          // 宽屏双栏 / 主列表：直接 back（内嵌时 UiUtil 会清空右侧）
          // 手机子 section：先回到主列表
          if (this.isSettingsSplit || this.currentSection === 'main') {
            UiUtil.back(this.getUIContext());
          } else {
            this.currentSection = 'main';
          }
        } })
        Text(this.isSettingsSplit || this.currentSection === 'main'
          ? '设置'
          : this.sectionTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
      }.height(56).padding({ left: 4, right: 12 }).width('100%')
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

      if (this.isSettingsSplit) {
        this.buildSplitBody()
      } else {
        this.buildCompactBody()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .onAreaChange((_o: Area, area: Area) => {
      const w = typeof area.width === 'number' ? area.width : Number(area.width);
      if (Number.isFinite(w) && w > 0 && Math.abs(w - this.localWidthVp) > 0.5) {
        this.localWidthVp = w;
      }
    })
  }

  /** 宽屏：左分类 + 右配置 */
  @Builder
  private buildSplitBody() {
    Row() {
      Column() {
        this.buildCategoryList(true)
      }
      .width(this.sizeClass >= WindowSizeClass.LARGE ? 260 : 220)
      .height('100%')
      .backgroundColor(ThemeColors.surface(this.isDark))

      Divider()
        .vertical(true)
        .strokeWidth(0.5)
        .color(ThemeColors.outlineVariant(this.isDark))

      Column() {
        Text(this.sectionTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 4 })
        Scroll() {
          Column() {
            this.buildSectionContent()
          }
          .width('100%')
          .constraintSize({ maxWidth: ContentMaxWidth.FORM })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.Spring)
      }
      .layoutWeight(1)
      .height('100%')
      .padding({ left: 4, right: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
  }

  /** 手机：单列逐级 */
  @Builder
  private buildCompactBody() {
    if (this.currentSection === 'main') {
      this.buildCategoryList(false)
    } else {
      Scroll() {
        Column() {
          this.buildSectionContent()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 打开设置分类：内嵌 section 或 classic router 打开独立子页 */
  private openCategory(item: SettingCategory): void {
    if (item.page.length > 0) {
      // 独立子页必须走 classic router，NavPathStack 当前会空白
      UiUtil.pushUrl(this.getUIContext(), { url: item.page });
      return;
    }
    this.currentSection = item.key;
  }

  @Builder
  buildCategoryList(splitMode: boolean) {
    List() {
      ForEach(this.categories, (item: SettingCategory) => {
        ListItem() {
          Row() {
            if (splitMode) {
              Column()
                .width(3)
                .height(24)
                .borderRadius(2)
                .backgroundColor(this.activeSection === item.key
                  ? ThemeColors.primary(this.isDark)
                  : ThemeColors.transparent())
                .margin({ right: 10 })
            }
            Text(item.icon)
              .fontSize(splitMode ? 18 : 22)
              .margin({ right: 12 })
              .fontColor(this.activeSection === item.key && splitMode
                ? ThemeColors.primary(this.isDark)
                : ThemeColors.onBackground(this.isDark))
            Text(item.title)
              .fontSize(splitMode ? 15 : 16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.activeSection === item.key && splitMode
                ? ThemeColors.primary(this.isDark)
                : ThemeColors.onBackground(this.isDark))
              .layoutWeight(1)
            if (!splitMode) {
              Text($r('app.string.ui_091385be99'))
                .fontSize(18)
                .fontColor(ThemeColors.secondaryText(this.isDark))
            }
          }
          .padding(splitMode
            ? { left: 12, right: 12, top: 12, bottom: 12 }
            : { left: 16, right: 16, top: 16, bottom: 16 })
          .width('100%')
          .backgroundColor(splitMode && this.activeSection === item.key
            ? ThemeColors.primaryContainer(this.isDark)
            : ThemeColors.transparent())
          .borderRadius(splitMode ? 10 : 0)
        }
        .margin(splitMode ? { left: 8, right: 8, top: 2, bottom: 2 } : { left: 0, right: 0, top: 0, bottom: 0 })
        .border(splitMode
          ? { width: 0 }
          : { width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
        .accessibilityText(item.title)
        .onClick(() => {
          this.openCategory(item);
        })
      }, (item: SettingCategory) => item.key)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(splitMode ? BarState.Auto : BarState.Off)
  }

  @Builder
  buildSectionContent() {
    if (this.activeSection === 'read') {
      this.buildReadSettings();
    } else if (this.activeSection === 'comic') {
      this.buildComicSettings();
    } else if (this.activeSection === 'search') {
      this.buildSearchSettings();
    } else if (this.activeSection === 'theme') {
      this.buildThemeSettings();
    } else if (this.activeSection === 'network') {
      this.buildNetSettings();
    } else if (this.activeSection === 'tts') {
      this.buildTtsSettings();
    } else if (this.activeSection === 'about') {
      this.buildAboutPage();
    } else {
      Column() {
        Text('请选择左侧分类')
          .fontSize(14)
          .fontColor(ThemeColors.secondaryText(this.isDark))
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  buildMainMenu() {
    this.buildCategoryList(false)
  }

  @Builder
  buildSearchSettings() {
    Column() {
      // 并发搜索数配置
      Row() {
        Text($r('app.string.ui_600907a2c7')).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Text(String(this.searchConcurrency)).fontSize(16).fontColor(ThemeColors.primary(this.isDark))
          .width(40).textAlign(TextAlign.End)
      }.padding({ left: 16, right: 16, top: 16, bottom: 8 }).width('100%')

      Row() {
        Slider({
          value: this.searchConcurrency,
          min: 1, max: 50, step: 1
        })
        .width('100%')
        .onChange((val: number) => {
          this.searchConcurrency = val;
          AppStorage.set<number>('searchConcurrency', val);
        })
      }.width('100%').padding({ left: 16, right: 16 })

      Text($r('app.string.ui_0a4ed43a7e'))
        .fontSize(12).fontColor(ThemeColors.onBackground(this.isDark)).padding({ left: 16, right: 16, top: 4 })

      // 分组：默认启用
      Row() {
        Text($r('app.string.ui_f2307104fe')).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Toggle({ type: ToggleType.Switch, isOn: true })
      }.padding(16).width('100%')
      .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })

      Text($r('app.string.ui_136ddb8c2d'))
        .fontSize(12).fontColor(ThemeColors.onBackground(this.isDark)).padding({ left: 16, right: 16, bottom: 8 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildReadSettings() {
    Column() {
      Text($r('app.string.ui_bc0832465e')).fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // 自动缓存章节数
      Text($r('app.string.ui_2cde0d64a9')).fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
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

	      Text($r('app.string.ui_761b13d7e8')).fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
	        .padding({ left: 16, right: 16, top: 4, bottom: 12 })

	      // EPUB 阅读引擎
	      Text($r('app.string.ui_e8a5847184')).fontSize(15).fontWeight(FontWeight.Bold)
	        .padding({ left: 16, top: 12, bottom: 4 }).fontColor(ThemeColors.onBackground(this.isDark))
	      Row() {
	        Text($r('app.string.ui_fc917f3a3c')).fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
	        Radio({ value: 'novel', group: 'epubEngine' })
	          .checked(this.epubEngine === 'novel')
	          .onChange(() => { this.setEpubEngine_('novel'); })
	      }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')
	      Row() {
		        Text($r('app.string.ui_9e712a850b')).fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
		        Radio({ value: 'epub_js', group: 'epubEngine' })
		          .checked(this.epubEngine === 'epub_js')
		          .onChange(() => { this.setEpubEngine_('epub_js'); })
		      }.padding({ left: 16, right: 16, top: 4, bottom: 4 }).width('100%')
	      Row() {
		        Text($r('app.string.ui_c695d53340')).fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
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
    Column() {
      Text($r('app.string.ui_a0d3218048')).fontSize(16).fontWeight(FontWeight.Medium)
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        .alignSelf(ItemAlign.Start)
        .fontColor(ThemeColors.onBackground(this.isDark))

      Text($r('app.string.ui_2f5f1495cc')).fontSize(15).fontWeight(FontWeight.Bold)
        .padding({ left: 16, right: 16, top: 12, bottom: 4 })
        .alignSelf(ItemAlign.Start)
        .fontColor(ThemeColors.onBackground(this.isDark))

      Text($r('app.string.ui_2a1cad5f9e')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        .alignSelf(ItemAlign.Start)
      Column() {
        TextInput({ text: this.ttsAzureEndpoint, placeholder: $r('app.string.ui_298b8d3d76') })
          .fontSize(13)
          .height(48)
          .width('100%')
          .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((v: string) => { this.ttsAzureEndpoint = v; })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      Text($r('app.string.ui_44aaab081d'))
        .fontSize(11)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Text($r('app.string.ui_0d1965e139')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        .alignSelf(ItemAlign.Start)
      Row() {
        TextInput({ text: this.ttsAzureKey, placeholder: $r('app.string.ui_81474dc689') })
          .fontSize(13)
          .layoutWeight(1)
          .height(48).fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .type(this.showTtsAzureKey ? InputType.Normal : InputType.Password)
          .onChange((v: string) => { this.ttsAzureKey = v; })
        Button(this.showTtsAzureKey ? '隐藏' : '显示')
          .fontSize(12)
          .height(40)
          .padding({ left: 10, right: 10 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .margin({ left: 8 })
          .onClick(() => { this.showTtsAzureKey = !this.showTtsAzureKey; })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Text($r('app.string.ui_7701f53574'))
        .fontSize(11)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      Column() {
        Button($r('app.string.ui_ea7c1a58fa'))
          .fontSize(14)
          .height(44)
          .width('100%')
          .backgroundColor(ThemeColors.primary(this.isDark))
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .onClick(() => { this.saveTtsSettings(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })

      Text($r('app.string.ui_2932250412'))
        .fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildComicSettings() {
    Column() {
      Text($r('app.string.ui_7da1731cca')).fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // 阅读方向
      Text($r('app.string.ui_d3eaabf98d')).fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Row() {
        ForEach([
          { mode: 0, label: '条漫' } as ReadModeOption,
          { mode: 1, label: '左->右' } as ReadModeOption,
          { mode: 2, label: '右->左' } as ReadModeOption,
        ], (item: ReadModeOption) => {
          Text(item.label)
            .fontSize(14).padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .fontColor(this.comicReadMode === item.mode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onBackground(this.isDark))
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
      Text($r('app.string.ui_1899e4c569')).fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
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
      Text($r('app.string.ui_c6e1130def')).fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })

      // 缓存管理
      Text($r('app.string.ui_f76562e2f2')).fontSize(15).padding({ left: 16, top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Row() {
        Text($r('app.string.ui_bc473d919d')).fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Text(this.formatCacheSize(this.comicCacheSize)).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ right: 8 })
        Button($r('app.string.ui_907c3945d8')).fontSize(13).height(40).onClick(async () => {
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
      Text($r('app.string.ui_9ce0aa853f')).fontSize(16).fontWeight(FontWeight.Medium)
        .padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

	      Row() {
	        Text($r('app.string.ui_f4bbd91f79')).fontSize(16).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
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
        Text($r('app.string.ui_750642ccd6')).fontSize(16).fontColor(this.isFollowSystem ? ThemeColors.secondaryText(this.isDark) : ThemeColors.onBackground(this.isDark)).layoutWeight(1)
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
        Text($r('app.string.ui_731e048a56')).fontSize(14).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
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
      Text($r('app.string.ui_2244992a1c')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, bottom: 12 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildNetSettings() {
    Column() {
      Text($r('app.string.ui_faec236cbb')).fontSize(16).fontWeight(FontWeight.Medium).padding(16).alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))

      // DNS 开关
      Row() { Text($r('app.string.ui_48ef79da8b')).fontSize(15).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled }).onChange((v: boolean) => {
          this.dnsEnabled = v; AppStorage.set<boolean>('dnsEnabled', v);
          NetUtil.setDns(this.dnsServers, v);
          this.syncWebViewNetwork();
        })
      }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')

      // DNS 服务器（紧凑：一行显示当前值 + 设置按钮）
      Row() {
        Text($r('app.string.ui_94c9cca7ea')).fontSize(15).fontColor(ThemeColors.onBackground(this.isDark)).margin({ right: 8 })
        Text(this.dnsServers).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button($r('app.string.common_settings')).fontSize(12).height(40).onClick(() => {
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
      Row() { Text($r('app.string.ui_bbd5eab31b')).fontSize(15).layoutWeight(1).fontColor(ThemeColors.onBackground(this.isDark))
        TextInput({ text: String(this.netTimeout), placeholder: $r('app.string.ui_e6c3dd6304') })
          .height(48).fontSize(13).width(60).type(InputType.Number)
          .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((v: string) => {
            const val = parseInt(v);
            if (val && val > 0) {
              this.netTimeout = val;
              AppStorage.set<number>('network_timeout', val);
            }
          })
        Text($r('app.string.ui_eb6aaba1a1')).fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 4 })
      }.padding({ left: 16, right: 16 }).width('100%')
      Row() {
        Text($r('app.string.ui_65eee70aa6')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).padding({ left: 16 })
      }.width('100%').margin({ bottom: 8 })

      Divider().margin({ top: 8, bottom: 8 })
      Text($r('app.string.ui_d95ef5ba39')).fontSize(15).fontWeight(FontWeight.Medium).padding({ left: 16, top: 4, bottom: 4 }).fontColor(ThemeColors.onBackground(this.isDark))

      // 代理地址和端口（@StorageLink 自动同步，无需手动保存）
      Row() {
        TextInput({ text: this.proxyHost, placeholder: $r('app.string.ui_d74862f686') })
          .height(48).fontSize(13).layoutWeight(1).margin({ left: 16 })
          .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((v: string) => { this.proxyHost = v; this.applyProxy_(); })
        TextInput({ text: this.proxyPort, placeholder: $r('app.string.ui_6cbb7335b5') })
          .height(48).fontSize(13).width(80).type(InputType.Number).margin({ left: 8, right: 16 })
          .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((v: string) => { this.proxyPort = v; this.applyProxy_(); })
      }.width('100%').margin({ top: 4 })

      Row() {
        Button($r('app.string.ui_be090d82b1')).fontSize(12).height(40).margin({ left: 16 }).backgroundColor(ThemeColors.error(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).onClick(() => {
          this.proxyHost = ''; this.proxyPort = '';
          NetUtil.clearProxy();
          this.syncWebViewNetwork();
          UiUtil.showToast(this.getUIContext(), { message: '代理已清除', duration: 1500 });
        })
      }.margin({ top: 4 })

      Text($r('app.string.ui_97ccf737aa')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).padding(16)
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
      Text($r('app.string.ui_3fbe4d7fb9')).fontSize(24).fontWeight(FontWeight.Bold).margin({ top: 40 }).fontColor(ThemeColors.onBackground(this.isDark))
      Text($r('app.string.ui_7ac19ee157')).fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
      Text($r('app.string.ui_4ac6b626ac')).fontSize(14).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 2 })
      Text($r('app.string.ui_af0f06ab56')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 16 })
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
