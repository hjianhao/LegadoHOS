/**
 * 书源编辑页面
 * 参照 legado-with-MD3 BookSourceEditActivity 实现
 *
 * 功能：
 * - 5 Tab 分组编辑所有书源字段
 * - 加载/保存到数据库
 * - 新建或编辑已有书源
 */
import { BookSource } from '../model/BookSource';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

interface FieldGroup {
  key: string;
  label: string;
  placeholder: ResourceStr;
}

const TAB_BASIC: FieldGroup[] = [
  { key: 'sourceName', label: '书源名称', placeholder: $r('app.string.ui_aa5499a758') },
  { key: 'sourceUrl', label: '书源 URL', placeholder: $r('app.string.ui_327c3fda87') },
  { key: 'sourceType', label: '书源类型', placeholder: $r('app.string.ui_ac1424ddd8') },
  { key: 'enabled', label: '启用书源', placeholder: $r('app.string.ui_6db4e26e48') },
  { key: 'group', label: '分组', placeholder: $r('app.string.ui_bce3df74e6') },
  { key: 'bookUrlPattern', label: '书 URL 正则', placeholder: $r('app.string.ui_114e089a41') },
  { key: 'bookSourceComment', label: '注释', placeholder: $r('app.string.ui_ef950bf450') },
  { key: 'variableComment', label: '变量说明', placeholder: $r('app.string.ui_073bef33f6') },
  { key: 'header', label: 'HTTP 头', placeholder: $r('app.string.ui_7877ebb0b5') },
  { key: 'loginUrl', label: '登录 URL', placeholder: $r('app.string.ui_e7395dbc96') },
  { key: 'loginCheckJs', label: '登录检测 JS', placeholder: $r('app.string.ui_5fac32676a') },
  { key: 'coverDecodeJs', label: '封面解密 JS', placeholder: $r('app.string.ui_b685e2d33d') },
  { key: 'weight', label: '权重', placeholder: $r('app.string.ui_9458b775c5') },
  { key: 'respondTime', label: '响应超时 (ms)', placeholder: $r('app.string.ui_1c822c4b5c') },
  { key: 'concurrentRate', label: '并发率', placeholder: $r('app.string.ui_5b636f79d2') },
  { key: 'jsLib', label: 'JS 库', placeholder: $r('app.string.ui_6b0a3df4f1') },
];

const TAB_SEARCH: FieldGroup[] = [
  { key: 'ruleSearchUrl', label: '搜索 URL', placeholder: $r('app.string.ui_bc111be397') },
  { key: 'ruleSearchList', label: '搜索列表规则', placeholder: $r('app.string.ui_7e0493b05c') },
  { key: 'ruleSearchName', label: '书名规则', placeholder: '' },
  { key: 'ruleSearchAuthor', label: '作者规则', placeholder: '' },
  { key: 'ruleSearchCover', label: '封面规则', placeholder: '' },
  { key: 'ruleSearchNoteUrl', label: '详情 URL 规则', placeholder: '' },
  { key: 'ruleSearchKind', label: '分类规则', placeholder: '' },
  { key: 'ruleSearchWordCount', label: '字数规则', placeholder: '' },
  { key: 'ruleSearchLastUpdateTime', label: '最后更新时间规则', placeholder: '' },
  { key: 'ruleSearchIntroduce', label: '简介规则', placeholder: '' },
];

