/**
 * 书源登录对话框（参照 Android Legado SourceLoginDialog）
 *
 * 两种模式：
 * - WebView 模式：loginUrl 是普通网址（如搬山人 https://www.banshanren.com）
 *   内嵌 WebView 打开登录页，用户手动登录；完成后把 WebView 的 Cookie
 *   拉回 CookieStore，后续 App 请求自动携带。
 * - 表单模式：loginUrl 是 JS 且 loginUi 定义了输入项/按钮
 *   渲染账号密码表单，点击按钮执行 loginUrl + action JS，
 *   登录信息持久化到 LoginInfoStore，Cookie 由 JS 请求自动入 CookieStore。
 */
import web_webview from '@ohos.web.webview';
import { ThemeColors } from '../../theme/ThemeColors';
import { CookieStore, parseCookieHeader } from '../../util/CookieStore';
import { LoginInfoStore } from '../../util/LoginInfoStore';
import { JsExpressionEvaluator } from '../../engine/source/JsExpressionEvaluator';
import { AppDatabase } from '../../data/database/AppDatabase';
import { BookSourceTable } from '../../data/database/BookSourceTable';
import { BookSource } from '../../model/BookSource';
import { UiUtil } from '../../util/UiUtil';

interface LoginUiRow {
  name: string;
  type: string;
  action?: string;
  default?: string;
}

@CustomDialog
export struct SourceLoginDialog {
  controller: CustomDialogController;
  sourceId: number = 0;
  sourceUrl: string = '';
  sourceName: string = '';
  loginUrl: string = '';
  loginUi: string = '';
  jsLib: string = '';
  variableComment: string = '';

  @StorageLink('isDark') isDark: boolean = false;
  @State private webViewMode: boolean = true;
  @State private inputRows: LoginUiRow[] = [];
  @State private buttonRows: LoginUiRow[] = [];
  @State private inputValues: string[] = [];
  @State private statusText: string = '';
  @State private busy: boolean = false;
  @State private pageLoading: boolean = true;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private isActive: boolean = false;
  private actionRequestId: number = 0;

  aboutToAppear(): void {
    this.isActive = true;
    // 解析 loginUi；loginUrl 是纯 URL 时走 WebView 模式
    const rows = this.parseLoginUi_();
    const isPlainUrl = /^https?:\/\//i.test(this.loginUrl.trim());
    this.inputRows = rows.filter(r => r.type !== 'button');
    this.buttonRows = rows.filter(r => r.type === 'button' && !!r.action);
    this.webViewMode = isPlainUrl || (this.inputRows.length === 0 && this.buttonRows.length === 0);

    if (!this.webViewMode) {
      // 预填：已保存的登录信息 > loginUi 默认值
      const saved = LoginInfoStore.getInstance().get(this.sourceUrl);
      let savedMap: Record<string, string> = {};
      try {
        if (saved) savedMap = JSON.parse(saved) as Record<string, string>;
      } catch (_e) { /* ignore */ }
      this.inputValues = this.inputRows.map(r => savedMap[r.name] || r.default || '');
    } else {
      // WebView 模式：把 App 侧已保存的 cookie 推进 WebView（幂等）
      try {
        web_webview.WebCookieManager.putAcceptCookieEnabled(true);
        const stored = CookieStore.getInstance().getCookie(this.loginUrl);
        if (stored) {
          parseCookieHeader(stored).forEach((v, k) => {
            web_webview.WebCookieManager.configCookie(this.loginUrl, k + '=' + v)
              .catch(() => {});
          });
        }
      } catch (e) {
        console.warn('[SourceLogin] push cookies to WebView failed:', (e as Error).message);
      }
    }
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.actionRequestId++;
  }

