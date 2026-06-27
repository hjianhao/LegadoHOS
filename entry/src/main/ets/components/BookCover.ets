/**
 * 书籍封面组件
 */
@Component
export struct BookCover {
  @Prop name: string = '';
  @Prop coverUrl: string = '';
  @Prop coverWidth: number = 52;
  @Prop coverHeight: number = 70;
  @State imgFailed: boolean = false;
  @State useNetwork: boolean = true;

  aboutToAppear(): void {
    // 过滤无效封面 URL（数字、空、非 http/data 开头）
    if (this.coverUrl && !/^(https?:\/\/|\/\/|data:)/.test(this.coverUrl)) {
      this.coverUrl = '';
    }
    this.useNetwork = !!this.coverUrl;
    console.info('[BookCover] init name=' + (this.name||'').substring(0,10) + ' url=' + (this.coverUrl||'').substring(0,50));
  }

  build() {
    Stack() {
      // 降级色块
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
      if (this.useNetwork && this.coverUrl && !this.imgFailed) {
        Image(this.coverUrl)
          .width(this.coverWidth).height(this.coverHeight)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .onError((err: ImageError) => {
            console.warn('[BookCover] img failed url=' + (this.coverUrl||'').substring(0,50) + ' err=' + (err?.message || ''));
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
