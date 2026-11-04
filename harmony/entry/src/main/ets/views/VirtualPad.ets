// 触屏手柄：画在一块 Canvas 上，按键位置（单位 vp）由“键位”算出来。两种摆法，键位分别保存：
//   叠加（overlay）：盖在画面上，Canvas 和播放器一样大；顶部中间留给播放页的菜单按钮（调整时拖不进去）
//   画面下方（split）：画面下方空间够大时（折叠屏展开），播放页把画面贴顶，Canvas 只占下面一块（regionTop 以下），
//   不挡画面；调整键位的工具条放到画面上，不压着按键
// 一个 onTouch 处理所有手指：按下时看落在哪个控件上（落在左半边空白处就是浮动的左摇杆），之后这根手指一直归它；
// 面向键、十字键、肩键可以滑着换键。所有手指合起来的状态交给原生层（padTouch），和实体手柄、键盘合成同一个手柄。
// 调整键位（editing）：拖动每个控件换位置，选中后可以改大小、隐藏；点“保存”才写入，“取消”丢掉改动。
// 键位按区域的比例保存（换设备、转屏都能用），大小是相对默认大小的倍数。
// 显示期间关掉系统的侧滑返回（拇指贴着屏幕边缘很容易误触），返回改成 1 秒内连按两次才断开（见播放页）。
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vibrator } from '@kit.SensorServiceKit';
import nssft from 'libentry.so';
import { FOCUS_BOX } from '../common/Focus';
import { tr } from '../common/I18n';
import { getLayout, UnitSave } from '../common/VpadLayouts';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

// 游戏机的按键位（HidNpadButton，与 core/sft_pad.h 一致）
const BIT_A = 1;
const BIT_B = 2;
const BIT_X = 4;
const BIT_Y = 8;
const BIT_L3 = 16;
const BIT_R3 = 32;
const BIT_L = 64;
const BIT_R = 128;
const BIT_ZL = 256;
const BIT_ZR = 512;
const BIT_PLUS = 1024;
const BIT_MINUS = 2048;
const BIT_LEFT = 4096;
const BIT_UP = 8192;
const BIT_RIGHT = 16384;
const BIT_DOWN = 32768;
const BIT_HOME = 262144;
const BIT_CAPTURE = 524288;
const DPAD_BITS = BIT_LEFT | BIT_UP | BIT_RIGHT | BIT_DOWN;

/** 大小档位（小 / 中 / 大）与透明度档位 */
export const VPAD_SCALES: number[] = [0.85, 1.0, 1.18];
export const VPAD_OPACITIES: number[] = [0.3, 0.5, 0.75];

// 控件分组：同一组里手指可以滑着换键
const GROUP_FACE = 1;
const GROUP_LEFT_SHOULDER = 2;
const GROUP_RIGHT_SHOULDER = 3;

// 一根手指归谁
const KIND_NONE = 0;
const KIND_KEY = 1;
const KIND_DPAD = 2;
const KIND_LSTICK = 3;
const KIND_RSTICK = 4;
// 叠加时顶部中间留给播放页的菜单按钮（44 vp，离顶 12），按键不放进这块
const MENU_RESERVE_W = 72;
const MENU_RESERVE_H = 64;

// 可以调整的控件（也是绘制和命中的顺序）。L3 / R3 默认隐藏，需要时在调整键位里打开
const UNIT_IDS: string[] = ['zl', 'l', 'zr', 'r', 'lstick', 'dpad', 'face', 'rstick', 'minus', 'capture', 'home', 'plus',
  'l3', 'r3'];
const SCALE_MIN = 0.6;
const SCALE_MAX = 1.8;

const GLASS = 'rgba(255,255,255,0.20)';
const EDGE = 'rgba(255,255,255,0.60)';
const LABEL = 'rgba(255,255,255,0.95)';
const PRESSED = 'rgba(32,201,151,0.85)';
const SELECTED = 'rgba(32,201,151,1)';

/** 一个控件的键位：中心在区域里的比例位置、相对默认大小的倍数、是否隐藏 */
interface Unit {
  id: string;
  fx: number;
  fy: number;
  s: number;
  hidden: boolean;
}


/** 一个按键：圆形（直径 w）或胶囊（w × h），中心 x、y */
interface PadKey {
  bit: number;
  label: string;
  x: number;
  y: number;
  w: number;
  h: number;
  round: boolean;
  group: number;  // 0：自己一组（不能滑过来）
}

interface PadStick {
  x: number;
  y: number;
  r: number;
  hidden: boolean;
}

interface Finger {
  id: number;
  kind: number;
  group: number;
  bits: number;
  // 摇杆的中心（浮动摇杆是按下的位置）与当前偏移
  ox: number;
  oy: number;
  dx: number;
  dy: number;
  // 按下时落在的键（不能滑的键要一直按在它上面）
  key: number;
}

