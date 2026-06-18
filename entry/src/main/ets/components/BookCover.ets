/**
 * 书籍封面组件
 *
 * 优先加载网络封面图，加载失败时降级显示首字母色块
 * 用于书架列表/网格和搜索结果
 */
@Component
export struct BookCover {
  @Prop name: string = '';
  @Prop coverUrl: string = '';
  @Prop coverWidth: number = 52;
  @Prop coverHeight: number = 70;
  @State imgFailed: boolean = false;

  build() {
    Stack() {
      // 降级色块（始终渲染）
      Column() {
        Text(this.name ? this.name.charAt(0) : '?')
          .fontSize(this.coverWidth > 50 ? 22 : 18)
          .fontColor('#FFF').fontWeight(FontWeight.Bold)
      }
      .width(this.coverWidth).height(this.coverHeight)
      .backgroundColor(this.getCoverColor(this.name))
      .borderRadius(6)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

      // 网络封面
      if (this.coverUrl && !this.imgFailed) {
        Image(this.coverUrl)
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.imgFailed = true;
          })
      }
    }
    .width(this.coverWidth).height(this.coverHeight)
  }

  private getCoverColor(name: string): string {
    const colors = ['#455A64', '#5C6BC0', '#26A69A', '#EC407A', '#AB47BC',
      '#42A5F5', '#66BB6A', '#FF7043', '#8D6E63', '#78909C', '#7E57C2', '#29B6F6'];
    if (!name) return colors[0];
    return colors[name.charCodeAt(0) % colors.length];
  }
}
