/**
 * 云端书库 · 来源管理页
 *
 * 阶段 2：管理多个 WebDAV 来源（列表 / 新增 / 编辑 / 删除 / 启用）。
 * 删除来源不删除已下载本地书。
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { CloudSource, cloudProviderDisplayName } from '../model/CloudSource';
import { CloudSourceRepository } from '../service/cloud/CloudSourceRepository';
import { CloudPath } from '../service/cloud/CloudPath';
import { ensureCloudProvidersRegistered } from '../service/cloud/CloudProviderBootstrap';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { common } from '@kit.AbilityKit';

@Entry
@Component
export struct CloudSourceManagePage {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageLink('cloud_sources_show_password_hint') showPasswordHint: boolean = false;
  @State sources: CloudSource[] = [];
  @State isLoading: boolean = true;
  @State errorText: string = '';
  @State missingCredentialCount: number = 0;

  aboutToAppear(): void {
    this.bootstrap_();
  }

  private async bootstrap_(): Promise<void> {
    this.isLoading = true;
    this.errorText = '';
    try {
      ensureCloudProvidersRegistered();
      await AppDatabase.getInstance().waitForInit();
      const ctx = this.getUIContext().getHostContext() as common.Context;
      if (ctx) {
        await SettingsStore.getInstance().init(ctx);
        await CloudCredentialStore.getInstance().init(ctx);
      } else if (!CloudCredentialStore.getInstance().isReady()) {
        throw new Error('无法获取 Context，凭证存储未就绪');
      }
      await this.loadData_();
    } catch (e) {
      this.errorText = (e as Error).message || '加载失败';
      console.error('[CloudSourceManage] bootstrap failed:', this.errorText);
    } finally {
      this.isLoading = false;
    }
  }

  private async loadData_(): Promise<void> {
    const repo = new CloudSourceRepository();
    const list = await repo.listAll();
    // 整体替换，触发 UI 刷新
    this.sources = list.slice();
    // 统计缺密码的来源（备份恢复后常见）
    let missing = 0;
    for (let i = 0; i < list.length; i++) {
      try {
        const cred = await repo.getCredential(list[i].id);
        if (!cred || !cred.secret) {
          missing++;
        }
      } catch (_e) {
        missing++;
      }
    }
    this.missingCredentialCount = missing;
    if (missing === 0 && this.showPasswordHint) {
      this.showPasswordHint = false;
      AppStorage.setOrCreate<boolean>('cloud_sources_show_password_hint', false);
    }
  }

  private openEdit_(sourceId: number): void {
    if (sourceId > 0) {
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/CloudSourceEditPage',
        params: { sourceId: sourceId },
      });
    } else {
      UiUtil.pushUrl(this.getUIContext(), { url: 'pages/CloudSourceEditPage' });
    }
  }

  private async onToggleEnabled_(source: CloudSource, enabled: boolean): Promise<void> {
    try {
      // 只改 enabled，绝不能走 save() 以免在凭证读失败时用空值覆盖
      const repo = new CloudSourceRepository();
      await repo.setEnabled(source.id, enabled);
      await this.loadData_();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: '更新失败: ' + ((e as Error).message || ''),
        duration: 2000,
      });
      await this.loadData_();
    }
  }

  private confirmDelete_(source: CloudSource): void {
    AlertDialog.show({
      title: '删除云端来源',
      message: '确定删除「' + source.name + '」？\n不会删除已下载到书架的本地书籍。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '删除',
        fontColor: ThemeColors.error(this.isDark),
        action: () => {
          this.doDelete_(source.id);
        },
      },
    });
  }

  private async doDelete_(id: number): Promise<void> {
    try {
      const repo = new CloudSourceRepository();
      await repo.deleteSource(id);
      UiUtil.showToast(this.getUIContext(), { message: '已删除来源', duration: 1500 });
      await this.loadData_();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: '删除失败: ' + ((e as Error).message || ''),
        duration: 2000,
      });
    }
  }

  private previewLine_(source: CloudSource): string {
    try {
      return CloudPath.previewUrl(source.endpoint, source.rootPath, '');
    } catch (_e) {
      return source.endpoint;
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          UiUtil.back(this.getUIContext());
        })

        Text('云端书库管理')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
          .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          Text('新增').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          this.openEdit_(0);
        })
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 8, bottom: 8 })

      Text('可配置多个 WebDAV 网盘；每个来源独立根目录与账号。下载后的书作为本地书进入书架。')
        .fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .padding({ left: 16, right: 16, bottom: 8 })
        .width('100%')

      if (this.showPasswordHint || this.missingCredentialCount > 0) {
        Column() {
          Text('备份恢复后不会包含密码。请编辑下方来源并重新填写账号密码。')
            .fontSize(13)
            .fontColor(ThemeColors.warning(this.isDark))
            .width('100%')
          if (this.missingCredentialCount > 0) {
            Text(`当前有 ${this.missingCredentialCount} 个来源缺少凭证。`)
              .fontSize(12)
              .fontColor(ThemeColors.secondaryText(this.isDark))
              .margin({ top: 4 })
              .width('100%')
          }
        }
        .width('100%')
        .padding(12)
        .margin({ left: 12, right: 12, bottom: 8 })
        .backgroundColor(ThemeColors.warningContainer(this.isDark))
        .borderRadius(10)
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36).color(ThemeColors.primary(this.isDark))
          Text('加载中…').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText) {
        Column() {
          Text(this.errorText).fontSize(14).fontColor(ThemeColors.error(this.isDark))
          Button('重试')
            .margin({ top: 12 })
            .onClick(() => {
              this.bootstrap_();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.sources.length === 0) {
        Column() {
          Text('尚未配置云端来源')
            .fontSize(15)
            .fontColor(ThemeColors.secondaryText(this.isDark))
          Text('点击右上角「新增」添加 WebDAV 服务器')
            .fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 8 })
          Button('新增来源')
            .margin({ top: 16 })
            .backgroundColor(ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => {
              this.openEdit_(0);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sources, (source: CloudSource) => {
            ListItem() {
              Column() {
                Row() {
                  Column() {
                    Text(source.name)
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onSurface(this.isDark))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.previewLine_(source))
                      .fontSize(11)
                      .fontColor(ThemeColors.secondaryText(this.isDark))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 4 })
                    Row() {
                      Text(cloudProviderDisplayName(source.providerType || 'webdav'))
                        .fontSize(10)
                        .fontColor(ThemeColors.primary(this.isDark))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .border({ width: 0.5, color: ThemeColors.primary(this.isDark), radius: 4 })
                      Text(source.rootPath ? ('根目录: ' + source.rootPath) : '根目录: (服务器根)')
                        .fontSize(10)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                        .margin({ left: 8 })
                      if (!source.enabled) {
                        Text('已禁用')
                          .fontSize(10)
                          .fontColor(ThemeColors.error(this.isDark))
                          .margin({ left: 8 })
                      }
                    }
                    .margin({ top: 6 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Toggle({ type: ToggleType.Switch, isOn: source.enabled })
                    .selectedColor(ThemeColors.primary(this.isDark))
                    .onChange((isOn: boolean) => {
                      this.onToggleEnabled_(source, isOn);
                    })
                }
                .width('100%')

                Row() {
                  Button('编辑')
                    .fontSize(13)
                    .height(32)
                    .backgroundColor(ThemeColors.outlineVariant(this.isDark))
                    .fontColor(ThemeColors.primary(this.isDark))
                    .onClick(() => {
                      this.openEdit_(source.id);
                    })
                  Button('删除')
                    .fontSize(13)
                    .height(32)
                    .margin({ left: 8 })
                    .backgroundColor(ThemeColors.outlineVariant(this.isDark))
                    .fontColor(ThemeColors.error(this.isDark))
                    .onClick(() => {
                      this.confirmDelete_(source);
                    })
                }
                .width('100%')
                .margin({ top: 10 })
                .justifyContent(FlexAlign.End)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(12)
              .margin({ left: 12, right: 12, bottom: 10 })
            }
          }, (source: CloudSource) => source.id.toString() + '_' + source.updatedAt.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .onAppear(() => {
          // 从编辑页返回时刷新
          this.loadData_().catch(() => {});
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }

  onPageShow(): void {
    if (!this.isLoading) {
      this.loadData_().catch(() => {});
    }
  }
}
