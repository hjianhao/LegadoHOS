/**
 * RSS 收藏管理页
 * 对应 Android RssFavoritesScreen — 管理收藏的 RSS 文章
 * 功能：分组显示、搜索、批量操作、改分组
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RssStar } from '../model/RSSSource';
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
export struct RssFavoritesPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State items: RssStar[] = [];
  @State groups: string[] = [];
  @State currentGroup: string = '';
  @State searchKey: string = '';
  @State isSearch: boolean = false;
  @State isLoading: boolean = true;
  @State selectedIds: Set<string> = new Set();

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    this.loadData();
  }

  async loadData() {
    this.isLoading = true;
    try {
      await this.db.waitForInit();
      let items: RssStar[];
      if (this.currentGroup) {
        items = await this.db.rssStarTable.getByGroup(this.currentGroup);
      } else {
        items = await this.db.rssStarTable.getAll();
      }
      const groups = await this.db.rssStarTable.getGroups();

      if (this.searchKey) {
        const key = this.searchKey.toLowerCase();
        items = items.filter(s => s.title.toLowerCase().includes(key));
      }

      this.items = items;
      this.groups = groups;
      this.isLoading = false;
    } catch (e) {
      console.error(`[RssFavoritesPage] 加载失败: ${e}`);
      this.isLoading = false;
    }
  }

  async search(val: string) {
    this.searchKey = val;
    this.loadData();
  }

  async setGroup(group: string) {
    this.currentGroup = group;
    this.loadData();
  }

  toggleSelect(id: string) {
    const set = new Set(this.selectedIds);
    if (set.has(id)) set.delete(id);
    else set.add(id);
    this.selectedIds = set;
  }

  selectAll() {
    this.selectedIds = new Set(this.items.map(i => `${i.origin}|${i.link}`));
  }

  clearSelection() {
    this.selectedIds = new Set();
  }

  async deleteSelected() {
    const ids: string[] = [];
    const iter = this.selectedIds.values();
    let next = iter.next();
    while (!next.done) {
      ids.push(next.value);
      next = iter.next();
    }
    for (let i = 0; i < ids.length; i++) {
      const parts = ids[i].split('|');
      const origin = parts[0];
      const link = parts[1];
      if (origin && link) {
        await this.db.rssStarTable.delete(origin, link);
      }
    }
    UiUtil.showToast(this.getUIContext(), { message: `已删除 ${this.selectedIds.size} 项` });
    this.selectedIds = new Set();
    this.loadData();
  }

  async deleteAll() {
    await this.db.rssStarTable.deleteAll();
    UiUtil.showToast(this.getUIContext(), { message: '已清空所有收藏' });
    this.loadData();
  }

  async deleteGroup(group: string) {
    await this.db.rssStarTable.deleteByGroup(group);
    UiUtil.showToast(this.getUIContext(), { message: `已删除分组「${group}」所有项目` });
    if (this.currentGroup === group) this.currentGroup = '';
    this.loadData();
  }

  async addToGroup(id: string, newGroup: string) {
    const parts = id.split('|');
    const origin = parts[0];
    const link = parts[1];
    if (!origin || !link || !newGroup) return;
    const star = await this.db.rssStarTable.get(origin, link);
    if (star) {
      star.group = newGroup;
      await this.db.rssStarTable.update(star);
      this.loadData();
    }
  }

  async updateGroup(star: RssStar, newGroup: string) {
    star.group = newGroup;
    await this.db.rssStarTable.update(star);
    this.loadData();
  }

  async batchAddGroup(group: string) {
    for (const id of this.selectedIds) {
      await this.addToGroup(id, group);
    }
    this.selectedIds = new Set();
  }

  openRead(star: RssStar) {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/RssReadPage',
      params: {
        title: star.title,
        origin: star.origin,
        link: star.link,
      },
    });
  }

  groupActionDialog() {
    const msg = '当前: ' + (this.currentGroup || '全部') +
      '\n可用分组: ' + (this.groups.length > 0 ? this.groups.join(', ') : '无');
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '分组管理',
      message: msg,
      autoCancel: true,
      primaryButton: {
        value: '全部',
        action: () => this.setGroup(''),
      },
      cancel: () => {},
    });
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor('#0078D7')
          .onClick(() => UiUtil.back(this.getUIContext()))
        Text('收藏文章').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A1A')
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text(this.currentGroup || '全部分组').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent')
        .onClick(() => this.groupActionDialog())
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== 搜索栏 =====
      Search({ placeholder: '搜索收藏...', value: this.searchKey })
        .onSubmit((val) => this.search(val))
        .onChange((val) => { if (!val) this.search(''); })
        .width('100%').padding({ left: 12, right: 12, bottom: 8 })

      // ===== 选中操作栏 =====
      if (this.selectedIds.size > 0) {
        Row() {
          Text(`已选 ${this.selectedIds.size} 项`).fontSize(13).fontColor('#0078D7')
          Blank()
          Button({ type: ButtonType.Normal }) {
            Text('删除').fontSize(13).fontColor('#F44336')
          }.backgroundColor('transparent')
          .onClick(() => this.deleteSelected())
        }
        .width('100%').padding({ left: 12, right: 12, bottom: 4 })
      }

      // ===== 列表 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7')
      } else if (this.items.length === 0) {
        Column() {
          Text('暂无收藏').fontSize(14).fontColor(this.isDark ? '#AAA' : '#888')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.items, (star: RssStar) => {
              Row() {
                // 选择框（多选模式）
                if (this.selectedIds.size > 0) {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.selectedIds.has(star.origin + '|' + star.link) })
                    .onChange(() => this.toggleSelect(star.origin + '|' + star.link))
                }

                Column() {
                  Text(star.title).fontSize(15)
                    .fontColor(this.isDark ? '#E0E0E0' : '#333')
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (star.pubDate) {
                    Text(star.pubDate).fontSize(11)
                      .fontColor(this.isDark ? '#888' : '#AAA')
                      .margin({ top: 4 })
                  }
                  if (star.group && star.group !== '默认分组') {
                    Text(star.group).fontSize(10).fontColor('#0078D7')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .border({ radius: 4 }).borderColor('#0078D7').borderWidth(0.5)
                      .margin({ top: 4 })
                  }
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
                .margin({ left: 8 })

                Button({ type: ButtonType.Normal }) {
                  Text('阅读').fontSize(12).fontColor('#0078D7')
                }
                .backgroundColor('transparent')
                .onClick(() => this.openRead(star))
              }
              .padding(12)
              .borderRadius(8)
              .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
              .margin({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
              // 长按进入选择模式
              .gesture(LongPressGesture({ repeat: false, duration: 400 })
                .onAction(() => {
                  this.selectedIds = new Set([star.origin + '|' + star.link]);
                })
              )
            })
          }
          .width('100%')
        }
        .layoutWeight(1)
      }

      // ===== 底部操作 =====
      Row() {
        if (this.selectedIds.size > 0) {
          Button({ type: ButtonType.Normal }) {
            Text('取消选择').fontSize(13).fontColor('#0078D7')
          }
          .backgroundColor('transparent').onClick(() => this.clearSelection())
          Blank()
          Button({ type: ButtonType.Normal }) {
            Text('全选').fontSize(13).fontColor('#0078D7')
          }
          .backgroundColor('transparent').onClick(() => this.selectAll())
        }
      }
      .padding({ left: 16, right: 16, bottom: 12 })
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
