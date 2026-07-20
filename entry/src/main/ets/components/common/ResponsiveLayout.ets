/**
 * 响应式布局容器组件
 *
 * 提供三个通用组件：
 * - MaxWidthContainer：内容居中 + 最大宽度约束（横屏表单/正文不限宽拉伸）
 * - ListDetailLayout：列表/详情分栏（Compact 单列、Medium+ 双列）
 * - AdaptiveDialogAlign 工具已移至 WindowLayout.adaptiveDialogAlignment()
 *
 * 参考 doc/ref/pad.md 的"统一内容宽度 Token"。
 */

import { WindowSizeClass, WindowLayout } from '../../util/WindowLayout';
import { ThemeColors } from '../../theme/ThemeColors';

/** 常用最大宽度 Token（vp） */
export class ContentMaxWidth {
  /** 确认/警告对话框 */
  static readonly DIALOG = 480;
  /** 表单类页面（设置、备份、AI 配置） */
  static readonly FORM = 640;
  /** 普通正文（阅读器横屏限宽） */
  static readonly BODY = 720;
  /** 列表页正文 */
  static readonly LIST = 840;
  /** 宽列表/书架 */
  static readonly WIDE_LIST = 1200;
}

/**
 * 内容居中 + 最大宽度约束容器。
 *
 * Compact 模式下铺满（不加约束），Medium+ 模式下内容居中并限制最大宽度。
 * 用法：
 *   MaxWidthContainer({ maxWidth: ContentMaxWidth.FORM }) {
 *     // 表单内容
 *   }
 */
@Component
export struct MaxWidthContainer {
  @StorageProp('windowSizeClass') sizeClass: WindowSizeClass = WindowSizeClass.COMPACT;
  /** 内容最大宽度（vp），Compact 时忽略 */
  maxWidth: number = ContentMaxWidth.BODY;
  /** 是否在 Compact 模式下也限宽（默认 false，手机铺满） */
  forceLimit: boolean = false;

  @BuilderParam content: () => void;

  build() {
    if (this.sizeClass >= WindowSizeClass.MEDIUM || this.forceLimit) {
      Row() {
        Blank().layoutWeight(1)
        Column() {
          this.content()
        }
        .constraintSize({ maxWidth: this.maxWidth })
        .layoutWeight(0)
        .width('100%')
        Blank().layoutWeight(1)
      }
      .width('100%')
    } else {
      Column() {
        this.content()
      }
      .width('100%')
    }
  }
}

/**
 * 列表/详情分栏布局。
 *
 * - Compact：只渲染 master（列表），点击项通过 onItemSelected 回调跳转到详情页
 * - Medium+：Row { master | detail }，master 占比由 masterRatio 控制
 *
 * 用法：
 *   ListDetailLayout({
 *     masterRatio: 0.4,
 *     hasDetail: this.selectedItem !== null,
 *     onItemSelected: (item) => { this.selectedItem = item; }
 *   }) {
 *     // master builder
 *   } detail: {
 *     // detail builder
 *   }
 */
@Component
export struct ListDetailLayout {
  @StorageProp('windowSizeClass') sizeClass: WindowSizeClass = WindowSizeClass.COMPACT;
  /** master 占比（0-1），默认 0.4 */
  masterRatio: number = 0.4;
  /** 是否有详情内容（false 时右侧显示占位） */
  hasDetail: boolean = false;
  /** 分隔线颜色 */
  dividerColor: string = '';

  @BuilderParam master: () => void;
  @BuilderParam detail: () => void;

  build() {
    if (this.sizeClass >= WindowSizeClass.MEDIUM) {
      Row() {
        Column() {
          this.master()
        }
        .layoutWeight(this.masterRatio)
        .height('100%')

        Divider()
          .vertical(true)
          .strokeWidth(0.5)
          .color(this.dividerColor || ThemeColors.outlineVariant(AppStorage.get<boolean>('isDark') ?? false))

        Column() {
          if (this.hasDetail) {
            this.detail()
          } else {
            // 详情占位
            Column() {
              Text('选择左侧项查看详情')
                .fontSize(14)
                .fontColor(ThemeColors.secondaryText(AppStorage.get<boolean>('isDark') ?? false))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
        }
        .layoutWeight(1 - this.masterRatio)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    } else {
      // Compact: 只渲染 master
      Column() {
        this.master()
      }
      .width('100%')
      .height('100%')
    }
  }
}

/**
 * 自适应弹窗对齐工具（委托给 WindowLayout）。
 * 保留此函数以兼容旧调用点。
 */
export function adaptiveDialogAlignment(): DialogAlignment {
  return WindowLayout.adaptiveDialogAlignment();
}
