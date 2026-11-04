// 触屏手柄键位管理（设置 → 手柄 → 触屏手柄键位）：横屏、竖屏、分离三种摆法各一组。
// 每组第一项是内置键位（按屏幕实时计算，不能改，只能复制），后面是自建键位：点一行设为当前，可以编辑、改名、复制、删除。
// 新建时选一个现有键位做底；编辑在全屏的编辑界面里做（播放页负责，会转到这种摆法的方向）。
// 竖屏和分离只在宽屏状态（阔折叠、折叠屏展开等）下能用：不是宽屏时照常列出、置灰并写明原因。
import { promptAction } from '@kit.ArkUI';
import { FOCUS_BOX } from '../common/Focus';
import { tr } from '../common/I18n';
import {
  activeLayoutId, createLayout, deleteLayout, getLayout, isWideScreen, layoutNameTaken, listLayouts, PadLayout,
  renameLayout, setActiveLayout, suggestLayoutName, UnitSave, VPAD_LAYOUTS_EPOCH, VPAD_MODES, VpadMode, vpadModeLabel
} from '../common/VpadLayouts';
import { TextPromptDialog } from './TextPromptDialog';
import { VirtualPad } from './VirtualPad';
import { Card } from './Widgets';

// 缩略图的高度和最大宽度：页面窄（手机竖着拿）时小一些，给名字留地方
const THUMB_H = 84;
const THUMB_MAX_W = 170;
const THUMB_H_NARROW = 52;
const THUMB_MAX_W_NARROW = 104;

/** 一个键位的缩略图：示意画面 + 按键，按本机屏幕（这种摆法的方向）排好再缩小 */
@Component
struct LayoutThumb {
  @Prop mode: string = 'landscape';
  @Prop layoutId: string = '';
  @Prop layoutKey: string = '';
  @Prop screenW: number = 800;
  @Prop screenH: number = 360;
  @Prop sizeLevel: number = 1;
  @Prop narrow: boolean = false;

  private shortSide(): number {
    return Math.max(1, Math.min(this.screenW, this.screenH));
  }

  private longSide(): number {
    return Math.max(1, Math.max(this.screenW, this.screenH));
  }

  // 这种摆法下整块屏幕的大小（vp）
  private refW(): number {
    return this.mode === 'landscape' ? this.longSide() : this.shortSide();
  }

  private refH(): number {
    return this.mode === 'landscape' ? this.shortSide() : this.longSide();
  }

  private thumbW(): number {
    const h = this.narrow ? THUMB_H_NARROW : THUMB_H;
    return Math.min(this.narrow ? THUMB_MAX_W_NARROW : THUMB_MAX_W, h * this.refW() / this.refH());
  }

  private thumbH(): number {
    return this.thumbW() * this.refH() / this.refW();
  }

  // 示意画面：横屏时铺满（按实际比例画会在两边留黑边，看着像没对齐）；竖屏是居中的 16:9，分离时 16:9 贴顶
  private picW(): number {
    return this.mode === 'landscape' ? this.thumbW() : Math.min(this.thumbW(), this.thumbH() * 16 / 9);
  }

  private picH(): number {
    return this.mode === 'landscape' ? this.thumbH() : this.picW() * 9 / 16;
  }

  build() {
    Stack({ alignContent: this.mode === 'split' ? Alignment.Top : Alignment.Center }) {
      Column()
        .width(this.picW())
        .height(this.picH())
        .backgroundColor('#3326C6B0')
      if (this.mode === 'split') {
        VirtualPad({
          preview: true,
          split: true,
          refW: this.refW(),
          refH: this.refH() - this.refW() * 9 / 16,
          layoutId: this.layoutId,
          layoutKey: this.layoutKey,
          sizeLevel: this.sizeLevel,
          interactive: false
        })
          .width(this.thumbW())
          .height(this.thumbH() - this.picH())
          .position({ x: 0, y: this.picH() })
      } else {
        VirtualPad({
          preview: true,
          split: false,
          refW: this.refW(),
          refH: this.refH(),
          layoutId: this.layoutId,
          layoutKey: this.layoutKey,
          sizeLevel: this.sizeLevel,
          interactive: false
        })
          .width(this.thumbW())
          .height(this.thumbH())
      }
    }
    .width(this.thumbW())
    .height(this.thumbH())
    .backgroundColor('#FF0E1414')
    .borderRadius(6)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}

@Component
export struct VpadLayoutsView {
  @StorageProp(VPAD_LAYOUTS_EPOCH) epoch: number = 0;
  @StorageProp('nssft.vpadActive') activeRaw: string = '';
  @StorageProp('ui.screenW') screenW: number = 800;
  @StorageProp('ui.screenH') screenH: number = 360;
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  @StorageProp('nssft.vpadSize') sizeLevel: number = 1;
  /** 编辑一个自建键位（全屏编辑界面由播放页负责） */
  onEdit: (id: string, mode: string) => void = () => {
  };
  private promptController: CustomDialogController | null = null;