function inKey(k: PadKey, x: number, y: number, pad: number): boolean {
  if (k.round) {
    const r = k.w / 2 + pad;
    return (x - k.x) * (x - k.x) + (y - k.y) * (y - k.y) <= r * r;
  }
  return Math.abs(x - k.x) <= k.w / 2 + pad && Math.abs(y - k.y) <= k.h / 2 + pad;
}

@Component
export struct VirtualPad {
  /** false：工具条或面板开着，触屏手柄变淡、不响应（触摸交给工具条） */
  @Prop @Watch('onInteractiveChanged') interactive: boolean = true;
  /** 画面下方的摆法（Canvas 只占画面下面一块） */
  @Prop @Watch('reload') split: boolean = false;
  /** 按键区从多高开始（vp）：画面下方时是画面的高度，叠加时是 0 */
  @Prop regionTop: number = 0;
  /** 用哪个自建键位（空串：内置）；layoutKey 变了（换键位、键位被改）就重新读 */
  @Prop layoutId: string = '';
  @Prop @Watch('reload') layoutKey: string = '';
  /** 缩略图：只画，不响应触摸；按 refW × refH 的屏幕排好再缩放到实际大小 */
  @Prop preview: boolean = false;
  @Prop refW: number = 0;
  @Prop refH: number = 0;
  /** 调整键位中 */
  @Prop @Watch('onEditingChanged') editing: boolean = false;
  @Prop @Watch('relayout') sizeLevel: number = 1;
  @Prop @Watch('redraw') opacityLevel: number = 1;
  @Prop haptic: boolean = true;
  @Prop @Watch('relayout') insetLeft: number = 0;
  @Prop @Watch('relayout') insetRight: number = 0;
  @Prop @Watch('relayout') insetBottom: number = 0;
  /** 调整键位：点了取消 */
  onEditDone: () => void = () => {
  };
  /** 调整键位：点了保存（由播放页存进当前键位，内置键位时另存为新键位） */
  onSave: (units: UnitSave[]) => void = () => {
  };
  // 调整键位：选中的控件、有没有没保存的改动
  @State selId: string = '';
  @State selHidden: boolean = false;
  @State dirty: boolean = false;
  // 整个组件的高度（按键区 = 它减去 regionTop）
  @State totalH: number = 0;

  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private areaW: number = 0;
  private areaH: number = 0;
  // Canvas 的实际大小（缩略图时 areaW/areaH 是参考屏幕的大小，画的时候缩放过来）
  private canvasW: number = 0;
  private canvasH: number = 0;
  private k: number = 1;
  private units: Unit[] = [];
  private keys: PadKey[] = [];
  private keyUnit: string[] = [];  // keys[i] 属于哪个控件
  private dpadX: number = 0;
  private dpadY: number = 0;
  private dpadA: number = 23;
  private dpadR: number = 19;
  private dpadHidden: boolean = false;
  private lstick: PadStick = { x: 0, y: 0, r: 52, hidden: false };
  private rstick: PadStick = { x: 0, y: 0, r: 52, hidden: false };
  private leftZoneTop: number = 0;
  private fingers: Finger[] = [];
  private sentButtons: number = 0;
  private sentAxes: number[] = [0, 0, 0, 0];
  // 调整键位：拖动中的手指和它相对控件中心的偏移
  private dragId: number = -1;
  private dragDx: number = 0;
  private dragDy: number = 0;

  aboutToAppear(): void {
    if (this.preview) {
      return;
    }
    nssft.padTouchShown(true);
    this.setGestureBack(false);
  }

  aboutToDisappear(): void {
    if (this.preview) {
      return;
    }
    this.fingers = [];
    this.send(true);
    nssft.padTouchShown(false);
    this.setGestureBack(true);
  }

