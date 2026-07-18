/**
 * 阅读设置面板 — 编码(本地TXT) / 阅读模式(分页/滚动) / 触控区域配置
 *
 * 原为触控区域动作配置面板，现合并为综合阅读设置。
 */
import { ClickAction, ACTION_LABELS, DEFAULT_ZONE_ACTIONS } from './ClickAction';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { UiUtil } from '../../util/UiUtil';
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ClickActionConfig {
  @StorageLink('isDark') isDark: boolean = false;
  @State zoneActions: number[] = [];
  @State editZone: number = -1;
  @State showEncodingOptions: boolean = false;

  // 编码设置（仅本地 TXT 书籍使用）
  @Prop isLocalTxt: boolean = false;
  @Prop txtEncoding: string = 'utf-8';
  // 阅读模式
  @Prop flowMode: string = 'paginated';

  onDismiss?: () => void;
  onChanged?: (actions: number[]) => void;
  onEncodingChange?: (encoding: string) => void;
  onFlowModeChange?: (mode: string) => void;

  aboutToAppear(): void {
    this.loadActions();
  }

  private async loadActions(): Promise<void> {
    const store = SettingsStore.getInstance();
    const ctx = UiUtil.getHostContext(this.getUIContext());
    await store.init(ctx);
    const actions: number[] = [];
    for (let z = 0; z < 9; z++) {
      actions.push(await store.getClickAction(z));
    }
    this.zoneActions = actions;
  }

  /** 区域标签 */
  private zoneLabel(z: number): string {
    const labels = ['左上', '上中', '右上', '左中', '中央', '右中', '左下', '下中', '右下'];
    return labels[z] || '';
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text($r('app.string.ui_bc0832465e')).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(ThemeColors.transparent()).accessibilityText($r('app.string.common_close')).onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      // ===== 编码设置（仅本地 TXT） =====
      if (this.isLocalTxt) {
        Row() {
          Text($r('app.string.ui_9b7b6a50fc')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
          Text(this.txtEncoding).fontSize(14).fontColor(ThemeColors.primary(this.isDark))
          Text($r('app.string.ui_13cadede9f')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 4 })
        }
        .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick(() => { this.showEncodingOptions = !this.showEncodingOptions; })

        if (this.showEncodingOptions) {
          Column() {
            ForEach(['utf-8', 'gbk', 'gb18030', 'big5', 'utf-16le', 'utf-16be'], (enc: string) => {
              Text(enc)
                .fontSize(14)
                .fontColor(enc === this.txtEncoding ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .width('100%').padding({ left: 24, top: 6, bottom: 6 })
                .onClick(() => {
                  this.showEncodingOptions = false;
                  this.onEncodingChange?.(enc);
                })
            })
          }.width('100%')
        }

        // 分隔线
        Row().width('100%').height(1)
          .backgroundColor(ThemeColors.outlineVariant(this.isDark)).margin({ top: 4, bottom: 2 })
      }

      // ===== 阅读模式（分页 / 滚动） =====
      Text($r('app.string.ui_3eac2277d9')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
        .padding({ left: 12, right: 12, top: 6 })
      Row() {
        this.flowModeChip('分页', 'paginated')
        this.flowModeChip('滚动', 'scrolled')
      }.width('100%').padding({ left: 12, right: 12, bottom: 6 })

      // 分隔线
      Row().width('100%').height(1)
        .backgroundColor(ThemeColors.outlineVariant(this.isDark)).margin({ top: 4, bottom: 6 })

      // ===== 触控区域设置 =====
      Text($r('app.string.ui_ee2972614e')).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .padding({ left: 12, right: 12, bottom: 4 })

      Text($r('app.string.ui_4e566eddb7'))
        .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 12, right: 12, bottom: 8 }).alignSelf(ItemAlign.Start)

      // 9 宫格
      Column() {
        this.buildRow(0, 1, 2)
        this.buildRow(3, 4, 5)
        this.buildRow(6, 7, 8)
      }
      .width('100%').padding({ left: 12, right: 12 })

      // 选择动作列表（当 editZone >= 0 时显示）
      if (this.editZone >= 0) {
        this.buildActionList()
      }

      // 恢复默认
      Button($r('app.string.ui_a191935bc6')).fontSize(14).fontColor(ThemeColors.primary(this.isDark))
        .backgroundColor(Color.Transparent).width('100%').height(40)
        .margin({ top: 4 })
        .onClick(() => {
          this.zoneActions = [...DEFAULT_ZONE_ACTIONS];
          this.saveAll();
        })
    }
    .width('100%').backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 }).padding({ bottom: 12 })
  }

  // ===== 阅读模式选择项 =====
  @Builder flowModeChip(label: string, mode: string) {
    Column() {
      Text(label).fontSize(13)
        .fontColor(this.flowMode === mode ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 6, bottom: 6, left: 20, right: 20 })
    }
    .backgroundColor(this.flowMode === mode ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(16).margin({ right: 8 })
    .onClick(() => { this.onFlowModeChange?.(mode); })
  }

  // ===== 触控区域 =====
  @Builder
  buildRow(z1: number, z2: number, z3: number) {
    Row() {
      this.zoneCell(z1)
      this.zoneCell(z2)
      this.zoneCell(z3)
    }.width('100%').height(48).margin({ bottom: 6 })
  }

  @Builder
  zoneCell(z: number) {
    Column() {
      Text(this.zoneLabel(z)).fontSize(9).fontColor(ThemeColors.secondaryText(this.isDark))
        .lineHeight(12)
      Text(ACTION_LABELS[this.zoneActions[z]] || '无')
        .fontSize(11).fontColor(ThemeColors.onSurface(this.isDark))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
    }
    .layoutWeight(1).height('100%')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor(this.editZone === z ?
      (ThemeColors.primaryContainer(this.isDark)) :
      ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(8)
    .border({ width: this.editZone === z ? 1 : 0, color: ThemeColors.primary(this.isDark) })
    .onClick(() => { this.editZone = (this.editZone === z) ? -1 : z; })
  }

  @Builder
  buildActionList() {
    Column() {
      Text('选择「' + this.zoneLabel(this.editZone) + '」的动作')
        .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 12, bottom: 4 }).alignSelf(ItemAlign.Start)
      Text($r('app.string.ui_c5cc5bb410')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === -1 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === -1 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(-1); })
      Text($r('app.string.ui_f73088bc8d')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 0 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 0 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(0); })
      Text($r('app.string.ui_67a246a344')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 1 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 1 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(1); })
      Text($r('app.string.ui_b41561d807')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 2 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 2 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(2); })
      Text($r('app.string.ui_1b061d776b')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 3 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 3 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(3); })
      Text($r('app.string.ui_1393bb2a70')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 4 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 4 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(4); })
      Text($r('app.string.ui_9dbbfd0278')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 7 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 7 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(7); })
      Text($r('app.string.ui_41e5243e2d')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 10 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 10 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(10); })
      Text($r('app.string.ui_8f84b8a07c')).fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 13 ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 13 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
        .borderRadius(6).onClick(() => { this.pickAction(13); })
    }
    .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  private pickAction(code: number): void {
    const copy: number[] = [];
    for (let i = 0; i < this.zoneActions.length; i++) {
      copy.push(this.zoneActions[i]);
    }
    copy[this.editZone] = code;
    this.zoneActions = copy;
    this.saveAll();
    this.editZone = -1;
  }

  private async saveAll(): Promise<void> {
    const store = SettingsStore.getInstance();
    for (let z = 0; z < 9; z++) {
      await store.setClickAction(z, this.zoneActions[z]);
    }
    this.onChanged?.(this.zoneActions);
  }
}
