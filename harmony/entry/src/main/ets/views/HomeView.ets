// 首页：附近和最近连过的主机做成大卡片，点卡片就开始串流；右上角进设置
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import nssft from 'libentry.so';
import { DeviceInfo } from 'libentry.so';
import { tr } from '../common/I18n';
import { Breakpoint, hotspotSupported, isValidIPv4, sftVersionOf } from '../common/Prefs';
import { HotspotSheet } from './HotspotSheet';
import { agoText, forgetHost, parseRecentHosts, RecentHost, renameHost } from '../common/RecentHosts';
import { StreamTarget } from '../common/StreamTarget';
import { formatBytes, listRecordings, RECORDINGS_EPOCH_KEY } from '../common/Recording';
import { FOCUS_BOX } from '../common/Focus';
import { TextPromptDialog } from './TextPromptDialog';
import { UsbConsole, usbHostSupported, UsbWatcher } from '../common/UsbConsole';

/** 首页上的一张主机卡片：广播发现的和连过的合在一起 */
interface HostItem {
  host: string;
  online: boolean;
  alias: string;
  version: string;
  /** 最后连接时间，没连过为 0 */
  at: number;
}

// 下拉后“正在搜索”显示多久
const PULL_SEARCH_MS = 1000;

@Component
export struct HomeView {
  @Prop bp: Breakpoint = 'sm';
  @Prop @Watch('onPlayingChange') playing: boolean = false;
  @StorageLink('nssft.recentHosts') recentRaw: string = '';
  @StorageProp('hs.on') hotspotOn: boolean = false;
  @StorageProp('hs.summary') hotspotSummary: string = '';
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  // 录像卡片：个数和总大小（录完、删除、存到图库后刷新）
  @StorageProp(RECORDINGS_EPOCH_KEY) @Watch('refreshRecordings') recordingsEpoch: number = 0;
  @State recordingCount: number = 0;
  @State recordingBytes: number = 0;
  @State devices: DeviceInfo[] = [];
  @State discoveryOk: boolean = true;
  onConnect: (t: StreamTarget) => void = () => {
  };
  onOpenSettings: () => void = () => {
  };
  onOpenGuide: () => void = () => {
  };
  onOpenRecordings: () => void = () => {
  };
  private timer: number = -1;
  private promptController: CustomDialogController | null = null;
  // 专用热点：点首页卡片从底部弹出配置面板
  @State showHotspot: boolean = false;
  // 宽屏时让同一行的卡片等高：量出主机卡片、USB 和热点入口内容的自然高度，作为相邻卡片的最小高度
  // （不用 height('100%')：在 Scroll 里百分比高度会被撑开）
  @State hostCardHeight: number = 0;
  @State usbRowHeight: number = 0;
  @State hotspotRowHeight: number = 0;
  // 下拉刷新：发现靠游戏机每秒一次的广播，一直在后台进行；下拉只显示 1 秒“正在搜索”，让用户知道在找
  @State refreshing: boolean = false;
  private refreshTimer: number = -1;
  // 横屏时底部少留白
  @State landscape: boolean = false;
  // USB：插着 SFT 设备时入口高亮，点一下就连
  @State usbPresent: boolean = false;
  @State usbOpening: boolean = false;
  private usbSupported: boolean = usbHostSupported();
  private usbWatcher: UsbWatcher = new UsbWatcher();

  aboutToAppear(): void {
    if (!this.playing) {
      this.startDiscovery();
    }
    this.refreshRecordings();
    if (this.usbSupported) {
      this.usbPresent = UsbConsole.find() !== undefined;
      this.usbWatcher.start(() => {
        this.usbPresent = UsbConsole.find() !== undefined;
      });
    }
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.stopDiscovery();
    this.usbWatcher.stop();
  }

