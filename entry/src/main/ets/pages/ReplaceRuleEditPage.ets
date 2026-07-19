/**
 * 替换净化规则编辑页
 * 入口参数：无参 = 新建；params: { id: '规则id' } = 编辑已有规则（从 DB 加载）。
 * 保存前 isValidRule 校验（pattern 非空、正则试编译、拦截裸 | 结尾）。
 */
import { DEFAULT_REPLACE_TIMEOUT, ReplaceRule, isValidRule } from '../model/ReplaceRule';
import { AppDatabase } from '../data/database/AppDatabase';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { AppBackButton } from '../components/common/AppTitleBar';

@Entry
@Component
struct ReplaceRuleEditPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State isLoading: boolean = true;
  @State isNew: boolean = true;
  @State isSaving: boolean = false;
  @State ruleId: number = 0;
  @State ruleOrder: number = 0;
  @State isEnabled: boolean = true;
  @State name: string = '';
  @State pattern: string = '';
  @State replacement: string = '';
  @State group: string = '';
  @State isRegex: boolean = true;
  @State scopeTitle: boolean = false;
  @State scopeContent: boolean = true;
  @State scope: string = '';
  @State excludeScope: string = '';
  @State timeoutText: string = '3000';
  private dao_: ReplaceRuleTable | null = null;

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    const idStr: string = params ? (params['id'] || '') : '';
    this.loadRule(idStr);
  }

  private async loadRule(idStr: string): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      this.dao_ = new ReplaceRuleTable(AppDatabase.getInstance().rdbStore);
      const id = Number(idStr);
      if (idStr && !isNaN(id) && id > 0) {
        const all = await this.dao_.getAll();
        const rule = all.find((item: ReplaceRule): boolean => item.id === id);
        if (rule) {
          this.isNew = false;
          this.ruleId = rule.id;
          this.ruleOrder = rule.order;
          this.isEnabled = rule.isEnabled;
          this.name = rule.name;
          this.pattern = rule.pattern;
          this.replacement = rule.replacement;
          this.group = rule.group;
          this.isRegex = rule.isRegex;
          this.scopeTitle = rule.scopeTitle;
          this.scopeContent = rule.scopeContent;
          this.scope = rule.scope;
          this.excludeScope = rule.excludeScope;
          this.timeoutText = String(rule.timeoutMillisecond);
        }
      }
    } catch (e) {
      console.error('[ReplaceRuleEdit] load error: ' + e);
    }
    this.isLoading = false;
  }

  /** 与 isValidRule 相同的校验，返回可读原因（空串 = 合法） */
  private validateMessage(): string {
    if (!this.pattern) {
      return '替换内容不能为空';
    }
    if (this.isRegex) {
      try {
        new RegExp(this.pattern);
      } catch (_e) {
        return '正则表达式无法编译，请检查语法';
      }
      if (this.pattern.endsWith('|') && !this.pattern.endsWith('\\|')) {
        return '正则不能以裸 | 结尾（易卡死），如确需请写成 \\|';
      }
    }
    return '';
  }

  private async save(): Promise<void> {
    const message = this.validateMessage();
    if (message) {
      UiUtil.showToast(this.getUIContext(), { message: message, duration: 2000 });
      return;
    }
    if (!this.dao_ || this.isSaving) return;
    this.isSaving = true;
    try {
      const timeout = parseInt(this.timeoutText, 10);
      const rule: ReplaceRule = {
        id: this.isNew ? Date.now() : this.ruleId,
        name: this.name.trim(),
        group: this.group.trim(),
        pattern: this.pattern,
        replacement: this.replacement,
        scope: this.scope.trim(),
        scopeTitle: this.scopeTitle,
        scopeContent: this.scopeContent,
        excludeScope: this.excludeScope.trim(),
        isEnabled: this.isEnabled,
        isRegex: this.isRegex,
        timeoutMillisecond: isNaN(timeout) ? DEFAULT_REPLACE_TIMEOUT : timeout,
        order: this.isNew ? (await this.dao_.getMaxOrder()) + 1 : this.ruleOrder,
      };
      if (!isValidRule(rule)) {
        UiUtil.showToast(this.getUIContext(), { message: '规则不合法，请检查替换内容', duration: 2000 });
        this.isSaving = false;
        return;
      }
      if (this.isNew) {
        await this.dao_.insert(rule);
        UiUtil.showToast(this.getUIContext(), { message: '已创建规则', duration: 1500 });
      } else {
        await this.dao_.update(rule);
        UiUtil.showToast(this.getUIContext(), { message: '已保存', duration: 1500 });
      }
      UiUtil.back(this.getUIContext());
    } catch (e) {
      console.error('[ReplaceRuleEdit] save error: ' + e);
      UiUtil.showToast(this.getUIContext(), { message: '保存失败：' + String(e), duration: 2000 });
    }
    this.isSaving = false;
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        AppBackButton({ onBack: () => { UiUtil.back(this.getUIContext()); } })
        Text(this.isNew ? '新建净化规则' : '编辑净化规则').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button(this.isSaving ? '保存中' : '保存').fontSize(14).height(40)
          .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
          .borderRadius(20).padding({ left: 16, right: 16 })
          .enabled(!this.isSaving)
          .onClick(() => { this.save(); })
      }.width('100%').height(56).padding({ left: 4, right: 12 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

      if (this.isLoading) {
        Column() {
          LoadingProgress().color(ThemeColors.primary(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            this.textField('规则名称', this.name, '可选，便于识别', false, (v: string) => { this.name = v; })
            this.textField('替换内容', this.pattern, '正则表达式或普通文本', true, (v: string) => { this.pattern = v; })
            this.textField('替换为', this.replacement, '留空 = 删除匹配内容；正则可引用 $1 分组', true,
              (v: string) => { this.replacement = v; })
            this.textField('分组', this.group, '可选，多个分组用 , 或 ; 分隔', false, (v: string) => { this.group = v; })

            this.switchRow('使用正则表达式', this.isRegex, (v: boolean) => { this.isRegex = v; })
            this.switchRow('作用于标题', this.scopeTitle, (v: boolean) => { this.scopeTitle = v; })
            this.switchRow('作用于正文', this.scopeContent, (v: boolean) => { this.scopeContent = v; })

            this.textField('作用范围', this.scope, '书名或书源URL，留空全部生效', false,
              (v: string) => { this.scope = v; })
            this.textField('排除范围', this.excludeScope, '书名或书源URL，命中即排除该规则', false,
              (v: string) => { this.excludeScope = v; })

            Column() {
              Text($r('app.string.ui_literal_a3ce47a749')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
              TextInput({ placeholder: '3000', text: this.timeoutText })
                .height(48).fontSize(14).borderRadius(12).width('100%').margin({ top: 4 })
                .type(InputType.Number)
                .padding({ left: 12, right: 12 }).backgroundColor(ThemeColors.surface(this.isDark))
                .fontColor(ThemeColors.onSurface(this.isDark))
                .placeholderColor(ThemeColors.secondaryText(this.isDark))
                .onChange((v: string) => { this.timeoutText = v; })
              Text($r('app.string.ui_literal_0147352334'))
                .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ top: 4 })
            }.width('100%').margin({ top: 12 })
          }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical)
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  textField(label: string, value: string, placeholder: string, multiline: boolean, onChanged: (v: string) => void) {
    Column() {
      Text(label).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
      if (multiline) {
        TextArea({ placeholder: placeholder, text: value })
          .height(100).fontSize(14).borderRadius(12).width('100%').margin({ top: 4 })
          .padding(12).backgroundColor(ThemeColors.surface(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange(onChanged)
      } else {
        TextInput({ placeholder: placeholder, text: value })
          .height(48).fontSize(14).borderRadius(12).width('100%').margin({ top: 4 })
          .padding({ left: 12, right: 12 }).backgroundColor(ThemeColors.surface(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange(onChanged)
      }
    }.width('100%').margin({ top: 12 })
  }

  @Builder
  switchRow(label: string, value: boolean, onChanged: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .onChange(onChanged)
    }.height(52).width('100%').margin({ top: 12 }).padding({ left: 12, right: 8 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
  }
}