const TAB_BOOKINFO_TOC: FieldGroup[] = [
  // 详情规则
  { key: 'ruleBookInfoInit', label: '【详情】初始化 JS', placeholder: $r('app.string.ui_33d7a0c1b0') },
  { key: 'ruleBookInfoName', label: '书名规则', placeholder: '' },
  { key: 'ruleBookInfoAuthor', label: '作者规则', placeholder: '' },
  { key: 'ruleBookInfoCover', label: '封面规则', placeholder: '' },
  { key: 'ruleBookInfoIntroduce', label: '简介规则', placeholder: '' },
  { key: 'ruleBookInfoKind', label: '分类规则', placeholder: '' },
  { key: 'ruleBookInfoWordCount', label: '字数规则', placeholder: '' },
  { key: 'ruleBookInfoLastUpdateTime', label: '最后更新时间规则', placeholder: '' },
  { key: 'ruleBookInfoLastChapter', label: '最新章节规则', placeholder: '' },
  { key: 'ruleBookInfoTocUrl', label: '目录 URL 规则', placeholder: '' },
  { key: 'ruleBookInfoCanReName', label: '能否重命名', placeholder: $r('app.string.ui_6db4e26e48') },
  { key: 'ruleBookInfoDownloadUrls', label: '下载 URL 规则', placeholder: '' },
  { key: 'ruleBookInfoRelatedBooks', label: '相关书籍规则', placeholder: '' },
  // 目录规则
  { key: 'ruleTocUrl', label: '【目录】URL 规则', placeholder: $r('app.string.ui_2a703199b1') },
  { key: 'ruleToc', label: '目录列表规则', placeholder: $r('app.string.ui_7e0493b05c') },
  { key: 'ruleTocTitle', label: '章节名规则', placeholder: '' },
  { key: 'ruleTocUrlItem', label: '章节 URL 规则', placeholder: '' },
  { key: 'ruleTocPreUpdateJs', label: '预处理 JS', placeholder: '' },
  { key: 'ruleTocFormatJs', label: '格式化 JS', placeholder: '' },
  { key: 'ruleTocIsVolume', label: '是否卷', placeholder: '' },
  { key: 'ruleTocIsVip', label: '是否 VIP', placeholder: '' },
  { key: 'ruleTocIsPay', label: '是否付费', placeholder: '' },
  { key: 'ruleTocUpdateTime', label: '更新时间规则', placeholder: '' },
  { key: 'ruleTocNextTocUrl', label: '下一页目录 URL', placeholder: '' },
];

const TAB_CONTENT_EXPLORE: FieldGroup[] = [
  // 正文规则
  { key: 'ruleBookContentUrl', label: '【正文】URL 规则', placeholder: '' },
  { key: 'ruleBookContent', label: '内容规则', placeholder: $r('app.string.ui_7e0493b05c') },
  { key: 'ruleBookContentSubContent', label: '副内容规则', placeholder: '' },
  { key: 'ruleBookContentTitle', label: '标题规则', placeholder: '' },
  { key: 'ruleBookContentNext', label: '下一页规则', placeholder: '' },
  { key: 'ruleBookContentWebJs', label: 'Web JS', placeholder: '' },
  { key: 'ruleBookContentSourceRegex', label: '源正则', placeholder: $r('app.string.ui_e20c0e0065') },
  { key: 'ruleBookContentReplaceRegex', label: '替换正则', placeholder: $r('app.string.ui_161778d3b5') },
  { key: 'ruleBookContentImageStyle', label: '图片样式', placeholder: '' },
  { key: 'ruleBookContentImageDecode', label: '图片解密', placeholder: '' },
  { key: 'ruleBookContentPayAction', label: '付费操作', placeholder: '' },
  { key: 'ruleBookContentCallBackJs', label: '回调 JS', placeholder: '' },
  // 发现规则
  { key: 'exploreUrl', label: '【发现】发现 URL', placeholder: $r('app.string.ui_9f32ff3eed') },
  { key: 'ruleExplores', label: '发现分类规则', placeholder: $r('app.string.ui_4fc8d91101') },
  { key: 'ruleExploreList', label: '发现列表规则', placeholder: '' },
  { key: 'ruleExploreName', label: '发现书名规则', placeholder: '' },
  { key: 'ruleExploreAuthor', label: '发现作者规则', placeholder: '' },
  { key: 'ruleExploreCover', label: '发现封面规则', placeholder: '' },
  { key: 'ruleExploreNoteUrl', label: '发现详情 URL 规则', placeholder: '' },
  { key: 'ruleExploreKind', label: '发现分类规则', placeholder: '' },
  { key: 'ruleExploreWordCount', label: '发现字数规则', placeholder: '' },
  { key: 'ruleExploreLastUpdateTime', label: '发现更新时间规则', placeholder: '' },
  { key: 'ruleExploreIntroduce', label: '发现简介规则', placeholder: '' },
];

