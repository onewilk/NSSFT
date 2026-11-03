// 设置页：画面、声音、连接、外观四组，最后是帮助和关于。只在首页打开（不在播放中），改了下次连接生效；
// 播放中要即时调整的选项在播放页的快捷面板里
import { ConfigurationConstant } from '@kit.AbilityKit';
import { applyAppLanguage, notifyLanguageChanged, tr } from '../common/I18n';
import { PipSession } from '../common/PipSession';
import { enhanceAvailable, enhanceLabels } from '../common/Prefs';
import { recordQualityDesc, recordQualityLabels, recordSupport, recordUnsupportedReason } from '../common/Recording';
import {
  padAxisSupported, padDeadZoneLabels, padLayoutLabels, vpadAvailable, vpadOpacityLabels, vpadSizeLabels
} from '../common/Gamepad';
import { applyColorMode } from '../common/Theme';
import { isWideScreen } from '../common/VpadLayouts';
import { Card, NavRow, SettingRow } from './Widgets';

// 语言名称用各自语言书写，不随界面语言翻译（方便看不懂当前语言的用户找到自己的语言）
const LANGUAGE_NAMES: string[] = ['', '简体中文', '繁體中文', 'English'];

function options(labels: string[]): SelectOption[] {
  return labels.map((label: string): SelectOption => {
    const option: SelectOption = { value: label };
    return option;
  });
}

@Component
export struct SettingsView {
  @StorageLink('nssft.freezeOnLoss') freezeOnLoss: boolean = true;
  @StorageLink('nssft.enhanceLevel') enhanceLevel: number = 0;
  @StorageLink('nssft.showStats') showStats: boolean = false;
  @StorageLink('nssft.lowRefresh') lowRefresh: boolean = true;
  @StorageLink('nssft.enableAudio') enableAudio: boolean = true;
  @StorageLink('nssft.netOpt') netOpt: boolean = true;
  @StorageLink('nssft.pipAuto') pipAuto: boolean = true;
  // -1 跟随系统 / 0 深色 / 1 浅色
  @StorageLink('nssft.colorMode') colorMode: number = -1;
  @StorageLink('nssft.languageIndex') languageIndex: number = 0;
  @StorageLink('nssft.recordQuality') recordQuality: number = 1;
  @StorageLink('nssft.padEnabled') padEnabled: boolean = true;
  @StorageLink('nssft.padLayout') padLayout: number = 0;
  @StorageLink('nssft.padDeadZone') padDeadZone: number = 1;
  @StorageLink('nssft.vpadShown') vpadShown: boolean = false;
  @StorageLink('nssft.vpadSize') vpadSize: number = 1;
  @StorageLink('nssft.vpadOpacity') vpadOpacity: number = 1;
  @StorageLink('nssft.vpadHaptic') vpadHaptic: boolean = true;
  @StorageLink('nssft.vpadAutoHide') vpadAutoHide: boolean = true;
  @StorageLink('nssft.vpadSplitMode') vpadSplitMode: boolean = false;
  @StorageLink('nssft.vpadPortrait') vpadPortrait: boolean = false;
  @StorageProp('ui.screenW') screenW: number = 0;
  @StorageProp('ui.screenH') screenH: number = 0;
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  onOpenGuide: () => void = () => {
  };
  onOpenVpadLayouts: () => void = () => {
  };
  onOpenAbout: () => void = () => {
  };

  // 强制竖屏、分离展示不能用的原因：不是手机/平板，或者现在不是宽屏状态
  private wideReason(): string {
    if (!vpadAvailable()) {
      return tr('vpad_unavailable');
    }
    return isWideScreen(this.screenW, this.screenH) ? '' : tr('vpad_wide_only');
  }

  // 录制画质的说明：档位规格；省空间档在本机不能缩放画面时注明按原尺寸录
  private recordDesc(): string {
    const desc = recordQualityDesc(this.recordQuality);
    return this.recordQuality === 2 && !recordSupport().scaler ? `${desc}\n${tr('record_quality_small_noscale')}` : desc;
  }

  private colorLabels(): string[] {
    return [tr('settings_theme_system'), tr('settings_theme_dark'), tr('settings_theme_light')];
  }

  // 下拉框顺序：跟随系统 / 深色 / 浅色，与 colorMode 的取值 -1 / 0 / 1 一一对应
  private colorIndex(): number {
    return this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET ? 0 :
      (this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 1 : 2);
  }