  private supported(mode: string): boolean {
    return mode === 'landscape' || isWideScreen(this.screenW, this.screenH);
  }

  private layouts(mode: string): PadLayout[] {
    return this.epoch >= 0 ? listLayouts(mode) : [];
  }

  private isActive(mode: string, id: string): boolean {
    return this.epoch >= 0 && this.activeRaw.length >= 0 && activeLayoutId(mode) === id;
  }

  private askName(title: string, initial: string, mode: string, exceptId: string, ok: (name: string) => void): void {
    this.promptController = new CustomDialogController({
      builder: TextPromptDialog({
        title: title,
        placeholder: tr('vpad_layout_name_placeholder'),
        confirmText: tr('common_save'),
        text: initial,
        numeric: false,
        onConfirm: (value: string): string => {
          if (value.length === 0) {
            return tr('vpad_layout_name_empty');
          }
          if (layoutNameTaken(mode, value, exceptId)) {
            return tr('vpad_layout_name_taken');
          }
          ok(value);
          return '';
        }
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      autoCancel: true
    });
    this.promptController.open();
  }

  // 以一个键位为底新建（base 空串：内置），设为当前；这种摆法能用时直接进编辑
  private createFrom(mode: string, base: string): void {
    const src = getLayout(base);
    const units: UnitSave[] = src !== undefined ? src.units.map((u: UnitSave): UnitSave => {
      const c: UnitSave = { id: u.id, x: u.x, y: u.y, s: u.s, h: u.h };
      return c;
    }) : [];
    this.askName(tr('vpad_layout_new_title'), suggestLayoutName(mode), mode, '', (name: string) => {
      const id = createLayout(mode, name, units);
      setActiveLayout(mode, id);
      if (this.supported(mode)) {
        this.onEdit(id, mode);
      }
    });
  }

  private rename(l: PadLayout): void {
    this.askName(tr('vpad_layout_rename_title'), l.name, l.mode, l.id, (name: string) => {
      renameLayout(l.id, name);
    });
  }

  private confirmDelete(l: PadLayout): void {
    promptAction.showDialog({
      title: tr('vpad_layout_delete_title'),
      message: tr('vpad_layout_delete_message', l.name),
      buttons: [
        { text: tr('common_cancel'), color: '#99000000' },
        { text: tr('vpad_layout_delete'), color: '#E5484D' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        deleteLayout(l.id);
      }
    }).catch(() => {
    });
  }

  // “新建”：选一个现有键位做底
  private newMenu(mode: string): MenuElement[] {
    const items: MenuElement[] = [{
      value: tr('vpad_layout_new_from', tr('vpad_builtin')),
      action: () => {
        this.createFrom(mode, '');
      }
    }];
    for (const l of this.layouts(mode)) {
      const item: MenuElement = {
        value: tr('vpad_layout_new_from', l.name),
        action: () => {
          this.createFrom(mode, l.id);
        }
      };
      items.push(item);
    }
    return items;
  }

  private moreMenu(l: PadLayout): MenuElement[] {
    return [
      {
        value: tr('vpad_layout_rename'), action: () => {
        this.rename(l);
      }
      },
      {
        value: tr('vpad_layout_copy'), action: () => {
        this.createFrom(l.mode, l.id);
      }
      },
      {
        value: tr('vpad_layout_delete'), action: () => {
        this.confirmDelete(l);
      }
      }
    ];
  }

  @Builder
  Tag(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor($r('app.color.accent'))
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor($r('app.color.accent_soft'))
      .flexShrink(0)
  }

  // 一行的操作：内置键位“复制”，自建键位“编辑”和更多菜单
  @Builder
  Actions(mode: string, l: PadLayout | null) {
    if (l === null) {
      Button(tr('vpad_layout_copy'))
        .fontSize(13)
        .height(32)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.accent_soft'))
        .focusBox(FOCUS_BOX)
        .onClick(() => {
          this.createFrom(mode, '');
        })
    } else {
      Button(tr('vpad_layout_edit'))
        .fontSize(13)
        .height(32)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.accent_soft'))
        .enabled(this.supported(mode))
        .focusBox(FOCUS_BOX)
        .onClick(() => {
          this.onEdit(l.id, mode);
        })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.dot_grid_2x2')).fontSize(18).fontColor([$r('app.color.text_secondary')])
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .focusBox(FOCUS_BOX)
      .bindMenu(this.moreMenu(l))
      .accessibilityText(tr('vpad_layout_more'))
    }
  }

  // 一行：缩略图、名字（当前在用的有标记）、操作；点一行设为当前。
  // 窄屏（手机竖屏）放不下右边的按钮，名字和说明会被挤掉，操作就放到说明下面
  @Builder
  LayoutRow(mode: string, l: PadLayout | null) {
    Row({ space: 12 }) {
      LayoutThumb({
        mode: mode,
        layoutId: l !== null ? l.id : '',
        layoutKey: `${l !== null ? l.id : ''}|${this.epoch}|${this.screenW}x${this.screenH}|${this.sizeLevel}`,
        screenW: this.screenW,
        screenH: this.screenH,
        sizeLevel: this.sizeLevel,
        narrow: this.screenW < 520
      })
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(l !== null ? l.name : tr('vpad_builtin'))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.isActive(mode, l !== null ? l.id : '')) {
            this.Tag(tr('vpad_current_tag'))
          }
        }
        // 限宽：名字太长时省略，不把“当前”标记挤到右边的按钮上
        .width('100%')
        Text(l === null ? tr('vpad_layout_builtin_desc') :
          this.isActive(mode, l.id) ? tr('vpad_layout_custom_active_desc') : tr('vpad_layout_custom_desc'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.screenW < 520) {
          Row({ space: 8 }) {
            this.Actions(mode, l)
          }
          .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.screenW >= 520) {
        this.Actions(mode, l)
      }
    }
    .width('100%')
    .alignItems(this.screenW < 520 ? VerticalAlign.Top : VerticalAlign.Center)
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      if (this.supported(mode)) {
        setActiveLayout(mode, l !== null ? l.id : '');
      }
    })
  }