  // 侧滑返回（API 13 起可以按窗口关掉）
  private setGestureBack(enabled: boolean): void {
    if (deviceInfo.sdkApiVersion < 13) {
      return;
    }
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      return win.setGestureBackEnabled(enabled);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'set gesture back failed: %{public}s', JSON.stringify(e));
    });
  }

  onInteractiveChanged(): void {
    if (!this.interactive) {
      // 工具条叫出来时松开所有手指
      this.fingers = [];
      this.send(false);
    }
    this.redraw();
  }

  onEditingChanged(): void {
    this.fingers = [];
    this.send(false);
    this.dragId = -1;
    this.selId = '';
    this.dirty = false;
    // 进入时从已保存的键位开始；结束时（保存后或取消）也重新读，取消的改动就丢掉了
    this.reload();
  }

  // ---------------------------------------------------------------- 键位

  private modeKey(): string {
    return this.split ? 'split' : 'overlay';
  }

  // 默认键位（vp）：叠加时肩键在顶部（平板上挪到摇杆上方够得着的地方），其余贴着底边排；画面下方时一样的排法
  private defaultUnits(): Unit[] {
    const W = this.areaW;
    const H = this.areaH;
    const k = this.k;
    const sl = this.insetLeft + 20;
    const sr = this.insetRight + 20;
    const bottom = H - this.insetBottom;
    const sh = 32 * k;
    const sy = Math.max(14 + sh / 2, bottom - 326 * k);
    // − ◎ HOME +：叠加时在底部中间（离底边留出距离，免得碰到系统的上滑手势）；画面下方时空间多，
    // 放到肩键那一行的中间（像实体手柄的 −/+），不和十字键、右摇杆挤在一起。
    // 叠加时屏幕不够宽（16:9 横屏只有 640vp），底部中间夹不下这一排（半宽 122），就抬到十字键和右摇杆上方
    const cx = W / 2;
    const roomy = cx - 122 * k >= sl + 244 * k + 4 && cx + 122 * k <= W - sr - 250 * k - 4;
    const by = this.split ? sy : roomy ? bottom - 36 * k : bottom - 135 * k - 8;
    const lsx = sl + 80 * k;
    const lsy = bottom - 174 * k;
    const rsx = W - sr - 198 * k;
    const rsy = bottom - 70 * k;
    const out: Unit[] = [];
    const put = (id: string, x: number, y: number, hidden: boolean) => {
      const u: Unit = { id: id, fx: x / W, fy: y / H, s: 1, hidden: hidden };
      out.push(u);
    };
    put('zl', sl + 38 * k, sy, false);
    put('l', sl + 76 * k + 10 + 32 * k, sy, false);
    put('zr', W - sr - 38 * k, sy, false);
    put('r', W - sr - 76 * k - 10 - 32 * k, sy, false);
    put('lstick', lsx, lsy, false);
    put('dpad', sl + 196 * k, bottom - 70 * k, false);
    put('face', W - sr - 76 * k, bottom - 194 * k, false);
    put('rstick', rsx, rsy, false);
    put('minus', cx - 96 * k, by, false);
    put('capture', cx - 32 * k, by, false);
    put('home', cx + 32 * k, by, false);
    put('plus', cx + 96 * k, by, false);
    put('l3', lsx + 66 * k, lsy - 66 * k, true);
    // R3 平时在右摇杆左上（和 L3 对称）；中间那排抬上来时那里是 HOME，换到右摇杆右上
    put('r3', this.split || roomy ? rsx - 66 * k : rsx + 66 * k, rsy - 66 * k, true);
    return out;
  }

  // 读这种摆法保存的键位（没保存过的控件用默认的）
  reload(): void {
    if (this.areaW <= 0 || this.areaH <= 0) {
      return;
    }
    this.k = (VPAD_SCALES[this.sizeLevel] ?? 1) * Math.min(1, this.areaH / 360, this.areaW / 640);
    const units = this.defaultUnits();
    const layout = getLayout(this.layoutId);
    const saved: UnitSave[] = layout !== undefined ? layout.units : [];
    for (const u of units) {
      const v = saved.find((x: UnitSave) => x.id === u.id);
      if (v !== undefined && Number.isFinite(v.x) && Number.isFinite(v.y)) {
        u.fx = Math.max(0, Math.min(1, v.x));
        u.fy = Math.max(0, Math.min(1, v.y));
        u.s = Number.isFinite(v.s) ? Math.max(SCALE_MIN, Math.min(SCALE_MAX, v.s)) : 1;
        u.hidden = v.h === true;
      }
    }
    this.units = units;
    this.geometry();
  }

  // 尺寸变了：默认键位跟着区域大小重新算（保存过的是比例，直接套上）；调整中动过按键才保留手上的改动、只重算位置
  // （刚进编辑时屏幕可能还在转向，没动过就按新尺寸重新算，免得按转向前的比例挤在一起）
  relayout(): void {
    if (!this.editing || !this.dirty || this.units.length === 0) {
      this.reload();
      return;
    }
    this.k = (VPAD_SCALES[this.sizeLevel] ?? 1) * Math.min(1, this.areaH / 360, this.areaW / 640);
    this.geometry();
  }

  private unit(id: string): Unit {
    const u = this.units.find((x: Unit) => x.id === id);
    if (u !== undefined) {
      return u;
    }
    const dummy: Unit = { id: id, fx: 0.5, fy: 0.5, s: 1, hidden: true };
    return dummy;
  }

  // 键位 → 每个按键、十字键、摇杆的位置和大小
  private geometry(): void {
    const W = this.areaW;
    const H = this.areaH;
    if (W <= 0 || H <= 0) {
      return;
    }
    const k = this.k;
    const keys: PadKey[] = [];
    const owners: string[] = [];
    const showAll = this.editing;  // 调整时隐藏的也画出来（淡一些），才能选中再打开
    const key = (u: Unit, bit: number, label: string, x: number, y: number, w: number, h: number, round: boolean,
      group: number) => {
      if (u.hidden && !showAll) {
        return;
      }
      const item: PadKey = {
        bit: bit, label: label, x: x, y: y, w: w, h: h, round: round, group: group
      };
      keys.push(item);
      owners.push(u.id);
    };
    const pill = (id: string, bit: number, label: string, w: number, h: number, group: number) => {
      const u = this.unit(id);
      key(u, bit, label, u.fx * W, u.fy * H, w * k * u.s, h * k * u.s, false, group);
    };
    pill('zl', BIT_ZL, 'ZL', 76, 32, GROUP_LEFT_SHOULDER);
    pill('l', BIT_L, 'L', 64, 32, GROUP_LEFT_SHOULDER);
    pill('zr', BIT_ZR, 'ZR', 76, 32, GROUP_RIGHT_SHOULDER);
    pill('r', BIT_R, 'R', 64, 32, GROUP_RIGHT_SHOULDER);
    // 面向键：位置和游戏机手柄一样（上 X、左 Y、右 A、下 B）
    const face = this.unit('face');
    const fx = face.fx * W;
    const fy = face.fy * H;
    const d = 40 * k * face.s;
    const fr = 46 * k * face.s;
    key(face, BIT_X, 'X', fx, fy - d, fr, fr, true, GROUP_FACE);
    key(face, BIT_Y, 'Y', fx - d, fy, fr, fr, true, GROUP_FACE);
    key(face, BIT_A, 'A', fx + d, fy, fr, fr, true, GROUP_FACE);
    key(face, BIT_B, 'B', fx, fy + d, fr, fr, true, GROUP_FACE);
    pill('minus', BIT_MINUS, '−', 52, 26, 0);
    pill('capture', BIT_CAPTURE, '◎', 52, 26, 0);
    pill('home', BIT_HOME, 'HOME', 60, 26, 0);
    pill('plus', BIT_PLUS, '+', 52, 26, 0);
    const l3 = this.unit('l3');
    key(l3, BIT_L3, 'L3', l3.fx * W, l3.fy * H, 36 * k * l3.s, 36 * k * l3.s, true, 0);
    const r3 = this.unit('r3');
    key(r3, BIT_R3, 'R3', r3.fx * W, r3.fy * H, 36 * k * r3.s, 36 * k * r3.s, true, 0);
    this.keys = keys;
    this.keyUnit = owners;
    const dp = this.unit('dpad');
    this.dpadX = dp.fx * W;
    this.dpadY = dp.fy * H;
    // 四个方向键之间留出空隙：相邻两键圆心距 30√2 ≈ 42，大于两个半径 36
    this.dpadA = 30 * k * dp.s;
    this.dpadR = 18 * k * dp.s;
    this.dpadHidden = dp.hidden;
    const ls = this.unit('lstick');
    this.lstick = { x: ls.fx * W, y: ls.fy * H, r: 52 * k * ls.s, hidden: ls.hidden };
    const rs = this.unit('rstick');
    this.rstick = { x: rs.fx * W, y: rs.fy * H, r: 52 * k * rs.s, hidden: rs.hidden };
    this.leftZoneTop = this.split ? 0 : 44;
    this.redraw();
  }

  // ---------------------------------------------------------------- 玩的时候的触摸

  private hitDown(id: number, x: number, y: number): Finger {
    const f: Finger = {
      id: id, kind: KIND_NONE, group: 0, bits: 0, ox: 0, oy: 0, dx: 0, dy: 0, key: -1
    };
    // 面向键取最近的一个（键之间的缝也算）
    const face = this.nearestFace(x, y, 1.3);
    if (face >= 0) {
      f.kind = KIND_KEY;
      f.group = GROUP_FACE;
      f.bits = this.keys[face].bit;
      return f;
    }
    for (let i = 0; i < this.keys.length; i++) {
      const kk = this.keys[i];
      if (kk.group !== GROUP_FACE && inKey(kk, x, y, 8 * this.k)) {
        f.kind = KIND_KEY;
        f.group = kk.group;
        f.bits = kk.bit;
        f.key = i;
        return f;
      }
    }
    const dx = x - this.dpadX;
    const dy = y - this.dpadY;
    const reach = this.dpadA + this.dpadR + 10 * this.k;
    if (!this.dpadHidden && dx * dx + dy * dy <= reach * reach) {
      f.kind = KIND_DPAD;
      f.bits = this.dpadBits(dx, dy);
      return f;
    }
    const rs = this.rstick;
    const rr = rs.r * 1.35;
    if (!rs.hidden && (x - rs.x) * (x - rs.x) + (y - rs.y) * (y - rs.y) <= rr * rr) {
      f.kind = KIND_RSTICK;
      f.ox = rs.x;
      f.oy = rs.y;
      this.moveStick(f, x, y, rs.r);
      return f;
    }
    // 左半边的空白处：浮动左摇杆，按下的位置就是中心（摇杆不出边）
    const ls = this.lstick;
    if (!ls.hidden && x < this.areaW * 0.45 && y > this.leftZoneTop) {
      const r = ls.r;
      f.kind = KIND_LSTICK;
      f.ox = Math.max(this.insetLeft + r * 0.6, Math.min(this.areaW * 0.45, x));
      f.oy = Math.max(this.leftZoneTop + r * 0.6, Math.min(this.areaH - this.insetBottom - r * 0.6, y));
      this.moveStick(f, x, y, r);
    }
    return f;
  }

  private nearestFace(x: number, y: number, reach: number): number {
    let best = -1;
    let bestD = Number.MAX_VALUE;
    for (let i = 0; i < this.keys.length; i++) {
      const kk = this.keys[i];
      if (kk.group !== GROUP_FACE) {
        continue;
      }
      const d = (x - kk.x) * (x - kk.x) + (y - kk.y) * (y - kk.y);
      const lim = kk.w / 2 * reach;
      if (d <= lim * lim && d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  // 十字键：8 个方向（斜向同时按两个），中心一小块不算
  private dpadBits(dx: number, dy: number): number {
    if (dx * dx + dy * dy < (this.dpadA * 0.35) * (this.dpadA * 0.35)) {
      return 0;
    }
    const sector = Math.round(Math.atan2(dy, dx) / (Math.PI / 4));  // -4..4，0 是右，2 是下（屏幕 y 向下）
    switch ((sector + 8) % 8) {
      case 0: return BIT_RIGHT;
      case 1: return BIT_RIGHT | BIT_DOWN;
      case 2: return BIT_DOWN;
      case 3: return BIT_DOWN | BIT_LEFT;
      case 4: return BIT_LEFT;
      case 5: return BIT_LEFT | BIT_UP;
      case 6: return BIT_UP;
      default: return BIT_UP | BIT_RIGHT;
    }
  }

  private moveStick(f: Finger, x: number, y: number, r: number): void {
    let dx = x - f.ox;
    let dy = y - f.oy;
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len > r) {
      dx = dx / len * r;
      dy = dy / len * r;
    }
    f.dx = dx;
    f.dy = dy;
  }

  private hitMove(f: Finger, x: number, y: number): void {
    switch (f.kind) {
      case KIND_KEY:
        if (f.group === GROUP_FACE) {
          const i = this.nearestFace(x, y, 1.45);
          f.bits = i >= 0 ? this.keys[i].bit : 0;
        } else if (f.group !== 0) {
          // 肩键：ZL 和 L 之间可以滑
          let bits = 0;
          for (const kk of this.keys) {
            if (kk.group === f.group && inKey(kk, x, y, 10 * this.k)) {
              bits = kk.bit;
              break;
            }
          }
          f.bits = bits;
        } else if (f.key >= 0) {
          // 小键不能滑过来：手指移出去就松开
          f.bits = inKey(this.keys[f.key], x, y, 12 * this.k) ? this.keys[f.key].bit : 0;
        }
        break;
      case KIND_DPAD:
        f.bits = this.dpadBits(x - this.dpadX, y - this.dpadY);
        break;
      case KIND_LSTICK:
        this.moveStick(f, x, y, this.lstick.r);
        break;
      case KIND_RSTICK:
        this.moveStick(f, x, y, this.rstick.r);
        break;
      default:
        break;
    }
  }

  private onTouchEvent(e: TouchEvent): void {
    if (this.editing) {
      this.onEditTouch(e);
      return;
    }
    if (!this.interactive) {
      return;
    }
    for (const t of e.changedTouches) {
      if (t.type === TouchType.Down) {
        this.fingers = this.fingers.filter((f: Finger) => f.id !== t.id);
        this.fingers.push(this.hitDown(t.id, t.x, t.y));
      } else if (t.type === TouchType.Up || t.type === TouchType.Cancel) {
        this.fingers = this.fingers.filter((g: Finger) => g.id !== t.id);
      }
    }
    if (e.type === TouchType.Move) {
      for (const t of e.touches) {
        const f = this.fingers.find((g: Finger) => g.id === t.id);
        if (f !== undefined) {
          this.hitMove(f, t.x, t.y);
        }
      }
    }
    this.send(false);
    this.redraw();
  }

  // 合起来交给原生层；有新按下的键时轻震一下
  private send(force: boolean): void {
    let bits = 0;
    const axes: number[] = [0, 0, 0, 0];
    for (const f of this.fingers) {
      bits |= f.bits;
      if (f.kind === KIND_LSTICK) {
        axes[0] = f.dx / this.lstick.r;
        axes[1] = f.dy / this.lstick.r;
      } else if (f.kind === KIND_RSTICK) {
        axes[2] = f.dx / this.rstick.r;
        axes[3] = f.dy / this.rstick.r;
      }
    }
    const same = bits === this.sentButtons && axes[0] === this.sentAxes[0] && axes[1] === this.sentAxes[1] &&
      axes[2] === this.sentAxes[2] && axes[3] === this.sentAxes[3];
    if (same && !force) {
      return;
    }
    const pressedNow = bits & ~this.sentButtons;
    this.sentButtons = bits;
    this.sentAxes = axes;
    nssft.padTouch(bits, axes[0], axes[1], axes[2], axes[3]);
    if (pressedNow !== 0 && this.haptic) {
      vibrator.startVibration({ type: 'time', duration: 12 }, { id: 0, usage: 'touch' }).catch(() => {
      });
    }
  }

  // ---------------------------------------------------------------- 调整键位

  // 控件的半宽、半高（选中、拖动、画选中框用）
  private unitHalf(u: Unit): number[] {
    const k = this.k * u.s;
    switch (u.id) {
      case 'zl':
      case 'zr':
        return [38 * k, 16 * k];
      case 'l':
      case 'r':
        return [32 * k, 16 * k];
      case 'home':
        return [30 * k, 13 * k];
      case 'minus':
      case 'capture':
      case 'plus':
        return [26 * k, 13 * k];
      case 'face':
        return [63 * k, 63 * k];
      case 'dpad':
        return [48 * k, 48 * k];
      case 'lstick':
      case 'rstick':
        return [52 * k, 52 * k];
      default:
        return [18 * k, 18 * k];
    }
  }

  // 手指下面的控件（后画的在上面，先找它）
  private unitAt(x: number, y: number): Unit | undefined {
    for (let i = this.units.length - 1; i >= 0; i--) {
      const u = this.units[i];
      const half = this.unitHalf(u);
      if (Math.abs(x - u.fx * this.areaW) <= half[0] + 6 && Math.abs(y - u.fy * this.areaH) <= half[1] + 6) {
        return u;
      }
    }
    return undefined;
  }

  private onEditTouch(e: TouchEvent): void {
    for (const t of e.changedTouches) {
      if (t.type === TouchType.Down && this.dragId < 0) {
        const u = this.unitAt(t.x, t.y);
        if (u === undefined) {
          this.selId = '';
        } else {
          this.selId = u.id;
          this.selHidden = u.hidden;
          this.dragId = t.id;
          this.dragDx = t.x - u.fx * this.areaW;
          this.dragDy = t.y - u.fy * this.areaH;
        }
      } else if ((t.type === TouchType.Up || t.type === TouchType.Cancel) && t.id === this.dragId) {
        this.dragId = -1;
      }
    }
    if (e.type === TouchType.Move && this.dragId >= 0 && this.selId.length > 0) {
      const t = e.touches.find((x: TouchObject) => x.id === this.dragId);
      const u = this.unit(this.selId);
      if (t !== undefined) {
        // 控件整个留在区域里
        const half = this.unitHalf(u);
        const x = Math.max(half[0], Math.min(this.areaW - half[0], t.x - this.dragDx));
        let y = Math.max(half[1], Math.min(this.areaH - half[1], t.y - this.dragDy));
        // 叠加时顶部中间留给菜单按钮：拖进去就往下推出来
        if (!this.split && Math.abs(x - this.areaW / 2) < half[0] + MENU_RESERVE_W / 2 && y - half[1] < MENU_RESERVE_H) {
          y = MENU_RESERVE_H + half[1];
        }
        u.fx = x / this.areaW;
        u.fy = y / this.areaH;
        this.dirty = true;
        this.geometry();
        return;
      }
    }
    this.redraw();
  }

  private resizeSelected(step: number): void {
    const u = this.units.find((x: Unit) => x.id === this.selId);
    if (u === undefined) {
      return;
    }
    u.s = Math.max(SCALE_MIN, Math.min(SCALE_MAX, Math.round((u.s + step) * 10) / 10));
    this.dirty = true;
    this.geometry();
  }

  private toggleSelectedHidden(): void {
    const u = this.units.find((x: Unit) => x.id === this.selId);
    if (u === undefined) {
      return;
    }
    u.hidden = !u.hidden;
    this.selHidden = u.hidden;
    this.dirty = true;
    this.geometry();
  }

  private resetUnits(): void {
    this.units = this.defaultUnits();
    this.selId = '';
    this.dirty = true;
    this.geometry();
  }

  private save(): void {
    const items: UnitSave[] = this.units.map((u: Unit): UnitSave => {
      const v: UnitSave = {
        id: u.id, x: Math.round(u.fx * 10000) / 10000, y: Math.round(u.fy * 10000) / 10000, s: u.s, h: u.hidden
      };
      return v;
    });
    this.onSave(items);
  }

  // ---------------------------------------------------------------- 绘制

  redraw(): void {
    if (!this.ready) {
      return;
    }
    const c = this.ctx;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, this.canvasW, this.canvasH);
    if (this.preview && this.areaW > 0 && this.areaH > 0) {
      c.setTransform(this.canvasW / this.areaW, 0, 0, this.canvasH / this.areaH, 0, 0);
    }
    const base = VPAD_OPACITIES[this.opacityLevel] ?? 0.5;
    const alpha = this.preview ? 0.6 : this.editing ? Math.max(base, 0.6) : base * (this.interactive ? 1 : 0.4);
    const bits = this.editing ? 0 : this.sentButtons;
    for (let i = 0; i < this.keys.length; i++) {
      const u = this.unit(this.keyUnit[i]);
      c.globalAlpha = Math.min(1, alpha * 1.6) * (u.hidden ? 0.35 : 1);  // 按键本身是半透明的玻璃色，整体再乘一次
      this.drawKey(this.keys[i], (bits & this.keys[i].bit) !== 0);
    }
    const dp = this.unit('dpad');
    if (!dp.hidden || this.editing) {
      c.globalAlpha = Math.min(1, alpha * 1.6) * (dp.hidden ? 0.35 : 1);
      this.drawDpad(bits & DPAD_BITS);
    }
    if (!this.lstick.hidden || this.editing) {
      c.globalAlpha = Math.min(1, alpha * 1.6) * (this.lstick.hidden ? 0.35 : 1);
      this.drawStick(this.lstick, KIND_LSTICK);
    }
    if (!this.rstick.hidden || this.editing) {
      c.globalAlpha = Math.min(1, alpha * 1.6) * (this.rstick.hidden ? 0.35 : 1);
      this.drawStick(this.rstick, KIND_RSTICK);
    }
    c.globalAlpha = Math.min(1, alpha * 1.6);
    if (this.editing) {
      if (!this.split) {
        this.drawReserved();
      }
      if (this.selId.length > 0) {
        this.drawSelection(this.unit(this.selId));
      }
    }
    c.globalAlpha = 1;
  }

  private shape(kk: PadKey): void {
    const c = this.ctx;
    c.beginPath();
    if (kk.round) {
      c.arc(kk.x, kk.y, kk.w / 2, 0, Math.PI * 2);
    } else {
      const r = kk.h / 2;
      const x0 = kk.x - kk.w / 2;
      const y0 = kk.y - kk.h / 2;
      c.moveTo(x0 + r, y0);
      c.lineTo(x0 + kk.w - r, y0);
      c.arc(x0 + kk.w - r, y0 + r, r, -Math.PI / 2, Math.PI / 2);
      c.lineTo(x0 + r, y0 + kk.h);
      c.arc(x0 + r, y0 + r, r, Math.PI / 2, Math.PI * 1.5);
      c.closePath();
    }
  }

  private drawKey(kk: PadKey, pressed: boolean): void {
    const c = this.ctx;
    this.shape(kk);
    c.fillStyle = pressed ? PRESSED : GLASS;
    c.fill();
    c.lineWidth = 1.5;
    c.strokeStyle = EDGE;
    c.stroke();
    const size = kk.round ? (kk.label.length > 1 ? 12 : 17) * kk.w / 46 : (kk.label.length > 2 ? 11 : 14) * kk.h / 26;
    c.font = `500 ${Math.max(9, Math.round(size))}vp sans-serif`;
    c.fillStyle = LABEL;
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    c.fillText(kk.label, kk.x, kk.y);
  }

  private drawDpad(bits: number): void {
    const c = this.ctx;
    const dirs: number[][] = [[0, -1, BIT_UP], [0, 1, BIT_DOWN], [-1, 0, BIT_LEFT], [1, 0, BIT_RIGHT]];
    for (const d of dirs) {
      const bx = this.dpadX + d[0] * this.dpadA;
      const by = this.dpadY + d[1] * this.dpadA;
      c.beginPath();
      c.arc(bx, by, this.dpadR, 0, Math.PI * 2);
      c.fillStyle = (bits & d[2]) !== 0 ? PRESSED : GLASS;
      c.fill();
      c.lineWidth = 1.5;
      c.strokeStyle = EDGE;
      c.stroke();
      // 三角形箭头
      const t = this.dpadR * 0.32;
      const px = -d[1];
      const py = d[0];
      c.beginPath();
      c.moveTo(bx + d[0] * t, by + d[1] * t);
      c.lineTo(bx - d[0] * t * 0.6 + px * t, by - d[1] * t * 0.6 + py * t);
      c.lineTo(bx - d[0] * t * 0.6 - px * t, by - d[1] * t * 0.6 - py * t);
      c.closePath();
      c.fillStyle = LABEL;
      c.fill();
    }
  }

  private drawStick(s: PadStick, kind: number): void {
    const c = this.ctx;
    const f = this.editing ? undefined : this.fingers.find((g: Finger) => g.kind === kind);
    const ox = f !== undefined ? f.ox : s.x;
    const oy = f !== undefined ? f.oy : s.y;
    c.beginPath();
    c.arc(ox, oy, s.r, 0, Math.PI * 2);
    c.fillStyle = 'rgba(255,255,255,0.10)';
    c.fill();
    c.lineWidth = 1.5;
    c.strokeStyle = EDGE;
    c.stroke();
    c.beginPath();
    c.arc(ox + (f !== undefined ? f.dx : 0), oy + (f !== undefined ? f.dy : 0), s.r * 0.46, 0, Math.PI * 2);
    c.fillStyle = f !== undefined ? PRESSED : 'rgba(255,255,255,0.35)';
    c.fill();
    c.strokeStyle = EDGE;
    c.stroke();
  }

  // 调整时标出顶部中间留给菜单按钮的区域
  private drawReserved(): void {
    const c = this.ctx;
    c.globalAlpha = 0.5;
    c.setLineDash([4, 4]);
    c.lineWidth = 1;
    c.strokeStyle = EDGE;
    c.strokeRect(this.areaW / 2 - MENU_RESERVE_W / 2, 2, MENU_RESERVE_W, MENU_RESERVE_H - 4);
    c.setLineDash([]);
  }

  private drawSelection(u: Unit): void {
    const c = this.ctx;
    const half = this.unitHalf(u);
    const x = u.fx * this.areaW;
    const y = u.fy * this.areaH;
    c.globalAlpha = 1;
    c.setLineDash([6, 4]);
    c.lineWidth = 2;
    c.strokeStyle = SELECTED;
    c.strokeRect(x - half[0] - 6, y - half[1] - 6, half[0] * 2 + 12, half[1] * 2 + 12);
    c.setLineDash([]);
  }

  // 调整键位的工具条：取消、重置、（选中时）大小和隐藏、保存
  @Builder
  EditBar() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        this.BarButton(tr('common_cancel'), false, () => {
          this.onEditDone();
        })
        this.BarButton(tr('vpad_edit_reset'), false, () => {
          this.resetUnits();
        })
        if (this.selId.length > 0) {
          this.BarButton('−', false, () => {
            this.resizeSelected(-0.1);
          })
          this.BarButton('+', false, () => {
            this.resizeSelected(0.1);
          })
          // @Builder 按值传的参数不会随状态刷新：两种文字分两个分支画
          if (this.selHidden) {
            this.BarButton(tr('vpad_edit_show'), false, () => {
              this.toggleSelectedHidden();
            })
          } else {
            this.BarButton(tr('vpad_edit_hide'), false, () => {
              this.toggleSelectedHidden();
            })
          }
        }
        if (this.dirty) {
          Text(tr('vpad_edit_unsaved')).fontSize(12).fontColor('#FFB74D')
        }
        this.BarButton(tr('vpad_edit_save'), true, () => {
          this.save();
        })
      }

      Text(this.selId.length > 0 ? tr('vpad_edit_hint_selected') :
        tr(this.split ? 'vpad_edit_hint_split' : 'vpad_edit_hint'))
        .fontSize(11)
        .fontColor('#CCFFFFFF')
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#E6141A1A')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  BarButton(label: string, primary: boolean, action: () => void) {
    Button(label)
      .fontSize(13)
      .fontColor(primary ? '#FF0B1A16' : Color.White)
      .backgroundColor(primary ? 'rgba(32,201,151,1)' : '#33FFFFFF')
      .height(30)
      .padding({ left: 12, right: 12 })
      .focusBox(FOCUS_BOX)
      .onClick(action)
  }

  build() {
    // 调整工具条：画面下方时在顶部（画面上），叠加时在屏幕中间（四周都是按键）
    Stack({ alignContent: this.split ? Alignment.Top : Alignment.Center }) {
      Canvas(this.ctx)
        .width('100%')
        .height(Math.max(0, this.totalH - this.regionTop))
        .position({ x: 0, y: this.regionTop })
        .hitTestBehavior(!this.preview && (this.interactive || this.editing) ? HitTestMode.Default : HitTestMode.None)
        .onReady(() => {
          this.ready = true;
          this.reload();
        })
        .onAreaChange((_old: Area, area: Area) => {
          this.canvasW = Number(area.width);
          this.canvasH = Number(area.height);
          // 缩略图：按参考屏幕排键位，画的时候再缩放
          this.areaW = this.preview && this.refW > 0 ? this.refW : this.canvasW;
          this.areaH = this.preview && this.refH > 0 ? this.refH : this.canvasH;
          this.relayout();
        })
        .onTouch((e: TouchEvent) => {
          this.onTouchEvent(e);
        })
        .onClick(() => {
          // 接住点击，别让它冒泡到播放器根节点（那里的点击会开关工具条，刚用 ≡ 叫出来就又被关掉）
        })

      if (this.editing) {
        Column() {
          this.EditBar()
        }
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_old: Area, area: Area) => {
      this.totalH = Number(area.height);
    })
  }
}