  private setColor(index: number): void {
    const mode = index === 0 ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET :
      (index === 1 ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    this.colorMode = mode;
    applyColorMode(getContext(this), mode);
  }

  private languageLabels(): string[] {
    return LANGUAGE_NAMES.map((name: string, i: number) => i === 0 ? tr('app_lang_system') : name);
  }

  private setLanguage(index: number): void {
    if (index === this.languageIndex || !applyAppLanguage(index)) {
      return;
    }
    this.languageIndex = index;
    // 页面按新语言重建，让所有 tr() 重新取词
    notifyLanguageChanged();
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Card({ title: tr('settings_group_picture') }) {
          SettingRow({ title: tr('settings_freeze'), desc: tr('settings_freeze_desc'), icon: $r('sys.symbol.pause') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.freezeOnLoss })
              .onChange((on: boolean) => {
                this.freezeOnLoss = on;
              })
          }
          SettingRow({
            title: tr('settings_enhance'),
            desc: tr('settings_enhance_desc'),
            icon: $r('sys.symbol.wand_and_stars'),
            unsupported: enhanceAvailable() ? '' : tr('settings_enhance_unsupported')
          }) {
            Select(options(enhanceLabels()))
              .selected(this.enhanceLevel)
              .value(enhanceLabels()[this.enhanceLevel])
              .font({ size: 14 })
              .onSelect((index: number) => {
                this.enhanceLevel = index;
              })
          }
          SettingRow({ title: tr('settings_refresh'), desc: tr('settings_refresh_desc'), icon: $r('sys.symbol.battery') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.lowRefresh })
              .onChange((on: boolean) => {
                this.lowRefresh = on;
              })
          }
          SettingRow({ title: tr('settings_stats'), desc: tr('settings_stats_desc'), icon: $r('sys.symbol.gauge_with_dots_needle_33percent') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.showStats })
              .onChange((on: boolean) => {
                this.showStats = on;
              })
          }
        }

        Card({ title: tr('settings_group_sound') }) {
          SettingRow({ title: tr('settings_audio'), desc: tr('settings_audio_desc'), icon: $r('sys.symbol.speaker_wave_2') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.enableAudio })
              .onChange((on: boolean) => {
                this.enableAudio = on;
              })
          }
        }

        Card({ title: tr('settings_group_connection') }) {
          SettingRow({ title: tr('settings_netopt'), desc: tr('settings_netopt_desc'), icon: $r('sys.symbol.bolt') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.netOpt })
              .onChange((on: boolean) => {
                this.netOpt = on;
              })
          }
          SettingRow({
            title: tr('settings_pip'),
            desc: tr('settings_pip_desc'),
            icon: $r('sys.symbol.rectangle_on_square'),
            unsupported: PipSession.supported() ? '' : tr('settings_pip_unsupported')
          }) {
            Toggle({ type: ToggleType.Switch, isOn: this.pipAuto })
              .onChange((on: boolean) => {
                this.pipAuto = on;
              })
          }
        }

        Card({ title: tr('settings_group_record') }) {
          SettingRow({
            title: tr('settings_record_quality'),
            desc: this.recordDesc(),
            icon: $r('sys.symbol.record_circle'),
            unsupported: recordUnsupportedReason(false)
          }) {
            Select(options(recordQualityLabels()))
              .selected(this.recordQuality)
              .value(recordQualityLabels()[this.recordQuality])
              .font({ size: 14 })
              .onSelect((index: number) => {
                this.recordQuality = index;
              })
          }
        }

        Card({ title: tr('pad_title') }) {
          SettingRow({
            title: tr('pad_enable'),
            desc: tr('pad_enable_desc'),
            icon: $r('sys.symbol.gamecontroller'),
            scope: tr('pad_beta')
          }) {
            Toggle({ type: ToggleType.Switch, isOn: this.padEnabled })
              .onChange((on: boolean) => {
                this.padEnabled = on;
              })
          }
          SettingRow({ title: tr('pad_layout'), desc: tr('pad_layout_desc'), icon: $r('sys.symbol.dot_grid_2x2') }) {
            Select(options(padLayoutLabels()))
              .selected(this.padLayout)
              .value(padLayoutLabels()[this.padLayout] ?? '')
              .font({ size: 14 })
              .enabled(this.padEnabled)
              .onSelect((index: number) => {
                this.padLayout = index;
              })
          }
          SettingRow({
            title: tr('pad_deadzone'),
            desc: tr('pad_deadzone_desc'),
            icon: $r('sys.symbol.slider_horizontal_2'),
            unsupported: padAxisSupported() ? '' : tr('pad_axis_unsupported')
          }) {
            Select(options(padDeadZoneLabels()))
              .selected(this.padDeadZone)
              .value(padDeadZoneLabels()[this.padDeadZone] ?? '')
              .font({ size: 14 })
              .enabled(this.padEnabled)
              .onSelect((index: number) => {
                this.padDeadZone = index;
              })
          }
          // 触屏手柄：电脑和智慧屏上照常列出、置灰并写明原因
          SettingRow({
            title: tr('vpad_show'),
            desc: tr('vpad_show_desc'),
            icon: $r('sys.symbol.dot_grid_2x2'),
            unsupported: vpadAvailable() ? '' : tr('vpad_unavailable')
          }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadShown })
              .enabled(this.padEnabled && vpadAvailable())
              .onChange((on: boolean) => {
                this.vpadShown = on;
              })
          }
          SettingRow({ title: tr('vpad_size'), icon: $r('sys.symbol.slider_horizontal_2'),
            unsupported: vpadAvailable() ? '' : tr('vpad_unavailable') }) {
            Select(options(vpadSizeLabels()))
              .selected(this.vpadSize)
              .value(vpadSizeLabels()[this.vpadSize] ?? '')
              .font({ size: 14 })
              .enabled(vpadAvailable())
              .onSelect((index: number) => {
                this.vpadSize = index;
              })
          }
          SettingRow({ title: tr('vpad_opacity'), icon: $r('sys.symbol.slider_horizontal_2'),
            unsupported: vpadAvailable() ? '' : tr('vpad_unavailable') }) {
            Select(options(vpadOpacityLabels()))
              .selected(this.vpadOpacity)
              .value(vpadOpacityLabels()[this.vpadOpacity] ?? '')
              .font({ size: 14 })
              .enabled(vpadAvailable())
              .onSelect((index: number) => {
                this.vpadOpacity = index;
              })
          }
          SettingRow({ title: tr('vpad_haptic'), desc: tr('vpad_haptic_desc'), icon: $r('sys.symbol.bolt'),
            unsupported: vpadAvailable() ? '' : tr('vpad_unavailable') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadHaptic })
              .enabled(vpadAvailable())
              .onChange((on: boolean) => {
                this.vpadHaptic = on;
              })
          }
          SettingRow({ title: tr('vpad_autohide'), desc: tr('vpad_autohide_desc'), icon: $r('sys.symbol.gamecontroller'),
            unsupported: vpadAvailable() ? '' : tr('vpad_unavailable') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadAutoHide })
              .enabled(vpadAvailable())
              .onChange((on: boolean) => {
                this.vpadAutoHide = on;
              })
          }
          // 宽屏状态（阔折叠、折叠屏展开等）下才有的两个选项：别的屏幕上照常列出、置灰并写明原因
          SettingRow({ title: tr('vpad_force_portrait'), desc: tr('vpad_force_portrait_desc'),
            icon: $r('sys.symbol.rectangle_on_square'), unsupported: this.wideReason() }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadPortrait })
              .enabled(this.wideReason().length === 0)
              .onChange((on: boolean) => {
                this.vpadPortrait = on;
              })
          }
          SettingRow({ title: tr('vpad_split'), desc: tr('vpad_split_desc'), icon: $r('sys.symbol.rectangle_on_square'),
            unsupported: this.wideReason() }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadSplitMode })
              .enabled(this.wideReason().length === 0)
              .onChange((on: boolean) => {
                this.vpadSplitMode = on;
              })
          }
          NavRow({ title: tr('vpad_layouts'), desc: tr('vpad_layouts_desc'), icon: $r('sys.symbol.dot_grid_2x2'),
            onTap: () => {
              this.onOpenVpadLayouts();
            } })
        }

        Card({ title: tr('settings_group_appearance') }) {
          SettingRow({ title: tr('settings_theme'), icon: $r('sys.symbol.paintpalette') }) {
            Select(options(this.colorLabels()))
              .selected(this.colorIndex())
              .value(this.colorLabels()[this.colorIndex()])
              .font({ size: 14 })
              .onSelect((index: number) => {
                this.setColor(index);
              })
          }
          SettingRow({ title: tr('settings_language'), icon: $r('sys.symbol.globe_and_keyboard') }) {
            Select(options(this.languageLabels()))
              .selected(this.languageIndex)
              .value(this.languageLabels()[this.languageIndex])
              .font({ size: 14 })
              .onSelect((index: number) => {
                this.setLanguage(index);
              })
          }
        }

        Card({ title: tr('settings_group_help') }) {
          NavRow({
            title: tr('guide_title'),
            desc: tr('settings_guide_desc'),
            icon: $r('sys.symbol.book'),
            onTap: () => {
              this.onOpenGuide();
            }
          })
          NavRow({
            title: tr('about_title'),
            desc: tr('settings_about_desc'),
            icon: $r('sys.symbol.info_circle'),
            onTap: () => {
              this.onOpenAbout();
            }
          })
        }
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
