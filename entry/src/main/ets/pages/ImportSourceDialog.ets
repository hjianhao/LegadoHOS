import { BookSourceTable } from '../data/database/BookSourceTable';
import { AppDatabase } from '../data/database/AppDatabase';
import { NetUtil } from '../util/NetUtil';
import promptAction from '@ohos.promptAction';

@CustomDialog
export struct ImportSourceDialog {
  controller: CustomDialogController;

  @State importUrl: string = '';
  @State importJson: string = '';
  @State isLoading: boolean = false;

  onImportSuccess?: () => void;

  /**
   * 离线导入：粘贴 JSON 内容
   */
  private async doOfflineImport(): Promise<void> {
    if (!this.importJson.trim()) {
      promptAction.showToast({ message: '请粘贴JSON内容', duration: 1500 });
      return;
    }
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      dao.importSources(this.importJson).then((count: number): void => {
        promptAction.showToast({ message: '成功导入 ' + count + ' 个书源', duration: 2000 });
        this.isLoading = false;
        this.controller.close();
        if (this.onImportSuccess !== undefined) {
          this.onImportSuccess();
        }
      }).catch((): void => {
        promptAction.showToast({ message: 'JSON格式错误', duration: 2000 });
        this.isLoading = false;
      });
    } catch (e) {
      promptAction.showToast({ message: '数据库异常: ' + (e as Error).message, duration: 2000 });
      this.isLoading = false;
    }
  }

  /**
   * 在线导入：通过 URL 获取 JSON
   */
  private async doOnlineImport(): Promise<void> {
    if (!this.importUrl.trim()) {
      promptAction.showToast({ message: '请输入链接', duration: 1500 });
      return;
    }
    this.isLoading = true;
    NetUtil.httpGet(this.importUrl).then(async (json: string): Promise<void> => {
      try {
        await AppDatabase.getInstance().waitForInit();
        const db = AppDatabase.getInstance().rdbStore;
        const dao = new BookSourceTable(db);
        dao.importSources(json).then((count: number): void => {
          promptAction.showToast({ message: '成功导入 ' + count + ' 个书源', duration: 2000 });
          this.isLoading = false;
          this.controller.close();
          if (this.onImportSuccess !== undefined) {
            this.onImportSuccess();
          }
        }).catch((): void => {
          promptAction.showToast({ message: 'JSON格式错误', duration: 2000 });
          this.isLoading = false;
        });
      } catch (e) {
        promptAction.showToast({ message: '数据库异常: ' + (e as Error).message, duration: 2000 });
        this.isLoading = false;
      }
    }).catch((): void => {
      promptAction.showToast({ message: '导入失败，请检查链接或网络', duration: 2000 });
      this.isLoading = false;
    });
  }

  build() {
    Column() {
      Text('导入书源').fontSize(18).fontWeight(FontWeight.Bold).padding({ top: 20, bottom: 12 })

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 20, bottom: 20 })
      } else {
        TextInput({ placeholder: '在线导入: 粘贴 JSON 链接...', text: this.importUrl })
          .height(44).backgroundColor('#F0F0F0')
          .borderRadius(8).padding({ left: 16 }).width('100%').margin({ bottom: 8 })
          .onChange((v: string): void => {
            this.importUrl = v
          })

        TextInput({ placeholder: '离线导入: 粘贴 JSON 内容...', text: this.importJson })
          .height(80).backgroundColor('#F0F0F0')
          .borderRadius(8).padding({ left: 16 }).width('100%').margin({ bottom: 16 })
          .onChange((v: string): void => {
            this.importJson = v
          })

        Row() {
          Button('取消').fontSize(14).height(40).layoutWeight(1).margin({ right: 4 })
            .onClick((): void => {
              this.controller.close()
            })
          Button('在线导入').fontSize(13).height(40).layoutWeight(1).margin({ left: 4, right: 4 })
            .backgroundColor('#0078D7').fontColor('#FFF')
            .onClick((): void => {
              this.doOnlineImport()
            })
          Button('离线导入').fontSize(13).height(40).layoutWeight(1).margin({ left: 4 })
            .backgroundColor('#4CAF50').fontColor('#FFF')
            .onClick((): void => {
              this.doOfflineImport()
            })
        }.width('100%').padding({ bottom: 20 })
      }
    }
    .padding({ left: 24, right: 24 })
    .width('100%')
  }
}
