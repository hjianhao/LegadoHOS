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
import { BookSourceTable, setSourceRawJson } from '../data/database/BookSourceTable';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';

interface FieldGroup {
  key: string;
  label: string;
  placeholder: string;
}

const TAB_BASIC: FieldGroup[] = [
  { key: 'sourceName', label: '书源名称', placeholder: '输入书源名称' },
  { key: 'sourceUrl', label: '书源 URL', placeholder: 'https://example.com' },
  { key: 'group', label: '分组', placeholder: '输入分组名' },
  { key: 'bookUrlPattern', label: '书 URL 正则', placeholder: '如 https?://example\\.com/book/\\d+' },
  { key: 'bookSourceComment', label: '注释', placeholder: '可选备注' },
  { key: 'variableComment', label: '变量说明', placeholder: 'JSON格式变量说明' },
  { key: 'header', label: 'HTTP 头', placeholder: '如 {"User-Agent":"..."}' },
  { key: 'loginUrl', label: '登录 URL', placeholder: '登录页面地址' },
  { key: 'loginCheckJs', label: '登录检测 JS', placeholder: '返回 true 表示已登录' },
  { key: 'coverDecodeJs', label: '封面解密 JS', placeholder: '封面 URL 解密脚本' },
  { key: 'weight', label: '权重', placeholder: '数值越大越优先' },
  { key: 'respondTime', label: '响应超时 (ms)', placeholder: '默认 180000' },
  { key: 'concurrentRate', label: '并发率', placeholder: '搜索并发数' },
  { key: 'jsLib', label: 'JS 库', placeholder: '自定义 JS 库代码' },
];

const TAB_SEARCH: FieldGroup[] = [
  { key: 'ruleSearchUrl', label: '搜索 URL', placeholder: '{{key}} 为关键词' },
  { key: 'ruleSearchList', label: '搜索列表规则', placeholder: 'CSS/JSONPath' },
  { key: 'ruleSearchName', label: '书名规则', placeholder: '' },
  { key: 'ruleSearchAuthor', label: '作者规则', placeholder: '' },
  { key: 'ruleSearchCover', label: '封面规则', placeholder: '' },
  { key: 'ruleSearchNoteUrl', label: '详情 URL 规则', placeholder: '' },
  { key: 'ruleSearchKind', label: '分类规则', placeholder: '' },
  { key: 'ruleSearchWordCount', label: '字数规则', placeholder: '' },
  { key: 'ruleSearchLastUpdateTime', label: '最后更新时间规则', placeholder: '' },
  { key: 'ruleSearchIntroduce', label: '简介规则', placeholder: '' },
  { key: 'ruleSearchLastChapter', label: '最新章节规则', placeholder: '' },
  { key: 'ruleSearchCheckKeyWord', label: '校验关键词', placeholder: '搜索测试关键词' },
];

const TAB_BOOKINFO_TOC: FieldGroup[] = [
  // 详情规则
  { key: 'ruleBookInfoInit', label: '【详情】初始化 JS', placeholder: '预处理脚本' },
  { key: 'ruleBookInfoName', label: '书名规则', placeholder: '' },
  { key: 'ruleBookInfoAuthor', label: '作者规则', placeholder: '' },
  { key: 'ruleBookInfoCover', label: '封面规则', placeholder: '' },
  { key: 'ruleBookInfoIntroduce', label: '简介规则', placeholder: '' },
  { key: 'ruleBookInfoKind', label: '分类规则', placeholder: '' },
  { key: 'ruleBookInfoWordCount', label: '字数规则', placeholder: '' },
  { key: 'ruleBookInfoLastUpdateTime', label: '最后更新时间规则', placeholder: '' },
  { key: 'ruleBookInfoLastChapter', label: '最新章节规则', placeholder: '' },
  { key: 'ruleBookInfoTocUrl', label: '目录 URL 规则', placeholder: '' },
  { key: 'ruleBookInfoCanReName', label: '能否重命名', placeholder: 'true/false' },
  { key: 'ruleBookInfoDownloadUrls', label: '下载 URL 规则', placeholder: '' },
  { key: 'ruleBookInfoRelatedBooks', label: '相关书籍规则', placeholder: '' },
  // 目录规则
  { key: 'ruleTocUrl', label: '【目录】URL 规则', placeholder: '目录页 URL' },
  { key: 'ruleToc', label: '目录列表规则', placeholder: 'CSS/JSONPath' },
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
  { key: 'ruleBookContent', label: '内容规则', placeholder: 'CSS/JSONPath' },
  { key: 'ruleBookContentSubContent', label: '副内容规则', placeholder: '' },
  { key: 'ruleBookContentTitle', label: '标题规则', placeholder: '' },
  { key: 'ruleBookContentNext', label: '下一页规则', placeholder: '' },
  { key: 'ruleBookContentWebJs', label: 'Web JS', placeholder: '' },
  { key: 'ruleBookContentSourceRegex', label: '源正则', placeholder: '替换前的正则' },
  { key: 'ruleBookContentReplaceRegex', label: '替换正则', placeholder: '替换后的内容' },
  { key: 'ruleBookContentImageStyle', label: '图片样式', placeholder: '' },
  { key: 'ruleBookContentImageDecode', label: '图片解密', placeholder: '' },
  { key: 'ruleBookContentPayAction', label: '付费操作', placeholder: '' },
  { key: 'ruleBookContentCallBackJs', label: '回调 JS', placeholder: '' },
  // 发现规则
  { key: 'exploreUrl', label: '【发现】发现 URL', placeholder: '发现页地址' },
  { key: 'ruleExplores', label: '发现分类规则', placeholder: 'JSON 数组或键值对' },
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
  { key: 'script', label: '脚本', placeholder: '书源脚本代码' },
  { key: 'loginUi', label: '登录 UI', placeholder: 'JSON 格式登录界面' },
  { key: 'eventListener', label: '事件监听', placeholder: 'JSON 格式' },
  { key: 'customButton', label: '自定义按钮', placeholder: 'JSON 格式' },
  { key: 'homepageModules', label: '首页模块', placeholder: 'JSON 格式' },
  { key: 'enabledCookieJar', label: '启用 Cookie', placeholder: 'true/false' },
  { key: 'enabledExplore', label: '启用发现', placeholder: 'true/false' },
  { key: 'exploreScreen', label: '发现屏幕', placeholder: '' },
  { key: 'review', label: '评论规则', placeholder: '评论列表规则' },
  { key: 'reviewUrl', label: '评论 URL 规则', placeholder: '' },
  { key: 'reviewAvatar', label: '评论头像规则', placeholder: '' },
  { key: 'reviewContent', label: '评论内容规则', placeholder: '' },
  { key: 'reviewPostTime', label: '评论时间规则', placeholder: '' },
  { key: 'reviewQuoteUrl', label: '评论引用 URL 规则', placeholder: '' },
];

