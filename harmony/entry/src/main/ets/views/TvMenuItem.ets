import { KeyCode } from '@kit.InputKit';
import { FOCUS_BOX } from '../common/Focus';

const ITEM_ACCENT = '#26C6B0';
const ITEM_DANGER = '#FF8A5C';

/**
 * 播放菜单（右侧侧滑菜单，各种设备共用）里的一行：图标 + 标题（+ 说明）+ 右侧当前值或箭头。
 * 触屏设备用紧凑的行高（compact），手机横屏一屏放得下整个一级菜单。
 * 用透明 Button 承载：Row/Column 拿不到遥控器焦点。注意别给这个 Button 写 .focusable(true)：
 * 显式写了反而在焦点树里变成不可获焦（智慧屏上遥控器进不了菜单）。
 * 有多个取值的选项（画质增强、屏幕方向）点进二级页单选，选中的一项用 checked 打勾。
 */
@Component
export struct TvMenuItem {
  @Prop label: string = '';
  @Prop desc: string = '';
  /** 右侧显示的当前值，空串不显示 */
  @Prop value: string = '';
  /** 当前值是否处于“开启”状态（用强调色显示；toggle 时就是开关的状态） */
  @Prop valueOn: boolean = false;
  /** 开关项：右侧画一个开关（跟着 valueOn），不显示文字值；点整行切换 */
  @Prop toggle: boolean = false;
  /** 单选列表（二级选择页）里选中的那一项：右侧画一个勾 */
  @Prop checked: boolean = false;
  /** 进入下一级时显示右箭头 */
  @Prop chevron: boolean = false;
  @Prop danger: boolean = false;
  /** 现在用不了：置灰、点不动（原因写在 desc 里） */
  @Prop disabled: boolean = false;
  /** 给焦点控制用的组件 id */
  @Prop itemId: string = '';
  /** 紧凑行高（触屏设备） */
  @Prop compact: boolean = false;
  icon: Resource | null = null;
  onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        if (this.icon !== null) {
          SymbolGlyph(this.icon)
            .fontSize(this.compact ? 20 : 22)
            .fontColor([this.danger ? ITEM_DANGER : Color.White])
        }
        Column({ space: 2 }) {
          Text(this.label)
            .fontSize(this.compact ? 15 : 16)
            .fontColor(this.danger ? ITEM_DANGER : Color.White)
          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize(12)
              .fontColor('#99FFFFFF')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.toggle) {
          // 只是显示：点击和遥控器焦点都交给整行的 Button
          Toggle({ type: ToggleType.Switch, isOn: this.valueOn })
            .selectedColor(ITEM_ACCENT)
            .hitTestBehavior(HitTestMode.None)
            .focusable(false)
        } else if (this.value.length > 0) {
          Text(this.value)
            .fontSize(14)
            .fontColor(this.valueOn ? ITEM_ACCENT : '#B3FFFFFF')
        }
        if (this.checked) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(18)
            .fontColor([ITEM_ACCENT])
        }
        if (this.chevron) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor(['#99FFFFFF'])
        }
      }
      .width('100%')
      .padding({ left: this.compact ? 12 : 16, right: this.compact ? 12 : 16, top: this.compact ? 8 : 12,
        bottom: this.compact ? 8 : 12 })
    }
    .width('100%')
    .height('auto')
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    .stateStyles({
      normal: {
        .backgroundColor(Color.Transparent)
      },
      focused: {
        .backgroundColor('#33FFFFFF')
      },
      pressed: {
        .backgroundColor('#26FFFFFF')
      }
    })
    .focusBox(FOCUS_BOX)
    .enabled(!this.disabled)
    .opacity(this.disabled ? 0.45 : 1)
    .id(this.itemId)
    .accessibilityText(this.value.length > 0 ? `${this.label} ${this.value}` : this.label)
    .onClick(() => {
      this.onTap();
    })
    .onKeyEvent((event: KeyEvent) => {
      // 遥控器的确认键：按钮默认只认回车，确认键要自己处理（松开时触发，按住不放不会重复）
      if (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
        if (event.type === KeyType.Up) {
          this.onTap();
        }
        event.stopPropagation();
      }
    })
  }
}
