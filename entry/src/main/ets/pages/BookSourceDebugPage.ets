import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { CheckDetail, CheckResult, SourceChecker } from '../service/SourceChecker';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
export struct BookSourceDebugPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State source: BookSource | null = null;
  @State keyword: string = '';
  @State details: CheckDetail[] = [];
  @State statusText: string = '输入关键词后运行，可依次检查搜索、详情、目录和正文。';
  @State isRunning: boolean = false;
  private checker: SourceChecker | null = null;

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    this.loadSource(params ? String(params['sourceUrl'] || params['url'] || '') : '');
  }

  private async loadSource(sourceUrl: string): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.source = await dao.getSourceByUrl(sourceUrl);
      if (this.source) {
        this.keyword = this.source.ruleSearchCheckKeyWord || '我';
      } else {
        this.statusText = '没有找到对应书源，请返回管理页重试。';
      }
    } catch (e) {
      this.statusText = '加载书源失败：' + String(e);
    }
  }

  private async runDebug(): Promise<void> {
    if (!this.source || this.isRunning) return;
    if (!this.keyword.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入测试关键词', duration: 1500 });
      return;
    }
    this.isRunning = true;
    this.details = [];
    this.statusText = '正在运行规则链路…';
    this.checker = new SourceChecker({
      keyword: this.keyword.trim(), timeout: 30000,
      checkSearch: true, checkDiscovery: false, checkInfo: true,
      checkCategory: true, checkContent: true
    });
    try {
      const result: CheckResult = await this.checker.checkSource(this.source);
      this.details = result.details.slice();
      this.statusText = result.status === 'success' ? '全部规则检查通过'
        : result.status === 'partial' ? '部分规则通过，请展开失败阶段排查' : '规则检查失败';
      const search = result.details.find((item: CheckDetail): boolean => item.name === '搜索' && item.passed);
      if (search && search.duration > 0) {
        const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
        await dao.updateRespondTime(this.source.id, search.duration);
      }
    } catch (e) {
      this.statusText = '调试失败：' + String(e);
    } finally {
      this.isRunning = false;
      this.checker = null;
    }
  }

  private cancelDebug(): void {
    this.checker?.cancel();
    this.statusText = '已请求停止；当前网络请求结束后不再继续。';
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.ui_0dccf90917')).fontSize(26).width(40).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.onBackground(this.isDark))
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Column() {
          Text($r('app.string.ui_51f7688b7a')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).width('100%')
          Text(this.source ? this.source.sourceName : '加载中…').fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').maxLines(1)
        }.layoutWeight(1)
      }.height(64).padding({ left: 8, right: 16 }).width('100%')

      Column() {
        Text($r('app.string.ui_284abffdc3')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        Row() {
          TextInput({ text: this.keyword, placeholder: $r('app.string.ui_57292d42ea') })
            .height(48).layoutWeight(1).borderRadius(12)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .onChange((value: string) => { this.keyword = value; })
          Button(this.isRunning ? '停止' : '运行').height(48).margin({ left: 8 })
            .borderRadius(24).padding({ left: 20, right: 20 })
            .backgroundColor(this.isRunning ? ThemeColors.error(this.isDark) : ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { if (this.isRunning) this.cancelDebug(); else this.runDebug(); })
        }.width('100%').margin({ top: 6 })
        Text(this.statusText).fontSize(13).lineHeight(20)
          .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ top: 12 })
      }.margin({ left: 16, right: 16, top: 4, bottom: 12 }).padding(16).borderRadius(16)
        .backgroundColor(ThemeColors.surface(this.isDark))

      if (this.isRunning) {
        Progress({ value: 20, total: 100, type: ProgressType.Linear }).width('100%')
          .color(ThemeColors.primary(this.isDark)).style({ strokeWidth: 3 })
      }

      if (!this.isRunning && this.details.length === 0) {
        Column() {
          Text($r('app.string.ui_45b3b04258')).fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_7d46687776')).fontSize(14).margin({ top: 10 })
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.details, (detail: CheckDetail) => {
            ListItem() {
              Row() {
                Text(detail.passed ? '✓' : '!').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(detail.passed ? ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
                  .width(32).height(32).textAlign(TextAlign.Center)
                Column() {
                  Row() {
                    Text(detail.name).fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
                    if (detail.duration > 0) {
                      Text(detail.duration + ' ms').fontSize(12)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                    }
                  }.width('100%')
                  Text(detail.message).fontSize(13).lineHeight(19).margin({ top: 4 })
                    .fontColor(detail.passed ? ThemeColors.secondaryText(this.isDark) : ThemeColors.error(this.isDark))
                    .width('100%')
                }.layoutWeight(1).margin({ left: 8 })
              }.padding(16).width('100%').borderRadius(16)
                .backgroundColor(ThemeColors.surface(this.isDark))
            }
          }, (detail: CheckDetail): string => detail.name)
        }.layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 })
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
