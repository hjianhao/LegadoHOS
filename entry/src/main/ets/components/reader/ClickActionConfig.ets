/**
 * 触控区域动作配置面板
 *
 * 9 宫格 3×3 布局，每个格子可配置点击动作。
 * 参考 Android Legado 的 ClickActionConfigSheet。
 */
import { ClickAction, ACTION_LABELS, DEFAULT_ZONE_ACTIONS } from './ClickAction';
import { SettingsStore } from '../../data/preferences/SettingsStore';
import { UiUtil } from '../../util/UiUtil';

@Component
export struct ClickActionConfig {
  @StorageLink('isDark') isDark: boolean = false;
  @State zoneActions: number[] = [];
  @State editZone: number = -1;

  onDismiss?: () => void;
  onChanged?: (actions: number[]) => void;

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
        Text('触控区域设置').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A2E').layoutWeight(1)
        Button('✕').fontSize(16).fontColor(this.isDark ? '#AAA' : '#888')
          .backgroundColor('transparent').onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      Text('点击下方格子，选择该区域点击时触发的动作')
        .fontSize(12).fontColor(this.isDark ? '#AAAAAA' : '#888')
        .padding({ left: 12, right: 12, top: 4, bottom: 8 }).alignSelf(ItemAlign.Start)

      // 9 宫格
      Column() {
        this.buildRow(0, 1, 2)
        this.buildRow(3, 4, 5)
        this.buildRow(6, 7, 8)
      }
      .width('100%').padding(12)

      // 选择动作列表（当 editZone >= 0 时显示）
      if (this.editZone >= 0) {
        this.buildActionList()
      }

      // 恢复默认
      Button('恢复默认').fontSize(14).fontColor('#4A90D9')
        .backgroundColor(Color.Transparent).width('100%').height(36)
        .margin({ top: 4 })
        .onClick(() => {
          this.zoneActions = [...DEFAULT_ZONE_ACTIONS];
          this.saveAll();
        })
    }
    .width('100%').backgroundColor(this.isDark ? '#2A2A2A' : '#FFF')
    .borderRadius({ topLeft: 16, topRight: 16 }).padding({ bottom: 12 })
  }

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
      Text(this.zoneLabel(z)).fontSize(9).fontColor(this.isDark ? '#AAA' : '#999')
        .lineHeight(12)
      Text(ACTION_LABELS[this.zoneActions[z]] || '无')
        .fontSize(11).fontColor(this.isDark ? '#E0E0E0' : '#333')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
    }
    .layoutWeight(1).height('100%')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor(this.editZone === z ?
      (this.isDark ? '#3A3A3A' : '#E8F0FE') :
      (this.isDark ? '#333333' : '#F5F5F5'))
    .borderRadius(8)
    .border({ width: this.editZone === z ? 1 : 0, color: '#0078D7' })
    .onClick(() => { this.editZone = (this.editZone === z) ? -1 : z; })
  }

  @Builder
  buildActionList() {
    Column() {
      Text('选择「' + this.zoneLabel(this.editZone) + '」的动作')
        .fontSize(13).fontColor(this.isDark ? '#CCCCCC' : '#666')
        .padding({ left: 12, bottom: 4 }).alignSelf(ItemAlign.Start)
      Text('无动作').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === -1 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === -1 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(-1); })
      Text('显示菜单').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 0 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 0 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(0); })
      Text('下一页').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 1 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 1 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(1); })
      Text('上一页').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 2 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 2 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(2); })
      Text('下一章').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 3 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 3 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(3); })
      Text('上一章').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 4 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 4 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(4); })
      Text('添加书签').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 7 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 7 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(7); })
      Text('目录').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 10 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 10 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
        .borderRadius(6).onClick(() => { this.pickAction(10); })
      Text('朗读').fontSize(14)
        .fontColor(this.zoneActions[this.editZone] === 13 ? '#0078D7' : (this.isDark ? '#E0E0E0' : '#333'))
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.zoneActions[this.editZone] === 13 ? (this.isDark ? '#1A3A5A' : '#E8F0FE') : 'transparent')
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