const TAB_LABELS: string[] = ['基本信息', '搜索', '详情/目录', '正文/发现', '高级'];

@Entry
@Component
export struct BookSourceEditPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State editSource: BookSource | null = null;
  @State currentTab: number = 0;
  @State isLoading: boolean = true;
  @State isNew: boolean = false;
  @State sourceUrl: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    const url: string = params ? (params['sourceUrl'] || '') : '';
    this.sourceUrl = url;
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
      ruleSearchLastChapter: '',
      ruleSearchCheckKeyWord: '',
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
      // 时间
      createTime: Date.now(),
      updateTime: Date.now(),
      rawJson: '',
    };
    this.isNew = true;
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
  }

  async saveSource(): Promise<void> {
    if (!this.editSource) return;
    if (!this.editSource.sourceName || !this.editSource.sourceUrl) {
      promptAction.showToast({ message: '书源名称和 URL 不能为空', duration: 1500 });
      return;
    }
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const source = this.editSource;
      source.updateTime = Date.now();
      setSourceRawJson(source, '');
      if (this.isNew || source.id === 0) {
        await dao.insertSource(source);
        promptAction.showToast({ message: '已创建新书源', duration: 1500 });
      } else {
        await dao.updateSource(source);
        promptAction.showToast({ message: '已保存', duration: 1500 });
      }
      router.back();
    } catch (_e) {
      promptAction.showToast({ message: '保存失败', duration: 2000 });
    }
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
            Text(field.label).fontSize(13).fontColor(this.isDark ? '#CCC' : '#666')
              .layoutWeight(1)
            Button() { Text('✕').fontSize(10).fontColor('#F44336') }
              .width(20).height(20).backgroundColor('transparent')
              .onClick(() => { this.deleteField(field.key); })
          }.width('100%')
          TextInput({
            placeholder: field.placeholder,
            text: this.getFieldValue(field.key)
          })
            .height(36).fontSize(14).borderRadius(4).width('100%').margin({ top: 2 })
            .padding({ left: 8 })
            .onChange((v: string) => { this.setField(field.key, v); })
            .placeholderColor('#999')
        }
        .width('100%').margin({ top: 8 })
      })
    }.width('100%').padding({ left: 16, right: 16 })
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text(this.isNew ? '新建书源' : '编辑书源').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('取消').fontSize(14).height(32).backgroundColor('transparent').fontColor('#888')
          .onClick(() => { router.back(); })
        Button('保存').fontSize(14).height(32).backgroundColor('#0078D7').fontColor('#FFF')
          .borderRadius(4).padding({ left: 10, right: 10 }).margin({ left: 6 })
          .onClick(() => { this.saveSource(); })
      }.padding({ left: 16, right: 16, top: 12 }).width('100%')

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
        Text('加载中...').fontSize(14).fontColor('#888').margin({ top: 8 })
          .width('100%').textAlign(TextAlign.Center)
      } else if (this.editSource) {
        // ===== Tab 栏 =====
        Scroll() {
          Row() {
            ForEach(TAB_LABELS, (label: string, idx: number) => {
              Column() {
                Text(label).fontSize(13)
                  .fontColor(this.currentTab === idx ? '#0078D7' : (this.isDark ? '#AAA' : '#666'))
                  .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Regular)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                if (this.currentTab === idx) {
                  Row().width('80%').height(2).backgroundColor('#0078D7').borderRadius(1)
                }
              }
              .onClick(() => { this.currentTab = idx; })
            })
          }.width('100%')
        }
        .width('100%').height(40).scrollBar(BarState.Off)

        Divider().height(1).color('#E0E0E0').width('100%')

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
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
