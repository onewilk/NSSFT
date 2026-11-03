// 录像时在通知栏显示录制状态，并提供“停止录制”按钮：实况窗（Live View Kit，计时场景 TIMER，按《实况窗设计规范》的计时模板）。
//    胶囊：录制图标 + 计时 + “录制中”；卡片：大字计时 + “录制中 · 已录大小”，右侧辅助区是“停止录制”按钮。
//    录像没有暂停，节点只有：录制中（录进第一帧时创建）→ 结束（立即撤掉）。
// 需要在 AGC 开通实况窗服务权益、Profile 里带上，并且用户没关掉实况窗；不可用时不显示（不再另发普通通知：
// 录像长时任务的系统实况窗已经显示录制时长和大小，两张卡片内容重复，用户 2026-11-03 要求去掉）。
import { liveViewManager } from '@kit.LiveViewKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { tr } from './I18n';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';
// 实况窗 id（应用自己定）：一次只有一个录制
const LIVE_VIEW_ID = 7301;
const RECORD_RED = '#FFE5484D';

/** 要显示的录制状态 */
export interface RecordStatusInfo {
  /** 已录时长（毫秒）：实况窗的计时从这里接着走 */
  elapsedMs: number;
  /** 已录大小，例如 “120 MB” */
  size: string;
}

type Mode = 'none' | 'live';

export class RecordStatus {
  /** 通知栏上的“停止录制”被点了（公共事件回调在主线程） */
  onStop: () => void = () => {
  };

  private ctx: common.UIAbilityContext;
  private stopEvent: string;
  private mode: Mode = 'none';
  private openAgent: WantAgent | undefined = undefined;
  private stopAgent: WantAgent | undefined = undefined;
  private subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private errors: number = 0;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
    this.stopEvent = `${ctx.abilityInfo.bundleName}.action.STOP_RECORDING`;
  }

  /** 当前用的是哪种（给日志和统计用） */
  current(): Mode {
    return this.mode;
  }

  /** 开始显示（应在前台调用：实况窗只能在前台创建） */
  async start(info: RecordStatusInfo): Promise<void> {
    if (this.mode !== 'none') {
      await this.update(info);
      return;
    }
    try {
      await this.prepareActions();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'record status actions failed: %{public}d %{public}s', err.code, err.message);
      return;
    }
    this.errors = 0;
    if (await this.startLiveView(info)) {
      this.mode = 'live';
      hilog.info(DOMAIN, TAG, 'recording status: live view');
      return;
    }
    await this.cleanup();
  }

  async update(info: RecordStatusInfo): Promise<void> {
    if (this.mode === 'live') {
      try {
        await liveViewManager.updateLiveView(this.buildLiveView(info));
      } catch (e) {
        this.logError('update live view', e as BusinessError);
      }
    }
  }

  /** 停止录制、离开播放页时调用 */
  async stop(info: RecordStatusInfo): Promise<void> {
    const mode = this.mode;
    this.mode = 'none';
    if (mode === 'live') {
      try {
        // 用户主动或被动结束录制：立即结束实况窗（规范要求）
        await liveViewManager.stopLiveView(this.buildLiveView(info));
      } catch (e) {
        this.logError('stop live view', e as BusinessError);
      }
    }
    await this.cleanup();
  }

  // ---------------------------------------------------------------- 实况窗

  private async startLiveView(info: RecordStatusInfo): Promise<boolean> {
    if (!canIUse('SystemCapability.LiveView.LiveViewService')) {
      return false;
    }
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        hilog.info(DOMAIN, TAG, 'live view switched off for this app');
        return false;
      }
      await liveViewManager.startLiveView(this.buildLiveView(info));
      return true;
    } catch (e) {
      // 常见原因：还没开通实况窗服务权益（Profile 里没有）
      const err = e as BusinessError;
      hilog.info(DOMAIN, TAG, 'live view unavailable (%{public}d %{public}s)',
        err.code, err.message);
      return false;
    }
  }

  // 计时场景的基础模板：标题是计时（系统每秒刷新），下一行是“录制中 · 已录大小”，辅助区是停止按钮
  private buildLiveView(info: RecordStatusInfo): liveViewManager.LiveView {
    const layout: liveViewManager.PickupLayout = { layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT };
    const capsule: liveViewManager.TimerCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
      status: 1,
      icon: 'live_rec.png',
      backgroundColor: RECORD_RED,
      time: info.elapsedMs,
      isCountdown: false,
      isPaused: false,
      content: tr('live_rec_state_recording')
    };
    return {
      id: LIVE_VIEW_ID,
      event: 'TIMER',
      isMute: true,
      timer: { time: info.elapsedMs, isCountdown: false, isPaused: false },
      liveViewData: {
        primary: {
          title: '${placeholder.timer}',
          content: [{ text: tr('live_rec_content', info.size) }],
          keepTime: 0,
          clickAction: this.openAgent,
          extensionData: {
            type: liveViewManager.ExtensionType.EXTENSION_TYPE_ICON,
            pic: 'live_stop.png',
            clickAction: this.stopAgent
          },
          // 必填：计时模板不显示扩展区（LAYOUT_TYPE_DEFAULT）。不传会报 401 “primary.layoutData must be LayoutData”
          layoutData: layout
        },
        capsule: capsule
      }
    };
  }

  // ---------------------------------------------------------------- 共用

  private async prepareActions(): Promise<void> {
    if (this.openAgent === undefined) {
      const openInfo: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: this.ctx.abilityInfo.bundleName, abilityName: this.ctx.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 11,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      this.openAgent = await wantAgent.getWantAgent(openInfo);
    }
    if (this.stopAgent === undefined) {
      const stopInfo: wantAgent.WantAgentInfo = {
        wants: [{ action: this.stopEvent }],
        actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
        requestCode: 12,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      this.stopAgent = await wantAgent.getWantAgent(stopInfo);
    }
    if (this.subscriber === undefined) {
      // 事件名带包名前缀，只有本应用通知栏上的按钮会发
      const sub = await commonEventManager.createSubscriber({ events: [this.stopEvent] });
      commonEventManager.subscribe(sub, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (!err && data.event === this.stopEvent) {
          hilog.info(DOMAIN, TAG, 'stop recording requested from the notification bar');
          this.onStop();
        }
      });
      this.subscriber = sub;
    }
  }

  private async cleanup(): Promise<void> {
    const sub = this.subscriber;
    if (sub !== undefined) {
      commonEventManager.unsubscribe(sub);
      this.subscriber = undefined;
    }
    this.openAgent = undefined;
    this.stopAgent = undefined;
  }

  private logError(what: string, err: BusinessError): void {
    if (this.errors++ < 5) {
      hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}d %{public}s', what, err.code, err.message);
    }
  }
}
