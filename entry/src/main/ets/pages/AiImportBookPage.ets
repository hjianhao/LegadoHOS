/**
 * AI 智能导入页面
 * 输入书籍目录页 URL → AI 分析 → 自动下载全书
 */
import { AiBookImporter, ImportProgress } from '../engine/ai/AiBookImporter';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct AiImportBookPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State url: string = '';
  @State isRunning: boolean = false;
  @State phase: string = '';
  @State progressText: string = '';
  @State progressCurrent: number = 0;
  @State progressTotal: number = 0;
  @State errorText: string = '';
  @State resultText: string = '';

  private importer_: AiBookImporter | null = null;

  aboutToAppear(): void {
    this.importer_ = new AiBookImporter((p: ImportProgress): void => {
      this.phase = p.phase;
      this.progressText = p.message;
      this.progressCurrent = p.current;
      this.progressTotal = p.total;
      if (p.phase === 'error') {
        this.errorText = p.message;
        this.isRunning = false;
      }
      if (p.phase === 'done') {
        this.resultText = p.message;
        this.isRunning = false;
      }
    });
  }

  private async startImport(): Promise<void> {
    const trimmed = this.url.trim();
    if (!trimmed) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书籍URL', duration: 1500 });
      return;
    }
    this.isRunning = true;
    this.errorText = '';
    this.resultText = '';

    try {
      if (!this.importer_) return;
      const ok = await this.importer_.init(UiUtil.getHostContext(this.getUIContext()));
      if (!ok) {
        this.errorText = '请先在"AI 配置"中设置 LLM API';
        this.isRunning = false;
        return;
      }
      const result = await this.importer_.import(trimmed);
      this.resultText = `导入成功！共 ${result.chapterCount} 章`;
    } catch (e) {
      this.errorText = '导入失败: ' + ((e as Error).message || '');
      this.isRunning = false;
    }
  }

  private getPhaseLabel(): string {
    switch (this.phase) {
      case 'fetch': return '🔍 抓取页面';
      case 'analyze_toc': return '🤖 分析目录';
      case 'analyze_content': return '🤖 分析正文';
      case 'download': return '📥 下载章节';
      case 'done': return '✅ 完成';
      case 'error': return '❌ 出错';
      default: return '';
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('< 返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark)).padding({ right: 12 })
          .onClick(() => { router.back(); })
        Text('AI 智能导入').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
      }.padding(16).width('100%')

      // URL 输入
      TextArea({ text: this.url, placeholder: '输入小说目录页URL' })
        .width('calc(100% - 32)').height(80).fontSize(14)
        .backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(8).padding(12).margin({ left: 16, right: 16, top: 8 })
        .onChange((v: string) => { this.url = v; })

      // 开始按钮
      Button('开始导入').fontSize(16).fontColor('#FFF')
        .height(44).width('calc(100% - 32)').borderRadius(8)
        .backgroundColor(ThemeColors.primary(this.isDark))
        .enabled(!this.isRunning)
        .margin({ left: 16, right: 16, top: 16 })
        .onClick(() => { this.startImport(); })

      // AI 配置入口
      Row() {
        Text('LLM 未配置？').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        Text('前往配置 →').fontSize(12).fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/AiConfigPage' }); })
      }.margin({ top: 8 })

      // 进度区域
      if (this.isRunning || this.resultText || this.errorText) {
        Column() {
          if (this.isRunning) {
            Row() {
              LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
              Text(this.getPhaseLabel()).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 8 })
            }.margin({ bottom: 8 })

            if (this.progressTotal > 0) {
              Row() {
                Row().width((this.progressCurrent / this.progressTotal) * 100 + '%')
                  .height(6).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(3)
              }.width('100%').height(6)
              .backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(3)
              .margin({ bottom: 4 })

              Text(this.progressText).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            } else {
              Text(this.progressText).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
            }
          }

          if (this.resultText) {
            Text(this.resultText).fontSize(15).fontColor('#4CAF50').margin({ top: 8 })
          }

          if (this.errorText) {
            Text(this.errorText).fontSize(13).fontColor(ThemeColors.error(this.isDark)).margin({ top: 8 })
              .padding(12).width('calc(100% - 32)')
          }
        }
        .width('calc(100% - 32)').padding(16).margin({ top: 16, left: 16, right: 16 })
        .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(8)
        .alignItems(HorizontalAlign.Start)
      }

      // 说明
      Column() {
        Text('📖 使用说明').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark)).margin({ bottom: 4 })
        Text('1. 输入小说网站的目录页URL')
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ bottom: 2 })
        Text('2. AI 自动分析页面的目录和正文结构')
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ bottom: 2 })
        Text('3. 自动下载所有章节到本地，后续无需网络')
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
      }
      .width('calc(100% - 32)').padding(12).margin({ top: 16, left: 16, right: 16 })
      .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
