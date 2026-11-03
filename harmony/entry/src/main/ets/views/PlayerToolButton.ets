import { FOCUS_BOX } from '../common/Focus';

const BUTTON_DANGER = '#FF8A5C';

/**
 * 播放页底部工具条上的一个按钮：图标在上、文字在下。
 * 用 @Component + @Prop 而不是 @Builder：@Builder 按值传入的图标和文字不会随状态刷新
 * （例如声音按钮点了之后要立刻换成静音图标）。
 */
@Component
export struct PlayerToolButton {
  @Prop icon: Resource = $r('sys.symbol.xmark');
  @Prop label: string = '';
  @Prop danger: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Column({ space: 2 }) {
      SymbolGlyph(this.icon).fontSize(20).fontColor([this.danger ? BUTTON_DANGER : Color.White])
      Text(this.label).fontSize(10).fontColor(this.danger ? BUTTON_DANGER : '#CCFFFFFF')
    }
    .width(58)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .focusable(true)
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.onTap();
    })
    .accessibilityText(this.label)
  }
}
