import { window, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import nssft from 'libentry.so';
import { ConnectConfig, DeviceInfo, SessionStats } from 'libentry.so';
import { BackgroundKeeper } from '../common/BackgroundKeeper';
import { HotspotService } from '../common/HotspotService';
import { SHORTCUT_HOTSPOT_CONNECT, SHORTCUT_KEY, shortcutAction } from '../common/LaunchShortcut';
import { NetBooster } from '../common/NetBooster';
import { PipSession } from '../common/PipSession';
import {
  APP_NAME, Breakpoint, breakpointOf, enhanceAvailable, enhanceLabels, formatDuration, hotspotSupported,
  KEEP_ALIVE_MINUTES, keepAliveLabels, SFT_PORT, sftVersionOf
} from '../common/Prefs';
import { languageSignature, tr, uiLanguageIndex } from '../common/I18n';
import { StatsRecorder } from '../common/StatsRecorder';
import { StreamTarget } from '../common/StreamTarget';
import { findRecentHost, lastRecentHost, RecentHost, rememberHost } from '../common/RecentHosts';
import { applyColorMode } from '../common/Theme';
import { UsbConsole, UsbLog, UsbPump, UsbWatcher } from '../common/UsbConsole';
import { AboutView } from '../views/AboutView';
import { GuideView } from '../views/GuideView';
import { HomeView } from '../views/HomeView';
import { SettingsView } from '../views/SettingsView';
import { TvMenuItem } from '../views/TvMenuItem';
import { FOCUS_BOX } from '../common/Focus';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';
const LIVE_VIEW_INTERVAL_MS = 5000;
// 前台时实况窗不可见（沉浸式隐藏了状态栏），每分钟刷新一次满足长时任务的进度更新要求即可
const FOREGROUND_REFRESH_TICKS = 12;
const VIDEO_ASPECT = 16 / 9;
// 锁定后锁形图标亮显多久再变淡
// 锁定后锁形按钮显示多久自动隐藏
const LOCK_ICON_MS = 3000;
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
const PLAYER_ON_ACCENT = '#00201C';
const PLAYER_GLASS = '#B3101414';

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
  // 横屏时摄像头挖孔占掉的左右宽度：页面和播放浮层都让开
  @StorageProp('ui.safeLeft') safeLeft: number = 0;
  @StorageProp('ui.safeRight') safeRight: number = 0;
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

  // 设置（和设置页共用）
  @StorageLink('nssft.enableAudio') enableAudio: boolean = true;
  @StorageLink('nssft.netOpt') netOpt: boolean = true;
  @StorageLink('nssft.keepAliveIndex') keepAliveIndex: number = 1;
  @StorageLink('nssft.pipAuto') pipAuto: boolean = true;
  @StorageLink('nssft.lowRefresh') @Watch('applyRefreshHint') lowRefresh: boolean = true;
  @StorageLink('nssft.showStats') showStats: boolean = false;
  @StorageLink('nssft.freezeOnLoss') freezeOnLoss: boolean = true;
  @StorageLink('nssft.enhanceLevel') enhanceLevel: number = 0;
  @StorageProp('hs.channel') hotspotChannel: number = 0;
  @StorageProp('hs.staChannel') staChannel: number = 0;

  // 播放页
  @State playing: boolean = false;
  @State showPanel: boolean = false;
  // 统计浮层的文字（一块面板，每秒刷新）
  @State statsText: string = '';
  @State statusText: string = '';
  // 左上角的画面信息：“1080p · 60 帧”
  @State badgeText: string = '';
  @State controlsVisible: boolean = true;
  @State locked: boolean = false;
  // 锁定时锁形按钮是否显示：锁定后先显示，几秒后自动隐藏；点画面切换显示/隐藏
  @State lockIconShown: boolean = false;
  private lockIconTimer: number = -1;
  // 智慧屏：右侧半屏的操作菜单（菜单键呼出），tvSubmenu 为 true 时显示二级的“播放选项”
  @State tvMenuOpen: boolean = false;
  @State tvSubmenu: boolean = false;
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
  private liveViewTick: number = 0;
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
    this.hideLockIcon();
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
          focus.requestFocus('player-root');
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'focusForRemote failed: %{public}s', JSON.stringify(e));
      }
    }, 300);
  }

  onPageHide(): void {
    this.pageHidden = true;
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

  // 切到后台、且没有在小窗里播放：开了后台保持就继续接收，否则断开
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
    const visible = this.sessionStarted && !this.inBackground;
    nssft.setRefreshRateHint(visible && this.lowRefresh ? PLAYBACK_REFRESH_HZ : 0);
  }

  private onPipClosed(): void {
    if (this.playing) {
      this.schedulePipCheck(PIP_CLOSED_GRACE_MS);
    }
  }

  private async startPip(): Promise<void> {
    this.showPanel = false;
    const err = await this.pip.start();
    if (err.length > 0) {
      promptAction.showToast({ message: tr('player_toast_pip_failed', err) });
      return;
    }
    // 手动转入小窗时主窗口不会自己退到后台：主动退回桌面
    try {
      await (getContext(this) as common.UIAbilityContext).moveAbilityToBackground();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'move to background failed: %{public}s', JSON.stringify(e));
    }
  }

  onBackPress(): boolean {
    if (this.playing && this.locked) {
      // 锁定时返回手势不断开，叫出锁形按钮并提示怎么解锁
      this.showLockIcon();
      promptAction.showToast({ message: tr('player_toast_locked') });
      return true;
    }
    if (this.showPanel) {
      this.showPanel = false;
      return true;
    }
    if (this.playing && IS_TV) {
      // 遥控器：菜单开着时返回键先退出二级列表、再收起菜单；菜单收起时返回键直接断开并回到首页
      if (this.tvMenuOpen) {
        if (this.tvSubmenu) {
          this.leaveTvOptions();
        } else {
          this.closeTvMenu();
        }
        return true;
      }
      this.leavePlayer();
      return true;
    }
    if (this.playing) {
      this.leavePlayer();
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

  private keepAliveMinutes(): number {
    return KEEP_ALIVE_MINUTES[this.keepAliveIndex] ?? 0;
  }

  private async play(target: StreamTarget): Promise<void> {
    if (this.connecting || this.playing) {
      return;
    }
    this.connecting = true;
    this.target = target;
    this.hostRemembered = false;
    // 长时任务只能在前台申请，而且可能先弹“允许通知”授权框，所以留在首页申请完再进播放页
    if (this.keepAliveMinutes() > 0) {
      await this.startKeeper();
    }
    this.statusText = tr('player_connecting', target.label);
    this.badgeText = '';
    this.statsText = '';
    this.locked = false;
    this.hideLockIcon();
    this.controlsVisible = true;
    this.showPanel = false;
    this.tvMenuOpen = false;
    this.tvSubmenu = false;
    // 显示 XComponent，surface 就绪后（onSurfaceReady）真正建立连接
    this.playing = true;
    this.connecting = false;
    this.setImmersive(true);
    this.focusForRemote();
    if (IS_TV) {
      promptAction.showToast({ message: tr('player_toast_tv_menu'), duration: 3000 });
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
    this.liveViewTick = 0;
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
    const cfg: ConnectConfig = {
      surfaceId: surfaceId,
      audio: this.enableAudio,
      netOpt: this.netOpt,
      freezeOnLoss: this.freezeOnLoss,
      enhanceLevel: enhanceAvailable() ? this.enhanceLevel : 0
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
      return;
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
    if (this.pipSupported) {
      this.pip.open(getContext(this), this.xController, this.pipAuto, this.enableAudio);
    }
    this.applyRefreshHint();
    this.startStats(t);
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

  // ---------------------------------------------------------------- 前后台切换

  private enterBackground(): void {
    this.inBackground = true;
    this.backgroundSince = Date.now();
    // 照常接收，释放解码器和音频，只维护 GOP 缓存；后台不渲染，也不必再占用网络加速
    nssft.pauseVideo();
    this.booster.leave();
    this.applyRefreshHint();
    this.refreshLiveView(true);
  }

  private exitBackground(): void {
    this.inBackground = false;
    this.resumeRendering();
    if (this.netOpt && this.target !== null && this.target.usb === null) {
      this.booster.enter();
    }
    this.applyRefreshHint();
    this.refreshLiveView(true);
    hilog.info(DOMAIN, TAG, 'back to foreground after %{public}d s',
      Math.round((Date.now() - this.backgroundSince) / 1000));
  }

  // 用户在通知栏删除了实况窗（长时任务随之被系统取消）：
  // 在后台时当作“停止串流”，立刻断开；前台播放时只关闭后台保持，不打断观看
  private onKeepAliveCanceled(): void {
    if (this.liveViewTimer >= 0) {
      clearInterval(this.liveViewTimer);
      this.liveViewTimer = -1;
    }
    if (!this.playing) {
      return;
    }
    if (this.inBackground) {
      this.leavePlayer();
    } else {
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
    this.liveViewTick++;
    if (this.inBackground) {
      const budgetMs = this.keepAliveMinutes() * 60000;
      const elapsed = Date.now() - this.backgroundSince;
      if (budgetMs > 0 && elapsed >= budgetMs) {
        hilog.info(DOMAIN, TAG, 'background keep-alive expired, disconnecting');
        this.leavePlayer();
        return;
      }
      const s = nssft.getStats();
      const mb = ((s.videoBytes + s.audioBytes) / 1e6).toFixed(1);
      const link = s.connected ? tr('app_live_receiving') : tr('app_live_reconnecting');
      keeper.update({
        title: tr('app_live_title_bg', APP_NAME),
        text: tr('app_live_text_bg', t.label, link, mb, formatDuration(budgetMs - elapsed)),
        progress: budgetMs > 0 ? elapsed * 100 / budgetMs : 0
      });
    } else if (force || this.liveViewTick % FOREGROUND_REFRESH_TICKS === 0) {
      keeper.update({ title: tr('app_live_title_fg', APP_NAME), text: tr('app_live_text_fg', t.label), progress: 0 });
    }
  }

  // ---------------------------------------------------------------- 统计

  // 统计浮层：参考 SFT 的 Android TV 接收端，左上角一块面板、每秒刷新，不分页签：
  // 连接·分辨率·码率 / 收到·显示帧率 / 游戏机端耗时·刷新率 / 声音 / 丢帧与定格 / 其他（画质增强、解码器错误）
  private pollStats(): void {
    const s = nssft.getStats();
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
    this.statusText = s.connected && (fps > 0 || s.frozen) ? '' : s.message;
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
        tr('stats_enhance_off', s.enhanceError.length > 0 ? s.enhanceError : '—'));
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
    this.showPanel = false;
    this.lastStats = null;
    if (this.keeper !== null) {
      this.keeper.stop();
    }
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

  private applyFreeze(on: boolean): void {
    if (on === this.freezeOnLoss) {
      return;
    }
    this.freezeOnLoss = on;
    if (this.sessionStarted) {
      nssft.setFreezeOnLoss(on);
    }
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

  private applyKeepAlive(index: number): void {
    if (index === this.keepAliveIndex) {
      return;
    }
    this.keepAliveIndex = index;
    const keeper = this.keeper;
    if (!this.playing || keeper === null) {
      return;
    }
    if (KEEP_ALIVE_MINUTES[index] > 0 && !keeper.isRunning()) {
      // 当前在前台，可以申请长时任务
      this.suppressPageHide = true;
      this.startKeeper().then(() => {
        this.suppressPageHide = false;
      });
    } else if (KEEP_ALIVE_MINUTES[index] === 0 && keeper.isRunning()) {
      if (this.liveViewTimer >= 0) {
        clearInterval(this.liveViewTimer);
        this.liveViewTimer = -1;
      }
      keeper.stop();
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
    this.stopPlayback();
    this.locked = false;
    this.hideLockIcon();
    this.controlsVisible = true;
    this.tvMenuOpen = false;
    this.tvSubmenu = false;
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

  // 播放时全屏、常亮；手机和平板强制横屏。其他时候跟随设备旋转，服从控制中心的旋转锁。PC 窗口不设方向
  private async setImmersive(on: boolean): Promise<void> {
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
      const landscape = type === 'tablet' || (type === 'phone' && this.bp === 'sm');
      await win.setPreferredOrientation(on && landscape ? window.Orientation.AUTO_ROTATION_LANDSCAPE :
        window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setImmersive failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 播放页：锁定与控件显隐

  private onPlayerTap(): void {
    if (IS_TV) {
      // 智慧屏（模拟器里可以用鼠标点）：点画面开关右侧菜单
      if (this.tvMenuOpen) {
        this.closeTvMenu();
      } else {
        this.openTvMenu();
      }
      return;
    }
    if (this.locked) {
      // 锁定时点画面只切换锁形按钮的显示，按钮显示时点它才解锁
      if (this.lockIconShown) {
        this.hideLockIcon();
      } else {
        this.showLockIcon();
      }
      return;
    }
    if (this.showPanel) {
      this.showPanel = false;
      return;
    }
    this.controlsVisible = !this.controlsVisible;
  }

  private setLocked(on: boolean): void {
    // 智慧屏只有遥控器，不会误触，没有锁定
    if (on && IS_TV) {
      return;
    }
    this.locked = on;
    this.showPanel = false;
    if (on) {
      this.showLockIcon();
    } else {
      this.hideLockIcon();
      this.controlsVisible = true;
    }
  }

  // 显示锁形按钮，几秒后自动隐藏，不挡画面
  private showLockIcon(): void {
    this.lockIconShown = true;
    if (this.lockIconTimer >= 0) {
      clearTimeout(this.lockIconTimer);
    }
    this.lockIconTimer = setTimeout(() => {
      this.lockIconTimer = -1;
      this.lockIconShown = false;
    }, LOCK_ICON_MS);
  }

  private hideLockIcon(): void {
    if (this.lockIconTimer >= 0) {
      clearTimeout(this.lockIconTimer);
      this.lockIconTimer = -1;
    }
    this.lockIconShown = false;
  }

  // ---------------------------------------------------------------- 智慧屏：右侧操作菜单

  // focusNow 为 false：长按确认键打开时，等松开确认键再把焦点移到第一项
  private openTvMenu(focusNow: boolean = true): void {
    this.tvSubmenu = false;
    this.tvMenuOpen = true;
    if (focusNow) {
      this.focusById('tv-main-first');
    } else {
      this.tvFocusOnRelease = true;
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
      if (this.tvMenuOpen) {
        this.closeTvMenu();
      } else {
        this.openTvMenu();
      }
      event.stopPropagation();
      return;
    }
    if (!confirm) {
      return;
    }
    if (event.type === KeyType.Down) {
      // 按住时系统会重复发 Down，只在第一次计时
      if (!this.tvOkDown && !this.tvMenuOpen) {
        this.tvOkDown = true;
        this.tvOkTimer = setTimeout(() => {
          this.tvOkTimer = -1;
          if (this.playing && !this.tvMenuOpen) {
            this.openTvMenu(false);
          }
        }, TV_LONG_PRESS_MS);
      }
      event.stopPropagation();
    } else if (event.type === KeyType.Up) {
      const focusMenu = this.tvFocusOnRelease;
      this.cancelTvLongPress();
      if (focusMenu && this.tvMenuOpen) {
        this.focusById('tv-main-first');
      }
      event.stopPropagation();
    }
  }

  private closeTvMenu(): void {
    this.tvMenuOpen = false;
    this.tvSubmenu = false;
    this.focusById('player-root');
  }

  private enterTvOptions(): void {
    this.tvSubmenu = true;
    this.focusById('tv-opt-first');
  }

  private leaveTvOptions(): void {
    this.tvSubmenu = false;
    this.focusById('tv-main-options');
  }

  // 菜单项刚插入时还拿不到焦点，等它建好再移过去
  private focusById(id: string): void {
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus(id);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'requestFocus %{public}s failed: %{public}s', id, JSON.stringify(e));
      }
    }, 50);
  }

  /** 在取值列表里循环前进/后退一格 */
  private stepIndex(index: number, count: number, dir: number): number {
    return ((index + dir) % count + count) % count;
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
      .visibility(this.playing ? Visibility.Hidden : Visibility.Visible)

      if (this.playing) {
        this.PlayerView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.playing ? Color.Black : $r('app.color.page_bg'))
    // 背景延伸到状态栏和底部小白条区域，页面与系统栏融为一体
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      this.bp = breakpointOf(Number(area.width));
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
    } else if (name === 'about') {
      NavDestination() {
        AboutView()
      }
      .title(tr('about_title'))
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
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

  // 底部工具条上的一个按钮：图标在上、文字在下
  @Builder
  ToolButton(icon: Resource, label: string, danger: boolean, onTap: () => void) {
    Column({ space: 2 }) {
      SymbolGlyph(icon).fontSize(20).fontColor([danger ? '#FF8A5C' : Color.White])
      Text(label).fontSize(10).fontColor(danger ? '#FF8A5C' : '#CCFFFFFF')
    }
    .width(58)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .focusable(true)
    .focusBox(FOCUS_BOX)
    .onClick(() => {
      onTap();
    })
    .accessibilityText(label)
  }

  // 注意：直接读 this.xxx，不能作为 @Builder 参数按值传入（按值传的参数不会随状态刷新）
  @Builder
  Toolbar() {
    Row({ space: 2 }) {
      // 智慧屏没有触屏，不需要防误触的锁定
      if (!IS_TV) {
        this.ToolButton($r('sys.symbol.lock_open'), tr('player_lock'), false, () => {
          this.setLocked(true);
        })
      }
      this.ToolButton(this.enableAudio ? $r('sys.symbol.speaker_wave_2') : $r('sys.symbol.speaker_slash'),
        this.enableAudio ? tr('player_sound_on') : tr('player_sound_off'), false, () => {
          this.applyAudio(!this.enableAudio);
        })
      // 手柄转发、录制：先放入口，功能还在开发
      this.ToolButton($r('sys.symbol.gamecontroller'), tr('player_gamepad'), false, () => {
        promptAction.showToast({ message: tr('player_toast_coming_soon', tr('player_gamepad')) });
      })
      this.ToolButton($r('sys.symbol.record_circle'), tr('player_record'), false, () => {
        promptAction.showToast({ message: tr('player_toast_coming_soon', tr('player_record')) });
      })
      if (this.pipSupported) {
        this.ToolButton($r('sys.symbol.rectangle_on_square'), tr('player_pip'), false, () => {
          this.startPip();
        })
      }
      this.ToolButton($r('sys.symbol.slider_horizontal_2'), tr('player_options'), false, () => {
        this.showPanel = !this.showPanel;
      })
      this.ToolButton($r('sys.symbol.power'), tr('player_stop'), true, () => {
        this.leavePlayer();
      })
    }
    .padding({ left: 6, right: 6 })
    .borderRadius(28)
    .backgroundColor(PLAYER_GLASS)
  }

  @Builder
  PlayerView() {
    Stack() {
      // 按 16:9 适配窗口：画质增强接管输出后不认 native 侧设的 FIT 缩放模式，surface 本身是 16:9 才不会被拉伸
      XComponent({ type: XComponentType.SURFACE, controller: this.xController })
        .width(this.playerWidth)
        .height(this.playerHeight)

      if (!this.locked) {
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
            .constraintSize({ maxWidth: 560 })
          }
          if (this.showStats) {
            this.StatsPanel()
          } else if (this.statusText.length === 0 && (IS_TV ? this.tvMenuOpen : this.controlsVisible) &&
            this.badgeText.length > 0) {
            Text(this.badgeText)
              .fontSize(12)
              .fontColor(PLAYER_ON_ACCENT)
              .fontWeight(FontWeight.Medium)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(PLAYER_ACCENT)
              .borderRadius(8)
          }
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16 + this.safeLeft, right: 16 + this.safeRight, top: 16, bottom: 16 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 底部居中：解锁时是工具条；锁定后只有一个锁形按钮，平时隐藏，点画面才出来，这是唯一可点的元素
      Column() {
        if (this.locked) {
          if (this.lockIconShown) {
            Row() {
              SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(22).fontColor([Color.White])
            }
            .width(52)
            .height(52)
            .borderRadius(26)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(PLAYER_GLASS)
            .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            .focusable(true)
            .focusBox(FOCUS_BOX)
            .onClick(() => {
              this.setLocked(false);
            })
            .accessibilityText(tr('player_unlock'))
          }
        } else if (this.controlsVisible && !this.showPanel && !IS_TV) {
          // 智慧屏不用底部工具条，改用右侧菜单
          this.Toolbar()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .padding({ bottom: 20 })
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.showPanel && !this.locked && !IS_TV) {
        this.OptionsSheet()
      }

      // 智慧屏：右侧半屏的操作菜单，从右边缘滑入
      if (IS_TV) {
        Row() {
          if (this.tvMenuOpen) {
            this.TvMenu()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 点画面空白处：解锁时显示/隐藏控件，锁定时显示/隐藏锁形按钮。挂在根节点上，按钮自己的点击优先
    .onClick(() => {
      this.onPlayerTap();
    })
    .onAreaChange((_old: Area, area: Area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      this.playerWidth = Math.min(w, h * VIDEO_ASPECT);
      this.playerHeight = this.playerWidth / VIDEO_ASPECT;
    })
    .focusable(true)
    .defaultFocus(true)
    .id('player-root')
    .onKeyEvent((event: KeyEvent) => {
      // 外接键盘：Esc 相当于返回（锁定时不断开）
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.onBackPress();
        return;
      }
      const confirm = event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER ||
        event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER;
      if (IS_TV) {
        // 菜单开着时，确认键由获焦的菜单项处理；这里只管菜单键和画面上的长按确认
        // （长按打开菜单后焦点还在这里，要等到确认键松开再移进菜单）
        if (!confirm || !this.tvMenuOpen || this.tvFocusOnRelease) {
          this.onTvKey(event, confirm);
        }
        return;
      }
      if (event.type !== KeyType.Down) {
        return;
      }
      // 键盘：控件隐藏时按确认键叫出控件（相当于点画面）；控件显示时确认键交给获焦的按钮
      if (confirm && !this.controlsVisible) {
        this.onPlayerTap();
        event.stopPropagation();
        return;
      }
      // 菜单键：打开/关闭播放选项
      if (event.keyCode === KeyCode.KEYCODE_MENU && !this.locked) {
        this.controlsVisible = true;
        this.showPanel = !this.showPanel;
        event.stopPropagation();
      }
    })
  }

  // 智慧屏的操作菜单：屏幕右侧一半宽的半透明面板，纵向列表。一级是常用操作，“选项”进入二级的播放选项。
  // 菜单项直接读 this.xxx 传给 TvMenuItem 的 @Prop，状态变了会跟着刷新
  @Builder
  TvMenu() {
    Column() {
      if (this.tvSubmenu) {
        this.TvOptionsList()
      } else {
        this.TvMainList()
      }
    }
    .width('50%')
    .height('100%')
    .padding({ left: 28, right: 28, top: 32, bottom: 24 })
    .backgroundColor('#D90E1414')
    .transition(TransitionEffect.move(TransitionEdge.END).animation({ duration: 260, curve: Curve.FastOutSlowIn }))
    .onClick(() => {
      // 吞掉点击，避免冒泡到画面把菜单关掉
    })
  }

  @Builder
  TvMainList() {
    Column({ space: 16 }) {
      Column({ space: 4 }) {
        Text(this.target !== null ? this.target.label : '')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.badgeText.length > 0) {
          Text(this.badgeText).fontSize(13).fontColor('#99FFFFFF')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16 })

      Scroll() {
        Column({ space: 4 }) {
          TvMenuItem({
            itemId: 'tv-main-first',
            icon: $r('sys.symbol.speaker_wave_2'),
            label: tr('player_sound_on'),
            value: this.enableAudio ? tr('tv_on') : tr('tv_off'),
            valueOn: this.enableAudio,
            onTap: () => {
              this.applyAudio(!this.enableAudio);
            }
          })
          // 手柄转发、录制：先放入口，功能还在开发
          TvMenuItem({
            icon: $r('sys.symbol.gamecontroller'),
            label: tr('player_gamepad'),
            onTap: () => {
              promptAction.showToast({ message: tr('player_toast_coming_soon', tr('player_gamepad')) });
            }
          })
          TvMenuItem({
            icon: $r('sys.symbol.record_circle'),
            label: tr('player_record'),
            onTap: () => {
              promptAction.showToast({ message: tr('player_toast_coming_soon', tr('player_record')) });
            }
          })
          if (this.pipSupported) {
            TvMenuItem({
              icon: $r('sys.symbol.rectangle_on_square'),
              label: tr('player_pip'),
              onTap: () => {
                this.closeTvMenu();
                this.startPip();
              }
            })
          }
          TvMenuItem({
            itemId: 'tv-main-options',
            icon: $r('sys.symbol.slider_horizontal_2'),
            label: tr('player_options_title'),
            chevron: true,
            onTap: () => {
              this.enterTvOptions();
            }
          })
          TvMenuItem({
            icon: $r('sys.symbol.power'),
            label: tr('player_stop'),
            danger: true,
            onTap: () => {
              this.leavePlayer();
            }
          })
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
  TvOptionsList() {
    Column({ space: 16 }) {
      // 标题行：遥控器用返回键回到上一级；鼠标点这一行也能返回
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([Color.White])
        Text(tr('player_options_title'))
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width('100%')
      .padding({ left: 12, right: 16 })
      .onClick(() => {
        this.leaveTvOptions();
      })

      Scroll() {
        Column({ space: 4 }) {
          TvMenuItem({
            itemId: 'tv-opt-first',
            label: tr('settings_freeze'),
            desc: tr('player_freeze_desc'),
            value: this.freezeOnLoss ? tr('tv_on') : tr('tv_off'),
            valueOn: this.freezeOnLoss,
            onTap: () => {
              this.applyFreeze(!this.freezeOnLoss);
            }
          })
          if (enhanceAvailable()) {
            TvMenuItem({
              label: tr('settings_enhance'),
              desc: tr('player_enhance_desc'),
              value: `‹ ${enhanceLabels()[this.enhanceLevel]} ›`,
              valueOn: this.enhanceLevel > 0,
              onTap: () => {
                this.applyEnhance(this.stepIndex(this.enhanceLevel, enhanceLabels().length, 1));
              },
              onStep: (dir: number) => {
                this.applyEnhance(this.stepIndex(this.enhanceLevel, enhanceLabels().length, dir));
              }
            })
          }
          TvMenuItem({
            label: tr('settings_netopt'),
            value: this.netOpt ? tr('tv_on') : tr('tv_off'),
            valueOn: this.netOpt,
            onTap: () => {
              this.applyNetOpt(!this.netOpt);
            }
          })
          TvMenuItem({
            label: tr('settings_stats'),
            value: this.showStats ? tr('tv_on') : tr('tv_off'),
            valueOn: this.showStats,
            onTap: () => {
              this.showStats = !this.showStats;
            }
          })
          TvMenuItem({
            label: tr('settings_keepalive'),
            value: `‹ ${keepAliveLabels()[this.keepAliveIndex]} ›`,
            valueOn: this.keepAliveIndex > 0,
            onTap: () => {
              this.applyKeepAlive(this.stepIndex(this.keepAliveIndex, keepAliveLabels().length, 1));
            },
            onStep: (dir: number) => {
              this.applyKeepAlive(this.stepIndex(this.keepAliveIndex, keepAliveLabels().length, dir));
            }
          })
          if (this.pipSupported) {
            TvMenuItem({
              label: tr('settings_pip'),
              value: this.pipAuto ? tr('tv_on') : tr('tv_off'),
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

  // 播放选项：从底部弹出的面板，改了立即生效
  @Builder
  OptionsSheet() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text(tr('player_options_title'))
              .fontSize(16)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(20)
              .fontColor([Color.White])
              .padding(6)
              .focusable(true)
              .focusBox(FOCUS_BOX)
              .onClick(() => {
                this.showPanel = false;
              })
          }
          .width('100%')

          Row() {
            this.OptionRow(tr('settings_freeze'), tr('player_freeze_desc'))
            Toggle({ type: ToggleType.Switch, isOn: this.freezeOnLoss })
              .selectedColor(PLAYER_ACCENT)
              .onChange((isOn: boolean) => {
                this.applyFreeze(isOn);
              })
          }
          .width('100%')

          if (enhanceAvailable()) {
            Row() {
              this.OptionRow(tr('settings_enhance'), tr('player_enhance_desc'))
              Select(selectOptions(enhanceLabels()))
                .selected(this.enhanceLevel)
                .value(enhanceLabels()[this.enhanceLevel])
                .font({ size: 13 })
                .fontColor(Color.White)
                .onSelect((index: number) => {
                  this.applyEnhance(index);
                })
            }
            .width('100%')
          }

          Row() {
            this.OptionRow(tr('settings_netopt'), '')
            Toggle({ type: ToggleType.Switch, isOn: this.netOpt })
              .selectedColor(PLAYER_ACCENT)
              .onChange((isOn: boolean) => {
                this.applyNetOpt(isOn);
              })
          }
          .width('100%')

          Row() {
            this.OptionRow(tr('settings_stats'), '')
            Toggle({ type: ToggleType.Switch, isOn: this.showStats })
              .selectedColor(PLAYER_ACCENT)
              .onChange((isOn: boolean) => {
                this.showStats = isOn;
              })
          }
          .width('100%')

          Row() {
            this.OptionRow(tr('settings_keepalive'), '')
            Select(selectOptions(keepAliveLabels()))
              .selected(this.keepAliveIndex)
              .value(keepAliveLabels()[this.keepAliveIndex])
              .font({ size: 13 })
              .fontColor(Color.White)
              .onSelect((index: number) => {
                this.applyKeepAlive(index);
              })
          }
          .width('100%')

          if (this.pipSupported) {
            Row() {
              this.OptionRow(tr('settings_pip'), '')
              Toggle({ type: ToggleType.Switch, isOn: this.pipAuto })
                .selectedColor(PLAYER_ACCENT)
                .onChange((isOn: boolean) => {
                  this.applyPipAuto(isOn);
                })
            }
            .width('100%')
          }
        }
        .padding(18)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .constraintSize({ maxWidth: 560, maxHeight: '70%' })
      .backgroundColor('#F2141A1A')
      .borderRadius({ topLeft: 24, topRight: 24 })
      .onClick(() => {
        // 吞掉点击，避免冒泡到画面把面板关掉
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
