// 使用说明：三步准备 + 三步连接 + SFT 设置要点 + 画质说明 + 常见问题。
// 要点和问题都是点标题才展开，一屏能看到全部条目
import { common, Want } from '@kit.AbilityKit';
import { tr } from '../common/I18n';
import { SFT_PROJECT_URL } from '../common/Prefs';
import { FOCUS_BOX } from '../common/Focus';
import { Card, Step, TipBar } from './Widgets';

interface Fold {
  title: string;
  body: string;
}

function fold(title: string, body: string): Fold {
  const item: Fold = { title: title, body: body };
  return item;
}

@Component
export struct GuideView {
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  // 展开的条目：'tip-0' / 'faq-2' 这样的键，空串表示都收起
  @State openKey: string = '';

  // SFT 端各选项生效的条件（来自 SFT 的说明和实测），用户最常卡住的几项
  private sftTips(): Fold[] {
    return [
      fold(tr('guide_sft_usb_title'), tr('guide_sft_usb_body')),
      fold(tr('guide_sft_one_title'), tr('guide_sft_one_body')),
      fold(tr('guide_sft_mem_title'), tr('guide_sft_mem_body')),
      fold(tr('guide_sft_1080_title'), tr('guide_sft_1080_body')),
      fold(tr('guide_sft_60_title'), tr('guide_sft_60_body')),
      fold(tr('guide_sft_sound_title'), tr('guide_sft_sound_body')),
      fold(tr('guide_sft_cheat_title'), tr('guide_sft_cheat_body'))
    ];
  }

  private faqs(): Fold[] {
    return [
      fold(tr('guide_faq_q1'), tr('guide_faq_a1')),
      fold(tr('guide_faq_q2'), tr('guide_faq_a2')),
      fold(tr('guide_faq_q3'), tr('guide_faq_a3')),
      fold(tr('guide_faq_q4'), tr('guide_faq_a4')),
      fold(tr('guide_faq_q5'), tr('guide_faq_a5'))
    ];
  }

  private openUrl(url: string): void {
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: url };
    (getContext(this) as common.UIAbilityContext).startAbility(want).catch(() => {
    });
  }

  // 可展开的一条：标题 + 箭头，展开后显示正文。直接读 this.openKey（@Builder 按值传入的参数不会随状态刷新）
  @Builder
  FoldRow(item: Fold, key: string) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        SymbolGlyph(this.openKey === key ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      if (this.openKey === key) {
        Text(item.body)
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .focusable(true)
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.openKey = this.openKey === key ? '' : key;
    })
  }

  @Builder
  FoldList(items: Fold[], prefix: string) {
    ForEach(items, (item: Fold, index: number) => {
      this.FoldRow(item, `${prefix}-${index}`)
      if (index < items.length - 1) {
        Divider().color($r('app.color.divider'))
      }
    }, (item: Fold) => item.title)
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Card({ title: tr('guide_prepare_title') }) {
          Step({ index: 1, text: tr('guide_prepare_step1') })
          Step({ index: 2, text: tr('guide_prepare_step2') })
          Step({ index: 3, text: tr('guide_prepare_step3') })
          Text(tr('guide_open_sft'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
            .focusable(true)
            .focusBox(FOCUS_BOX)
            .onClick(() => {
              this.openUrl(SFT_PROJECT_URL);
            })
        }

        Card({ title: tr('guide_connect_title') }) {
          Step({ index: 1, text: tr('guide_connect_step1') })
          Step({ index: 2, text: tr('guide_connect_step2') })
          Step({ index: 3, text: tr('guide_connect_step3') })
        }

        Card({ title: tr('guide_sft_title'), subtitle: tr('guide_sft_intro') }) {
          this.FoldList(this.sftTips(), 'tip')
        }

        Card({ title: tr('guide_quality_title') }) {
          Text(tr('guide_quality_body'))
            .fontSize(14)
            .lineHeight(22)
            .fontColor($r('app.color.text_primary'))
          TipBar({ text: tr('guide_quality_tip') })
        }

        Card({ title: tr('guide_faq_title') }) {
          this.FoldList(this.faqs(), 'faq')
        }

        Text(tr('guide_disclaimer'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 4, right: 4 })
          .width('100%')
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