const TAB_ADVANCED: FieldGroup[] = [
  { key: 'script', label: '脚本', placeholder: $r('app.string.ui_c1a33f3ea5') },
  { key: 'loginUi', label: '登录 UI', placeholder: $r('app.string.ui_bfd7a18e56') },
  { key: 'eventListener', label: '事件监听', placeholder: $r('app.string.ui_554d61a111') },
  { key: 'customButton', label: '自定义按钮', placeholder: $r('app.string.ui_554d61a111') },
  { key: 'homepageModules', label: '首页模块', placeholder: $r('app.string.ui_554d61a111') },
  { key: 'enabledCookieJar', label: '启用 Cookie', placeholder: $r('app.string.ui_6db4e26e48') },
  { key: 'enabledExplore', label: '启用发现', placeholder: $r('app.string.ui_6db4e26e48') },
  { key: 'exploreScreen', label: '发现屏幕', placeholder: '' },
  { key: 'review', label: '评论规则', placeholder: $r('app.string.ui_9faba6fa67') },
  { key: 'reviewUrl', label: '评论 URL 规则', placeholder: '' },
  { key: 'reviewAvatar', label: '评论头像规则', placeholder: '' },
  { key: 'reviewContent', label: '评论内容规则', placeholder: '' },
  { key: 'reviewPostTime', label: '评论时间规则', placeholder: '' },
  { key: 'reviewQuoteUrl', label: '评论引用 URL 规则', placeholder: '' },
];

const TAB_LABELS: string[] = ['基本信息', '搜索', '详情/目录', '正文/发现', '高级'];

