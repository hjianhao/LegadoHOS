/**
 * RSS 源编辑页
 * 对应 Android RssSourceEditActivity — 编辑 RSS 源全部字段
 * 分 Tab：基本信息、列表规则、内容规则、WebView 配置
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource } from '../model/RSSSource';
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

interface FieldGroup {
  key: string;
  label: string;
  placeholder: string;
}

const TAB_BASIC: FieldGroup[] = [
  { key: 'sourceName', label: '名称', placeholder: 'RSS 源名称' },
  { key: 'sourceUrl', label: '源 URL', placeholder: 'https://example.com/rss' },
  { key: 'sourceIcon', label: '图标 URL', placeholder: '图标地址（可选）' },
  { key: 'sourceGroup', label: '分组', placeholder: '分组名称' },
  { key: 'sourceComment', label: '备注', placeholder: '备注信息' },
  { key: 'sortUrl', label: '分类 URL', placeholder: '分类 URL（可选）' },
  { key: 'searchUrl', label: '搜索 URL', placeholder: '搜索 URL（可选）' },
];

const TAB_LIST_RULES: FieldGroup[] = [
  { key: 'ruleArticles', label: '文章列表规则', placeholder: 'CSS/JSONPath 规则' },
  { key: 'ruleTitle', label: '标题规则', placeholder: '文章标题提取规则' },
  { key: 'ruleLink', label: '链接规则', placeholder: '文章链接提取规则' },
  { key: 'rulePubDate', label: '发布日期规则', placeholder: '发布日期提取规则' },
  { key: 'ruleDescription', label: '描述规则', placeholder: '描述提取规则' },
  { key: 'ruleImage', label: '图片规则', placeholder: '图片提取规则' },
  { key: 'ruleNextPage', label: '下一页规则', placeholder: '分页规则' },
];

const TAB_CONTENT_RULES: FieldGroup[] = [
  { key: 'ruleContent', label: '正文规则', placeholder: '正文提取规则' },
  { key: 'contentWhitelist', label: 'URL 白名单', placeholder: '允许的 URL 模式' },
  { key: 'contentBlacklist', label: 'URL 黑名单', placeholder: '禁止的 URL 模式' },
];

const TAB_WEBVIEW: FieldGroup[] = [
  { key: 'style', label: '样式 CSS', placeholder: '自定义 CSS 样式' },
  { key: 'injectJs', label: '注入 JS', placeholder: '注入 JavaScript' },
  { key: 'preloadJs', label: '预加载 JS', placeholder: '预加载 JavaScript' },
  { key: 'startHtml', label: '起始 HTML', placeholder: '起始 HTML 内容' },
  { key: 'startJs', label: '起始 JS', placeholder: '起始 JavaScript' },
  { key: 'header', label: '自定义请求头', placeholder: 'JSON 格式请求头' },
  { key: 'loginUrl', label: '登录地址', placeholder: '登录页面 URL' },
  { key: 'loginCheckJs', label: '登录检测 JS', placeholder: '登录状态检测 JS' },
];

@Entry
@Component
export struct RssSourceEditPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State sourceUrl: string = '';
  @State editSource: RSSSource = this.defaultSource();
  @State isNew: boolean = true;
  @State currentTab: number = 0;
  @State isSaving: boolean = false;

  private db: AppDatabase = AppDatabase.getInstance();

  private tabs: string[] = ['基本信息', '列表规则', '内容规则', 'WebView'];

  defaultSource(): RSSSource {
    return {
      sourceUrl: '',
      sourceName: '',
      sourceIcon: '',
      sourceGroup: '',
      sourceComment: null,
      enabled: true,
      variableComment: null,
      jsLib: null,
      enabledCookieJar: true,
      concurrentRate: null,
      header: null,
      loginUrl: null,
      loginUi: null,
      loginCheckJs: null,
      coverDecodeJs: null,
      sortUrl: null,
      singleUrl: false,
      articleStyle: 0,
      ruleArticles: '',
      ruleNextPage: '',
      ruleTitle: '',
      rulePubDate: '',
      ruleDescription: '',
      ruleImage: '',
      ruleLink: '',
      ruleContent: '',
      contentWhitelist: null,
      contentBlacklist: null,
      shouldOverrideUrlLoading: null,
      style: null,
      enableJs: true,
      loadWithBaseUrl: true,
      injectJs: null,
      preloadJs: null,
      startHtml: null,
      startStyle: null,
      startJs: null,
      showWebLog: false,
      lastUpdateTime: Date.now(),
      customOrder: 0,
      type: 0,
      preload: false,
      cacheFirst: false,
      searchUrl: null,
      redirectPolicy: 'ASK_CROSS_ORIGIN',
    };
  }

  aboutToAppear() {
    const params = router.getParams() as Record<string, string>;
    if (params && params['sourceUrl']) {
      this.sourceUrl = params['sourceUrl'];
      this.isNew = false;
      this.loadSource();
    }
  }

  async loadSource() {
    try {
      await this.db.waitForInit();
      const s = await this.db.rssSourceTable.getByKey(this.sourceUrl);
      if (s) {
        // 深拷贝
        this.editSource = JSON.parse(JSON.stringify(s));
      }
    } catch (e) {
      console.error('[RssSourceEditPage] 加载源失败: ' + e);
    }
  }

  setField(key: string, value: string | boolean | number) {
    // 使用 JSON 深拷贝后修改
    const copy = JSON.parse(JSON.stringify(this.editSource)) as RSSSource;
    copy[key] = value;
    this.editSource = copy;
  }

  async save() {
    if (!this.editSource.sourceName || !this.editSource.sourceUrl) {
      promptAction.showToast({ message: '名称和源 URL 不能为空' });
      return;
    }
    this.isSaving = true;
    try {
      this.editSource.lastUpdateTime = Date.now();
      const exists = await this.db.rssSourceTable.has(this.editSource.sourceUrl);
      if (exists) {
        await this.db.rssSourceTable.update(this.editSource);
      } else {
        await this.db.rssSourceTable.insert(this.editSource);
      }
      promptAction.showToast({ message: '保存成功' });
      router.back();
    } catch (e) {
      promptAction.showToast({ message: `保存失败: ${e}` });
    } finally {
      this.isSaving = false;
    }
  }

  async testFetch() {
    promptAction.showToast({ message: '正在测试...' });
    try {
      const RssService = await import('../engine/rss/RssService');
      const result = await RssService.fetchArticles('测试', this.editSource.sortUrl || this.editSource.sourceUrl, this.editSource, 1, null);
      const articles = result[0] as Object[];
      promptAction.showToast({ message: '成功获取 ' + articles.length + ' 篇文章' });
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      promptAction.showToast({ message: '获取失败: ' + msg });
    }
  }

  getFieldValue(key: string): string {
    const s = JSON.parse(JSON.stringify(this.editSource)) as Record<string, Object>;
    return String(s[key] || '');
  }

  @Builder
  buildFieldInputs(fields: FieldGroup[]) {
    Column() {
      ForEach(fields, (field: FieldGroup) => {
        Text(field.label).fontSize(13).fontColor(this.isDark ? '#CCC' : '#666')
          .margin({ top: 12, bottom: 4 })
        TextInput({ placeholder: field.placeholder, text: this.getFieldValue(field.key) })
          .onChange((val) => this.setField(field.key, val))
          .width('100%')
      })
    }
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor('#0078D7')
          .onClick(() => router.back())
        Text(this.isNew ? '新建 RSS 源' : '编辑 RSS 源')
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A1A')
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('测试').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.testFetch())
        Button({ type: ButtonType.Normal }) {
          Text(this.isSaving ? '保存中...' : '保存').fontSize(14)
            .fontColor('#0078D7').fontWeight(FontWeight.Bold)
        }
        .backgroundColor('transparent')
        .enabled(!this.isSaving)
        .onClick(() => this.save())
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== Tab 栏 =====
      Scroll() {
        Row() {
          ForEach(this.tabs, (tab: string, idx: number) => {
            Column() {
              Text(tab).fontSize(14)
                .fontColor(this.currentTab === idx ? '#0078D7' : (this.isDark ? '#AAA' : '#666'))
                .fontWeight(this.currentTab === idx ? FontWeight.Bold : FontWeight.Normal)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              if (this.currentTab === idx) {
                Divider().color('#0078D7').width('80%').height(2).borderRadius(1)
              }
            }
            .onClick(() => { this.currentTab = idx; })
          })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%').height(40)

      // ===== 编辑内容 =====
      Scroll() {
        Column() {
          if (this.currentTab === 0) {
            this.buildFieldInputs(TAB_BASIC)
            // articleStyle 选择
            Text('文章列表样式').fontSize(13).fontColor(this.isDark ? '#CCC' : '#666')
              .margin({ top: 12, bottom: 4 })
            Row() {
              ForEach(['列表', '大卡片', '网格', '瀑布流'], (label: string, idx: number) => {
                Column() {
                  Text(label).fontSize(12)
                    .fontColor(this.editSource.articleStyle === idx ? '#0078D7' : (this.isDark ? '#AAA' : '#666'))
                    .padding(8)
                    .border({ radius: 4, width: 1, color: this.editSource.articleStyle === idx ? '#0078D7' : '#CCC' })
                }
                .onClick(() => { this.setField('articleStyle', idx); })
              })
            }
            .width('100%').justifyContent(FlexAlign.SpaceEvenly).margin({ top: 4 })

            // 开启选项
            Row() {
              Text('启用').fontSize(14).fontColor(this.isDark ? '#CCC' : '#666')
              Toggle({ type: ToggleType.Switch, isOn: this.editSource.enabled })
                .onChange((val) => this.setField('enabled', val))
            }
            .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 16 })
          } else if (this.currentTab === 1) {
            this.buildFieldInputs(TAB_LIST_RULES)
          } else if (this.currentTab === 2) {
            this.buildFieldInputs(TAB_CONTENT_RULES)
          } else if (this.currentTab === 3) {
            this.buildFieldInputs(TAB_WEBVIEW)
            // WebView 选项
            Column() {
              Row() {
                Text('启用 JS').fontSize(14).fontColor(this.isDark ? '#CCC' : '#666')
                Toggle({ type: ToggleType.Switch, isOn: this.editSource.enableJs })
                  .onChange((val) => this.setField('enableJs', val))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 12 })

              Row() {
                Text('使用 Base URL 加载').fontSize(14).fontColor(this.isDark ? '#CCC' : '#666')
                Toggle({ type: ToggleType.Switch, isOn: this.editSource.loadWithBaseUrl })
                  .onChange((val) => this.setField('loadWithBaseUrl', val))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 12 })

              Row() {
                Text('预加载').fontSize(14).fontColor(this.isDark ? '#CCC' : '#666')
                Toggle({ type: ToggleType.Switch, isOn: this.editSource.preload })
                  .onChange((val) => this.setField('preload', val))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 12 })

              Row() {
                Text('优先使用缓存').fontSize(14).fontColor(this.isDark ? '#CCC' : '#666')
                Toggle({ type: ToggleType.Switch, isOn: this.editSource.cacheFirst })
                  .onChange((val) => this.setField('cacheFirst', val))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 12 })
            }
          }
        }
        .width('100%').padding(16)
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
