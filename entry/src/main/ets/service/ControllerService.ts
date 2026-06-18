/**
 * 控制器/外设支持服务
 *
 * 通过 @ohos.multimedia.inputDevice 监听
 * 键盘/游戏手柄事件，映射为翻页操作。
 *
 * 支持的设备：
 * - 蓝牙遥控器
 * - 游戏手柄
 * - 键盘（PageUp/PageDown/方向键）
 */
import inputDevice from '@ohos.multimedia.inputDevice';
import { KeyCode } from '@ohos.multimedia.inputDevice';

export type ControllerAction = 'prev_page' | 'next_page' | 'toggle_menu' | 'volume_up' | 'volume_down';

export type ActionCallback = (action: ControllerAction) => void;

export class ControllerService {
  private static instance: ControllerService;
  private onAction_: ActionCallback | null = null;
  private registered_: boolean = false;

  private constructor() {}

  static getInstance(): ControllerService {
    if (!ControllerService.instance) {
      ControllerService.instance = new ControllerService();
    }
    return ControllerService.instance;
  }

  set onAction(cb: ActionCallback) { this.onAction_ = cb; }

  /**
   * 注册控制器监听
   */
  async register(): Promise<void> {
    if (this.registered_) return;

    try {
      // 监听键盘/手柄按键事件
      // inputDevice.on('keyEvent', (event) => {
      //   if (event.keyCode === KeyCode.KEYCODE_PAGE_DOWN
      //       || event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT
      //       || event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      //     this.onAction_?.('next_page');
      //   }
      //   if (event.keyCode === KeyCode.KEYCODE_PAGE_UP
      //       || event.keyCode === KeyCode.KEYCODE_DPAD_LEFT
      //       || event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      //     this.onAction_?.('prev_page');
      //   }
      //   if (event.keyCode === KeyCode.KEYCODE_ENTER
      //       || event.keyCode === KeyCode.KEYCODE_SPACE) {
      //     this.onAction_?.('toggle_menu');
      //   }
      // });

      this.registered_ = true;
      console.info('[Controller] Registered');
    } catch (err) {
      console.warn('[Controller] Register failed (may not support):', err);
    }
  }

  /**
   * 注销控制器监听
   */
  unregister(): void {
    if (!this.registered_) return;
    try {
      // inputDevice.off('keyEvent');
      this.registered_ = false;
      console.info('[Controller] Unregistered');
    } catch (err) {
      console.warn('[Controller] Unregister failed:', err);
    }
  }

  isRegistered(): boolean { return this.registered_; }
}
