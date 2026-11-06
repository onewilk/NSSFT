// 设置页：画面与声音、串流、手柄、触屏手柄、录像、外观几组，最后是帮助和关于（分组和串流菜单对齐）。
// 只在首页打开（不在播放中），改了下次连接生效；播放中要即时调整的选项在串流菜单里
import { ConfigurationConstant } from '@kit.AbilityKit';
import { applyAppLanguage, notifyLanguageChanged, tr } from '../common/I18n';
import { PipSession } from '../common/PipSession';
import { enhanceAvailable, enhanceLabels } from '../common/Prefs';
import { recordQualityDesc, recordQualityLabels, recordSupport, recordUnsupportedReason } from '../common/Recording';
import {
  padAxisSupported, padDeadZoneLabels, padLayoutLabels, playOrientLabels, playOrientReason, VPAD_AVAILABLE_KEY,
  vpadOpacityLabels, vpadSizeLabels
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
  @StorageProp(VPAD_AVAILABLE_KEY) vpadOk: boolean = false;  // 本机有没有触摸屏
  @StorageLink('nssft.vpadShown') vpadShown: boolean = false;
  @StorageLink('nssft.vpadSize') vpadSize: number = 1;
  @StorageLink('nssft.vpadOpacity') vpadOpacity: number = 1;
  @StorageLink('nssft.vpadHaptic') vpadHaptic: boolean = true;
  @StorageLink('nssft.vpadAutoHide') vpadAutoHide: boolean = true;
  @StorageLink('nssft.playOrientation') playOrientation: number = 0;
  @StorageProp('ui.screenW') screenW: number = 0;
  @StorageProp('ui.screenH') screenH: number = 0;
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  onOpenGuide: () => void = () => {
  };
  onOpenVpadLayouts: () => void = () => {
  };
  onOpenAbout: () => void = () => {
  };

  // 串流时的屏幕方向不能选的原因：电视、电脑，或者现在不是宽屏状态（手机、折叠屏外屏固定横屏）
  private orientReason(): string {
    return playOrientReason(isWideScreen(this.screenW, this.screenH));
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
        // 和串流菜单的分组对齐：画面与声音、串流（串流时的显示和网络）、手柄、触屏手柄，然后是录像、外观、帮助
        Card({ title: tr('settings_group_av') }) {
          SettingRow({ title: tr('settings_audio'), desc: tr('settings_audio_desc'), icon: $r('sys.symbol.speaker_wave_2') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.enableAudio })
              .onChange((on: boolean) => {
                this.enableAudio = on;
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
        }

        Card({ title: tr('settings_group_stream') }) {
          // 宽屏状态（平板、阔折叠、折叠屏展开等）才能选；别的设备照常列出、置灰并写明原因
          SettingRow({
            title: tr('play_orient'),
            desc: tr('play_orient_desc'),
            icon: $r('sys.symbol.screen_rotation'),
            unsupported: this.orientReason()
          }) {
            Select(options(playOrientLabels()))
              .selected(this.playOrientation)
              .value(playOrientLabels()[this.playOrientation] ?? '')
              .font({ size: 14 })
              .enabled(this.orientReason().length === 0)
              .onSelect((index: number) => {
                this.playOrientation = index;
              })
          }
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
          SettingRow({ title: tr('settings_stats'), desc: tr('settings_stats_desc'), icon: $r('sys.symbol.gauge_with_dots_needle_33percent') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.showStats })
              .onChange((on: boolean) => {
                this.showStats = on;
              })
          }
        }

        Card({ title: tr('pad_title'), tag: tr('pad_beta') }) {
          SettingRow({
            title: tr('pad_enable'),
            desc: tr('pad_enable_desc'),
            icon: $r('sys.symbol.gamecontroller')
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
        }

        // 电脑和智慧屏上照常列出、置灰并写明原因；还在调试，整组标“实验性”（已知问题见使用说明）
        Card({ title: tr('vpad_show'), tag: tr('vpad_experimental') }) {
          SettingRow({
            title: tr('vpad_show_in_menu'),
            icon: $r('sys.symbol.hand_point_up_tap'),
            unsupported: this.vpadOk ? '' : tr('vpad_unavailable')
          }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadShown })
              .enabled(this.padEnabled && this.vpadOk)
              .onChange((on: boolean) => {
                this.vpadShown = on;
              })
          }
          SettingRow({ title: tr('vpad_size'), icon: $r('sys.symbol.slider_horizontal_2'),
            unsupported: this.vpadOk ? '' : tr('vpad_unavailable') }) {
            Select(options(vpadSizeLabels()))
              .selected(this.vpadSize)
              .value(vpadSizeLabels()[this.vpadSize] ?? '')
              .font({ size: 14 })
              .enabled(this.vpadOk)
              .onSelect((index: number) => {
                this.vpadSize = index;
              })
          }
          SettingRow({ title: tr('vpad_opacity'), icon: $r('sys.symbol.slider_horizontal_2'),
            unsupported: this.vpadOk ? '' : tr('vpad_unavailable') }) {
            Select(options(vpadOpacityLabels()))
              .selected(this.vpadOpacity)
              .value(vpadOpacityLabels()[this.vpadOpacity] ?? '')
              .font({ size: 14 })
              .enabled(this.vpadOk)
              .onSelect((index: number) => {
                this.vpadOpacity = index;
              })
          }
          SettingRow({ title: tr('vpad_haptic'), desc: tr('vpad_haptic_desc'), icon: $r('sys.symbol.bolt'),
            unsupported: this.vpadOk ? '' : tr('vpad_unavailable') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadHaptic })
              .enabled(this.vpadOk)
              .onChange((on: boolean) => {
                this.vpadHaptic = on;
              })
          }
          SettingRow({ title: tr('vpad_autohide'), desc: tr('vpad_autohide_desc'), icon: $r('sys.symbol.gamecontroller'),
            unsupported: this.vpadOk ? '' : tr('vpad_unavailable') }) {
            Toggle({ type: ToggleType.Switch, isOn: this.vpadAutoHide })
              .enabled(this.vpadOk)
              .onChange((on: boolean) => {
                this.vpadAutoHide = on;
              })
          }
          NavRow({ title: tr('vpad_layouts'), desc: tr('vpad_layouts_desc'), icon: $r('sys.symbol.dot_grid_2x2'),
            onTap: () => {
              this.onOpenVpadLayouts();
            } })
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
    // 滚动区域延伸到底部小白条下面（内容末尾已留出 safeBottom），页面底部不再被一条底色挡住
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
