// 各页面共用的小组件：分组、设置行、提示条、标签。整体风格是“分组列表”：组标题在卡片外面，
// 行首图标放在浅色圆角方块里
import { FOCUS_BOX } from '../common/Focus';

@Builder
function emptyBuilder() {
}

/** 行首图标：浅色圆角方块里的符号图标 */
@Builder
export function IconTile(icon: Resource, dim: boolean) {
  Row() {
    SymbolGlyph(icon).fontSize(18).fontColor([$r('app.color.accent')])
  }
  .width(32)
  .height(32)
  .borderRadius(9)
  .justifyContent(FlexAlign.Center)
  .backgroundColor($r('app.color.accent_soft'))
  .opacity(dim ? 0.4 : 1)
}

/**
 * 能用键盘选中的点击区域。Row、Column 这类容器没有可获焦的子组件时不能获焦，
 * 所以套在透明的 Button 里：Button 能获焦，按确认键也会触发点击；焦点框用 FOCUS_BOX，触屏上看不到
 */
@Component
export struct Tappable {
  @BuilderParam content: () => void = emptyBuilder;
  radius: number = 14;
  @Prop isDefaultFocus: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      this.content()
    }
    .width('100%')
    .height('auto')
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(this.radius)
    .focusBox(FOCUS_BOX)
    .defaultFocus(this.isDefaultFocus)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 分组：组标题和说明在外面，内容放在圆角面板里 */
@Component
export struct Card {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  /** 整组的标签（如“测试中”“实验性”），显示在分组标题行最右边 */
  @Prop tag: string = '';
  @BuilderParam content: () => void = emptyBuilder;

  build() {
    Column({ space: 8 }) {
      if (this.title.length > 0) {
        Column({ space: 2 }) {
          Row({ space: 8 }) {
            Text(this.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.accent'))
              .layoutWeight(1)
            if (this.tag.length > 0) {
              Chip({ text: this.tag })
            }
          }
          .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 4, right: 4 })
      }
      Column({ space: 12 }) {
        this.content()
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(20)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 设置行：左边图标方块 + 标题 + 说明，右边控件由尾随闭包提供（开关、下拉框等） */
@Component
export struct SettingRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  /**
   * 本机不支持时的原因：这一项照常显示（让用户知道 App 有这个功能），原因用警示色写在说明下面，
   * 右侧控件置灰、不可操作
   */
  @Prop unsupported: string = '';
  @Prop scope: string = '';
  icon: Resource | null = null;
  @BuilderParam trailing: () => void = emptyBuilder;

  build() {
    Row({ space: 12 }) {
      if (this.icon !== null) {
        IconTile(this.icon, this.unsupported.length > 0)
      }
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(this.title)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          if (this.scope.length > 0) {
            Chip({ text: this.scope })
          }
        }
        .opacity(this.unsupported.length > 0 ? 0.6 : 1)
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .opacity(this.unsupported.length > 0 ? 0.6 : 1)
        }
        if (this.unsupported.length > 0) {
          Text(this.unsupported)
            .fontSize(12)
            .fontColor($r('app.color.warn'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 系统的下拉框禁用后看不出变化，统一再调淡一些
      Row() {
        this.trailing()
      }
      .enabled(this.unsupported.length === 0)
      .opacity(this.unsupported.length > 0 ? 0.5 : 1)
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
  }
}

/** 提示条：左侧一道色条；青绿是建议，橙红是警告 */
@Component
export struct TipBar {
  @Prop text: string = '';
  @Prop warn: boolean = false;
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      Column()
        .width(3)
        .alignSelf(ItemAlign.Stretch)
        .borderRadius(2)
        .backgroundColor(this.warn ? $r('app.color.warn') : $r('app.color.accent'))
      Column({ space: 4 }) {
        Text(this.text)
          .fontSize(13)
          .lineHeight(20)
          .fontColor(this.warn ? $r('app.color.warn') : $r('app.color.tip_text'))
        if (this.actionText.length > 0) {
          Text(this.actionText)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
            .focusable(true)
            .focusBox(FOCUS_BOX)
            .onClick(() => {
              this.onAction();
            })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: 10, right: 12, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor(this.warn ? $r('app.color.warn_bg') : $r('app.color.tip_bg'))
  }
}

/** 小标签：描边样式，accent 时填充 */
@Component
export struct Chip {
  @Prop text: string = '';
  @Prop accent: boolean = false;

  build() {
    Text(this.text)
      .fontSize(11)
      .fontColor(this.accent ? $r('app.color.on_accent') : $r('app.color.accent'))
      .backgroundColor(this.accent ? $r('app.color.accent') : Color.Transparent)
      .border({ width: this.accent ? 0 : 1, color: $r('app.color.card_outline') })
      .padding({ left: 7, right: 7, top: 1, bottom: 1 })
      .borderRadius(6)
  }
}

/** 编号步骤（使用说明页）：圆角方块里的序号 + 文字 */
@Component
export struct Step {
  @Prop index: number = 1;
  @Prop text: string = '';

  build() {
    Row({ space: 12 }) {
      Text(`${this.index}`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.accent_soft'))
        .width(24)
        .height(24)
        .borderRadius(7)
        .textAlign(TextAlign.Center)
      Text(this.text)
        .fontSize(14)
        .lineHeight(22)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .focusable(true)
        .focusBox(FOCUS_BOX)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }
}

/** 可点击的跳转行：图标方块 + 标题 + 说明 + 右箭头（或外链箭头） */
@Component
export struct NavRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop external: boolean = false;
  icon: Resource | null = null;
  onTap: () => void = () => {
  };

  build() {
    Tappable({ onTap: this.onTap }) {
      Row({ space: 12 }) {
        if (this.icon !== null) {
          IconTile(this.icon, false)
        }
        Column({ space: 2 }) {
          Text(this.title).fontSize(15).fontColor($r('app.color.text_primary'))
          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph(this.external ? $r('sys.symbol.arrow_up_right') : $r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .constraintSize({ minHeight: 48 })
    }
  }
}

/** 播放菜单（深色、半透明）里的一组选项：可选的小标题（和标签），下面是半透明圆角底的一组行 */
@Component
export struct MenuGroup {
  @Prop title: string = '';
  @Prop tag: string = '';
  @BuilderParam content: () => void = emptyBuilder;

  build() {
    Column({ space: 6 }) {
      if (this.title.length > 0) {
        Row({ space: 6 }) {
          Text(this.title).fontSize(12).fontColor('#99FFFFFF')
          if (this.tag.length > 0) {
            Text(this.tag)
              .fontSize(10)
              .fontColor('#FFB74D')
              .border({ width: 1, color: '#80FFB74D' })
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(6)
          }
        }
        .padding({ left: 4 })
      }
      Column() {
        this.content()
      }
      .width('100%')
      .padding({ left: 12, right: 8, top: 2, bottom: 2 })
      .backgroundColor('#14FFFFFF')
      .borderRadius(14)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
