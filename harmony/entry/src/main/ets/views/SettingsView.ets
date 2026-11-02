// 设置页：画面、声音、连接、外观四组，最后是帮助和关于。只在首页打开（不在播放中），改了下次连接生效；
// 播放中要即时调整的选项在播放页的快捷面板里
import { ConfigurationConstant } from '@kit.AbilityKit';
import { applyAppLanguage, notifyLanguageChanged, tr } from '../common/I18n';
import { PipSession } from '../common/PipSession';
import { enhanceAvailable, enhanceLabels, keepAliveLabels } from '../common/Prefs';
import { applyColorMode } from '../common/Theme';
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
  @StorageLink('nssft.keepAliveIndex') keepAliveIndex: number = 1;
  @StorageLink('nssft.pipAuto') pipAuto: boolean = true;
  // -1 跟随系统 / 0 深色 / 1 浅色
  @StorageLink('nssft.colorMode') colorMode: number = -1;
  @StorageLink('nssft.languageIndex') languageIndex: number = 0;
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  onOpenGuide: () => void = () => {
  };
  onOpenAbout: () => void = () => {
  };

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
            title: tr('settings_keepalive'),
            desc: tr('settings_keepalive_desc'),
            icon: $r('sys.symbol.clock')
          }) {
            Select(options(keepAliveLabels()))
              .selected(this.keepAliveIndex)
              .value(keepAliveLabels()[this.keepAliveIndex])
              .font({ size: 14 })
              .onSelect((index: number) => {
                this.keepAliveIndex = index;
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
