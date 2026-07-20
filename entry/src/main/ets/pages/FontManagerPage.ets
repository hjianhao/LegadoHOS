/**
 * 字体管理页面
 *
 * - 列表显示已导入的自定义字体，每行用字体本身渲染预览文字 "日出江花红似火"
 * - 支持单行删除和批量选择删除
 * - 右上角导入按钮，通过 DocumentViewPicker 选择 .ttf/.otf 文件导入
 */
import { FontManager, FontInfo } from '../utils/FontManager';
import { ThemeColors } from '../theme/ThemeColors';
import { AppTheme } from '../theme/AppTheme';
import { UiUtil } from '../util/UiUtil';
import { SettingsStore } from '../data/preferences/SettingsStore';
import picker from '@ohos.file.picker';
import common from '@ohos.app.ability.common';
import { AppBackButton } from '../components/common/AppTitleBar';

@Entry
@Component
export struct FontManagerPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State fontList: FontInfo[] = [];
  @State selectedIds: Set<string> = new Set();
  @State isSelectMode: boolean = false;
  @State isLoading: boolean = false;
  @State renameFontId: string = '';
  private renameDialog_: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.loadFonts();
  }

  private async loadFonts(): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.Context;
      await SettingsStore.getInstance().init(ctx);
      await FontManager.getInstance().init(ctx);
      FontManager.getInstance().registerAll(this.getUIContext());
      this.fontList = FontManager.getInstance().getAllFonts().filter(f => f.type === 'custom');
    } catch (e) {
      console.error('[FontManagerPage] loadFonts failed:', (e as Error).message);
    }
  }

  build() {
    Column() {
      // 顶部导航栏
      Row() {
        AppBackButton({ onBack: () => { UiUtil.back(this.getUIContext()); } })
        Text($r('app.string.ui_4831ec355a')).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)

        if (this.isSelectMode) {
          // 批量模式下显示全选和删除
          Button($r('app.string.common_select_all')).fontSize(13)
            .fontColor(ThemeColors.primary(this.isDark))
            .backgroundColor(ThemeColors.transparent())
            .onClick(() => {
              const allSelected = this.fontList.length === this.selectedIds.size;
              this.selectedIds = allSelected ? new Set() : new Set(this.fontList.map(f => f.id));
            })
          Button($r('app.string.common_delete')).fontSize(13)
            .fontColor(this.selectedIds.size > 0 ? ThemeColors.error(this.isDark) : ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.transparent())
            .margin({ left: 12 })
            .onClick(() => {
              if (this.selectedIds.size === 0) return;
              this.confirmBatchDelete();
            })
          Button($r('app.string.common_cancel')).fontSize(13)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .backgroundColor(ThemeColors.transparent())
            .margin({ left: 12 })
            .onClick(() => {
              this.isSelectMode = false;
              this.selectedIds = new Set();
            })
        } else {
          Button($r('app.string.common_import')).fontSize(13)
            .fontColor(ThemeColors.primary(this.isDark))
            .backgroundColor(ThemeColors.transparent())
            .onClick(() => { this.importFont(); })
        }
      }
      .width('100%').height(56).padding({ left: 4, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark))
      .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

      // 字体列表
      if (this.fontList.length === 0) {
        Column() {
          Text($r('app.string.ui_4c106ddba7')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(48).margin({ bottom: 12 })
          Text($r('app.string.ui_524f9b3e07')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
          Text($r('app.string.ui_ce206202aa')).fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.fontList, (font: FontInfo) => {
            ListItem() {
              this.fontRow(font)
            }
            .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
          }, (font: FontInfo) => font.id + '_' + font.name)  // key包含name，重命名后触发重新渲染
        }
        .width('100%').layoutWeight(1)
        .backgroundColor(ThemeColors.background(this.isDark))
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder fontRow(font: FontInfo) {
    Row() {
      // 批量选择模式下显示选择框
      if (this.isSelectMode) {
        Stack() {
          Row() {
            if (this.selectedIds.has(font.id)) {
              Text($r('app.string.ui_698a879938')).fontSize(16).fontColor(ThemeColors.onPrimary(this.isDark))
            }
          }
          .width(24).height(24).borderRadius(12)
          .backgroundColor(this.selectedIds.has(font.id) ? ThemeColors.primary(this.isDark) : ThemeColors.transparent())
          .border({ width: 1.5, color: this.selectedIds.has(font.id) ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark) })
        }.width(44).height(44).margin({ right: 4 }).accessibilityText(font.name)
      }

      // 字体信息
      Column() {
        Text(font.name)
          .fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text($r('app.string.ui_4ab1cac229'))
          .fontSize(18)
          .fontFamily(font.familyName)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .margin({ top: 6 })
          .width('100%')
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      // 非选择模式下显示操作按钮
      if (!this.isSelectMode) {
        Button($r('app.string.ui_1cd80fd7a8')).fontSize(12)
          .fontColor(ThemeColors.primary(this.isDark))
          .backgroundColor(ThemeColors.transparent())
          .margin({ left: 4 })
          .onClick(() => { this.openRenameDialog(font); })
        Button($r('app.string.common_delete')).fontSize(12)
          .fontColor(ThemeColors.error(this.isDark))
          .backgroundColor(ThemeColors.transparent())
          .margin({ left: 4 })
          .onClick(() => { this.confirmDelete(font); })
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { if (this.isSelectMode) this.toggleSelect(font.id); })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (!this.isSelectMode) {
            this.isSelectMode = true;
            this.selectedIds = new Set([font.id]);
          }
        })
    )
  }

  private toggleSelect(id: string): void {
    const newSet = new Set(this.selectedIds);
    if (newSet.has(id)) {
      newSet.delete(id);
    } else {
      newSet.add(id);
    }
    this.selectedIds = newSet;
  }

  private confirmDelete(font: FontInfo): void {
    UiUtil.showDialog(this.getUIContext(), {
      title: '删除字体',
      message: `确定删除 "${font.name}" 吗？`,
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) },
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.doDelete([font.id]);
      }
    }).catch(() => {});
  }

  private confirmBatchDelete(): void {
    const ids = Array.from(this.selectedIds);
    UiUtil.showDialog(this.getUIContext(), {
      title: '批量删除',
      message: `确定删除选中的 ${ids.length} 个字体吗？`,
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) },
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.doDelete(ids);
      }
    }).catch(() => {});
  }

  private async doDelete(ids: string[]): Promise<void> {
    try {
      await FontManager.getInstance().removeFonts(ids);
      this.fontList = FontManager.getInstance().getAllFonts().filter(f => f.type === 'custom');
      this.isSelectMode = false;
      this.selectedIds = new Set();
      UiUtil.showToast(this.getUIContext(), { message: '已删除', duration: 2000 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '删除失败: ' + (e as Error).message, duration: 3000 });
    }
  }

  private async importFont(): Promise<void> {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.ttf', '.otf'];
      documentSelectOptions.maxSelectNumber = 10;
      const uris = await new picker.DocumentViewPicker().select(documentSelectOptions);
      if (!uris || uris.length === 0) return;

      this.isLoading = true;
      UiUtil.showToast(this.getUIContext(), { message: '正在导入字体…', duration: 2000 });

      let successCount = 0;
      for (const uri of uris) {
        const fontInfo = await FontManager.getInstance().importFont(uri);
        if (fontInfo) {
          FontManager.getInstance().registerOne(this.getUIContext(), fontInfo);
          successCount++;
        }
      }

      this.fontList = FontManager.getInstance().getAllFonts().filter(f => f.type === 'custom');
      this.isLoading = false;

      if (successCount > 0) {
        UiUtil.showToast(this.getUIContext(), { message: `已导入 ${successCount} 个字体`, duration: 2000 });
      } else {
        UiUtil.showToast(this.getUIContext(), { message: '导入失败，请检查文件格式', duration: 3000 });
      }
    } catch (e) {
      this.isLoading = false;
      console.error('[FontManagerPage] Import failed:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '导入失败: ' + (e as Error).message, duration: 3000 });
    }
  }

  /** 打开重命名对话框 */
  private openRenameDialog(font: FontInfo): void {
    this.renameFontId = font.id;
    this.renameDialog_ = new CustomDialogController({
      builder: RenameFontDialog({
        currentName: font.name,
        onConfirm: (name: string) => { this.doRename(name); },
      }),
      autoCancel: true,
      customStyle: true,
      cornerRadius: 16,
    });
    this.renameDialog_.open();
  }

  /** 执行重命名 */
  private async doRename(name: string): Promise<void> {
    if (!name.trim() || !this.renameFontId) return;
    try {
      await FontManager.getInstance().renameFont(this.renameFontId, name.trim());
      this.fontList = FontManager.getInstance().getAllFonts().filter(f => f.type === 'custom');
    } catch (e) {
      console.error('[FontManagerPage] Rename failed:', (e as Error).message);
    }
    this.renameDialog_?.close();
    this.renameDialog_ = null;
  }
}

/** 重命名字体对话框 */
@CustomDialog
struct RenameFontDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State currentName: string = '';
  @State newName: string = '';
  onConfirm?: (name: string) => void;

  aboutToAppear(): void {
    this.newName = this.currentName;
  }

  build() {
    Column() {
      Text($r('app.string.ui_ba525dae9b')).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 20, bottom: 16 })

      TextInput({ placeholder: $r('app.string.ui_7c6286bb83'), text: this.newName })
        .width('100%').height(44).margin({ bottom: 16 })
        .backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(8).fontSize(15)
        .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
        .onChange((v: string) => { this.newName = v; })

      Row() {
        Button($r('app.string.common_cancel')).fontSize(14).fontColor(ThemeColors.onBackground(this.isDark))
          .height(48).layoutWeight(1)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
          .onClick(() => { this.controller.close(); })

        Button($r('app.string.common_confirm')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .height(48).layoutWeight(1).margin({ left: 12 })
          .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(8)
          .onClick(() => {
            this.onConfirm?.(this.newName.trim());
          })
      }.width('100%').margin({ bottom: 20 })
    }
    .width('80%').constraintSize({ maxWidth: 520, maxHeight: '90%' }).padding(20)
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }
}
