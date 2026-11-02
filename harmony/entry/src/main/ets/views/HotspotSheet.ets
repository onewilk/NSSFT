import { promptAction } from '@kit.ArkUI';
import { checkHotspotConfig, HotspotService, randomPassphrase } from '../common/HotspotService';
import { tr } from '../common/I18n';
import { hotspotSupported } from '../common/Prefs';
import { FOCUS_BOX } from '../common/Focus';
import { Card, SettingRow, TipBar } from './Widgets';

/**
 * 游戏机专用热点的配置面板：首页“专用热点”卡片点开后从底部弹出（作为 bindSheet 的内容）。
 * 一屏里放开关和状态、当前网络名和密码、自定义网络名和密码、打开 App 时自动开启。
 * 标题栏自己画：没改动时右上角是关闭；改了网络名或密码就变成醒目的“保存”（不会被软键盘挡住）。
 */
@Component
export struct HotspotSheet {
  @StorageProp('hs.on') on: boolean = false;
  @StorageProp('hs.busy') busy: boolean = false;
  @StorageProp('hs.summary') summary: string = '';
  @StorageProp('hs.detail') detail: string = '';
  @StorageProp('hs.warn') warn: string = '';
  @StorageLink('nssft.hotspotSsid') ssid: string = 'DIRECT-NSSFT';
  @StorageLink('nssft.hotspotPass') pass: string = '';
  @StorageLink('nssft.hotspotAuto') auto: boolean = false;
  // 编辑中的草稿，点右上角“保存”才生效；直接关掉弹框则放弃修改
  @State draftSsid: string = '';
  @State draftPass: string = '';
  @State draftError: string = '';
  @State showPass: boolean = false;
  /** 关闭弹框（由首页把 bindSheet 的开关置回 false） */
  onClose: () => void = () => {
  };
  private supported: boolean = hotspotSupported();

  aboutToAppear(): void {
    this.draftSsid = this.ssid;
    this.draftPass = this.pass;
  }

  /** 网络名或密码改过（和已保存的不一样）：右上角的关闭按钮变成“保存” */
  private dirty(): boolean {
    return this.draftSsid.trim() !== this.ssid || this.draftPass !== this.pass;
  }

  private async save(): Promise<void> {
    const ssid = this.draftSsid.trim();
    const invalid = checkHotspotConfig(ssid, this.draftPass);
    if (invalid.length > 0) {
      this.draftError = invalid;
      return;
    }
    const changed = ssid !== this.ssid || this.draftPass !== this.pass;
    this.ssid = ssid;
    this.pass = this.draftPass;
    this.draftSsid = ssid;
    this.onClose();
    if (changed && this.on) {
      const err = await HotspotService.get().restart();
      promptAction.showToast({
        message: err.length > 0 ? tr('cfg_hs_rebuild_failed', err) : tr('cfg_hs_rebuilt'),
        duration: 3000
      });
    }
  }

  private toggle(isOn: boolean): void {
    if (isOn) {
      HotspotService.get().start().then((err: string) => {
        if (err.length > 0) {
          promptAction.showToast({ message: err, duration: 3000 });
        }
      });
    } else {
      HotspotService.get().stop();
    }
  }