  // 下拉：马上刷新一次列表；之前监听广播失败（端口被占）就重试一次。“正在搜索”显示 1 秒后收起
  private onPullRefresh(): void {
    if (!this.playing) {
      if (!this.discoveryOk) {
        this.stopDiscovery();
        this.startDiscovery();
      } else {
        this.devices = nssft.getDevices();
      }
      if (this.usbSupported) {
        this.usbPresent = UsbConsole.find() !== undefined;
      }
    }
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = -1;
      this.refreshing = false;
    }, PULL_SEARCH_MS);
  }

  // recordOnly：长按 USB 卡片选“只录制”
  private async connectUsb(recordOnly: boolean = false): Promise<void> {
    if (!this.usbSupported || this.usbOpening) {
      return;
    }
    const device = UsbConsole.find();
    if (device === undefined) {
      this.usbPresent = false;
      promptAction.showDialog({
        title: tr('home_usb'),
        message: UsbConsole.notFoundHint(),
        buttons: [{ text: tr('common_ok'), color: '#00897B' }]
      }).catch(() => {
      });
      return;
    }
    this.usbOpening = true;
    const r = await UsbConsole.open(device);
    this.usbOpening = false;
    if (r.link === null) {
      promptAction.showToast({ message: r.error, duration: 4000 });
      return;
    }
    this.onConnect({ host: '', label: 'USB', version: '', usb: r.link, recordOnly: recordOnly });
  }

  onPlayingChange(): void {
    // 串流时游戏机不广播，也不用占着端口轮询
    if (this.playing) {
      this.stopDiscovery();
    } else {
      this.startDiscovery();
      this.refreshRecordings();
    }
  }

  refreshRecordings(): void {
    const files = listRecordings(getContext(this));
    let bytes = 0;
    for (const f of files) {
      bytes += f.bytes;
    }
    this.recordingCount = files.length;
    this.recordingBytes = bytes;
  }

  private startDiscovery(): void {
    if (this.timer >= 0) {
      return;
    }
    this.discoveryOk = nssft.startDiscovery();
    this.devices = nssft.getDevices();
    this.timer = setInterval(() => {
      this.devices = nssft.getDevices();
    }, 1000);
  }

  private stopDiscovery(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    nssft.stopDiscovery();
  }

  private items(): HostItem[] {
    const recents: RecentHost[] = parseRecentHosts(this.recentRaw);
    const out: HostItem[] = [];
    for (const d of this.devices) {
      const r = recents.find((h: RecentHost): boolean => h.host === d.ip);
      const version = sftVersionOf(d.name);
      out.push({
        host: d.ip, online: true, alias: r !== undefined ? r.alias : '',
        version: version.length > 0 ? version : (r !== undefined ? r.version : ''), at: r !== undefined ? r.at : 0
      });
    }
    for (const r of recents) {
      if (!out.some((i: HostItem): boolean => i.host === r.host)) {
        out.push({ host: r.host, online: false, alias: r.alias, version: r.version, at: r.at });
      }
    }
    return out;
  }

  private titleOf(item: HostItem): string {
    if (item.alias.length > 0) {
      return item.alias;
    }
    const parts = item.host.split('.');
    return tr('home_host_default', parts[parts.length - 1]);
  }

  private subtitleOf(item: HostItem): string {
    const parts: string[] = [item.host];
    parts.push(item.online ? tr('home_host_online') : tr('home_host_seen', agoText(item.at)));
    if (item.version.length > 0) {
      parts.push(`SFT ${item.version}`);
    }
    return parts.join(' · ');
  }

  private connect(item: HostItem, recordOnly: boolean = false): void {
    this.onConnect({ host: item.host, label: this.titleOf(item), version: item.version, usb: null, recordOnly: recordOnly });
  }

  private openPrompt(title: string, placeholder: string, confirmText: string, initial: string, numeric: boolean,
    onConfirm: (value: string) => string): void {
    this.promptController = new CustomDialogController({
      builder: TextPromptDialog({
        title: title,
        placeholder: placeholder,
        confirmText: confirmText,
        text: initial,
        numeric: numeric,
        onConfirm: onConfirm
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      autoCancel: true
    });
    this.promptController.open();
  }

  private askManualHost(): void {
    const last = parseRecentHosts(this.recentRaw);
    this.openPrompt(tr('home_manual_title'), tr('home_manual_placeholder'), tr('home_manual_connect'),
      last.length > 0 ? last[0].host : '', true, (value: string): string => {
        if (!isValidIPv4(value)) {
          return tr('home_manual_invalid');
        }
        const parts = value.split('.');
        this.onConnect({ host: value, label: tr('home_host_default', parts[3]), version: '', usb: null });
        return '';
      });
  }

  private askRename(item: HostItem): void {
    this.openPrompt(tr('home_rename_title'), tr('home_rename_placeholder'), tr('common_save'), item.alias, false,
      (value: string): string => {
        renameHost(item.host, value);
        return '';
      });
  }

  private confirmForget(item: HostItem): void {
    promptAction.showDialog({
      title: tr('home_forget_title'),
      message: tr('home_forget_message', this.titleOf(item)),
      buttons: [
        { text: tr('common_cancel'), color: '#99000000' },
        { text: tr('home_forget_confirm'), color: '#D9480F' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        forgetHost(item.host);
      }
    }).catch(() => {
    });
  }

  @Builder
  HostMenu(item: HostItem) {
    Menu() {
      // 只录制：不显示画面，后台照常录
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.record_circle')), content: tr('home_record_only') })
        .onClick(() => {
          this.connect(item, true);
        })
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')), content: tr('home_rename') })
        .onClick(() => {
          this.askRename(item);
        })
      if (item.at > 0) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')), content: tr('home_forget') })
          .onClick(() => {
            this.confirmForget(item);
          })
      }
    }
  }

  // first：第一张卡片。智慧屏只有遥控器，打开首页时焦点默认落在它的“开始串流”上
  @Builder
  HostCard(item: HostItem, first: boolean) {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Row() {
            SymbolGlyph($r('sys.symbol.gamecontroller')).fontSize(24).fontColor([$r('app.color.accent')])
          }
          .width(48)
          .height(48)
          .borderRadius(14)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.accent_soft'))

          // 在线状态点（Circle 的 fill/stroke 要 API 26，用圆角块兼容老系统）
          Column()
            .width(12)
            .height(12)
            .borderRadius(6)
            .backgroundColor(item.online ? $r('app.color.ok') : $r('app.color.text_tertiary'))
            .border({ width: 2, color: $r('app.color.card_bg') })
        }

        Column({ space: 3 }) {
          Text(this.titleOf(item))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitleOf(item))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .focusBox(FOCUS_BOX)
        .bindMenu(this.HostMenu(item))
        .accessibilityText(tr('home_more'))
      }
      .width('100%')

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(16).fontColor([$r('app.color.on_accent')])
          Text(item.online ? tr('home_start') : tr('home_try_connect'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_accent'))
        }
      }
      .width('100%')
      .height(44)
      .backgroundColor(item.online ? $r('app.color.accent') : $r('app.color.text_tertiary'))
      .focusBox(FOCUS_BOX)
      .defaultFocus(first && deviceInfo.deviceType === 'tv')
      .onClick(() => {
        this.connect(item);
      })
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: item.online ? 1.5 : 0, color: $r('app.color.card_outline') })
    .bindContextMenu(this.HostMenu(item), ResponseType.LongPress)
    .onAreaChange((_old: Area, area: Area) => {
      if (first) {
        this.hostCardHeight = Number(area.height);
      }
    })
  }

  /** 宽屏（横屏、平板、PC、智慧屏）：手动输入放进主机网格，USB 和热点并排 */
  private wide(): boolean {
    return this.bp !== 'sm';
  }

  // inGrid：作为主机网格的最后一格，宽屏时和主机卡片一样高
  @Builder
  ManualCard(inGrid: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([$r('app.color.accent')])
        Column({ space: 2 }) {
          Text(tr('home_manual')).fontSize(15).fontColor($r('app.color.accent'))
          Text(tr('home_manual_desc')).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('auto')
    .borderRadius(24)
    .backgroundColor(Color.Transparent)
    // 圆角要写进 border 里：border 不带 radius 会把上面的 borderRadius 覆盖成直角
    .border({ width: 1.5, color: $r('app.color.card_outline'), style: BorderStyle.Dashed, radius: 24 })
    .constraintSize({ minHeight: inGrid && this.wide() ? this.hostCardHeight : 0 })
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.askManualHost();
    })
  }

  // USB 入口：插着游戏机时高亮；本机没有 USB 主机能力时置灰并写明原因（不隐藏）
  @Builder
  UsbEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.charg_cable'))
          .fontSize(20)
          .fontColor([this.usbPresent ? $r('app.color.on_accent') : $r('app.color.accent')])
        Column({ space: 2 }) {
          Text(this.usbPresent ? tr('home_usb_found') : tr('home_usb'))
            .fontSize(15)
            .fontColor(this.usbPresent ? $r('app.color.on_accent') : $r('app.color.text_primary'))
          Text(!this.usbSupported ? tr('home_usb_unsupported') :
            (this.usbPresent ? tr('home_usb_found_desc') : tr('home_usb_desc')))
            .fontSize(12)
            .fontColor(this.usbPresent ? $r('app.color.on_accent') : $r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.usbOpening) {
          LoadingProgress().width(20).height(20).color($r('app.color.on_accent'))
        } else {
          SymbolGlyph(this.usbPresent ? $r('sys.symbol.play_fill') : $r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([this.usbPresent ? $r('app.color.on_accent') : $r('app.color.text_tertiary')])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onAreaChange((_old: Area, area: Area) => {
        this.usbRowHeight = Number(area.height);
      })
    }
    .width('100%')
    .height('auto')
    .constraintSize({ minHeight: this.wide() ? Math.max(this.usbRowHeight, this.hotspotRowHeight) : 0 })
    .borderRadius(20)
    .backgroundColor(this.usbPresent ? $r('app.color.accent') : $r('app.color.card_bg'))
    .opacity(this.usbSupported ? 1 : 0.6)
    .enabled(this.usbSupported)
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.connectUsb();
    })
    // 长按：只录制
    .bindContextMenu(this.UsbMenu(), ResponseType.LongPress)
  }

  @Builder
  UsbMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.record_circle')), content: tr('home_record_only') })
        .onClick(() => {
          this.connectUsb(true);
        })
    }
  }

  // 录像管理：录好的视频先存在应用里（图库里看不到），在这里查看、存到图库或删除
  @Builder
  RecordingsEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.film'))
          .fontSize(20)
          .fontColor([$r('app.color.accent')])
        Column({ space: 2 }) {
          Text(tr('home_recordings'))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Text(this.recordingCount > 0 ? tr('home_recordings_desc', this.recordingCount, formatBytes(this.recordingBytes)) :
            tr('home_recordings_empty'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    }
    .width('100%')
    .height('auto')
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.onOpenRecordings();
    })
  }

  @Builder
  HotspotEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.hotspot'))
          .fontSize(20)
          .fontColor([this.hotspotOn ? $r('app.color.on_accent') : $r('app.color.accent')])
        Column({ space: 2 }) {
          Text(tr('home_hotspot'))
            .fontSize(15)
            .fontColor(this.hotspotOn ? $r('app.color.on_accent') : $r('app.color.text_primary'))
          Text(!hotspotSupported() ? tr('home_hotspot_unsupported') :
            (this.hotspotOn && this.hotspotSummary.length > 0 ? this.hotspotSummary : tr('home_hotspot_desc')))
            .fontSize(12)
            .fontColor(this.hotspotOn ? $r('app.color.on_accent') : $r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([this.hotspotOn ? $r('app.color.on_accent') : $r('app.color.text_tertiary')])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onAreaChange((_old: Area, area: Area) => {
        this.hotspotRowHeight = Number(area.height);
      })
    }
    .width('100%')
    .height('auto')
    .constraintSize({ minHeight: this.wide() ? Math.max(this.usbRowHeight, this.hotspotRowHeight) : 0 })
    .borderRadius(20)
    .backgroundColor(this.hotspotOn ? $r('app.color.accent') : $r('app.color.card_bg'))
    .opacity(hotspotSupported() ? 1 : 0.6)
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      this.showHotspot = true;
    })
    .bindSheet($$this.showHotspot, this.HotspotSheetContent(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg')
    })
  }

  @Builder
  HotspotSheetContent() {
    HotspotSheet({
      onClose: () => {
        this.showHotspot = false;
      }
    })
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(36).fontColor([$r('app.color.text_tertiary')])
      Text(tr('home_empty_title')).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(tr('home_empty_desc'))
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Text(tr('home_open_guide'))
        .fontSize(14)
        .fontColor($r('app.color.accent'))
        .fontWeight(FontWeight.Medium)
        .padding(6)
        .focusable(true)
        .focusBox(FOCUS_BOX)
        .onClick(() => {
          this.onOpenGuide();
        })
    }
    .width('100%')
    .padding({ top: 28, bottom: 28, left: 20, right: 20 })
    .borderRadius(24)
    .backgroundColor($r('app.color.card_bg'))
  }

  build() {
    Column() {
      // 标题区：固定在顶部，下面的内容单独滚动。Navigation 已经让开了状态栏，这里不能再加 safeTop（否则标题上方留白翻倍）
      Row() {
        Column({ space: 2 }) {
          Text('NSSFT')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(tr('home_tagline'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([$r('app.color.text_primary')])
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.card_bg'))
        .focusBox(FOCUS_BOX)
        .accessibilityText(tr('settings_title'))
        .onClick(() => {
          this.onOpenSettings();
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: 1080 })
      .padding({ left: 16, right: 16, top: 12, bottom: 4 })

      Refresh({ refreshing: $$this.refreshing, promptText: tr('home_searching') }) {
        Scroll() {
          Column({ space: 16 }) {
            // 附近的主机
            Row({ space: 8 }) {
              Text(tr('home_section_hosts'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent'))
                .layoutWeight(1)
              // 平时不显示“正在搜索”（一直转圈会以为卡住了），下拉时由刷新动效显示 1 秒；只在监听失败时提示
              if (!this.discoveryOk) {
                Text(tr('home_discovery_failed')).fontSize(12).fontColor($r('app.color.warn'))
              }
            }
            .width('100%')
            .padding({ left: 4, right: 4 })

            if (this.items().length === 0) {
              this.EmptyState()
              this.ManualCard(false)
            } else {
              // 栅格：手机一列，折叠屏展开/平板竖屏两列，横屏三列；手动输入作为最后一格紧跟在主机后面
              GridRow({ columns: { sm: 1, md: 2, lg: 3 }, gutter: { x: 12, y: 12 } }) {
                ForEach(this.items(), (item: HostItem, index: number) => {
                  GridCol() {
                    this.HostCard(item, index === 0)
                  }
                }, (item: HostItem) => `${item.host}|${item.online}|${item.alias}|${item.version}|${item.at}`)
                GridCol() {
                  this.ManualCard(true)
                }
              }
              .width('100%')
            }

            if (this.wide()) {
              // 宽屏：USB 和专用热点并排一行
              Row({ space: 12 }) {
                Column() {
                  this.UsbEntry()
                }
                .layoutWeight(1)

                Column() {
                  this.HotspotEntry()
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            } else {
              this.UsbEntry()
              this.HotspotEntry()
            }
            this.RecordingsEntry()
          }
          .padding({ left: 16, right: 16, top: 8, bottom: this.safeBottom + (this.landscape ? 8 : 24) })
          .constraintSize({ maxWidth: 1080 })
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.onPullRefresh();
      })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.landscape = Number(area.width) > Number(area.height);
    })
  }
}
