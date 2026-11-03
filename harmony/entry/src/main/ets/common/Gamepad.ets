// 手柄（SFT 0.7.20 起，游戏机上的 SFT 打开 “Controls from the viewer”）：本机的手柄、键盘和触屏手柄 → 游戏机上的一个手柄。
// 按键状态、摇杆死区和发送（变了马上发、每 100 ms 重发、退出时拔掉）都在原生层（core/sft_pad.h），这里负责：
//   设置（开关、按键布局、摇杆死区）、本机连着哪些手柄（系统输入设备列表），以及把播放页收到的焦点轴事件
//   （摇杆、模拟扳机、帽子开关式十字键，API 15 起）转给原生层。按键事件由播放页的 onKeyEvent 直接转。
// 一个客户端在游戏机上只对应一个手柄：本机的几个手柄、键盘、触屏手柄（views/VirtualPad.ets）都合并成这一个。
import { inputDevice } from '@kit.InputKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import nssft from 'libentry.so';
import { tr } from './I18n';

PersistentStorage.persistProp('nssft.padEnabled', true);
// 0 按位置（默认，下面那个键是 B，和游戏机手柄一样）/ 1 按标签
PersistentStorage.persistProp('nssft.padLayout', 0);
// 摇杆死区档位，见 PAD_DEAD_ZONES
PersistentStorage.persistProp('nssft.padDeadZone', 1);

// 触屏手柄：显示着没有（在手柄面板里打开，记住选择）、大小、透明度、按键震动、接上实体手柄时自动收起
PersistentStorage.persistProp('nssft.vpadShown', false);
PersistentStorage.persistProp('nssft.vpadSize', 1);
PersistentStorage.persistProp('nssft.vpadOpacity', 1);
PersistentStorage.persistProp('nssft.vpadHaptic', true);
PersistentStorage.persistProp('nssft.vpadAutoHide', true);
// 宽屏状态下（阔折叠、折叠屏展开等，见 VpadLayouts.isWideScreen）的两个选项，默认都关：
//   强制竖屏：串流时竖着显示；分离展示：画面在上、触屏手柄在下（画面下方空出足够的位置时）
PersistentStorage.persistProp('nssft.vpadPortrait', false);
PersistentStorage.persistProp('nssft.vpadSplitMode', false);
// 第二版的键位（叠加 / 画面下方两套），只为了第一次启动时转成自建键位（VpadLayouts.migrateOldLayouts）
PersistentStorage.persistProp('nssft.vpadLayout', '');

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

export const PAD_DEAD_ZONES: number[] = [0.04, 0.08, 0.12, 0.16];
const PAD_TRIGGER_POINT = 0.3;

export function padLayoutLabels(): string[] {
  return [tr('pad_layout_place'), tr('pad_layout_label')];
}

export function padDeadZoneLabels(): string[] {
  return PAD_DEAD_ZONES.map((z: number, i: number): string => {
    const label = `${Math.round(z * 100)}%`;
    return i === 1 ? tr('pad_deadzone_default', label) : label;
  });
}

/** 触屏手柄只在手机和平板上提供（电脑用键鼠，智慧屏没有触屏） */
export function vpadAvailable(): boolean {
  return deviceInfo.deviceType === 'phone' || deviceInfo.deviceType === 'tablet';
}

export function vpadSizeLabels(): string[] {
  return [tr('vpad_size_small'), tr('vpad_size_medium'), tr('vpad_size_large')];
}

export function vpadOpacityLabels(): string[] {
  return ['30%', '50%', '75%'];
}

/** 摇杆、模拟扳机用的焦点轴事件（onFocusAxisEvent）API 15 起才有；更早的系统只有按键 */
export function padAxisSupported(): boolean {
  return deviceInfo.sdkApiVersion >= 15;
}

/** 把设置交给原生层。active：播放页在前台、在显示画面（不是只录制） */
export function padConfigure(active: boolean): void {
  const enabled = AppStorage.get<boolean>('nssft.padEnabled') ?? true;
  const layout = AppStorage.get<number>('nssft.padLayout') ?? 0;
  const dead = PAD_DEAD_ZONES[AppStorage.get<number>('nssft.padDeadZone') ?? 1] ?? PAD_DEAD_ZONES[1];
  nssft.padConfigure({
    enabled: active && enabled,
    faceByLabel: layout === 1,
    deadZone: dead,
    triggerPoint: PAD_TRIGGER_POINT
  });
}

// 开始键和选择键（游戏机上的 + 和 −），以及键盘上对应的键：同时按住 1.5 秒打开串流选项
const PLUS_KEYS: number[] = [2312, 2058, 2066, 2116];
const MINUS_KEYS: number[] = [2311, 2057, 2115];
export const PAD_BUTTON_B = 2302;