  @Builder
  ModeCard(mode: VpadMode) {
    Card({ title: vpadModeLabel(mode), subtitle: this.supported(mode) ? '' : tr('vpad_wide_only') }) {
      Column({ space: 4 }) {
        this.LayoutRow(mode, null)
        ForEach(this.layouts(mode), (l: PadLayout) => {
          this.LayoutRow(mode, l)
        }, (l: PadLayout) => `${l.id}|${l.name}|${l.updated}|${this.epoch}|${this.activeRaw}`)

        Button(tr('vpad_layout_new'))
          .fontSize(14)
          .height(36)
          .margin({ top: 4 })
          .fontColor($r('app.color.accent'))
          .backgroundColor($r('app.color.accent_soft'))
          .focusBox(FOCUS_BOX)
          .bindMenu(this.newMenu(mode))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .opacity(this.supported(mode) ? 1 : 0.55)
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        ForEach(VPAD_MODES, (mode: VpadMode) => {
          this.ModeCard(mode)
        }, (mode: VpadMode) => `${mode}|${this.epoch}|${this.activeRaw}|${this.screenW}x${this.screenH}`)

        Text(tr('vpad_layouts_note'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 4, right: 4 })
      }
      .padding({ left: 16, right: 16, top: 8, bottom: this.safeBottom + 24 })
      .constraintSize({ maxWidth: 720 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