@Entry
@Component
struct BookSourceEditPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State editSource: BookSource | null = null;
  @State currentTab: number = 0;
  @State isLoading: boolean = true;
  @State isNew: boolean = false;
  @State sourceUrl: string = '';
  @State loadVersion: number = 0;   // 递增强制 TextInput 重建
  @State isDirty: boolean = false;
  @State isSaving: boolean = false;

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    const url: string = params ? (params['url'] || params['sourceUrl'] || '') : '';
    this.sourceUrl = url;
    console.info('[SrcEdit] opening, url param:', url);
    this.loadSource(url);
  }

  async loadSource(url: string): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      if (url) {
        const s = await dao.getSourceByUrl(url);
        if (s) {
          this.editSource = JSON.parse(JSON.stringify(s));
          this.isNew = false;
          this.isDirty = false;
          this.loadVersion++;
          console.info('[SrcEdit] loaded source:', s.sourceName,
            'searchUrl:', s.ruleSearchUrl ? s.ruleSearchUrl.substring(0,40) : 'EMPTY',
            'name:', s.sourceName);
        } else {
          this.newSource();
        }
      } else {
        this.newSource();
      }
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  newSource(): void {
    this.editSource = {
      id: 0,
      sourceName: '',
      sourceUrl: '',
      sourceType: 0,
      group: '',
      enabled: true,
      weight: 0,
      customOrder: 0,
      // 搜索规则
      ruleSearchUrl: '',
      ruleSearchList: '',
      ruleSearchName: '',
      ruleSearchAuthor: '',
      ruleSearchCover: '',
      ruleSearchNoteUrl: '',
      ruleSearchKind: '',
      ruleSearchWordCount: '',
      ruleSearchLastUpdateTime: '',
      ruleSearchIntroduce: '',
      // 详情规则
      ruleBookInfoInit: '',
      ruleBookInfoName: '',
      ruleBookInfoAuthor: '',
      ruleBookInfoCover: '',
      ruleBookInfoIntroduce: '',
      ruleBookInfoKind: '',
      ruleBookInfoWordCount: '',
      ruleBookInfoLastUpdateTime: '',
      ruleBookInfoLastChapter: '',
      ruleBookInfoTocUrl: '',
      ruleBookInfoCanReName: '',
      ruleBookInfoDownloadUrls: '',
      ruleBookInfoRelatedBooks: '',
      // 目录规则
      ruleTocUrl: '',
      ruleToc: '',
      ruleTocTitle: '',
      ruleTocUrlItem: '',
      ruleTocPreUpdateJs: '',
      ruleTocFormatJs: '',
      ruleTocIsVolume: '',
      ruleTocIsVip: '',
      ruleTocIsPay: '',
      ruleTocUpdateTime: '',
      ruleTocNextTocUrl: '',
      // 正文规则
      ruleBookContentUrl: '',
      ruleBookContent: '',
      ruleBookContentSubContent: '',
      ruleBookContentTitle: '',
      ruleBookContentNext: '',
      ruleBookContentWebJs: '',
      ruleBookContentSourceRegex: '',
      ruleBookContentReplaceRegex: '',
      ruleBookContentImageStyle: '',
      ruleBookContentImageDecode: '',
      ruleBookContentPayAction: '',
      ruleBookContentCallBackJs: '',
      // 发现规则
      ruleExplores: '',
      ruleExploreList: '',
      ruleExploreName: '',
      ruleExploreAuthor: '',
      ruleExploreCover: '',
      ruleExploreNoteUrl: '',
      ruleExploreKind: '',
      ruleExploreWordCount: '',
      ruleExploreLastUpdateTime: '',
      ruleExploreIntroduce: '',
      ruleExploreLastChapter: '',
      // 评论规则
      ruleReview: '',
      ruleReviewUrl: '',
      ruleReviewAvatar: '',
      ruleReviewContent: '',
      ruleReviewPostTime: '',
      ruleReviewQuoteUrl: '',
      // 顶层配置
      script: '',
      jsLib: '',
      bookUrlPattern: '',
      enabledCookieJar: true,
      enabledExplore: true,
      concurrentRate: '',
      header: '',
      loginUrl: '',
      loginUi: '',
      loginCheckJs: '',
      coverDecodeJs: '',
      bookSourceComment: '',
      variableComment: '',
      respondTime: 180000,
      exploreUrl: '',
      exploreScreen: '',
      eventListener: false,
      customButton: false,
      homepageModules: '',
      ruleBookInfoFrom: '',
      ruleSearchCheckKeyWord: '',
      ruleSearchLastChapter: '',
      respond: 0,
      reviewUrl: '',
      ruleExploreScreen: '',
      review: '',
      reviewAvatar: '',
      reviewContent: '',
      reviewPostTime: '',
      reviewQuoteUrl: '',
      // 时间
      createTime: Date.now(),
      updateTime: Date.now(),
      rawJson: '',
      isAiGenerated: false,
    };
    this.isNew = true;
    this.isDirty = false;
  }

	  getFieldValue(key: string): string {
	    if (!this.editSource) return '';
	    const src = this.editSource as object;
	    const v = (src as Record<string, string | number | boolean>)[key];
	    if (v === undefined || v === null) return '';
	    if (typeof v === 'boolean') return v ? 'true' : 'false';
	    if (typeof v === 'number') return String(v);
	    return String(v);
	  }

	  setField(key: string, value: string): void {
	    if (!this.editSource) return;
	    const copy: Record<string, string | number | boolean> = JSON.parse(JSON.stringify(this.editSource));
    // 根据字段名推断类型
    if (value === 'true' || value === 'false') {
      copy[key] = value === 'true';
    } else if (value === '' || value === undefined || value === null) {
      if (key === 'enabled' || key === 'enabledCookieJar' || key === 'enabledExplore') {
        copy[key] = false;
      } else if (key === 'weight' || key === 'respondTime' || key === 'customOrder') {
        copy[key] = 0;
      } else {
        copy[key] = '';
      }
    } else if (!isNaN(Number(value)) && key.endsWith('ime') === false && key !== 'sourceName') {
      // 只有数字类型的字段才转 number
      const numFields: string[] = ['weight', 'respondTime', 'customOrder', 'concurrentRate', 'sourceType'];
      if (numFields.indexOf(key) >= 0) {
        copy[key] = Number(value);
      } else {
        copy[key] = value;
      }
    } else {
      copy[key] = value;
    }
	    this.editSource = JSON.parse(JSON.stringify(copy));
    this.isDirty = true;
  }

  async saveSource(): Promise<void> {
    if (!this.editSource) return;
    if (!this.editSource.sourceName || !this.editSource.sourceUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '书源名称和 URL 不能为空', duration: 1500 });
      return;
    }
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const source = this.editSource;
      source.updateTime = Date.now();
      this.isSaving = true;
      if (this.isNew || source.id === 0) {
        await dao.insertSource(source);
        UiUtil.showToast(this.getUIContext(), { message: '已创建新书源', duration: 1500 });
      } else {
        await dao.updateSource(source);
        UiUtil.showToast(this.getUIContext(), { message: '已保存', duration: 1500 });
      }
      this.isDirty = false;
      UiUtil.back(this.getUIContext());
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '保存失败', duration: 2000 });
    } finally {
      this.isSaving = false;
    }
  }

  private cancelEdit(): void {
    if (!this.isDirty) {
      UiUtil.back(this.getUIContext());
      return;
    }
    UiUtil.showDialog(this.getUIContext(), {
      title: '放弃修改？',
      message: '尚未保存的书源规则将会丢失。',
      buttons: [
        { text: '继续编辑', color: ThemeColors.secondaryText(this.isDark) },
        { text: '放弃', color: ThemeColors.error(this.isDark) }
      ]
    }).then((result) => {
      if (result.index === 1) UiUtil.back(this.getUIContext());
    });
  }

  private openSearchTest(): void {
    if (!this.editSource || !this.editSource.sourceUrl) return;
    const scope = '{"type":"source","sources":[{"name":' +
      JSON.stringify(this.editSource.sourceName) + ',"url":' +
      JSON.stringify(this.editSource.sourceUrl) + '}]}';
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/SearchPage', params: { searchScope: scope }
    });
  }

  private openDebug(): void {
    if (!this.editSource || !this.editSource.sourceUrl) return;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/BookSourceDebugPage', params: { sourceUrl: this.editSource.sourceUrl }
    });
  }

  private isBooleanField(key: string): boolean {
    return ['enabled', 'enabledCookieJar', 'enabledExplore', 'eventListener', 'customButton'].includes(key);
  }

  private isMultilineField(key: string): boolean {
    return key.includes('Js') || key.includes('script') || key === 'header' || key === 'loginUi'
      || key === 'homepageModules' || key === 'bookSourceComment' || key === 'variableComment'
      || key === 'ruleExplores' || key.includes('Regex') || key.includes('Content');
  }

  deleteField(key: string): void {
    this.setField(key, '');
  }

  @Builder
  buildFieldInputs(fields: FieldGroup[]) {
    Column() {
      ForEach(fields, (field: FieldGroup) => {
        Column() {
          Row() {
            Text(field.label).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
              .layoutWeight(1)
            Button() { Text($r('app.string.ui_0951b9a022')).fontSize(10).fontColor(ThemeColors.error(this.isDark)) }
              .width(40).height(40).backgroundColor(ThemeColors.transparent())
              .accessibilityText($r('app.string.common_close')).onClick(() => { this.deleteField(field.key); })
          }.width('100%')
          if (this.isBooleanField(field.key)) {
            Row() {
              Text(this.getFieldValue(field.key) === 'true' ? '已启用' : '已停用')
                .fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.getFieldValue(field.key) === 'true' })
                .onChange((value: boolean) => { this.setField(field.key, value ? 'true' : 'false'); })
            }.height(48).width('100%').padding({ left: 12, right: 8 })
              .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
          } else if (this.isMultilineField(field.key)) {
            TextArea({ placeholder: field.placeholder, text: this.getFieldValue(field.key) })
              .height(112).fontSize(14).borderRadius(12).width('100%').margin({ top: 4 })
              .padding(12).backgroundColor(ThemeColors.surface(this.isDark))
              .fontColor(ThemeColors.onSurface(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .onChange((v: string) => { this.setField(field.key, v); })
          } else {
            TextInput({ placeholder: field.placeholder, text: this.getFieldValue(field.key) })
              .height(48).fontSize(14).borderRadius(12).width('100%').margin({ top: 4 })
              .padding({ left: 12, right: 12 }).backgroundColor(ThemeColors.surface(this.isDark))
              .fontColor(ThemeColors.onSurface(this.isDark))
              .onChange((v: string) => { this.setField(field.key, v); })
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
          }
        }
        .width('100%').margin({ top: 8 })
      }, (field: FieldGroup): string => field.key + '_v' + this.loadVersion.toString())
    }.width('100%').padding({ left: 16, right: 16 })
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Button($r('app.string.ui_0dccf90917')).fontSize(26).width(40).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.onBackground(this.isDark)).onClick(() => { this.cancelEdit(); })
        Text(this.isNew ? '新建书源' : '编辑书源').fontColor(ThemeColors.onSurface(this.isDark)).fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
        if (!this.isNew) {
          Button($r('app.string.ui_0b5d7ed54b')).fontSize(13).height(40).backgroundColor(ThemeColors.transparent())
            .fontColor(ThemeColors.primary(this.isDark)).onClick(() => { this.openSearchTest(); })
          Button($r('app.string.ui_f4c117afe8')).fontSize(13).height(40).backgroundColor(ThemeColors.transparent())
            .fontColor(ThemeColors.primary(this.isDark)).onClick(() => { this.openDebug(); })
        }
        Button(this.isSaving ? '保存中' : '保存').fontSize(14).height(40)
          .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
          .borderRadius(20).padding({ left: 16, right: 16 }).margin({ left: 4 })
          .onClick(() => { this.saveSource(); })
          .enabled(!this.isSaving)
      }.padding({ left: 8, right: 12, top: 8, bottom: 4 }).width('100%').height(56)

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 100 })
        Text($r('app.string.common_loading')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          .width('100%').textAlign(TextAlign.Center)
      } else if (this.editSource) {
        // ===== Tab 栏 =====
        Scroll() {
          Row() {
            ForEach(TAB_LABELS, (label: string, idx: number) => {
              Column() {
                Text(label).fontSize(13)
                  .fontColor(this.currentTab === idx ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
                  .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Regular)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                if (this.currentTab === idx) {
                  Row().width('80%').height(2).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(1)
                }
              }
              .onClick(() => { this.currentTab = idx; })
            })
          }.width('100%')
        }
        .width('100%').height(40).scrollBar(BarState.Off)

        Divider().height(1).color(ThemeColors.outlineVariant(this.isDark)).width('100%')

        // ===== Tab 内容 =====
        Scroll() {
          if (this.currentTab === 0) {
            this.buildFieldInputs(TAB_BASIC)
          } else if (this.currentTab === 1) {
            this.buildFieldInputs(TAB_SEARCH)
          } else if (this.currentTab === 2) {
            this.buildFieldInputs(TAB_BOOKINFO_TOC)
          } else if (this.currentTab === 3) {
            this.buildFieldInputs(TAB_CONTENT_EXPLORE)
          } else if (this.currentTab === 4) {
            this.buildFieldInputs(TAB_ADVANCED)
          }
        }
        .width('100%').layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
