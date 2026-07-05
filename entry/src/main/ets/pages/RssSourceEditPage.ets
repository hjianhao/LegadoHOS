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
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

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
  { key: 'rulePubDate', label: '日期规则', placeholder: '文章发布日期规则' },
  { key: 'ruleDescription', label: '摘要规则', placeholder: '文章摘要提取规则' },
  { key: 'ruleImage', label: '图片规则', placeholder: '文章图片提取规则' },
  { key: 'ruleLink', label: '链接规则', placeholder: '文章链接提取规则' },
  { key: 'ruleNextPage', label: '下一页规则', placeholder: '分页规则' },
];

const TAB_CONTENT_RULES: FieldGroup[] = [
  { key: 'ruleContent', label: '正文规则', placeholder: '文章正文提取规则' },
  { key: 'contentWhitelist', label: '标签白名单', placeholder: '允许的 HTML 标签' },
  { key: 'contentBlacklist', label: '标签黑名单', placeholder: '禁用的 HTML 标签' },
];

const TAB_WEBVIEW: FieldGroup[] = [
  { key: 'style', label: '自定义样式(CSS)', placeholder: '注入的 CSS 样式' },
  { key: 'injectJs', label: '注入 JS', placeholder: '页面加载后注入的 JS' },
  { key: 'preloadJs', label: '预载 JS', placeholder: '页面加载前执行的 JS' },
  { key: 'startHtml', label: '自定义 HTML', placeholder: '替换页面的 HTML 模板' },
  { key: 'startStyle', label: '自定义内部 CSS', placeholder: '嵌入 HTML 的 style 标签内容' },
  { key: 'startJs', label: '自定义内部 JS', placeholder: '嵌入 HTML 的 script 标签内容' },
];

@Entry
@Component
struct RssSourceEditPage {
  @StorageProp('isDark') isDark: boolean = false;
  @State currentTab: number = 0;
  @State editSource: RSSSource = this.createDefault();
  @State isSaving: boolean = false;
  private sourceUrl: string = '';
  private isNew: boolean = true;
  private tabs: string[] = ['基本信息', '列表规则', '内容规则', 'WebView'];
  private db: AppDatabase = AppDatabase.getInstance();

  createDefault(): RSSSource {
    return {
      sourceUrl: '',
      sourceName: '',
      sourceIcon: '',
      sourceGroup: '',
      sourceComment: '',
      enabled: true,
      variableComment: '',
      jsLib: '',
      enabledCookieJar: false,
      concurrentRate: '',
      header: '',
      loginUrl: '',
      loginUi: '',
      loginCheckJs: '',
      coverDecodeJs: '',
      sortUrl: '',
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
      contentWhitelist: '',
      contentBlacklist: '',
      shouldOverrideUrlLoading: '',
      style: '',
      enableJs: true,
      loadWithBaseUrl: true,
      injectJs: '',
      preloadJs: '',
      startHtml: '',
      startStyle: '',
      startJs: '',
      showWebLog: false,
      lastUpdateTime: Date.now(),
      customOrder: 0,
      type: 0,
      preload: false,
      cacheFirst: false,
      searchUrl: '',
      redirectPolicy: 'ASK_CROSS_ORIGIN',
    };
  }

  aboutToAppear() {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
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
        this.editSource = JSON.parse(JSON.stringify(s));
      }
    } catch (e) {
      console.error('[RssSourceEditPage] load failed: ' + e);
    }
  }

  async save() {
    if (!this.editSource.sourceName || !this.editSource.sourceUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '名称和源 URL 不能为空' });
      return;
    }
    // 去除 URL 中的 # 片段（可能由导入时带入）
    const hashIdx = this.editSource.sourceUrl.indexOf('#');
    if (hashIdx > 0) {
      this.editSource.sourceUrl = this.editSource.sourceUrl.substring(0, hashIdx);
    }
    this.isSaving = true;
    try {
      this.editSource.lastUpdateTime = Date.now();
      try {
        await this.db.rssSourceTable.insert(this.editSource);
      } catch (_e) {
        await this.db.rssSourceTable.update(this.editSource);
      }
      UiUtil.showToast(this.getUIContext(), { message: '保存成功' });
      UiUtil.back(this.getUIContext());
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '保存失败' });
    } finally {
      this.isSaving = false;
    }
  }

  getFieldsForTab(): FieldGroup[] {
    switch (this.currentTab) {
      case 0: return TAB_BASIC;
      case 1: return TAB_LIST_RULES;
      case 2: return TAB_CONTENT_RULES;
      case 3: return TAB_WEBVIEW;
      default: return TAB_BASIC;
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('← 返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent')
        .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text(this.isNew ? '添加 RSS 源' : '编辑 RSS 源').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('保存').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
        }
        .backgroundColor('transparent')
        .onClick(() => { this.save(); })
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // Tab 切换
      Row() {
        ForEach(this.tabs, (tab: string, idx: number) => {
          Text(tab).fontSize(13)
            .fontColor(this.currentTab === idx ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .onClick(() => { this.currentTab = idx; })
        })
      }
      .width('100%').padding({ left: 8, right: 8, bottom: 4 })

      // 表单
      Scroll() {
        Column() {
          ForEach(this.getFieldsForTab(), (field: FieldGroup) => {
            Row() {
              Text(field.label).fontSize(13)
                .fontColor(ThemeColors.secondaryText(this.isDark))
                .width(60)
              TextInput({ text: this.editSource[field.key] as string, placeholder: field.placeholder })
                .fontSize(13)
                .layoutWeight(1)
                .onChange((val: string) => {
                  this.editSource[field.key] = val;
                })
            }
            .width('100%').padding(8).margin({ bottom: 4 })
            .borderRadius(6)
            .backgroundColor(ThemeColors.surface(this.isDark))
          })
        }.width('100%').padding({ left: 8, right: 8 })
      }.layoutWeight(1)
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