  @Builder
  Header() {
    Row() {
      Text(tr('home_hotspot'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.dirty()) {
        Button(tr('cfg_hs_save'), { type: ButtonType.Capsule })
          .height(36)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 18, right: 18 })
          .backgroundColor($r('app.color.accent'))
          .focusBox(FOCUS_BOX)
          .onClick(() => {
            this.save();
          })
      } else {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.chip_bg'))
        .accessibilityText(tr('cfg_hs_close'))
        .focusable(true)
        .focusBox(FOCUS_BOX)
        .onClick(() => {
          this.onClose();
        })
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
  }

  // 开关和状态：没开时说明是什么，开着时显示运行状态；本机不支持时开关置灰并写明原因
  @Builder
  SwitchCard() {
    Card() {
      SettingRow({
        title: tr('cfg_hs_title'),
        desc: this.on || this.busy ? this.summary : tr('cfg_hs_desc'),
        unsupported: this.supported ? '' : tr('home_hotspot_unsupported'),
        icon: $r('sys.symbol.hotspot')
      }) {
        if (this.busy) {
          LoadingProgress().width(28).height(28).color($r('app.color.accent')).focusable(false)
        } else {
          Toggle({ type: ToggleType.Switch, isOn: this.on })
            .onChange((isOn: boolean) => {
              this.toggle(isOn);
            })
        }
      }
      if (!this.on && !this.busy && this.summary.length > 0 && this.summary !== tr('hs_closed')) {
        Text(this.summary).fontSize(12).fontColor($r('app.color.warn'))
      }
      if (this.warn.length > 0) {
        TipBar({ text: this.warn, warn: true })
      }
    }
  }

  // 正在运行的热点：网络名、密码和信道等，可以长按复制
  @Builder
  CurrentInfo() {
    Card({ title: tr('cfg_hs_current') }) {
      Text(`${tr('cfg_hs_ssid_line', this.ssid)}\n${tr('cfg_hs_pass_line', this.pass)}\n${this.detail}`)
        .fontSize(13)
        .lineHeight(21)
        .fontColor($r('app.color.text_primary'))
        .copyOption(CopyOptions.LocalDevice)
    }
  }

  // 自定义网络名和密码：没开热点时也能先改好
  @Builder
  EditCard() {
    Card({ title: tr('cfg_hs_custom_title') }) {
      // 关掉系统自动填充：否则密码保险箱会把“网络名 + 密码”当成登录表单弹出填充和人脸验证
      TextInput({ text: this.draftSsid, placeholder: tr('cfg_hs_ssid_hint') })
        .height(44)
        .fontSize(16)
        .placeholderFont({ size: 16 })
        .enableAutoFill(false)
        .onChange((v: string) => {
          this.draftSsid = v;
          this.draftError = '';
        })
      Row({ space: 8 }) {
        TextInput({ text: this.draftPass, placeholder: tr('cfg_hs_pass_hint') })
          .type(this.showPass ? InputType.Normal : InputType.Password)
          .showPasswordIcon(true)
          .maxLength(63)
          .height(44)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .layoutWeight(1)
          .enableAutoFill(false)
          .onChange((v: string) => {
            this.draftPass = v;
            this.draftError = '';
          })
        Button(tr('cfg_hs_random'))
          .height(40)
          .fontSize(13)
          .focusBox(FOCUS_BOX)
          .onClick(() => {
            this.draftPass = randomPassphrase();
            this.showPass = true;
          })
      }
      .width('100%')
      if (this.draftError.length > 0) {
        Text(this.draftError).fontSize(12).fontColor($r('app.color.warn'))
      } else if (this.dirty()) {
        Text(tr('cfg_hs_unsaved')).fontSize(12).fontColor($r('app.color.accent'))
      } else {
        Text(tr('cfg_hs_edit_note')).fontSize(12).fontColor($r('app.color.text_tertiary'))
      }
    }
  }

  build() {
    Column() {
      this.Header()
      Scroll() {
        Column({ space: 16 }) {
          this.SwitchCard()
          if (this.on && this.detail.length > 0) {
            this.CurrentInfo()
          }
          this.EditCard()
          Card() {
            SettingRow({
              title: tr('cfg_hs_auto_title'),
              desc: tr('cfg_hs_auto_desc'),
              unsupported: this.supported ? '' : tr('home_hotspot_unsupported'),
              icon: $r('sys.symbol.power')
            }) {
              Toggle({ type: ToggleType.Switch, isOn: this.auto })
                .onChange((isOn: boolean) => {
                  this.auto = isOn;
                })
            }
          }
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }
}