export function isPadPlusKey(code: number): boolean {
  return PLUS_KEYS.indexOf(code) >= 0;
}

export function isPadMinusKey(code: number): boolean {
  return MINUS_KEYS.indexOf(code) >= 0;
}

/** 本机连着的手柄（系统输入设备里带 joystick 的）；插拔时刷新，并告诉原生层有没有手柄 */
export class PadDevices {
  names: string[] = [];
  onChange: () => void = () => {
  };
  private listening: boolean = false;
  private generation: number = 0;
  private changeCallback = (_d: inputDevice.DeviceListener): void => {
    this.refresh();
  };

  start(): void {
    if (!this.listening) {
      try {
        inputDevice.on('change', this.changeCallback);
        this.listening = true;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listen input devices failed: %{public}s', JSON.stringify(e));
      }
    }
    this.refresh();
  }

  stop(): void {
    this.generation++;
    if (this.listening) {
      try {
        inputDevice.off('change', this.changeCallback);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'unlisten input devices failed: %{public}s', JSON.stringify(e));
      }
      this.listening = false;
    }
    this.names = [];
    nssft.padDevicePresent(false);
  }

  async refresh(): Promise<void> {
    const gen = ++this.generation;
    const names: string[] = [];
    try {
      const ids = await inputDevice.getDeviceList();
      for (const id of ids) {
        const info = await inputDevice.getDeviceInfo(id);
        if (info.sources.indexOf('joystick') >= 0) {
          names.push(info.name.length > 0 ? info.name : tr('pad_device_generic'));
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list input devices failed: %{public}s', JSON.stringify(e));
    }
    if (gen !== this.generation) {
      return;  // 期间又刷新过或已停止
    }
    if (names.join('|') !== this.names.join('|')) {
      hilog.info(DOMAIN, TAG, 'controllers: %{public}s', names.length > 0 ? names.join(', ') : '(none)');
    }
    this.names = names;
    nssft.padDevicePresent(names.length > 0);
    this.onChange();
  }
}

// 系统报的轴值一般已经是 -1..1（扳机 0..1）；万一是原始值，按常见量程粗略换算，免得一推就满
function stickValue(v: number | undefined): number {
  if (v === undefined || Number.isNaN(v)) {
    return NaN;
  }
  const n = Math.abs(v) > 2 ? v / 32767 : v;
  return Math.max(-1, Math.min(1, n));
}

function triggerValue(v: number | undefined): number {
  if (v === undefined || Number.isNaN(v)) {
    return NaN;
  }
  const n = v > 2 ? v / (v > 255 ? 1023 : 255) : v;
  return Math.max(0, Math.min(1, n));
}

let axisLogged = 0;

/** 一个焦点轴事件 → 原生层；返回 true 表示交给了游戏机 */
export function padForwardAxis(e: FocusAxisEvent): boolean {
  const m = e.axisMap;
  if (axisLogged < 5) {
    // 方便排查不同手柄的轴（测试阶段）
    axisLogged++;
    const parts: string[] = [];
    m.forEach((v: number, k: AxisModel) => {
      parts.push(`${k}=${v.toFixed(3)}`);
    });
    hilog.info(DOMAIN, TAG, 'pad axes: %{public}s', parts.join(' '));
  }
  // 左摇杆 X/Y，右摇杆 Z/RZ，左扳机 BRAKE、右扳机 GAS，十字键 HAT0X/HAT0Y（y 都是向下为正）
  return nssft.padAxes(
    stickValue(m.get(AxisModel.ABS_X)), stickValue(m.get(AxisModel.ABS_Y)),
    stickValue(m.get(AxisModel.ABS_Z)), stickValue(m.get(AxisModel.ABS_RZ)),
    triggerValue(m.get(AxisModel.ABS_BRAKE)), triggerValue(m.get(AxisModel.ABS_GAS)),
    stickValue(m.get(AxisModel.ABS_HAT0X)), stickValue(m.get(AxisModel.ABS_HAT0Y)));
}

/**
 * 给播放页根节点挂焦点轴事件。onFocusAxisEvent 是 API 15 的属性方法，应用最低支持 API 12：
 * 直接写在组件上，低版本系统上一渲染就会因为没有这个方法而出错，所以放在 modifier 里按版本挂
 */
export class PadAxisModifier implements AttributeModifier<StackAttribute> {
  handler: (e: FocusAxisEvent) => void = () => {
  };

  applyNormalAttribute(instance: StackAttribute): void {
    if (padAxisSupported()) {
      instance.onFocusAxisEvent((e: FocusAxisEvent) => {
        this.handler(e);
      });
    }
  }
}
