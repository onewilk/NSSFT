import { window, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { inputMethod } from '@kit.IMEKit';
import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import nssft from 'libentry.so';
import { ConnectConfig, DeviceInfo, SessionStats } from 'libentry.so';
import { formatBytes, formatClock, recordUnsupportedReason, RecordingSession } from '../common/Recording';
import {
  isPadMinusKey, isPadPlusKey, PAD_BUTTON_B, PadAxisModifier, padAxisSupported, padConfigure, padDeadZoneLabels,
  PadDevices, padForwardAxis, padLayoutLabels, PLAY_ORIENT_FOLLOW, PLAY_ORIENT_LANDSCAPE, PLAY_ORIENT_PORTRAIT,
  playOrientLabels,
  playOrientReason, VPAD_AVAILABLE_KEY, vpadOpacityLabels, vpadSizeLabels, watchTouchscreen
} from '../common/Gamepad';
import { VirtualPad } from '../views/VirtualPad';
import { VpadLayoutsView } from '../views/VpadLayoutsView';
import { TextPromptDialog } from '../views/TextPromptDialog';
import {
  activeLayoutId, createLayout, getLayout, isWideScreen, layoutNameTaken, listLayouts, migrateOldLayouts,
  migrateSplitLayouts, PadLayout,
  setActiveLayout, suggestLayoutName, UnitSave, updateLayoutUnits, VPAD_LAYOUTS_EPOCH, VpadMode, vpadModeLabel
} from '../common/VpadLayouts';
import { RecordStatus, RecordStatusInfo } from '../common/RecordStatus';
import { loadPicPos, PIC_ANCHORS, picPosKey, picPosName, savePicPos } from '../common/PicturePos';
import { BackgroundKeeper } from '../common/BackgroundKeeper';
import { HotspotService } from '../common/HotspotService';
import { SHORTCUT_HOTSPOT_CONNECT, SHORTCUT_KEY, shortcutAction } from '../common/LaunchShortcut';
import { NetBooster } from '../common/NetBooster';
import { PipSession } from '../common/PipSession';
import {
  APP_NAME, Breakpoint, breakpointOf, enhanceAvailable, enhanceLabels, hotspotSupported, SFT_PORT, sftVersionOf
} from '../common/Prefs';
import { languageSignature, tr, uiLanguageIndex } from '../common/I18n';
import { StatsRecorder } from '../common/StatsRecorder';
import { StreamTarget } from '../common/StreamTarget';
import { findRecentHost, lastRecentHost, RecentHost, rememberHost } from '../common/RecentHosts';
import { applyColorMode, updateSystemBarColors } from '../common/Theme';
import { UsbConsole, UsbLog, UsbPump, UsbWatcher } from '../common/UsbConsole';
import { AboutView } from '../views/AboutView';
import { GuideView } from '../views/GuideView';
import { HomeView } from '../views/HomeView';
import { RecordingsView } from '../views/RecordingsView';
import { SettingsView } from '../views/SettingsView';
import { TvMenuItem } from '../views/TvMenuItem';
import { MenuGroup } from '../views/Widgets';
import { FOCUS_BOX, NO_FOCUS_BOX } from '../common/Focus';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';
// 录像时长时任务的系统实况窗每秒刷新一次（录制时长、大小）
const LIVE_VIEW_INTERVAL_MS = 1000;
const VIDEO_ASPECT = 16 / 9;
// 播放页的 HUD（完整的菜单按钮）没有操作多久后自动收成小把手
const HUD_HIDE_MS = 3000;
// 菜单按钮的点击范围（vp）：完整按钮和收起后的小把手都一样，在触屏手柄给菜单按钮留的区域里（按键拖不进来）
const MENU_HIT_W = 72;
const MENU_HIT_H = 60;
// 收起后的小把手：一条很淡的短横线
const MENU_HANDLE_COLOR = '#59FFFFFF';
// 完整按钮 ↔ 小把手的变形时长（毫秒）：外形一起过渡；三条横线收起时先淡出，展开时等外形长出来再淡入
const MENU_MORPH_MS = 320;
const MENU_LINES_MS = 160;
// 切后台后等多久还没转入小窗（例如系统设置里关了画中画），就按普通切后台处理
const PIP_WAIT_MS = 1000;
// 小窗关闭后等一下再按切后台处理：用户也可能是点了桌面图标回到 App
const PIP_CLOSED_GRACE_MS = 500;
// “热点+连接”快捷方式：开启专用热点后最多等游戏机多久
const SHORTCUT_WAIT_MS = 90000;
// 播放时请求的屏幕刷新率：游戏画面最高 60 帧，高刷屏降到 60Hz 省电，上屏节奏也更稳
const PLAYBACK_REFRESH_HZ = 60;
// 播放页的强调色（播放页总是深色底，不随主题变）
const PLAYER_ACCENT = '#26C6B0';
const PLAYER_GLASS = '#B3101414';
// 录制中的红点、停止录制按钮
const RECORD_RED = '#E5484D';
// 只录制页面的底色（连同状态栏和底部小白条区域）
const RECORD_ONLY_BG = '#101414';

// 通过 XComponentController 拿 surface 的创建/销毁时机（API 12）
class StreamSurfaceController extends XComponentController {
  onCreated: (surfaceId: string) => void = () => {
  };
  onDestroyed: () => void = () => {
  };

  onSurfaceCreated(surfaceId: string): void {
    this.onCreated(surfaceId);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    this.onDestroyed();
  }
}

// 智慧屏：确认键按住这么久算长按，打开右侧菜单
const TV_LONG_PRESS_MS = 500;
const IS_TV: boolean = deviceInfo.deviceType === 'tv';
// 手柄：同时按住开始键和选择键（+ 和 −）这么久打开串流选项（只用手柄时也能叫出菜单，与 SFT 的客户端一致）
const PAD_CHORD_MS = 1500;
// 手柄的 B 键按下后这么久内的系统返回不算数（有的系统把手柄 B 当作返回键）
const PAD_BACK_GUARD_MS = 400;
// 播放页拦截返回时的提示（怎么断开），隔这么久（毫秒）才再提示一次，免得玩的时候误触一直弹
const BACK_HINT_GAP_MS = 10000;
// 侧滑菜单最宽多少（vp），窄屏上不超过屏宽的 88%（智慧屏占半屏）
const MENU_MAX_WIDTH = 360;
// 播放区至少这么高（vp）时菜单用宽松的行距（平板、折叠屏展开等）；更矮时（手机横屏）用紧凑行距，一级菜单一屏放得下
const MENU_ROOMY_MIN_VP = 480;
// 播放菜单二级页里一行选项的最小高度（vp），手指好点、行和行之间不挤
const MENU_ROW_MIN_H = 46;
// 画面上下的空白至少这么高（vp）才能调整画面位置；拖到离顶部、居中、底部这么近（vp）时吸附过去
const PIC_MIN_FREE_VP = 24;
const PIC_SNAP_VP = 20;
// 调整画面位置的工具条要占的高度（vp）：空白比这小就盖在画面上
const PIC_EDIT_BAR_SLOT_VP = 110;
// 离开播放页摆回原来的方向后，等这么久（毫秒）再把方向交还给系统
const ORIENT_SETTLE_MS = 600;
// 手柄面板开着时“正在按”的刷新间隔
const PAD_PANEL_POLL_MS = 100;

function selectOptions(labels: string[]): SelectOption[] {
  return labels.map((label: string): SelectOption => {
    const option: SelectOption = { value: label };
    return option;
  });
}

@Entry
@Component
struct Index {
  @State bp: Breakpoint = 'sm';
  // 宽屏状态（阔折叠、折叠屏展开等，见 VpadLayouts.isWideScreen）：按短边和长宽比算，和横竖屏无关，只在折叠 / 展开时变。
  // 决定“串流时的屏幕方向”和竖屏键位能不能用。不能用 bp 判断：转成横屏后宽度变大、bp 跟着变，会来回切横竖屏
  @State @Watch('onScreenClassChanged') wideScreen: boolean = false;
  // 横屏时摄像头挖孔占掉的左右宽度：页面和播放浮层都让开
  @StorageProp('ui.safeLeft') safeLeft: number = 0;
  @StorageProp('ui.safeRight') safeRight: number = 0;
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  @StorageLink('nssft.colorMode') colorMode: number = -1;
  // 界面语言变了（设置里手动切换，或跟随系统时系统语言变了）：页面重建，所有 tr() 重新取词
  @StorageProp('ui.langEpoch') @Watch('onLanguageChanged') langEpoch: number = 0;
  // 桌面快捷方式（冷启动和热启动都写这个键）
  @StorageProp(SHORTCUT_KEY) @Watch('onShortcut') shortcut: string = '';
  private handledShortcut: string = '';
  private shortcutTimer: number = -1;
  private builtLanguage: string = '';
  private languageTimer: number = -1;
  private languageStale: boolean = false;
  private navStack: NavPathStack = new NavPathStack();
  @State playerWidth: number = 0;
  @State playerHeight: number = 0;
  // 播放区域的大小：画面上下空出来多少决定画面位置能不能调；宽度决定侧滑菜单多宽
  @State playerAreaH: number = 0;
  @State playerAreaW: number = 0;
  // 画面位置（见 PicturePos.ets）：这种屏幕形态记住的位置，-1 是没记过（用默认位置）
  @State picPos: number = -1;
  private picKey: string = '';
  // 调整画面位置中：拖动时的位置、进入时的位置（判断有没有改动）、这次拖动开始时画面的顶边
  @State picEditing: boolean = false;
  @State picEditPos: number = 0.5;
  private picEditOrig: number = 0.5;
  private picDragStartTop: number = 0;

  // 设置（和设置页共用）
  @StorageLink('nssft.enableAudio') enableAudio: boolean = true;
  @StorageLink('nssft.netOpt') netOpt: boolean = true;
  @StorageLink('nssft.pipAuto') pipAuto: boolean = true;
  @StorageLink('nssft.lowRefresh') @Watch('applyRefreshHint') lowRefresh: boolean = true;
  @StorageLink('nssft.showStats') showStats: boolean = false;
  @StorageLink('nssft.enhanceLevel') enhanceLevel: number = 0;
  @StorageProp('hs.channel') hotspotChannel: number = 0;
  @StorageProp('hs.staChannel') staChannel: number = 0;

  // 播放页
  @State playing: boolean = false;
  // 串流选项面板：打开时 HUD 不自动隐藏，关上后重新计时
  // 播放菜单：右上角的菜单按钮（智慧屏是菜单键、长按确认键）打开的右侧侧滑菜单。
  // menuPage：'' 一级（常用操作和串流选项）/ 'pad' 手柄（智慧屏上手柄只有开关，不进二级）/ 'orient' 屏幕方向 / 'enhance' 画质增强
  @State @Watch('onMenuToggled') menuOpen: boolean = false;
  @State @Watch('onMenuPageChanged') menuPage: string = '';
  // 统计浮层的文字（一块面板，每秒刷新）
  @State statsText: string = '';
  @State statusText: string = '';
  // 左上角的画面信息：“1080p · 60 帧”
  @State badgeText: string = '';
  // 底部工具条和左上角画面信息是否显示：显示后 HUD_HIDE_MS 内没有操作就自动隐藏，点画面再叫出来
  @State controlsVisible: boolean = true;
  private hudTimer: number = -1;
  // 播放页上一次提示“怎么断开”的时间（毫秒）
  private backHintAt: number = 0;
  // 录像：recording 为 true 时在录（边播边录或只录制）；recordOnly 为 true 时是“只录制”页面，不显示画面
  @State recording: boolean = false;
  @State recordOnly: boolean = false;
  // 还没录进第一帧（等关键帧）
  @State recordWaiting: boolean = true;
  @State recordDurationMs: number = 0;
  @State recordBytes: number = 0;
  // 只录制页面上的详细信息：输出尺寸、编码、码率、没录进去的帧
  @State recordInfo: string = '';
  private recordSession: RecordingSession | null = null;
  private recordStopping: boolean = false;
  // 为录像申请的长时任务（录完就停）
  private keeperForRecording: boolean = false;
  private recordOnlySince: number = 0;
  // 通知栏上的计时实况窗，带“停止录制”按钮（目前关闭，见 RecordStatus.ets 的 TIMER_LIVE_VIEW_ENABLED）
  private recordStatus: RecordStatus | null = null;
  private recordStatusShown: boolean = false;

  // 手柄（菜单里的“手柄”页）：菜单开着时手柄不操作游戏机，手柄页开着时“正在按”实时显示
  @State padTakes: boolean = false;
  @State padAttached: boolean = false;
  @State padPressing: string = '';
  @State padSticks: string = '';
  @State padDeviceName: string = '';
  @StorageLink('nssft.padEnabled') @Watch('applyPad') padEnabled: boolean = true;
  @StorageLink('nssft.padLayout') @Watch('applyPad') padLayout: number = 0;
  @StorageLink('nssft.padDeadZone') @Watch('applyPad') padDeadZone: number = 1;
  // 触屏手柄（views/VirtualPad.ets）；本机有没有触摸屏（common/Gamepad.ets watchTouchscreen）
  @StorageProp(VPAD_AVAILABLE_KEY) vpadOk: boolean = false;
  @StorageLink('nssft.vpadShown') vpadShown: boolean = false;
  @StorageLink('nssft.vpadSize') vpadSize: number = 1;
  @StorageLink('nssft.vpadOpacity') vpadOpacity: number = 1;
  @StorageLink('nssft.vpadHaptic') vpadHaptic: boolean = true;
  @StorageLink('nssft.vpadAutoHide') vpadAutoHide: boolean = true;
  // 串流时的屏幕方向（宽屏状态下生效，见 Gamepad.PLAY_ORIENT_*）
  @StorageLink('nssft.playOrientation') @Watch('onScreenClassChanged') playOrientation: number = 0;
  // 进播放页（或键位编辑）前页面是不是竖着的：退出时摆回这个方向再交给系统
  private prePlayPortrait: boolean = true;
  // 播放页或键位编辑把方向锁成了横屏 / 竖屏（不是跟随系统）：退出时才需要先摆回去，见 restoreOrientation
  private orientLocked: boolean = false;
  // 键位有变化（新建、改名、删除、保存、换当前）时刷新触屏手柄和菜单里的键位列表
  @StorageProp(VPAD_LAYOUTS_EPOCH) layoutsEpoch: number = 0;
  // 从键位管理页编辑某个键位（全屏编辑，不在串流时）：键位 id 和它的摆法
  @State layoutEditId: string = '';
  @State layoutEditMode: string = '';
  @State editorW: number = 0;
  @State editorH: number = 0;
  private promptController: CustomDialogController | null = null;
  // 调整键位中（手柄面板里的“调整键位”进入）
  @State @Watch('onVpadEditingChanged') vpadEditing: boolean = false;
  private padDevices: PadDevices = new PadDevices();
  private padAxis: PadAxisModifier = new PadAxisModifier();
  private padPanelTimer: number = -1;
  private padChordTimer: number = -1;
  private padPlusDown: boolean = false;
  private padMinusDown: boolean = false;
  private padBackAt: number = 0;
  private padKeyLogged: boolean = false;
  private target: StreamTarget | null = null;
  private xController: StreamSurfaceController = new StreamSurfaceController();
  private surfaceId: string = '';
  private sessionStarted: boolean = false;
  private connecting: boolean = false;
  // 申请长时任务时可能弹出授权框，触发 onPageHide；这期间不当作切后台
  private suppressPageHide: boolean = false;
  private inBackground: boolean = false;
  private backgroundSince: number = 0;
  private pageHidden: boolean = false;
  private pip: PipSession = new PipSession();
  private pipSupported: boolean = PipSession.supported();
  private pipTimer: number = -1;
  private keeper: BackgroundKeeper | null = null;
  private booster: NetBooster = new NetBooster();
  private recorder: StatsRecorder = new StatsRecorder();
  private statsTimer: number = -1;
  private liveViewTimer: number = -1;
  private lastStats: SessionStats | null = null;
  private enhanceWarned: boolean = false;
  private hostRemembered: boolean = false;
  private usbPump: UsbPump = new UsbPump();
  private usbWatcher: UsbWatcher = new UsbWatcher();
  // 智慧屏：上次按返回键提示“再按一次断开”的时间
  // 智慧屏长按确认键：按下时计时，到点打开菜单；松开前不把焦点移进菜单，免得松手时误点第一项
  private tvOkTimer: number = -1;
  private tvOkDown: boolean = false;
  private tvFocusOnRelease: boolean = false;

  aboutToAppear(): void {
    migrateOldLayouts();
    watchTouchscreen();
    this.padAxis.handler = (e: FocusAxisEvent) => {
      this.onPadAxis(e);
    };
    this.padDevices.onChange = () => {
      this.padDeviceName = this.padDevices.names.length > 0 ? this.padDevices.names[0] : '';
    };
    this.xController.onCreated = (surfaceId: string) => {
      this.onSurfaceReady(surfaceId);
    };
    this.xController.onDestroyed = () => {
      this.onSurfaceGone();
    };
    const keeper = new BackgroundKeeper(getContext(this) as common.UIAbilityContext);
    keeper.onStopRequested = () => {
      this.leavePlayer();
    };
    keeper.onCanceled = () => {
      this.onKeepAliveCanceled();
    };
    this.keeper = keeper;
    const status = new RecordStatus(getContext(this) as common.UIAbilityContext);
    status.onStop = () => {
      if (this.recordOnly) {
        this.finishRecordOnly();
      } else {
        this.stopRecording('');
      }
    };
    this.recordStatus = status;
    this.pip.onClosed = () => {
      this.onPipClosed();
    };
    this.pip.onAudioToggled = (on: boolean) => {
      this.applyAudio(on);
    };
    applyColorMode(getContext(this), this.colorMode);
    UsbLog.init((getContext(this) as common.UIAbilityContext).filesDir);
    // native 层的状态文字跟随界面语言
    nssft.setLanguage(uiLanguageIndex());
    this.builtLanguage = languageSignature();
    // 专用热点：同步系统里仍在运行的热点，按设置自动开启
    HotspotService.get().init();
    if (this.shortcut.length > 0) {
      // 从快捷方式冷启动：等首页建好再连接
      setTimeout(() => {
        this.onShortcut();
      }, 300);
    }
  }

  aboutToDisappear(): void {
    this.cancelShortcutWait();
    if (this.languageTimer >= 0) {
      clearTimeout(this.languageTimer);
      this.languageTimer = -1;
    }
    this.clearHudTimer();
    this.cancelTvLongPress();
    this.stopPlayback();
  }

  // ---------------------------------------------------------------- 界面语言

  // 配置更新可能稍晚才到，等一下再比对，多次通知只处理一次
  onLanguageChanged(): void {
    if (this.languageTimer >= 0) {
      clearTimeout(this.languageTimer);
    }
    this.languageTimer = setTimeout(() => {
      this.languageTimer = -1;
      this.refreshLanguage();
    }, 150);
  }

  private refreshLanguage(): void {
    nssft.setLanguage(uiLanguageIndex());
    const now = languageSignature();
    if (now === this.builtLanguage) {
      return;
    }
    if (this.playing) {
      this.languageStale = true;
      return;
    }
    this.rebuildForLanguage();
  }

  // 重建页面，让所有 tr() 按新语言重新取词（热点等全局状态不受影响）；在设置页里切换的，重建后回到设置页
  private rebuildForLanguage(): void {
    this.languageStale = false;
    AppStorage.setOrCreate('ui.reopenSettings', this.navStack.size() > 0);
    try {
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'rebuild page failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'rebuild page failed: %{public}s', JSON.stringify(e));
    }
  }

  onPageShow(): void {
    this.pageHidden = false;
    this.applyPad();
    this.cancelPipCheck();
    if (AppStorage.get<boolean>('ui.reopenSettings') === true) {
      AppStorage.setOrCreate('ui.reopenSettings', false);
      this.navStack.pushPathByName('settings', null, false);
    }
    // 小窗开着时点桌面图标回来：系统不会自动收起小窗，播放页只剩黑底
    this.pip.restore();
    this.focusForRemote();
    if (this.inBackground) {
      this.exitBackground();
    }
  }

  // 智慧屏只能用遥控器：进入焦点模式（显示焦点框），首页焦点放在第一个可点的元素上，播放页交给播放器根节点。
  // 不主动激活的话，焦点停在页面根节点，方向键没有反应
  private focusForRemote(): void {
    if (!IS_TV || deviceInfo.sdkApiVersion < 14) {
      return;
    }
    setTimeout(() => {
      try {
        const focus = this.getUIContext().getFocusController();
        focus.activate(true);
        if (this.playing) {
          focus.requestFocus('player-focus');
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'focusForRemote failed: %{public}s', JSON.stringify(e));
      }
    }, 300);
  }

  onPageHide(): void {
    this.pageHidden = true;
    // 页面看不见了（切后台、进小窗）就收不到按键：游戏机上拔掉这个手柄，回来再接上
    this.applyPad();
    if (!this.playing) {
      // 离开 App 就不再等游戏机连上热点
      this.cancelShortcutWait();
      return;
    }
    if (this.suppressPageHide || this.pip.isActive()) {
      return;
    }
    if (this.pip.autoStartArmed()) {
      // 系统会在切后台时自动转入小窗；没转入（例如系统设置里关了画中画）再按切后台处理
      this.schedulePipCheck(PIP_WAIT_MS);
      return;
    }
    this.handleBackground();
  }

  // 切到后台、且没有在小窗里播放：在录像就继续接收（长时任务），否则断开
  private handleBackground(): void {
    if (this.keeper !== null && this.keeper.isRunning()) {
      this.enterBackground();
    } else {
      this.leavePlayer();
    }
  }

  private schedulePipCheck(delayMs: number): void {
    this.cancelPipCheck();
    this.pipTimer = setTimeout(() => {
      this.pipTimer = -1;
      if (this.pageHidden && this.playing && !this.inBackground && !this.pip.isActive()) {
        this.handleBackground();
      }
    }, delayMs);
  }

  private cancelPipCheck(): void {
    if (this.pipTimer >= 0) {
      clearTimeout(this.pipTimer);
      this.pipTimer = -1;
    }
  }

  // 播放画面可见时（前台或小窗）请求 60Hz，切后台、断开后撤销，交还系统决定
  applyRefreshHint(): void {
    const visible = this.sessionStarted && !this.inBackground && !this.recordOnly;
    nssft.setRefreshRateHint(visible && this.lowRefresh ? PLAYBACK_REFRESH_HZ : 0);
  }

  private onPipClosed(): void {
    if (this.playing) {
      this.schedulePipCheck(PIP_CLOSED_GRACE_MS);
    }
  }

  onBackPress(): boolean {
    if (this.layoutEditId.length > 0) {
      this.closeLayoutEditor();  // 编辑键位时返回 = 取消
      return true;
    }
    if (this.playing && this.padPlayingNow() && Date.now() - this.padBackAt < PAD_BACK_GUARD_MS) {
      return true;  // 手柄的 B 键被系统当成了返回：这一下是给游戏机的
    }
    if (this.menuOpen) {
      // 菜单开着：返回先回到一级，再收起菜单
      if (this.menuPage.length > 0) {
        this.backToMainMenu();
      } else {
        this.closeMenu();
      }
      return true;
    }
    if (this.vpadEditing) {
      this.vpadEditing = false;  // 调整键位时返回 = 取消（没保存的改动丢掉）
      return true;
    }
    if (this.picEditing) {
      this.picEditing = false;  // 调整画面位置时返回 = 取消
      return true;
    }
    if (this.playing && this.recordOnly) {
      this.confirmStopRecordOnly();
      return true;
    }
    if (this.playing && IS_TV) {
      this.requestLeave();  // 智慧屏只有遥控器，不会误触：返回直接断开（录制中先问）
      return true;
    }
    if (this.playing) {
      // 防误返回：播放页的返回（侧滑手势和返回键）都不断开，只提示并叫出菜单按钮；断开只能打开菜单点退出按钮
      // 提示点菜单按钮退出，同时把菜单按钮叫出来（几秒后会收成顶部中间的小把手）
      this.showControls();
      const now = Date.now();
      if (now - this.backHintAt >= BACK_HINT_GAP_MS) {
        this.backHintAt = now;
        promptAction.showToast({ message: tr('player_toast_back_blocked') });
      }
      return true;
    }
    if (this.navStack.size() > 0) {
      this.navStack.pop();
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- 桌面快捷方式

  onShortcut(): void {
    const raw = this.shortcut;
    if (raw.length === 0 || raw === this.handledShortcut) {
      return;
    }
    this.handledShortcut = raw;
    // 已经在串流（或正在连接）：快捷方式只是把 App 带回前台
    if (this.playing || this.connecting) {
      return;
    }
    this.cancelShortcutWait();
    const last = lastRecentHost();
    if (last === null) {
      promptAction.showToast({ message: tr('shortcut_no_recent') });
      return;
    }
    this.navStack.clear();
    if (shortcutAction(raw) === SHORTCUT_HOTSPOT_CONNECT) {
      if (hotspotSupported()) {
        this.hotspotThenConnect(last);
        return;
      }
      promptAction.showToast({ message: tr('shortcut_hotspot_unsupported') });
    }
    this.connectRecent(last, last.host);
  }

  private connectRecent(h: RecentHost, host: string): void {
    this.play({ host: host, label: h.alias.length > 0 ? h.alias : host, version: h.version, usb: null });
  }

  // “热点+连接”：开启专用热点，等游戏机连上来、发出广播再连接（游戏机在热点上的地址不一定和上次一样）
  private async hotspotThenConnect(last: RecentHost): Promise<void> {
    const hs = HotspotService.get();
    if (!hs.isOn()) {
      promptAction.showToast({ message: tr('shortcut_hotspot_starting') });
      const err = await hs.start();
      if (err.length > 0) {
        promptAction.showToast({ message: tr('shortcut_hotspot_failed', err), duration: 4000 });
        return;
      }
    }
    promptAction.showToast({ message: tr('shortcut_waiting'), duration: 4000 });
    const deadline = Date.now() + SHORTCUT_WAIT_MS;
    this.shortcutTimer = setInterval(() => {
      this.pollShortcutWait(last, deadline);
    }, 1000);
  }

  private pollShortcutWait(last: RecentHost, deadline: number): void {
    if (this.playing || this.connecting) {
      this.cancelShortcutWait();
      return;
    }
    const goIp = AppStorage.get<string>('hs.goIp') ?? '';
    if (HotspotService.get().isOn() && goIp.length > 0) {
      const devices = nssft.getDevices();
      const prefix = (ip: string): string => ip.split('.').slice(0, 3).join('.');
      const pick = devices.find((d: DeviceInfo): boolean => d.ip === last.host) ??
        devices.find((d: DeviceInfo): boolean => prefix(d.ip) === prefix(goIp));
      if (pick !== undefined) {
        this.cancelShortcutWait();
        this.connectRecent(last, pick.ip);
        return;
      }
    }
    if (Date.now() > deadline) {
      this.cancelShortcutWait();
      promptAction.showToast({ message: tr('shortcut_wait_timeout'), duration: 4000 });
    }
  }

  private cancelShortcutWait(): void {
    if (this.shortcutTimer >= 0) {
      clearInterval(this.shortcutTimer);
      this.shortcutTimer = -1;
    }
  }

  // ---------------------------------------------------------------- 连接与播放

  private async play(target: StreamTarget): Promise<void> {
    if (this.connecting || this.playing) {
      return;
    }
    if (target.recordOnly === true) {
      await this.playRecordOnly(target);
      return;
    }
    this.connecting = true;
    this.target = target;
    this.hostRemembered = false;
    this.statusText = tr('player_connecting', target.label);
    this.badgeText = '';
    this.statsText = '';
    this.backHintAt = 0;
    this.menuOpen = false;
    this.menuPage = '';
    this.controlsVisible = true;
    // 显示 XComponent，surface 就绪后（onSurfaceReady）真正建立连接
    this.playing = true;
    // 进入播放页先显示工具条，几秒后自动隐藏（要在 playing 置位之后计时）
    this.armHudTimer();
    this.connecting = false;
    this.rememberPageOrientation();
    this.setImmersive(true);
    // 防误返回：侧滑返回照常可用，和返回键一样只提示、不断开（见 onBackPress）；系统层面关掉手势的话，
    // 侧滑时 App 收不到返回，用户就看不到“如需退出…”的提示。调整键位时才关掉（见 onVpadEditingChanged）
    this.focusForRemote();
    this.startPad();
    if (IS_TV) {
      if (AppStorage.get<boolean>('nssft.tvGuideShown') !== true) {
        // 第一次在智慧屏上串流：弹窗说明遥控器各个键的用法
        AppStorage.setOrCreate('nssft.tvGuideShown', true);
        promptAction.showDialog({
          title: tr('tv_guide_title'),
          message: tr('tv_guide_body'),
          buttons: [{ text: tr('common_ok'), color: '#FF26C6B0' }]
        }).catch(() => {
        });
      } else {
        promptAction.showToast({ message: tr('player_toast_tv_menu'), duration: 3000 });
      }
    } else if (AppStorage.get<boolean>('nssft.menuHintShown') !== true) {
      AppStorage.setOrCreate('nssft.menuHintShown', true);
      promptAction.showToast({ message: tr('player_toast_menu_hint'), duration: 4000 });
    }
    if (target.usb !== null) {
      // 播放中拔线：及时退出并提示
      this.usbWatcher.start(() => {
        if (this.playing && this.target !== null && this.target.usb !== null && UsbConsole.find() === undefined) {
          promptAction.showToast({ message: tr('player_toast_usb_detached') });
          this.leavePlayer();
        }
      });
    }
  }

  private async startKeeper(): Promise<void> {
    const keeper = this.keeper;
    if (keeper === null) {
      return;
    }
    const err = await keeper.start();
    if (err.length > 0) {
      promptAction.showToast({ message: tr('player_toast_keepalive_unavailable', err), duration: 4000 });
      return;
    }
    this.refreshLiveView(true);
    this.liveViewTimer = setInterval(() => {
      this.refreshLiveView(false);
    }, LIVE_VIEW_INTERVAL_MS);
  }

  private onSurfaceReady(surfaceId: string): void {
    this.surfaceId = surfaceId;
    const t = this.target;
    if (t === null) {
      return;
    }
    if (this.sessionStarted) {
      if (!this.inBackground) {
        // 会话还在但 surface 重建了：绑定到新 surface
        this.resumeRendering();
      }
      return;
    }
    this.connectSession(t, surfaceId);
  }

  // 建立原生会话并开始轮询统计；只录制时 surfaceId 为空。失败时已提示并退出，返回 false
  private connectSession(t: StreamTarget, surfaceId: string): boolean {
    const recordOnly = t.recordOnly === true;
    const cfg: ConnectConfig = {
      surfaceId: surfaceId,
      audio: this.enableAudio && !recordOnly,
      netOpt: this.netOpt,
      // 丢帧定格一直开着（原生层默认）：SFT 的网络和 USB 都是可靠传输，实测从不触发，只当保险，不再给开关
      enhanceLevel: enhanceAvailable() && !recordOnly ? this.enhanceLevel : 0,
      recordOnly: recordOnly
    };
    const link = t.usb;
    if (link !== null) {
      cfg.usb = true;
      cfg.usbFd = link.fd;
      cfg.usbInterface = link.iface.id;
      cfg.usbEpIn = link.epIn.address;
      cfg.usbEpOut = link.epOut.address;
      cfg.usbPump = link.pump;
      if (link.pump) {
        cfg.onUsbWrite = this.usbPump.onWrite;
      }
    } else {
      cfg.host = t.host;
      cfg.port = SFT_PORT;
    }
    const err = nssft.connect(cfg);
    if (err.length > 0) {
      hilog.error(DOMAIN, TAG, 'connect failed: %{public}s', err);
      promptAction.showToast({ message: tr('player_toast_start_failed', err), duration: 4000 });
      this.leavePlayer();
      return false;
    }
    if (link !== null && link.pump) {
      this.usbPump.start(link);
    }
    this.sessionStarted = true;
    this.lastStats = null;
    this.enhanceWarned = false;
    if (link === null && this.netOpt) {
      this.booster.enter();
    }
    if (this.pipSupported && !recordOnly) {
      this.pip.open(getContext(this), this.xController, this.pipAuto, this.enableAudio);
    }
    this.applyRefreshHint();
    this.startStats(t);
    return true;
  }

  private startStats(t: StreamTarget): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.recorder.start(ctx.filesDir, `target=${t.usb !== null ? 'usb' : t.host}`);
    this.statsTimer = setInterval(() => {
      try {
        this.pollStats();
      } catch (e) {
        // 统计只是辅助信息，出错不能把播放带崩
        hilog.warn(DOMAIN, TAG, 'pollStats failed: %{public}s', JSON.stringify(e));
      }
    }, 1000);
  }

  private onSurfaceGone(): void {
    this.surfaceId = '';
    if (this.sessionStarted) {
      // 解码器不能继续往已销毁的 surface 上画
      nssft.pauseVideo();
    }
  }

  // ---------------------------------------------------------------- 手柄

  // 进入播放页（显示画面时）：开始监听本机的手柄，设置交给原生层（会话建立时带上）
  private startPad(): void {
    if (this.recordOnly) {
      return;
    }
    this.padPlusDown = false;
    this.padMinusDown = false;
    this.padKeyLogged = false;
    this.padDevices.start();
    this.applyPad();
    // 按键和焦点轴事件只发给获焦的组件链：播放器是进入播放页才渲染出来的，defaultFocus 不生效，要主动给它焦点
    // （不激活焦点框，触屏上看不出来）
    setTimeout(() => {
      if (!this.playing) {
        return;
      }
      try {
        this.getUIContext().getFocusController().requestFocus('player-focus');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'focus player failed: %{public}s', JSON.stringify(e));
      }
    }, 300);
  }

  private stopPad(): void {
    this.stopPadPoll();
    this.vpadEditing = false;
    this.clearPadChord();
    this.padDevices.stop();
    padConfigure(false);
  }

  // 设置变了、切前后台时：只有播放页在前台、在显示画面时才用手柄
  applyPad(): void {
    padConfigure(this.playing && !this.recordOnly && !this.inBackground && !this.pageHidden);
    this.syncPadPlaying();
  }

  // 菜单、面板开着时手柄接着但不操作游戏机（按键留给界面）
  syncPadPlaying(): void {
    nssft.padPlaying(this.padPlayingNow());
  }

  // 触屏手柄现在显示不显示：打开了、手柄功能开着、在显示画面；接上实体手柄时按设置自动收起
  private vpadVisible(): boolean {
    return this.vpadOk && this.vpadShown && this.padEnabled && this.playing && !this.recordOnly &&
      !(this.vpadAutoHide && this.padDeviceName.length > 0);
  }

  // 触屏手柄现在的摆法：播放区竖着就用竖屏键位（内置的按键集中在下方），否则用横屏键位。
  // 触屏手柄是盖满播放区的一层，和画面互不影响：挪画面不会移动、缩放按键，也不会换键位
  private vpadMode(): VpadMode {
    return this.playerAreaH > this.playerAreaW ? 'portrait' : 'landscape';
  }

  // ---------------------------------------------------------------- 画面位置

  // 画面上下一共空出多高（画面按 16:9 放进播放区，宽度铺满时下面这个才大于 0）
  private picFreeV(): number {
    return Math.max(0, this.playerAreaH - this.playerHeight);
  }

  // 有没有地方可以挪画面（手机横屏、电视这种画面占满高度的没有）
  private picMovable(): boolean {
    return this.playing && !this.recordOnly && this.picFreeV() >= PIC_MIN_FREE_VP;
  }

  // 现在的位置：调整中用拖动的位置；这种形态记过就用记住的；没记过时竖屏贴顶（下方留给按键），横屏居中
  private picPosNow(): number {
    if (this.picEditing) {
      return this.picEditPos;
    }
    if (this.picPos >= 0) {
      return this.picPos;
    }
    return this.playerAreaH > this.playerAreaW ? 0 : 0.5;
  }

  private picTop(): number {
    return this.picFreeV() * this.picPosNow();
  }

  // 画面下方的空白（调整画面位置时，工具条放上面还是下面看它）
  private picFreeBelow(): number {
    return this.picFreeV() - this.picTop();
  }

  private picPosLabel(pos: number): string {
    return picPosName(pos, tr('pic_pos_top'), tr('pic_pos_center'), tr('pic_pos_bottom'), tr('pic_pos_custom'));
  }

  // 播放区大小变了（折叠 / 展开、转屏、PC 窗口）：换成这种形态记住的位置
  private reloadPicPos(): void {
    const key = picPosKey(this.playerAreaW, this.playerAreaH);
    if (key !== this.picKey) {
      this.picKey = key;
      this.picPos = loadPicPos(key);
      // 调整中换了形态（转屏、折叠展开）：拖的是上一种形态的位置，取消，免得保存到这种形态上
      this.picEditing = false;
    }
  }

  // 调整画面位置：收起菜单和工具条，上下拖动画面，点“保存”才记住
  private startPicEdit(): void {
    if (!this.picMovable()) {
      return;
    }
    this.closeMenu();
    this.clearHudTimer();
    this.controlsVisible = false;
    this.picEditOrig = this.picPosNow();
    this.picEditPos = this.picEditOrig;
    this.picEditing = true;
  }

  // 调整画面位置的工具条放在哪：上方空白大就放上方，下方大就放画面下面；两块都放不下时贴顶
  private picEditBarTop(): number {
    const above = this.picTop();
    const below = this.picFreeBelow();
    if (Math.max(above, below) < PIC_EDIT_BAR_SLOT_VP || above >= below) {
      return 0;
    }
    return above + this.playerHeight;
  }

  private savePicEdit(): void {
    this.picPos = this.picEditPos;
    savePicPos(this.picKey, this.picEditPos);
    this.picEditing = false;
    promptAction.showToast({ message: tr('pic_pos_saved') });
  }

  // 拖到 top（画面顶边离播放区顶部多少 vp）：限制在空白范围内，靠近顶部、居中、底部时吸附
  private dragPicTo(top: number): void {
    const free = this.picFreeV();
    if (free <= 0) {
      return;
    }
    const t = Math.max(0, Math.min(free, top));
    // 吸附到最近的那个点：空白不大时（不到 2 × PIC_SNAP_VP）几个点的吸附范围会重叠，按顺序取第一个就到不了底部
    let pos = t / free;
    let best = PIC_SNAP_VP;
    for (const a of PIC_ANCHORS) {
      const d = Math.abs(t - a * free);
      if (d <= best) {
        best = d;
        pos = a;
      }
    }
    this.picEditPos = pos;
  }

  // 当前摆法用的键位 id（空串：内置）；layoutsEpoch 让它随键位变化重新算
  private vpadLayoutId(mode: string): string {
    return this.layoutsEpoch >= 0 ? activeLayoutId(mode) : '';
  }

  // 调整键位后点了保存：存进当前键位；当前是内置键位（不能改）时先起个名字，另存为新键位并换成它
  private saveVpadLayout(mode: string, units: UnitSave[], done: () => void): void {
    const id = activeLayoutId(mode);
    if (id.length > 0) {
      updateLayoutUnits(id, units);
      promptAction.showToast({ message: tr('vpad_layout_saved') });
      done();
      return;
    }
    this.askLayoutName(tr('vpad_layout_saveas_title'), suggestLayoutName(mode), mode, '', (name: string) => {
      setActiveLayout(mode, createLayout(mode, name, units));
      promptAction.showToast({ message: tr('vpad_layout_saved') });
      done();
    });
  }

  // 菜单里的键位下拉框：第一项是内置，后面是这种摆法的自建键位
  private layoutNames(mode: string): string[] {
    const names: string[] = [tr('vpad_builtin')];
    if (this.layoutsEpoch >= 0) {
      for (const l of listLayouts(mode)) {
        names.push(l.name);
      }
    }
    return names;
  }

  private layoutIndex(mode: string): number {
    const id = this.vpadLayoutId(mode);
    const i = listLayouts(mode).findIndex((l: PadLayout) => l.id === id);
    return i < 0 ? 0 : i + 1;
  }

  // 键位名称输入框（不能空、同一种摆法里不能重名）
  private askLayoutName(title: string, initial: string, mode: string, exceptId: string, ok: (name: string) => void): void {
    this.promptController = new CustomDialogController({
      builder: TextPromptDialog({
        title: title,
        placeholder: tr('vpad_layout_name_placeholder'),
        confirmText: tr('common_save'),
        text: initial,
        address: false,
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

  // 横屏键位的触屏手柄（左上角、右上角是肩键，状态提示和录制标记要挪开）；竖屏键位的按键在下方，不用挪
  private vpadOverlayNow(): boolean {
    return this.vpadVisible() && this.vpadMode() === 'landscape';
  }

  // 调整键位：收起面板和工具条，在当前摆法（横屏 / 竖屏）上拖动
  private startVpadEdit(): void {
    this.closeMenu();
    this.clearHudTimer();
    this.controlsVisible = false;
    this.vpadEditing = true;
  }

  private padPlayingNow(): boolean {
    return !this.menuOpen;
  }

  // 按键事件 → 原生层；返回 true 表示交给了游戏机（调用方吞掉，不再移动界面焦点）
  private onPadKey(event: KeyEvent): boolean {
    if (!this.playing || this.recordOnly || (event.type !== KeyType.Down && event.type !== KeyType.Up)) {
      return false;
    }
    const down = event.type === KeyType.Down;
    const code = event.keyCode;
    const taken = nssft.padKey(code, down);
    if (!this.padKeyLogged && down) {
      // 每次串流只记第一个键，方便排查手柄的键有没有送到
      this.padKeyLogged = true;
      hilog.info(DOMAIN, TAG, 'pad first key %{public}d (device %{public}d) taken=%{public}s', code,
        event.deviceId, String(taken));
    }
    if (!taken) {
      return false;
    }
    if (down && code === PAD_BUTTON_B) {
      this.padBackAt = Date.now();
    }
    if (!this.padPlayingNow()) {
      return false;  // 面板开着：键照样记下（“正在按”要显示），但留给界面处理
    }
    this.trackPadChord(code, down);
    return true;
  }

  private onPadAxis(e: FocusAxisEvent): void {
    if (!this.playing || this.recordOnly) {
      return;
    }
    if (padForwardAxis(e) && this.padPlayingNow()) {
      e.stopPropagation();
    }
  }

  // 同时按住开始键和选择键（+ 和 −）1.5 秒：打开串流选项（智慧屏上打开菜单）
  private trackPadChord(code: number, down: boolean): void {
    if (isPadPlusKey(code)) {
      this.padPlusDown = down;
    } else if (isPadMinusKey(code)) {
      this.padMinusDown = down;
    } else {
      return;
    }
    if (!this.padPlusDown || !this.padMinusDown) {
      this.clearPadChord();
      return;
    }
    if (this.padChordTimer >= 0) {
      return;
    }
    this.padChordTimer = setTimeout(() => {
      this.padChordTimer = -1;
      if (!this.playing || !this.padPlusDown || !this.padMinusDown) {
        return;
      }
      this.padPlusDown = false;
      this.padMinusDown = false;
      nssft.padReset();
      this.openMenu('');
    }, PAD_CHORD_MS);
  }

  private clearPadChord(): void {
    if (this.padChordTimer >= 0) {
      clearTimeout(this.padChordTimer);
      this.padChordTimer = -1;
    }
  }

  // 手柄页开着时“正在按”每 100 ms 刷新
  private syncPadPoll(): void {
    const want = this.menuOpen && this.menuPage === 'pad';
    if (want === this.padPanelTimer >= 0) {
      return;
    }
    if (!want) {
      this.stopPadPoll();
      return;
    }
    this.padDevices.refresh();
    this.pollPad();
    this.padPanelTimer = setInterval(() => {
      this.pollPad();
    }, PAD_PANEL_POLL_MS);
  }

  private stopPadPoll(): void {
    if (this.padPanelTimer >= 0) {
      clearInterval(this.padPanelTimer);
      this.padPanelTimer = -1;
    }
  }

  private pollPad(): void {
    const s = nssft.getPadStatus();
    this.padTakes = s.takesInput;
    this.padAttached = s.attached;
    this.padPressing = s.buttons;
    this.padSticks = tr('pad_sticks', s.lx, s.ly, s.rx, s.ry);
  }

  private padStatusText(): string {
    if (!this.padEnabled) {
      return tr('pad_status_off');
    }
    if (!this.padTakes) {
      return tr('pad_status_console_off');
    }
    const who = this.padDeviceName.length > 0 ? this.padDeviceName :
      this.vpadVisible() ? tr('vpad_name') : this.padAttached ? tr('pad_device_keyboard') : '';
    if (who.length === 0) {
      return tr('pad_status_no_device');
    }
    return this.padAttached ? tr('pad_status_ready', who) : tr('pad_status_connecting', who);
  }

  // ---------------------------------------------------------------- 前后台切换

  private enterBackground(): void {
    this.inBackground = true;
    this.backgroundSince = Date.now();
    // 照常接收，释放解码器和音频，只维护 GOP 缓存；后台不渲染，也不必再占用网络加速
    nssft.pauseVideo();
    this.booster.leave();
    this.applyRefreshHint();
    this.refreshLiveView(true);
    this.applyPad();  // 后台收不到按键：游戏机上拔掉这个手柄
  }

  private exitBackground(): void {
    this.inBackground = false;
    this.resumeRendering();
    this.applyPad();
    if (this.netOpt && this.target !== null && this.target.usb === null) {
      this.booster.enter();
    }
    this.applyRefreshHint();
    this.refreshLiveView(true);
    hilog.info(DOMAIN, TAG, 'back to foreground after %{public}d s',
      Math.round((Date.now() - this.backgroundSince) / 1000));
  }

  // 用户在通知栏删除了录像的系统实况窗（长时任务随之被系统取消）：
  // 在后台时当作“停止”，录像写完文件后断开；前台时只提示切到后台录制会停止，不打断录制
  private onKeepAliveCanceled(): void {
    if (this.liveViewTimer >= 0) {
      clearInterval(this.liveViewTimer);
      this.liveViewTimer = -1;
    }
    this.keeperForRecording = false;
    if (!this.playing) {
      return;
    }
    if (this.inBackground) {
      this.leavePlayer();
    } else if (this.recording) {
      promptAction.showToast({ message: tr('player_toast_keepalive_off') });
    }
  }

  private resumeRendering(): void {
    if (this.surfaceId.length === 0) {
      return; // surface 还没就绪，等 onSurfaceCreated 再恢复
    }
    const err = nssft.resumeVideo(this.surfaceId);
    if (err.length > 0) {
      hilog.error(DOMAIN, TAG, 'resume failed: %{public}s', err);
      promptAction.showToast({ message: tr('player_toast_resume_failed', err) });
    }
  }

  private refreshLiveView(force: boolean): void {
    const keeper = this.keeper;
    const t = this.target;
    if (keeper === null || !keeper.isRunning() || t === null) {
      return;
    }
    // 长时任务只为录像申请：实况窗显示录了多久、多大（只录制模式下还没录进画面时显示“等待画面”），每秒刷新
    keeper.update({
      title: tr('app_live_title_rec', APP_NAME),
      text: this.recording && !this.recordWaiting ?
        tr('app_live_text_rec', t.label, formatClock(this.recordDurationMs), formatBytes(this.recordBytes)) :
        tr('app_live_text_rec_wait', t.label),
      progress: 0,
      // 正计时（系统实况窗支持时显示，系统每秒自己走）；还没录进画面时不带
      elapsedMs: this.recording && !this.recordWaiting ? this.recordDurationMs : undefined
    });
  }

  // ---------------------------------------------------------------- 统计

  // 统计浮层：参考 SFT 的 Android TV 接收端，左上角一块面板、每秒刷新，不分页签：
  // 连接·分辨率·码率 / 收到·显示帧率 / 游戏机端耗时·刷新率 / 声音 / 丢帧与定格 / 其他（画质增强、解码器错误）
  private pollStats(): void {
    const s = nssft.getStats();
    if (this.recordOnly) {
      this.pollRecordOnly(s);
    }
    if (this.recording) {
      this.pollRecording();
    }
    const prev = this.lastStats;
    const viaUsb = this.target !== null && this.target.usb !== null;
    this.rememberTarget(s.connected && s.videoPackets > 0);
    let recvFps = 0;
    let fps = 0;
    let kbps = 0;
    let linkMbps = 0;
    let audioKbps = 0;
    if (prev !== null) {
      audioKbps = Math.max(0, Math.round((s.audioBytes - prev.audioBytes) * 8 / 1000));
      // 游戏机一帧一个包：收包数/秒就是“收到的帧率”，和显示帧率对比能看出瓶颈在传输还是本机
      recvFps = Math.max(0, s.videoPackets - prev.videoPackets);
      fps = Math.max(0, s.framesRendered - prev.framesRendered);
      kbps = Math.max(0, Math.round((s.videoBytes - prev.videoBytes) * 8 / 1000));
      linkMbps = Math.max(0, (s.videoBytes + s.audioBytes - prev.videoBytes - prev.audioBytes) * 8 / 1e6);
    }
    this.lastStats = s;
    // 画面起来之前显示连接状态，起来之后收起；丢帧定格时这一秒可能一帧都没出，但画面是有意停住的
    // （只录制时没有显示，状态由 pollRecordOnly 按收到的帧决定）
    if (!this.recordOnly) {
      this.statusText = s.connected && (fps > 0 || s.frozen) ? '' : s.message;
    }
    if (s.streamHeight > 0 && fps > 0) {
      this.badgeText = tr('player_badge', s.streamHeight >= 1000 ? '1080p' : `${s.streamHeight}p`, recvFps);
    }

    const t = this.target;
    const where = t === null ? '' : (t.usb !== null ? `USB · ${t.usb.transport}` : tr('stats_network', t.host));
    const lines: string[] = [
      tr('stats_line_link', where, s.streamWidth, s.streamHeight, linkMbps.toFixed(1)),
      tr('stats_line_video', recvFps, fps, kbps, s.keyframes, s.keyRequests),
      tr('stats_line_latency', s.consoleAgeMs.toFixed(1), s.vsyncPeriodUs > 0 ? Math.round(1e6 / s.vsyncPeriodUs) : 0,
        s.renderJitterMs.toFixed(1), s.renderMaxGapMs),
      s.audioEnabled ?
        (s.audioPackets > 0 ? tr('stats_line_audio', audioKbps, s.audioBufferedMs, s.audioTargetMs, s.audioUnderruns) :
        tr('stats_line_audio_none')) : tr('stats_line_audio_off'),
      tr('stats_line_loss', s.lossGap, s.lostFrames, s.lossResync, s.freezeEvents,
        s.frozen ? tr('stats_frozen_now') : '', s.videoDropped, s.reconnects)
    ];
    if (s.enhanceRequested > 0) {
      lines.push(s.enhanceLevel > 0 ?
        tr('stats_enhance_on', enhanceLabels()[s.enhanceLevel], (s.enhanceLatencyUs / 1000).toFixed(1)) :
        tr('stats_enhance_off', s.enhanceError.length > 0 ? s.enhanceError : s.enhanceIdle.length > 0 ? s.enhanceIdle : '—'));
    }
    if (s.consoleStatusReason !== 0) {
      lines.push(tr('stats_console_status', s.consoleStatusHead, s.consoleStatusDetail));
    }
    if (!viaUsb && this.netOpt && !this.inBackground) {
      this.booster.updateFlows(nssft.getSocketFlows());
    }
    if (s.decoderError.length > 0) {
      lines.push(s.decoderError);
    }
    this.statsText = lines.join('\n');

    if (!this.enhanceWarned && s.enhanceRequested > 0 && s.enhanceLevel === 0 && s.enhanceError.length > 0) {
      // 设置里开了画质增强但本机不支持：只提示一次，播放照常进行
      this.enhanceWarned = true;
      promptAction.showToast({ message: tr('player_toast_enhance_unavailable', s.enhanceError), duration: 3500 });
    }
    if (prev !== null) {
      const delta = (now: number, before: number): number => Math.max(0, now - before);
      this.recorder.write([this.inBackground ? 1 : 0, recvFps, fps, kbps, audioKbps,
        delta(s.videoDropped, prev.videoDropped),
        s.audioEnabled ? 1 : 0, s.audioBufferedMs, s.audioTargetMs, delta(s.audioUnderruns, prev.audioUnderruns),
        s.netOpt ? 1 : 0, s.reconnects, s.resyncs,
        s.streamWidth, s.streamHeight, Math.round(s.consoleAgeMs * 10) / 10, delta(s.keyframes, prev.keyframes),
        delta(s.keyRequests, prev.keyRequests),
        delta(s.lossGap, prev.lossGap), delta(s.lostFrames, prev.lostFrames), delta(s.lossResync, prev.lossResync),
        delta(s.lossOversize, prev.lossOversize), s.freezeOnLoss ? 1 : 0, s.frozen ? 1 : 0,
        delta(s.freezeEvents, prev.freezeEvents), delta(s.freezeTotalMs, prev.freezeTotalMs),
        delta(s.freezeGiveUps, prev.freezeGiveUps), Math.round(s.frameIntervalUs / 100) / 10, s.keyframeIntervalMs,
        Math.round(s.vsyncPeriodUs / 100) / 10, delta(s.vsyncDeferred, prev.vsyncDeferred),
        delta(s.vsyncDropped, prev.vsyncDropped), delta(s.stutters, prev.stutters), s.renderJitterMs,
        s.renderMaxGapMs, s.enhanceLevel, Math.round(s.enhanceLatencyUs / 100) / 10, this.hotspotChannel,
        this.staChannel]);
    }
  }

  // 收到画面后把这台主机记进“最近连接”（广播里看到的 SFT 版本一起记下）
  private rememberTarget(connected: boolean): void {
    const t = this.target;
    if (!connected || this.hostRemembered || t === null) {
      return;
    }
    this.hostRemembered = true;
    let version = t.version;
    if (version.length === 0) {
      const seen = nssft.getDevices().find((d: DeviceInfo): boolean => d.ip === t.host);
      version = seen !== undefined ? sftVersionOf(seen.name) : '';
    }
    rememberHost(t.host, version);
    const r = findRecentHost(AppStorage.get<string>('nssft.recentHosts') ?? '', t.host);
    if (r !== undefined && r.alias.length > 0) {
      t.label = r.alias;
    }
  }

  private stopPlayback(): void {
    this.stopPad();
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    if (this.liveViewTimer >= 0) {
      clearInterval(this.liveViewTimer);
      this.liveViewTimer = -1;
    }
    this.cancelPipCheck();
    this.pip.close();
    // 顺序：先停兼容传输的读循环、再停 native 会话（会发告别），最后关闭 USB 设备
    this.usbPump.stop();
    nssft.disconnect();
    this.usbWatcher.stop();
    const t = this.target;
    if (t !== null && t.usb !== null) {
      UsbConsole.close(t.usb);
      t.usb = null;
    }
    this.booster.leave();
    this.recorder.stop();
    this.sessionStarted = false;
    this.inBackground = false;
    this.applyRefreshHint();
    this.menuOpen = false;
    this.lastStats = null;
    if (this.keeper !== null) {
      this.keeper.stop();
    }
  }

  // ---------------------------------------------------------------- 录像

  private toggleRecording(): void {
    if (this.recording) {
      this.stopRecording('');
    } else {
      this.startRecording();
    }
  }

  // 开始录制（播放页点“录制”，或只录制模式下等到画面后自动开始）；返回是否已开始
  private startRecording(): boolean {
    if (this.recording || this.recordStopping || !this.sessionStarted) {
      return false;
    }
    const why = recordUnsupportedReason(!this.recordOnly);
    if (why.length > 0) {
      promptAction.showToast({ message: tr('player_toast_record_unsupported', why), duration: 4000 });
      return false;
    }
    const t = this.target;
    const session = new RecordingSession();
    const err = session.start(getContext(this), t !== null ? t.label : '');
    if (err.length > 0) {
      promptAction.showToast({ message: tr('player_toast_record_failed', err), duration: 4000 });
      return false;
    }
    this.recordSession = session;
    this.recording = true;
    this.recordWaiting = true;
    this.recordDurationMs = 0;
    this.recordBytes = 0;
    this.recordInfo = '';
    this.ensureRecordingKeeper();
    this.recordStatusShown = false;
    if (!this.recordOnly) {
      promptAction.showToast({ message: tr('player_toast_record_started') });
    }
    hilog.info(DOMAIN, TAG, 'recording started');
    return true;
  }

  // 为录像申请长时任务：切到后台、锁屏也能继续录（录完再停）
  private ensureRecordingKeeper(): void {
    const keeper = this.keeper;
    if (keeper === null || keeper.isRunning()) {
      return;
    }
    this.keeperForRecording = true;
    this.suppressPageHide = true;
    this.startKeeper().then(() => {
      this.suppressPageHide = false;
    });
  }

  // 停止录制：原生层马上摘下录像器、在工作线程写完文件；reason 非空时先说明为什么停
  private async stopRecording(reason: string): Promise<void> {
    const session = this.recordSession;
    if (!this.recording || session === null) {
      return;
    }
    this.recording = false;
    this.recordStopping = true;
    this.recordSession = null;
    this.recordStatus?.stop(this.recordStatusInfo());
    const r = await session.stop();
    this.recordStopping = false;
    const saved = r.files.length > 0 ?
      tr('player_toast_record_saved', formatClock(r.durationMs), formatBytes(r.bytes)) : tr('player_toast_record_empty');
    promptAction.showToast({ message: reason.length > 0 ? `${reason}\n${saved}` : saved, duration: 4000 });
    this.releaseRecordingKeeper();
  }

  // 录完就停掉为录像申请的长时任务（还在后台就顺便断开：不录制时不在后台保持连接）
  private releaseRecordingKeeper(): void {
    if (!this.keeperForRecording) {
      return;
    }
    this.keeperForRecording = false;
    if (!this.playing) {
      return;
    }
    if (this.inBackground) {
      this.leavePlayer();
      return;
    }
    if (this.liveViewTimer >= 0) {
      clearInterval(this.liveViewTimer);
      this.liveViewTimer = -1;
    }
    if (this.keeper !== null) {
      this.keeper.stop();
    }
  }

  // 通知栏上显示的录制状态
  private recordStatusInfo(): RecordStatusInfo {
    return {
      elapsedMs: this.recordDurationMs,
      size: formatBytes(this.recordBytes)
    };
  }

  // 每秒随统计：录了多久、多大；出错或空间不够时停止
  private pollRecording(): void {
    const session = this.recordSession;
    if (session === null) {
      return;
    }
    const r = nssft.getRecordStats();
    this.recordWaiting = r.framesEncoded === 0;
    this.recordDurationMs = r.durationMs;
    this.recordBytes = r.bytes;
    if (r.width > 0) {
      const parts: string[] = [`${r.width}×${r.height}`, r.hevc ? 'H.265' : 'H.264', `${(r.bitrateKbps / 1000).toFixed(0)} Mbps`];
      if (r.framesDropped > 0) {
        parts.push(tr('record_info_dropped', r.framesDropped));
      }
      this.recordInfo = parts.join(' · ');
    }
    // 通知栏：录进第一帧时才创建（录像没有暂停，只有“录制中”一个状态），之后每秒更新已录大小并校准计时
    if (!this.recordWaiting && !this.recordStatusShown) {
      this.recordStatusShown = true;
      this.recordStatus?.start(this.recordStatusInfo());
    } else if (this.recordStatusShown) {
      this.recordStatus?.update(this.recordStatusInfo());
    }
    if (r.error.length > 0) {
      this.stopRecording(tr('player_toast_record_error', r.error));
    } else if (session.lowSpace()) {
      this.stopRecording(tr('player_toast_record_low_space'));
    }
  }

  // 只录制：不显示画面、不出声。连上并收到画面后自动开始录；切到后台、锁屏照常录
  private async playRecordOnly(target: StreamTarget): Promise<void> {
    const why = recordUnsupportedReason(false);
    if (why.length > 0) {
      promptAction.showToast({ message: tr('player_toast_record_unsupported', why), duration: 4000 });
      return;
    }
    this.connecting = true;
    this.target = target;
    this.hostRemembered = false;
    // 长时任务只能在前台申请：先申请好再进录制页面
    if (this.keeper !== null && !this.keeper.isRunning()) {
      await this.startKeeper();
    }
    this.statusText = tr('player_connecting', target.label);
    this.badgeText = '';
    this.statsText = '';
    this.recordWaiting = true;
    this.recordDurationMs = 0;
    this.recordBytes = 0;
    this.recordInfo = '';
    this.recordOnly = true;
    this.playing = true;
    this.connecting = false;
    this.recordOnlySince = Date.now();
    this.setRecordOnlyBars(true);
    this.focusForRemote();
    this.connectSession(target, '');
  }

  // 只录制页面是深色底：状态栏和小白条的文字、图标换成白色，离开时按当前深浅色模式恢复
  private async setRecordOnlyBars(on: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      updateSystemBarColors(win, on || (AppStorage.get<boolean>('ui.dark') ?? false));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'set record-only bars failed: %{public}s', JSON.stringify(e));
    }
  }

  private pollRecordOnly(s: SessionStats): void {
    // 这一秒收到了画面才算在录（游戏机回到主菜单时会停流，这时显示原生层的状态说明）
    const prev = this.lastStats;
    const receiving = s.connected && prev !== null && s.videoPackets > prev.videoPackets;
    this.statusText = receiving ? '' : s.message;
    // 收到画面后开始录；声音包一般同时就到了，最多再等 3 秒（游戏机可能关了声音）
    if (!this.recording && !this.recordStopping && s.connected && s.videoPackets > 0 &&
      (s.audioPackets > 0 || Date.now() - this.recordOnlySince > 3000)) {
      if (!this.startRecording()) {
        this.leavePlayer();
      }
    }
  }

  // 退出串流（菜单的退出按钮、智慧屏的返回）：录制中先问——停止录制并退出，或继续录制（转到只录制页面），或取消
  private requestLeave(): void {
    if (!this.recording || this.recordOnly) {
      this.leavePlayer();
      return;
    }
    promptAction.showDialog({
      title: tr('player_exit_rec_title'),
      message: tr('player_exit_rec_message'),
      buttons: [
        { text: tr('common_cancel'), color: '#99000000' },
        { text: tr('player_exit_rec_keep'), color: '#FF26C6B0' },
        { text: tr('player_exit_rec_stop'), color: '#E5484D' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (!this.playing || this.recordOnly) {
        return;
      }
      if (r.index === 1 && this.recording) {
        this.switchToRecordOnly();
      } else if (r.index === 1 || r.index === 2) {
        this.leavePlayer();  // 选了停止；或者弹窗期间录制已经自己停了（空间不足、出错），没东西可继续
      }
    }).catch(() => {
    });
  }

  // 边看边录 → 只录制（退出时选了“继续录制”）：停掉画面和本机声音（网络照常收，录像有自己的一路解码，
  // 不受影响），拔掉手柄、关小窗，退出全屏，方向和侧滑返回交还给系统，换成只录制页面。
  // 只录制页面暂时不能再转回边看边录（正式发布后再做）
  private switchToRecordOnly(): void {
    this.closeMenu();
    this.clearHudTimer();
    this.vpadEditing = false;
    this.picEditing = false;
    nssft.pauseVideo();
    this.cancelPipCheck();
    this.pip.close();
    this.stopPad();
    this.recordOnly = true;
    this.recordOnlySince = Date.now();
    this.statusText = '';
    this.statsText = '';
    this.applyRefreshHint();
    this.setGestureBack(true);
    this.setImmersive(false).then(() => {
      this.setRecordOnlyBars(true);
    });
    this.focusForRemote();
    hilog.info(DOMAIN, TAG, 'keep recording: switched to record-only');
  }

  private async finishRecordOnly(): Promise<void> {
    if (this.recording) {
      await this.stopRecording('');
    }
    if (this.playing && this.recordOnly) {
      this.leavePlayer();
    }
  }

  private confirmStopRecordOnly(): void {
    promptAction.showDialog({
      title: tr('record_only_stop_title'),
      message: tr('record_only_stop_message'),
      buttons: [
        { text: tr('record_only_continue'), color: '#99000000' },
        { text: tr('record_only_stop'), color: '#E5484D' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        this.finishRecordOnly();
      }
    }).catch(() => {
    });
  }

  // ---------------------------------------------------------------- 播放页快捷设置（即时生效，不用重连）

  private applyAudio(on: boolean): void {
    if (on === this.enableAudio) {
      return;
    }
    this.enableAudio = on;
    if (!this.sessionStarted) {
      return;
    }
    const err = nssft.setAudioEnabled(on);
    if (err.length > 0) {
      this.enableAudio = !on;
      promptAction.showToast({ message: err });
    }
    this.pip.setAudio(this.enableAudio);
  }

  private applyEnhance(level: number): void {
    if (level === this.enhanceLevel) {
      return;
    }
    this.enhanceLevel = level;
    if (!this.sessionStarted || !enhanceAvailable()) {
      return;
    }
    // 开关画质增强会重建视频链路（重放缓存的画面，一般不到半秒）；失败时已退回直出
    const err = nssft.setEnhanceLevel(level);
    this.enhanceWarned = err.length > 0;
    if (err.length > 0) {
      promptAction.showToast({ message: tr('player_toast_enhance_unavailable', err), duration: 3500 });
    }
  }

  private applyNetOpt(on: boolean): void {
    if (on === this.netOpt) {
      return;
    }
    this.netOpt = on;
    if (!this.sessionStarted) {
      return;
    }
    nssft.setNetOptimization(on);
    if (on && !this.inBackground && this.target !== null && this.target.usb === null) {
      this.booster.enter();
    } else {
      this.booster.leave();
    }
  }

  private applyPipAuto(on: boolean): void {
    if (on === this.pipAuto) {
      return;
    }
    this.pipAuto = on;
    this.pip.setAutoStart(on);
  }

  private leavePlayer(): void {
    if (this.recording) {
      this.stopRecording('');
    }
    this.recordStatus?.stop(this.recordStatusInfo());
    if (this.recordOnly) {
      this.setRecordOnlyBars(false);
    }
    this.recordOnly = false;
    this.keeperForRecording = false;
    this.stopPlayback();
    this.picEditing = false;
    this.setGestureBack(true);
    this.clearHudTimer();
    this.controlsVisible = true;
    this.menuOpen = false;
    this.menuPage = '';
    this.cancelTvLongPress();
    this.playing = false;
    this.target = null;
    this.statusText = '';
    this.badgeText = '';
    this.statsText = '';
    this.setImmersive(false);
    this.focusForRemote();
    if (this.languageStale) {
      // 播放中界面语言变了：退出播放后再重建页面（等退出全屏、转回竖屏）
      setTimeout(() => {
        if (!this.playing) {
          this.rebuildForLanguage();
        }
      }, 300);
    }
  }

  // 串流中折叠或展开（宽屏状态变了）、改了“串流时的屏幕方向”：按新的屏幕重新设方向（编辑键位时也一样）。
  // 不在串流时折叠或展开：把方向交还给系统（串流时定的方向只管播放页，别的页面跟随系统）
  onScreenClassChanged(): void {
    if (this.playing) {
      if (!this.recordOnly) {
        this.setImmersive(true);  // 只录制页面不全屏、不常亮、不锁方向
      }
    } else if (this.layoutEditId.length > 0) {
      this.setImmersive(true, this.layoutEditMode === 'landscape' ? 'landscape' : 'portrait');
    } else {
      this.restoreOrientation();
    }
  }

  // 方向现在由播放页（显示画面时）或键位编辑决定；只录制页面（包括边看边录转过去的）不锁方向，交给系统
  private orientOwnedByPlayer(): boolean {
    return (this.playing && !this.recordOnly) || this.layoutEditId.length > 0;
  }

  // 进播放页或键位编辑前记下页面是竖着还是横着，退出时先摆回去（见 restoreOrientation）
  private rememberPageOrientation(): void {
    this.prePlayPortrait = (AppStorage.get<number>('ui.screenH') ?? 0) > (AppStorage.get<number>('ui.screenW') ?? 0);
  }

  // 非播放页的方向：跟随系统。播放页或键位编辑锁过方向时，先摆回进入前的方向（手机和折叠屏外屏就是竖屏）再交给系统：
  // 串流时锁了方向，设备没有转动时（平放、模拟器）系统不会自己转回来，首页、设置页就会停在串流时的方向。
  // 没锁过（刚启动、跟随系统、只录制、在设置页改选项、不在串流时折叠展开）直接交给系统，不去转屏
  private async restoreOrientation(): Promise<void> {
    const type = deviceInfo.deviceType;
    if (type === '2in1' || type === 'tv') {
      return;
    }
    try {
      const win = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      if (this.orientOwnedByPlayer()) {
        return;  // 等窗口的工夫又进了播放页或键位编辑：方向（和 orientLocked）由它们定，别清掉新设的锁定标记
      }
      const snapBack = this.orientLocked;
      this.orientLocked = false;
      if (snapBack) {
        await win.setPreferredOrientation(!this.wideScreen || this.prePlayPortrait ? window.Orientation.PORTRAIT :
          window.Orientation.LANDSCAPE);
        // 等转过去再交给系统：紧接着设“跟随系统”会让还没转完的窗口停在原来的方向
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, ORIENT_SETTLE_MS);
        });
        if (this.orientOwnedByPlayer()) {
          return;  // 这期间又进了播放页或键位编辑：方向由它们定
        }
      }
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'restore orientation failed: %{public}s', JSON.stringify(e));
    }
  }

  // 播放时全屏、常亮。手机和折叠屏外屏固定横屏；宽屏状态（平板、阔折叠、折叠屏展开等）按“串流时的屏幕方向”：
  // 跟随系统（随设备转动，服从控制中心的旋转锁）/ 横屏 / 竖屏。不播放时跟随设备旋转。
  // PC 窗口、智慧屏不设方向。force：编辑键位时按键位的摆法指定方向
  private async setImmersive(on: boolean, force: string = ''): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowKeepScreenOn(on);
      const type = deviceInfo.deviceType;
      if (type === '2in1') {
        return;
      }
      await win.setWindowLayoutFullScreen(on);
      await win.setWindowSystemBarEnable(on ? [] : ['status', 'navigation']);
      if (type === 'tv') {
        return;
      }
      if (!on) {
        await this.restoreOrientation();
        return;
      }
      // 播放页（和键位编辑）：手机和折叠屏外屏固定横屏；宽屏状态按“串流时的屏幕方向”
      let orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
      if (force.length > 0) {
        orientation = force === 'portrait' ? window.Orientation.AUTO_ROTATION_PORTRAIT :
          window.Orientation.AUTO_ROTATION_LANDSCAPE;
      } else if (this.wideScreen && this.playOrientation === PLAY_ORIENT_PORTRAIT) {
        orientation = window.Orientation.AUTO_ROTATION_PORTRAIT;
      } else if (this.wideScreen && this.playOrientation === PLAY_ORIENT_FOLLOW) {
        orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
      }
      this.orientLocked = orientation !== window.Orientation.AUTO_ROTATION_RESTRICTED;
      await win.setPreferredOrientation(orientation);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setImmersive failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 播放页：控件显隐

  private onPlayerTap(): void {
    if (this.menuOpen) {
      this.closeMenu();  // 点菜单外面：收起菜单
      return;
    }
    if (IS_TV) {
      this.openMenu('');  // 智慧屏（模拟器里可以用鼠标点）：点画面打开菜单
      return;
    }
    if (this.vpadEditing || this.picEditing || this.vpadVisible()) {
      return;  // 触屏手柄显示着：点空白处不做什么（玩的时候太容易误触），菜单从顶部中间的小把手打开
    }
    if (this.controlsVisible) {
      this.clearHudTimer();
      this.controlsVisible = false;
    } else {
      this.showControls();
    }
  }

  // 叫出右上角的菜单按钮和左上角画面信息，没有操作 HUD_HIDE_MS 后自动隐藏
  private showControls(): void {
    this.controlsVisible = true;
    this.armHudTimer();
  }

  // 重新计时（菜单收起时调用）；菜单开着时不计时
  private armHudTimer(): void {
    this.clearHudTimer();
    if (!this.playing || IS_TV || this.menuOpen || this.vpadEditing || this.picEditing || !this.controlsVisible) {
      return;
    }
    this.hudTimer = setTimeout(() => {
      this.hudTimer = -1;
      if (!this.menuOpen) {
        this.controlsVisible = false;
      }
    }, HUD_HIDE_MS);
  }

  private clearHudTimer(): void {
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
      this.hudTimer = -1;
    }
  }

  // 菜单开关：打开时停止计时，收起后菜单按钮再显示一会儿；手柄在菜单开着时不操作游戏机
  onMenuToggled(): void {
    if (this.menuOpen) {
      this.clearHudTimer();
    } else {
      this.menuPage = '';
      this.controlsVisible = true;
      this.armHudTimer();
    }
    this.syncPadPlaying();
    this.syncPadPoll();
  }

  onMenuPageChanged(): void {
    this.syncPadPoll();
  }

  // 播放页里调整键位时关掉侧滑返回：把贴边的按键往屏幕边上拖时很容易碰到，返回 = 取消会丢掉没保存的改动
  onVpadEditingChanged(): void {
    if (this.playing && !this.recordOnly) {
      this.setGestureBack(!this.vpadEditing);
    }
  }

  // 系统的侧滑返回（API 13 起可以按窗口关掉）：调整键位、全屏键位编辑器里关掉，结束后再打开（智慧屏没有侧滑）
  private setGestureBack(enabled: boolean): void {
    if (deviceInfo.sdkApiVersion < 13 || IS_TV) {
      return;
    }
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      return win.setGestureBackEnabled(enabled);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'set gesture back failed: %{public}s', JSON.stringify(e));
    });
  }

  // ---------------------------------------------------------------- 右侧侧滑菜单（各种设备共用）

  // 打开菜单（page：'' 一级 / 'pad' / 'orient' / 'enhance'）。智慧屏要把焦点移进菜单；
  // focusNow 为 false：长按确认键打开时，等松开确认键再把焦点移到第一项
  private openMenu(page: string, focusNow: boolean = true): void {
    if (this.vpadEditing || this.picEditing) {
      return;
    }
    this.menuPage = page;
    this.menuOpen = true;
    if (!IS_TV) {
      return;
    }
    if (focusNow) {
      this.focusById('menu-main-first');
    } else {
      this.tvFocusOnRelease = true;
    }
  }

  private closeMenu(): void {
    if (!this.menuOpen) {
      return;
    }
    this.menuOpen = false;
    if (IS_TV) {
      this.focusById('player-focus');
    }
  }

  // 进二级页：“手柄”（只在触屏设备上，智慧屏上手柄只有开关）、“屏幕方向”（智慧屏固定横屏）、“画质增强”。
  // 智慧屏进二级页时把焦点移到第一个选项，遥控器才进得去
  private openMenuPage(page: string): void {
    this.menuPage = page;
    if (IS_TV) {
      this.focusById('menu-sub-first');
    }
  }

  private backToMainMenu(): void {
    this.menuPage = '';
    if (IS_TV) {
      this.focusById('menu-main-first');
    }
  }

  private cancelTvLongPress(): void {
    if (this.tvOkTimer >= 0) {
      clearTimeout(this.tvOkTimer);
      this.tvOkTimer = -1;
    }
    this.tvOkDown = false;
    this.tvFocusOnRelease = false;
  }

  // 智慧屏的按键（焦点在播放器根节点上时）：菜单键开关菜单；长按确认键打开菜单
  private onTvKey(event: KeyEvent, confirm: boolean): void {
    if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_MENU) {
      if (this.menuOpen) {
        this.closeMenu();
      } else {
        this.openMenu('');
      }
      event.stopPropagation();
      return;
    }
    if (!confirm) {
      return;
    }
    if (event.type === KeyType.Down) {
      // 按住时系统会重复发 Down，只在第一次计时
      if (!this.tvOkDown && !this.menuOpen) {
        this.tvOkDown = true;
        this.tvOkTimer = setTimeout(() => {
          this.tvOkTimer = -1;
          if (this.playing && !this.menuOpen) {
            this.openMenu('', false);
          }
        }, TV_LONG_PRESS_MS);
      }
      event.stopPropagation();
    } else if (event.type === KeyType.Up) {
      const focusMenu = this.tvFocusOnRelease;
      this.cancelTvLongPress();
      if (focusMenu && this.menuOpen) {
        this.focusById('menu-main-first');
      }
      event.stopPropagation();
    }
  }


  // 菜单项刚插入时还拿不到焦点，等它建好再移过去
  private focusById(id: string): void {
    setTimeout(() => {
      try {
        const focus = this.getUIContext().getFocusController();
        if (IS_TV) {
          focus.activate(true);  // 用触屏或鼠标点过之后焦点框会收起，遥控器操作前重新激活
        }
        focus.requestFocus(id);
        hilog.info(DOMAIN, TAG, 'requestFocus %{public}s ok', id);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'requestFocus %{public}s failed: %{public}s', id, JSON.stringify(e));
      }
    }, 320);
  }

  // ---------------------------------------------------------------- 界面

  build() {
    Stack() {
      Navigation(this.navStack) {
        HomeView({
          bp: this.bp,
          playing: this.playing,
          onConnect: (t: StreamTarget) => {
            this.play(t);
          },
          onOpenSettings: () => {
            this.navStack.pushPathByName('settings', null);
          },
          onOpenGuide: () => {
            this.navStack.pushPathByName('guide', null);
          },
          onOpenRecordings: () => {
            this.navStack.pushPathByName('recordings', null);
          }
        })
      }
      .hideTitleBar(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .navDestination(this.PageMap)
      .width('100%')
      .height('100%')
      .padding({ left: this.safeLeft, right: this.safeRight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .visibility(this.playing || this.layoutEditId.length > 0 ? Visibility.Hidden : Visibility.Visible)

      if (this.playing) {
        if (this.recordOnly) {
          this.RecordOnlyView()
        } else {
          this.PlayerView()
        }
      } else if (this.layoutEditId.length > 0) {
        this.LayoutEditorView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.playing ? (this.recordOnly ? RECORD_ONLY_BG : Color.Black) : $r('app.color.page_bg'))
    // 背景延伸到状态栏和底部小白条区域，页面与系统栏融为一体
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      this.bp = breakpointOf(Number(area.width));
      this.wideScreen = isWideScreen(Number(area.width), Number(area.height));
      if (this.wideScreen) {
        migrateSplitLayouts(Number(area.width), Number(area.height));
      }
      // 键位管理页按本机屏幕画缩略图
      AppStorage.setOrCreate('ui.screenW', Number(area.width));
      AppStorage.setOrCreate('ui.screenH', Number(area.height));
    })
  }

  @Builder
  PageMap(name: string) {
    if (name === 'settings') {
      NavDestination() {
        SettingsView({
          onOpenGuide: () => {
            this.navStack.pushPathByName('guide', null);
          },
          onOpenVpadLayouts: () => {
            this.navStack.pushPathByName('vpadLayouts', null);
          },
          onOpenAbout: () => {
            this.navStack.pushPathByName('about', null);
          }
        })
      }
      .title(tr('settings_title'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else if (name === 'guide') {
      NavDestination() {
        GuideView()
      }
      .title(tr('guide_title'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else if (name === 'recordings') {
      NavDestination() {
        RecordingsView()
      }
      .title(tr('recordings_title'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else if (name === 'vpadLayouts') {
      NavDestination() {
        VpadLayoutsView({
          onEdit: (id: string, mode: string) => {
            this.openLayoutEditor(id, mode);
          }
        })
      }
      .title(tr('vpad_layouts'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else if (name === 'about') {
      NavDestination() {
        AboutView()
      }
      .title(tr('about_title'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
  }

  // ---------------------------------------------------------------- 键位编辑（从键位管理页进入，不在串流时）

  private openLayoutEditor(id: string, mode: string): void {
    if (mode !== 'landscape' && !this.wideScreen) {
      promptAction.showToast({ message: tr('vpad_wide_only') });
      return;
    }
    // 从起名弹窗过来时输入法键盘可能还开着，会把编辑界面挤矮
    inputMethod.getController().stopInputSession().catch(() => {
    });
    this.layoutEditMode = mode;
    this.layoutEditId = id;
    this.rememberPageOrientation();
    this.setImmersive(true, mode === 'landscape' ? 'landscape' : 'portrait');
    // 拖贴边的按键（ZL、ZR、摇杆）时很容易碰到侧滑返回，返回 = 取消会丢掉没保存的改动：编辑期间关掉侧滑返回
    this.setGestureBack(false);
  }

  private closeLayoutEditor(): void {
    if (this.layoutEditId.length === 0) {
      return;
    }
    this.layoutEditId = '';
    this.setGestureBack(true);
    this.setImmersive(false);
  }

  // 示意画面：横屏时铺满（和键位管理页的缩略图一致）；竖屏是贴顶的 16:9（竖屏时画面默认在顶部）
  private editorPicW(): number {
    return this.layoutEditMode === 'landscape' ? this.editorW : Math.min(this.editorW, this.editorH * VIDEO_ASPECT);
  }

  private editorPicH(): number {
    return this.layoutEditMode === 'landscape' ? this.editorH : this.editorPicW() / VIDEO_ASPECT;
  }

  // 全屏编辑一个自建键位：和串流时一样的屏幕和方向，按键下面是示意画面
  @Builder
  LayoutEditorView() {
    Stack() {
      Column() {
        Text(tr('vpad_editor_picture')).fontSize(14).fontColor('#66FFFFFF')
      }
      .width(this.editorPicW())
      .height(this.editorPicH())
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#1F26C6B0')

      VirtualPad({
        portrait: this.layoutEditMode === 'portrait',
        keysTop: this.editorPicH(),
        layoutId: this.layoutEditId,
        layoutKey: `${this.layoutEditId}|${this.layoutEditMode}`,
        editing: true,
        interactive: false,
        sizeLevel: this.vpadSize,
        opacityLevel: this.vpadOpacity,
        haptic: false,
        insetLeft: this.safeLeft,
        insetRight: this.safeRight,
        insetBottom: this.safeBottom,
        onEditDone: () => {
          this.closeLayoutEditor();
        },
        onSave: (units: UnitSave[]) => {
          updateLayoutUnits(this.layoutEditId, units);
          promptAction.showToast({ message: tr('vpad_layout_saved') });
          this.closeLayoutEditor();
        }
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .alignContent(this.layoutEditMode === 'portrait' ? Alignment.Top : Alignment.Center)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      this.editorW = Number(area.width);
      this.editorH = Number(area.height);
    })
  }

  // 只录制：不显示画面，只显示录了多久、多大和连接状态；可以锁屏或切走，录制在后台继续
  @Builder
  RecordOnlyView() {
    Column({ space: 0 }) {
      Column({ space: 4 }) {
        Text(tr('record_only_title')).fontSize(20).fontWeight(FontWeight.Medium).fontColor(Color.White)
        Text(this.target !== null ? this.target.label : '').fontSize(13).fontColor('#99FFFFFF')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Blank()

      Column({ space: 12 }) {
        Row({ space: 8 }) {
          if (this.recording && !this.recordWaiting) {
            Column().width(12).height(12).borderRadius(6).backgroundColor(RECORD_RED)
            Text(tr('record_only_recording')).fontSize(15).fontColor(Color.White)
          } else {
            LoadingProgress().width(20).height(20).color(PLAYER_ACCENT).focusable(false)
            Text(this.statusText.length > 0 ? this.statusText : tr('record_only_waiting'))
              .fontSize(15)
              .fontColor(Color.White)
              .maxLines(3)
          }
        }

        Text(formatClock(this.recordDurationMs))
          .fontSize(64)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .fontFeature('"tnum" on')
        Text(formatBytes(this.recordBytes)).fontSize(17).fontColor('#CCFFFFFF')
        if (this.recordInfo.length > 0) {
          Text(this.recordInfo).fontSize(13).fontColor('#99FFFFFF').textAlign(TextAlign.Center)
        }
        if (this.recording && this.statusText.length > 0) {
          // 录制中断线重连：录像在等画面恢复
          Text(this.statusText).fontSize(13).fontColor('#FFB74D').textAlign(TextAlign.Center).maxLines(3)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Blank()

      Column({ space: 16 }) {
        Text(tr('record_only_hint'))
          .fontSize(13)
          .fontColor('#99FFFFFF')
          .textAlign(TextAlign.Center)
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.stop_circle_fill')).fontSize(20).fontColor([Color.White])
            Text(tr('record_only_stop')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Color.White)
          }
        }
        .width('100%')
        .height(52)
        .constraintSize({ maxWidth: 420 })
        .backgroundColor(RECORD_RED)
        .focusBox(FOCUS_BOX)
        .defaultFocus(true)
        .onClick(() => {
          this.finishRecordOnly();
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    // 页面本身已经排在状态栏和小白条之间（深色底由外层延伸到系统栏下面），这里不再加 safeTop / safeBottom，否则上下留白翻倍
    .padding({ left: 24 + this.safeLeft, right: 24 + this.safeRight, top: 24, bottom: 24 })
    .backgroundColor(RECORD_ONLY_BG)
  }

  // 统计浮层：参考 SFT 的 Android TV 接收端，左上角一块半透明面板，内容点击穿透到画面
  @Builder
  StatsPanel() {
    Text(this.statsText.length > 0 ? this.statsText : '—')
      .fontSize(12)
      .lineHeight(18)
      .fontColor(Color.White)
      .fontFamily('HarmonyOS Sans')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(PLAYER_GLASS)
      .borderRadius(8)
      .constraintSize({ maxWidth: 520 })
      .hitTestBehavior(HitTestMode.Transparent)
  }

  // 顶部中间的菜单按钮（离四角的肩键远，玩的时候不容易误触），串流中一直在。
  // 菜单按钮：同一个元素在“完整的圆形按钮”和“小把手”之间变形。宽高、圆角、底色一起过渡，顶边不动，
  // 收起时像往屏幕顶边缩回去；中间三条横线收起时先淡出缩小，展开时等外形长出来再淡入。
  // 点击范围固定（MENU_HIT_W × MENU_HIT_H），两种形态点了都直接打开菜单
  @Builder
  MenuButton() {
    Column() {
      Column() {
        Column({ space: 4 }) {
          Column().width(18).height(2).borderRadius(1).backgroundColor(Color.White)
          Column().width(18).height(2).borderRadius(1).backgroundColor(Color.White)
          Column().width(18).height(2).borderRadius(1).backgroundColor(Color.White)
        }
        .opacity(this.controlsVisible ? 1 : 0)
        .scale({ x: this.controlsVisible ? 1 : 0.5, y: this.controlsVisible ? 1 : 0.5 })
        .animation({
          duration: MENU_LINES_MS,
          delay: this.controlsVisible ? MENU_MORPH_MS - MENU_LINES_MS : 0,
          curve: Curve.Sharp
        })
      }
      .width(this.controlsVisible ? 44 : 28)
      .height(this.controlsVisible ? 44 : 4)
      .borderRadius(this.controlsVisible ? 22 : 2)
      .backgroundColor(this.controlsVisible ? PLAYER_GLASS : MENU_HANDLE_COLOR)
      .justifyContent(FlexAlign.Center)
      .clip(true)
      .animation({ duration: MENU_MORPH_MS, curve: Curve.FastOutSlowIn })
    }
    .width(MENU_HIT_W)
    .height(MENU_HIT_H)
    .justifyContent(FlexAlign.Start)
    .padding({ top: 8 })
    .focusable(true)
    .focusBox(FOCUS_BOX)
    .accessibilityText(tr('player_menu'))
    .onClick(() => {
      this.openMenu('');
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  // 左上角的状态提示别伸到顶部中间的菜单按钮下面
  private statusMaxWidth(): number {
    if (this.vpadOverlayNow() || !this.menuButtonShown()) {
      return 560;
    }
    return Math.max(160, Math.min(560, this.playerAreaW / 2 - 40 - this.safeLeft));
  }

  // 菜单按钮：控件显示时（进播放页、关菜单、按返回、点画面后的几秒）是完整的圆形按钮，之后收成顶部中间的小把手。
  // 串流中一直在（开不开触屏手柄都一样），菜单开着或在调整键位、画面位置时没有
  private menuButtonShown(): boolean {
    return !IS_TV && this.playing && !this.menuOpen && !this.vpadEditing && !this.picEditing;
  }

  // 调整画面位置：虚线框标出画面现在的位置（框里写位置名），整层都能上下拖；顶部是取消 / 保存
  @Builder
  PicEditLayer() {
    Stack({ alignContent: Alignment.Top }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.arrow_up_and_down_square_portrait')).fontSize(28).fontColor([Color.White])
        Text(this.picPosLabel(this.picEditPos)).fontSize(15).fontColor(Color.White)
      }
      .width(this.playerWidth)
      .height(this.playerHeight)
      .position({ x: Math.max(0, (this.playerAreaW - this.playerWidth) / 2), y: this.picTop() })
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#40000000')
      .border({ width: 2, color: PLAYER_ACCENT, style: BorderStyle.Dashed })

      // 工具条放在上下两块空白里大的那一块的正中，不压画面；空白都太小时贴着顶部盖在画面上
      Column() {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            this.PicEditButton(tr('common_cancel'), false, () => {
              this.picEditing = false;
            })
            if (Math.abs(this.picEditPos - this.picEditOrig) > 0.0005) {
              Text(tr('vpad_edit_unsaved')).fontSize(12).fontColor('#FFB74D')
            }
            this.PicEditButton(tr('vpad_edit_save'), true, () => {
              this.savePicEdit();
            })
          }
          Text(tr('pic_edit_hint'))
            .fontSize(11)
            .fontColor('#CCFFFFFF')
            .textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: 420 })
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#E6141A1A')
        .borderRadius(18)
        .alignItems(HorizontalAlign.Center)
        .margin({ left: 16, right: 16 })
      }
      .width('100%')
      .height(Math.max(PIC_EDIT_BAR_SLOT_VP, Math.max(this.picTop(), this.picFreeBelow())))
      .position({ x: 0, y: this.picEditBarTop() })
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .gesture(
      // 用默认的起拖距离：太小（1 vp）时点“取消”“保存”手指稍一抖就先认成拖动，按钮的点击被吃掉
      PanGesture({ direction: PanDirection.Vertical })
        .onActionStart(() => {
          this.picDragStartTop = this.picTop();
        })
        .onActionUpdate((e: GestureEvent) => {
          this.dragPicTo(this.picDragStartTop + e.offsetY);
        })
    )
  }

  @Builder
  PicEditButton(label: string, primary: boolean, action: () => void) {
    Button(label)
      .fontSize(13)
      .fontColor(primary ? '#FF0B1A16' : Color.White)
      .backgroundColor(primary ? PLAYER_ACCENT : '#33FFFFFF')
      .height(30)
      .padding({ left: 12, right: 12 })
      .focusBox(FOCUS_BOX)
      .onClick(action)
  }

  @Builder
  PlayerView() {
    Stack() {
      // 按 16:9 适配窗口：画质增强接管输出后不认 native 侧设的 FIT 缩放模式，surface 本身是 16:9 才不会被拉伸
      XComponent({ type: XComponentType.SURFACE, controller: this.xController })
        .width(this.playerWidth)
        .height(this.playerHeight)
        // 画面位置：横向居中，纵向按位置放在上下空白里（只挪位置、不改大小，解码和画质增强不受影响）
        .position({ x: Math.max(0, (this.playerAreaW - this.playerWidth) / 2), y: this.picTop() })

      // 点画面：叫出 / 收起完整的菜单按钮（触屏手柄显示时不响应）。单独垫一层接点击，不挂在播放器根节点上：
      // 挂了点击事件的容器，里面的子节点拿不到焦点，智慧屏的遥控器就进不了菜单。
      // 串流时焦点停在这一层（不显示焦点框），按键冒泡到播放器根节点的 onKeyEvent；打开菜单时焦点移进菜单
      // 用 Text 是因为它是焦点树里的叶子节点：空的 Column 是“容器”，没有可获焦的子节点就不能获焦
      // 菜单开着时这一层不可获焦，方向键不会把焦点带出菜单
      Text('')
        .width('100%')
        .height('100%')
        .focusable(!this.menuOpen)
        .defaultFocus(true)
        .focusBox(NO_FOCUS_BOX)
        .id('player-focus')
        .onClick((e: ClickEvent) => {
          // 菜单盖在这一层上面，点菜单里的空白处会落到这里：按位置忽略，免得把菜单关掉
          if (this.menuOpen && e.x >= this.playerAreaW - this.menuWidth()) {
            return;
          }
          this.onPlayerTap();
        })

      // 左上角：连接状态（不受控件显隐影响，免得以为卡住了），下面是统计浮层；没开统计时显示画面信息
      Column({ space: 8 }) {
        if (this.statusText.length > 0) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(PLAYER_ACCENT).focusable(false)
            Text(this.statusText).fontSize(13).fontColor(Color.White).maxLines(3)
          }
          .padding({ left: 12, right: 14, top: 7, bottom: 7 })
          .backgroundColor(PLAYER_GLASS)
          .borderRadius(12)
          .constraintSize({ maxWidth: this.statusMaxWidth() })
        }
        if (this.showStats) {
          this.StatsPanel()
        }
      }
      .width('100%')
      .height('100%')
      // 触屏手柄叠在画面上时左上角是 ZL：挪到顶部中间（菜单按钮、录制标记下面）
      .alignItems(this.vpadOverlayNow() ? HorizontalAlign.Center : HorizontalAlign.Start)
      .padding({
        left: 16 + this.safeLeft,
        right: 16 + this.safeRight,
        top: this.vpadOverlayNow() ? (this.recording ? 96 : 64) : 16,
        bottom: 16
      })
      .hitTestBehavior(HitTestMode.Transparent)

      // 右上角：录制中的标记（一直显示，不随 HUD 自动隐藏）。
      // 触屏手柄叠在画面上时右上角是肩键，录制标记挪到顶部中间（菜单按钮下面）
      if (this.recording && !IS_TV) {
        Row() {
          Row({ space: 6 }) {
            Column().width(8).height(8).borderRadius(4).backgroundColor(RECORD_RED)
            Text(this.recordWaiting ? tr('player_record_waiting') : formatClock(this.recordDurationMs))
              .fontSize(12)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 10, right: 12, top: 5, bottom: 5 })
          .backgroundColor(PLAYER_GLASS)
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .justifyContent(this.vpadOverlayNow() ? FlexAlign.Center : FlexAlign.End)
        .alignItems(VerticalAlign.Top)
        .padding({ left: 16 + this.safeLeft, right: 16 + this.safeRight, top: this.vpadOverlayNow() ? 64 : 16, bottom: 16 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 触屏手柄：工具条或面板开着时变淡、不响应
      // 按键盖满整个播放区域，和画面是独立的两层（挪画面不影响按键）
      if (this.vpadVisible() && !IS_TV) {
        Column() {
          VirtualPad({
            interactive: !this.menuOpen && !this.picEditing,
            portrait: this.vpadMode() === 'portrait',
            keysTop: this.playerHeight,
            layoutId: this.vpadLayoutId(this.vpadMode()),
            layoutKey: `${this.vpadMode()}|${this.vpadLayoutId(this.vpadMode())}|${this.layoutsEpoch}`,
            editing: this.vpadEditing,
            sizeLevel: this.vpadSize,
            opacityLevel: this.vpadOpacity,
            haptic: this.vpadHaptic,
            insetLeft: this.safeLeft,
            insetRight: this.safeRight,
            insetBottom: this.safeBottom,
            onEditDone: () => {
              this.vpadEditing = false;
            },
            onSave: (units: UnitSave[]) => {
              this.saveVpadLayout(this.vpadMode(), units, () => {
                this.vpadEditing = false;
              });
            }
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.picEditing) {
        this.PicEditLayer()
      }

      // 顶部中间的菜单按钮：位置固定，不能调整（调整键位时按键拖不进这块），返回被拦截后退出也从这里进
      if (this.menuButtonShown()) {
        Row() {
          this.MenuButton()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Top)
        .padding({ top: 4 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 右侧侧滑菜单：从右边缘滑入；点菜单外面收起
      Row() {
        if (this.menuOpen) {
          this.SideMenu()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 画面按画面位置自己定位（XComponent 的 position），其他图层都铺满
    .alignContent(Alignment.Top)
    .onAreaChange((_old: Area, area: Area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      this.playerWidth = Math.min(w, h * VIDEO_ASPECT);
      this.playerHeight = this.playerWidth / VIDEO_ASPECT;
      this.playerAreaH = h;
      this.playerAreaW = w;
      this.reloadPicPos();
    })
    .focusable(true)
    .defaultFocus(true)
    .id('player-root')
    // 手柄的摇杆、扳机（焦点轴事件，API 15 起；低版本不挂，见 PadAxisModifier）
    .attributeModifier(this.padAxis)
    .onKeyEvent((event: KeyEvent) => {
      // 手柄和键盘：游戏机接受手柄时，有对应的键交给游戏机，不再移动界面焦点
      if (this.onPadKey(event)) {
        event.stopPropagation();
        return;
      }
      // 外接键盘：Esc 相当于返回（串流时只提示怎么退出，不断开）
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.onBackPress();
        return;
      }
      const confirm = event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER ||
        event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER;
      if (IS_TV) {
        // 菜单开着时，确认键由获焦的菜单项处理；这里只管菜单键和画面上的长按确认
        // （长按打开菜单后焦点还在这里，要等到确认键松开再移进菜单）
        if (!confirm || !this.menuOpen || this.tvFocusOnRelease) {
          this.onTvKey(event, confirm);
        }
        return;
      }
      if (event.type !== KeyType.Down) {
        return;
      }
      // 键盘：控件隐藏时按确认键叫出菜单按钮（相当于点画面）；显示时确认键交给获焦的按钮
      if (confirm && !this.controlsVisible && !this.menuOpen) {
        this.onPlayerTap();
        event.stopPropagation();
        return;
      }
      // 菜单键：打开/收起菜单
      if (event.keyCode === KeyCode.KEYCODE_MENU) {
        if (this.menuOpen) {
          this.closeMenu();
        } else {
          this.openMenu('');
        }
        event.stopPropagation();
      }
    })
  }

  // 右侧侧滑菜单（各种设备共用）：一级是常用操作和串流选项，“手柄”“屏幕方向”进入二级。智慧屏占半屏，其他设备最多 360 vp。
  // 菜单项直接读 this.xxx 传给 TvMenuItem 的 @Prop，状态变了会跟着刷新
  @Builder
  SideMenu() {
    Column() {
      if (this.menuPage === 'pad') {
        this.MenuPad()
      } else if (this.menuPage === 'orient') {
        this.MenuOrient()
      } else if (this.menuPage === 'enhance') {
        this.MenuEnhance()
      } else {
        this.MenuMain()
      }
    }
    .width(this.menuWidth())
    .height('100%')
    .padding(this.menuPadding())
    .backgroundColor('#E60E1414')
    .transition(TransitionEffect.move(TransitionEdge.END).animation({ duration: 260, curve: Curve.FastOutSlowIn }))
    // 不挂空的 onClick 吞点击（可点击的容器里面的菜单项拿不到遥控器焦点）：菜单盖在点击层上面，点菜单空白处到不了点击层
  }

  // 侧滑菜单的宽度：智慧屏占半屏，其他设备最多 360 vp，窄屏上不超过屏宽的 88%
  // 菜单项用紧凑行距：手机横屏这种矮屏；智慧屏、平板和折叠屏展开时用宽松的
  private menuCompact(): boolean {
    return !IS_TV && this.playerAreaH < MENU_ROOMY_MIN_VP;
  }

  // 菜单标题行下面留的距离（vp）：和第一项拉开，免得误触标题行的按钮
  private menuHeaderGap(): number {
    return IS_TV ? 8 : this.menuCompact() ? 10 : 14;
  }

  private menuWidth(): number {
    return IS_TV ? this.playerAreaW / 2 : Math.min(MENU_MAX_WIDTH, this.playerAreaW * 0.88);
  }

  private menuPadding(): Padding {
    if (IS_TV) {
      const tv: Padding = { left: 28, right: 28, top: 32, bottom: 24 };
      return tv;
    }
    const p: Padding = { left: 12, right: 12 + this.safeRight, top: 16, bottom: 12 + this.safeBottom };
    return p;
  }

  // 一级菜单标题行右边的图标按钮（录制、退出）
  // 标题行的录制按钮：没在录时是圆形录制图标；录制中变成红色胶囊（白点 + 已录时长，还没录进画面时显示“等待画面”），
  // 点它停止录制。录制状态在这里面读：@Builder 按值传进去的参数不会随状态刷新，传图标进 MenuIconButton 会一直是老样子
  @Builder
  RecordButton() {
    if (this.recording) {
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 6 }) {
          Column().width(8).height(8).borderRadius(4).backgroundColor(Color.White)
          Text(this.recordWaiting ? tr('player_record_waiting') : formatClock(this.recordDurationMs))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .fontFeature('"tnum" on')
        }
      }
      .height(40)
      .padding({ left: 12, right: 14 })
      .backgroundColor(RECORD_RED)
      .focusBox(FOCUS_BOX)
      .accessibilityText(tr('player_record_stop'))
      .onClick(() => {
        this.toggleRecording();
      })
      .onKeyEvent((event: KeyEvent) => {
        // 遥控器的确认键（按钮默认只认回车）
        if (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
          if (event.type === KeyType.Up) {
            this.toggleRecording();
          }
          event.stopPropagation();
        }
      })
    } else {
      this.MenuIconButton($r('sys.symbol.record_circle'), tr('player_record'), false, () => {
        this.toggleRecording();
      })
    }
  }

  @Builder
  MenuIconButton(icon: Resource, label: string, danger: boolean, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon).fontSize(20).fontColor([danger ? '#FF8A5C' : Color.White])
    }
    .width(40)
    .height(40)
    .backgroundColor('#26FFFFFF')
    .focusBox(FOCUS_BOX)
    .accessibilityText(label)
    .onClick(action)
    .onKeyEvent((event: KeyEvent) => {
      // 遥控器的确认键（按钮默认只认回车）；别写 .focusable(true)，见 TvMenuItem
      if (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
        if (event.type === KeyType.Up) {
          action();
        }
        event.stopPropagation();
      }
    })
  }

  // 一级菜单里一组的小标题（串流选项）
  @Builder
  MenuSection(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor('#99FFFFFF')
      .width('100%')
      .padding({ left: 12, right: 12, top: this.menuCompact() ? 10 : 14, bottom: 2 })
  }

  // 二级页的标题行：点它回到一级（遥控器用返回键）
  @Builder
  MenuHeader(title: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([Color.White])
      Text(title)
        .fontSize(IS_TV ? 22 : 18)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 6, bottom: this.menuHeaderGap() })
    .border({ width: { bottom: 1 }, color: '#1FFFFFFF' })
    .onClick(() => {
      this.backToMainMenu();
    })
  }

  @Builder
  MenuMain() {
    Column({ space: IS_TV ? 16 : 10 }) {
      // 标题行：主机名和画面信息（“1080p · 60 帧”只在这里显示），右边是录制和退出按钮（录制中录制按钮变成红色胶囊，显示时长）。
      // 小窗不放按钮：离开 App 时会自动转入小窗（串流选项里的开关），手动进的需求不高
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(this.target !== null ? this.target.label : '')
            .fontSize(IS_TV ? 22 : 18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.badgeText.length > 0) {
            Text(this.badgeText).fontSize(13).fontColor('#99FFFFFF')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.RecordButton()
        this.MenuIconButton($r('sys.symbol.arrow_right_and_square'), tr('player_stop'), true, () => {
          this.requestLeave();
        })
      }
      .width('100%')
      // 和下面的第一项（声音）拉开距离、隔一条细线：手指点声音时不会误触录制、退出
      .padding({ left: 16, right: 4, bottom: this.menuHeaderGap() })
      .border({ width: { bottom: 1 }, color: '#1FFFFFFF' })

      Scroll() {
        Column({ space: this.menuCompact() ? 2 : 4 }) {
          TvMenuItem({
            compact: this.menuCompact(),
            itemId: 'menu-main-first',
            icon: this.enableAudio ? $r('sys.symbol.speaker_wave_2') : $r('sys.symbol.speaker_slash'),
            label: tr('player_sound_on'),
            value: this.enableAudio ? tr('tv_on') : tr('tv_off'),
            toggle: true,
            valueOn: this.enableAudio,
            onTap: () => {
              this.applyAudio(!this.enableAudio);
            }
          })
          if (IS_TV) {
            // 智慧屏上手柄只做开关（遥控器操作二级的下拉框不方便），状态和按键说明见使用说明
            TvMenuItem({
              compact: this.menuCompact(),
              icon: $r('sys.symbol.gamecontroller'),
              label: tr('pad_enable'),
              value: this.padEnabled ? tr('tv_on') : tr('tv_off'),
              toggle: true,
              valueOn: this.padEnabled,
              onTap: () => {
                this.padEnabled = !this.padEnabled;
              }
            })
          } else {
            TvMenuItem({
              compact: this.menuCompact(),
              icon: $r('sys.symbol.gamecontroller'),
              label: tr('pad_title'),
              value: this.padEnabled ? tr('tv_on') : tr('tv_off'),
              valueOn: this.padEnabled,
              chevron: true,
              onTap: () => {
                this.openMenuPage('pad');
              }
            })
          }
          TvMenuItem({
            compact: this.menuCompact(),
            icon: $r('sys.symbol.arrow_up_and_down_square_portrait'),
            label: tr('pic_pos'),
            desc: this.picMovable() ? '' : tr('pic_pos_unavailable_short'),
            value: this.picMovable() ? this.picPosLabel(this.picPosNow()) : '',
            chevron: this.picMovable(),
            disabled: !this.picMovable(),
            onTap: () => {
              this.startPicEdit();
            }
          })
          this.MenuSection(tr('player_options_title'))
          // 设备不支持时照常列出、置灰并写明原因（和设置页一样）
          TvMenuItem({
            compact: this.menuCompact(),
            icon: $r('sys.symbol.wand_and_stars'),
            label: tr('settings_enhance'),
            desc: enhanceAvailable() ? '' : tr('settings_enhance_unsupported'),
            value: enhanceAvailable() ? (enhanceLabels()[this.enhanceLevel] ?? '') : '',
            valueOn: this.enhanceLevel > 0,
            chevron: enhanceAvailable(),
            disabled: !enhanceAvailable(),
            onTap: () => {
              this.openMenuPage('enhance');
            }
          })
          TvMenuItem({
            compact: this.menuCompact(),
            icon: $r('sys.symbol.screen_rotation'),
            label: tr('play_orient_short'),
            desc: playOrientReason(this.wideScreen, true),
            value: playOrientReason(this.wideScreen).length > 0 ? '' : (playOrientLabels()[this.playOrientation] ?? ''),
            chevron: playOrientReason(this.wideScreen).length === 0,
            disabled: playOrientReason(this.wideScreen).length > 0,
            onTap: () => {
              this.openMenuPage('orient');
            }
          })
          TvMenuItem({
            compact: this.menuCompact(),
            icon: $r('sys.symbol.bolt'),
            label: tr('settings_netopt'),
            value: this.netOpt ? tr('tv_on') : tr('tv_off'),
            toggle: true,
            valueOn: this.netOpt,
            onTap: () => {
              this.applyNetOpt(!this.netOpt);
            }
          })
          TvMenuItem({
            compact: this.menuCompact(),
            icon: $r('sys.symbol.gauge_with_dots_needle_33percent'),
            label: tr('settings_stats'),
            value: this.showStats ? tr('tv_on') : tr('tv_off'),
            toggle: true,
            valueOn: this.showStats,
            onTap: () => {
              this.showStats = !this.showStats;
            }
          })
          if (this.pipSupported) {
            TvMenuItem({
              compact: this.menuCompact(),
              icon: $r('sys.symbol.rectangle_on_rectangle'),
              label: tr('settings_pip'),
              value: this.pipAuto ? tr('tv_on') : tr('tv_off'),
              toggle: true,
              valueOn: this.pipAuto,
              onTap: () => {
                this.applyPipAuto(!this.pipAuto);
              }
            })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  // 播放菜单二级页里一行选项的标题（和一行小字说明）；“实验性”这类标签放在 MenuGroup 的组标题上
  @Builder
  OptionRow(title: string, desc: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(14).fontColor(Color.White)
      if (desc.length > 0) {
        Text(desc).fontSize(11).fontColor('#99FFFFFF')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  // 屏幕方向页：跟随系统 / 横屏 / 竖屏，当前的打勾；选了就回一级菜单。下面一行说明跟随系统的含义
  @Builder
  MenuOrient() {
    Column({ space: 10 }) {
      this.MenuHeader(tr('play_orient_short'))

      Scroll() {
        Column({ space: this.menuCompact() ? 2 : 4 }) {
          this.OrientChoice(PLAY_ORIENT_FOLLOW)
          this.OrientChoice(PLAY_ORIENT_LANDSCAPE)
          this.OrientChoice(PLAY_ORIENT_PORTRAIT)
          Text(tr('play_orient_desc'))
            .fontSize(11)
            .lineHeight(16)
            .fontColor('#80FFFFFF')
            .width('100%')
            .padding({ left: 12, right: 12, top: 8 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  OrientChoice(value: number) {
    TvMenuItem({
      compact: this.menuCompact(),
      itemId: value === PLAY_ORIENT_FOLLOW ? 'menu-sub-first' : '',
      label: playOrientLabels()[value] ?? '',
      checked: this.playOrientation === value,
      onTap: () => {
        this.playOrientation = value;
        this.backToMainMenu();
      }
    })
  }

  // 画质增强页：关闭 / 标准 / 高，当前的打勾；选了马上生效（会重建一次视频链路）并回一级菜单。下面是完整说明
  @Builder
  MenuEnhance() {
    Column({ space: 10 }) {
      this.MenuHeader(tr('settings_enhance'))

      Scroll() {
        Column({ space: this.menuCompact() ? 2 : 4 }) {
          ForEach(enhanceLabels(), (label: string, i: number) => {
            this.EnhanceChoice(i)
          }, (label: string, i: number) => `${i}`)
          Text(tr('settings_enhance_desc'))
            .fontSize(11)
            .lineHeight(16)
            .fontColor('#80FFFFFF')
            .width('100%')
            .padding({ left: 12, right: 12, top: 8 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  EnhanceChoice(level: number) {
    TvMenuItem({
      compact: this.menuCompact(),
      itemId: level === 0 ? 'menu-sub-first' : '',
      label: enhanceLabels()[level] ?? '',
      checked: this.enhanceLevel === level,
      onTap: () => {
        this.applyEnhance(level);
        this.backToMainMenu();
      }
    })
  }

  // 手柄页：状态卡片（游戏机接不接手柄、正在按什么）、总开关、实体手柄和键盘、触屏手柄几组；“正在按”在这一页开着时
  // 每 100 ms 刷新。各项的详细说明在设置页和使用说明里，这里只留标题，免得太挤
  @Builder
  MenuPad() {
    Column({ space: 10 }) {
      this.MenuHeader(tr('pad_title'))

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Text(this.padStatusText())
              .fontSize(13)
              .lineHeight(18)
              .fontColor(this.padEnabled && this.padTakes ? Color.White : '#FFB74D')
              .width('100%')
            if (this.padEnabled) {
              Row({ space: 8 }) {
                Text(tr('pad_pressing')).fontSize(12).fontColor('#99FFFFFF')
                Text(this.padPressing.length > 0 ? this.padPressing : tr('pad_pressing_none'))
                  .fontSize(13)
                  .fontColor(this.padPressing.length > 0 ? PLAYER_ACCENT : '#99FFFFFF')
                  .fontWeight(FontWeight.Medium)
                  .layoutWeight(1)
                  .maxLines(2)
              }
              .width('100%')

              Text(this.padSticks).fontSize(12).fontColor('#99FFFFFF').fontFeature('"tnum" on')
            }
            if (!padAxisSupported()) {
              Text(tr('pad_axis_unsupported')).fontSize(12).fontColor('#FFB74D').width('100%')
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor('#14FFFFFF')
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          MenuGroup() {
            Row() {
              this.OptionRow(tr('pad_enable'), '')
              Toggle({ type: ToggleType.Switch, isOn: this.padEnabled })
                .selectedColor(PLAYER_ACCENT)
                .onChange((isOn: boolean) => {
                  this.padEnabled = isOn;
                })
            }
            .width('100%')
            .constraintSize({ minHeight: MENU_ROW_MIN_H })
          }

          MenuGroup({ title: tr('pad_section_device') }) {
            Row() {
              this.OptionRow(tr('pad_layout'), '')
              Select(selectOptions(padLayoutLabels()))
                .selected(this.padLayout)
                .value(padLayoutLabels()[this.padLayout] ?? '')
                .font({ size: 13 })
                .fontColor(Color.White)
                .enabled(this.padEnabled)
                .onSelect((index: number) => {
                  this.padLayout = index;
                })
            }
            .width('100%')
            .constraintSize({ minHeight: MENU_ROW_MIN_H })
            .opacity(this.padEnabled ? 1 : 0.4)

            Row() {
              this.OptionRow(tr('pad_deadzone'), '')
              Select(selectOptions(padDeadZoneLabels()))
                .selected(this.padDeadZone)
                .value(padDeadZoneLabels()[this.padDeadZone] ?? '')
                .font({ size: 13 })
                .fontColor(Color.White)
                .enabled(this.padEnabled && padAxisSupported())
                .onSelect((index: number) => {
                  this.padDeadZone = index;
                })
            }
            .width('100%')
            .constraintSize({ minHeight: MENU_ROW_MIN_H })
            .opacity(this.padEnabled && padAxisSupported() ? 1 : 0.4)
          }

          // 触屏手柄（本机有触摸屏时）：组标题带“实验性”标签；打开后才列出大小、透明度、键位
          if (this.vpadOk) {
            MenuGroup({ title: tr('vpad_show'), tag: tr('vpad_experimental') }) {
              Row() {
                this.OptionRow(tr('vpad_show_in_menu'), '')
                Toggle({ type: ToggleType.Switch, isOn: this.vpadShown })
                  .selectedColor(PLAYER_ACCENT)
                  .enabled(this.padEnabled)
                  .onChange((isOn: boolean) => {
                    this.vpadShown = isOn;
                  })
              }
              .width('100%')
              .constraintSize({ minHeight: MENU_ROW_MIN_H })
              .opacity(this.padEnabled ? 1 : 0.4)

              if (this.vpadShown) {
                Row() {
                  this.OptionRow(tr('vpad_size'), '')
                  Select(selectOptions(vpadSizeLabels()))
                    .selected(this.vpadSize)
                    .value(vpadSizeLabels()[this.vpadSize] ?? '')
                    .font({ size: 13 })
                    .fontColor(Color.White)
                    .onSelect((index: number) => {
                      this.vpadSize = index;
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: MENU_ROW_MIN_H })

                Row() {
                  this.OptionRow(tr('vpad_opacity'), '')
                  Select(selectOptions(vpadOpacityLabels()))
                    .selected(this.vpadOpacity)
                    .value(vpadOpacityLabels()[this.vpadOpacity] ?? '')
                    .font({ size: 13 })
                    .fontColor(Color.White)
                    .onSelect((index: number) => {
                      this.vpadOpacity = index;
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: MENU_ROW_MIN_H })

                // 键位：这种摆法（横屏 / 竖屏）现在用哪一个，可以直接换；“调整”改的是当前这个
                Row() {
                  this.OptionRow(tr('vpad_layout_in_menu'), vpadModeLabel(this.vpadMode()))
                  Select(selectOptions(this.layoutNames(this.vpadMode())))
                    .selected(this.layoutIndex(this.vpadMode()))
                    .value(this.layoutNames(this.vpadMode())[this.layoutIndex(this.vpadMode())] ?? '')
                    .font({ size: 13 })
                    .fontColor(Color.White)
                    .onSelect((index: number) => {
                      const mode = this.vpadMode();
                      const list = listLayouts(mode);
                      setActiveLayout(mode, index === 0 ? '' : (list[index - 1]?.id ?? ''));
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: MENU_ROW_MIN_H })

                Row() {
                  this.OptionRow(tr('vpad_edit'), '')
                  Button(tr('vpad_edit_start'))
                    .fontSize(13)
                    .fontColor(Color.White)
                    .backgroundColor('#33FFFFFF')
                    .height(32)
                    .focusBox(FOCUS_BOX)
                    .onClick(() => {
                      this.startVpadEdit();
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: MENU_ROW_MIN_H })
              }
            }
          }

          Text(tr('pad_menu_hint'))
            .fontSize(11)
            .lineHeight(16)
            .fontColor('#80FFFFFF')
            .width('100%')
            .padding({ left: 4, right: 4 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }
}