  private parseLoginUi_(): LoginUiRow[] {
    if (!this.loginUi) return [];
    try {
      const parsed = JSON.parse(this.loginUi) as Array<Record<string, Object>>;
      if (!Array.isArray(parsed)) return [];
      const rows: LoginUiRow[] = [];
      for (const item of parsed) {
        const name = String(item['name'] || '').trim();
        const type = String(item['type'] || '').trim();
        if (!name || !type) continue;
        rows.push({
          name: name,
          type: type,
          action: item['action'] ? String(item['action']) : undefined,
          default: item['default'] !== undefined ? String(item['default']) : undefined,
        });
      }
      return rows;
    } catch (_e) {
      return [];
    }
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text('登录 ' + this.sourceName).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.webViewMode) {
          Button($r('app.string.common_done')).fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark))
            .height(44).padding({ left: 12, right: 12 })
            .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(22)
            .onClick(() => { void this.finishWebViewLogin(); })
        }
        Button($r('app.string.common_close')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark))
          .height(44).padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.controller.close(); })
      }
      .width('100%').height(52).padding({ left: 12, right: 8 })

      if (this.webViewMode) {
        // ===== WebView 登录 =====
        Stack() {
          Web({ src: this.loginUrl, controller: this.webController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .zoomAccess(false)
            .onPageBegin(() => { if (this.isActive) this.pageLoading = true; })
            .onPageEnd(() => { if (this.isActive) this.pageLoading = false; })
            .width('100%').layoutWeight(1)
          if (this.pageLoading) {
            LoadingProgress().color(ThemeColors.primary(this.isDark))
          }
        }
        .width('100%').layoutWeight(1)
        Text($r('app.string.ui_ea210a4fcc'))
          .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 8 })
      } else {
        // ===== 表单登录 =====
        Scroll() {
          Column() {
          ForEach(this.inputRows, (row: LoginUiRow, idx: number) => {
            TextInput({ placeholder: row.name, text: this.inputValues[idx] || '' })
              .type(row.type === 'password' ? InputType.Password : InputType.Normal)
              .width('100%').height(44).margin({ bottom: 10 })
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(8).fontSize(14)
              .fontColor(ThemeColors.onBackground(this.isDark))
              .placeholderColor(ThemeColors.secondaryText(this.isDark))
              .onChange((v: string) => {
                const next = this.inputValues.slice();
                next[idx] = v;
                this.inputValues = next;
              })
          }, (row: LoginUiRow, idx: number): string => idx + row.name)

          if (this.statusText) {
            Text(this.statusText).fontSize(13)
              .fontColor(this.statusText.includes('成功') || this.statusText.includes('完成') ?
                ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
              .margin({ bottom: 10 })
          }

          Row() {
            ForEach(this.buttonRows, (row: LoginUiRow) => {
              Button(this.busy ? '执行中...' : row.name).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
                .height(44).layoutWeight(1).margin({ right: 8 })
                .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(8)
                .enabled(!this.busy)
                .onClick(() => { void this.runLoginAction(row); })
            }, (row: LoginUiRow): string => row.name)
          }.width('100%').margin({ top: 4, bottom: 8 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }.width('100%').constraintSize({ maxHeight: '80%' }).scrollBar(BarState.Auto)
      }
    }
    .width(this.webViewMode ? '96%' : '85%')
    .height(this.webViewMode ? '92%' : undefined)
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }

  /** WebView 模式：把 WebView 的 Cookie 拉回 CookieStore 持久化 */
  private async finishWebViewLogin(): Promise<void> {
    const runId = ++this.actionRequestId;
    try {
      const wc = web_webview.WebCookieManager.fetchCookieSync(this.loginUrl);
      if (wc && wc.trim()) {
        await CookieStore.getInstance().setCookie(this.loginUrl, wc);
        if (!this.isActive || runId !== this.actionRequestId) return;
        console.info('[SourceLogin] pulled cookies from WebView');
        UiUtil.showToast(this.getUIContext(), { message: '登录凭据已保存' });
      } else {
        UiUtil.showToast(this.getUIContext(), { message: '未获取到 Cookie，请确认已在页面中登录' });
        return;
      }
    } catch (e) {
      if (!this.isActive || runId !== this.actionRequestId) return;
      console.warn('[SourceLogin] pull cookies failed:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '读取 Cookie 失败：' + (e as Error).message });
      return;
    }
    this.controller.close();
  }

  /** 表单模式：执行 loginUrl + action 登录 JS */
  private async runLoginAction(row: LoginUiRow): Promise<void> {
    if (this.busy || !row.action) return;
    this.busy = true;
    const runId = ++this.actionRequestId;
    this.statusText = '';
    try {
      // 收集表单值 → 登录信息
      const infoMap: Record<string, string> = {};
      for (let i = 0; i < this.inputRows.length; i++) {
        infoMap[this.inputRows[i].name] = this.inputValues[i] || '';
      }
      const infoJson = JSON.stringify(infoMap);
      await LoginInfoStore.getInstance().put(this.sourceUrl, infoJson);
      if (!this.isActive || runId !== this.actionRequestId) return;

      // 追加 dump：把登录后的 loginInfo / variable 带回来持久化
      const script = this.loginUrl + '\n' + row.action +
        '\n;JSON.stringify({loginInfo: source.getLoginInfo(), variable: source.getVariable()});';
      const srcObj: Partial<BookSource> = {
        sourceUrl: this.sourceUrl,
        sourceName: this.sourceName,
      };
      const result = await JsExpressionEvaluator.evaluate(script, {
        source: srcObj,
        jsLib: this.jsLib,
        baseUrl: this.sourceUrl,
        variableBlob: this.variableComment,
        loginInfoJson: infoJson,
      });
      if (!this.isActive || runId !== this.actionRequestId) return;

      // 解析 dump 结果并持久化
      let persisted = false;
      if (result && result.trim().startsWith('{')) {
        try {
          const dump = JSON.parse(result) as Record<string, string>;
          if (dump['loginInfo']) {
            await LoginInfoStore.getInstance().put(this.sourceUrl, dump['loginInfo']);
            persisted = true;
          }
          if (dump['variable'] && dump['variable'] !== this.variableComment) {
            await AppDatabase.getInstance().waitForInit();
            const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
            await dao.updateVariable(this.sourceId, this.sourceUrl, dump['variable']);
          }
        } catch (_e) { /* dump 解析失败仅记录 */ }
      }
      this.statusText = row.name + '已执行' + (persisted ? '，凭据已保存' : '');
      UiUtil.showToast(this.getUIContext(), { message: row.name + '完成' });
      this.controller.close();
    } catch (e) {
      if (!this.isActive || runId !== this.actionRequestId) return;
      console.error('[SourceLogin] action failed:', (e as Error).message);
      this.statusText = row.name + '失败：' + (e as Error).message;
    } finally {
      if (this.isActive && runId === this.actionRequestId) this.busy = false;
    }
  }
}
