/** 局域网里广播过的游戏机（UDP 9951） */
export interface DeviceInfo {
  ip: string;
  port: number;
  /** 广播里带的名称（含 SFT 版本号），可能为空 */
  name: string;
}

export interface SessionStats {
  active: boolean;
  /** 在后台：照常接收，不渲染 */
  renderingPaused: boolean;
  /** 给用户看的连接状态 */
  message: string;

  // ---- 收流（游戏机 → 本机）
  connected: boolean;
  videoPackets: number;
  videoBytes: number;
  keyframes: number;
  audioPackets: number;
  audioBytes: number;
  /** 发出的关键帧请求次数 */
  keyRequests: number;
  resyncs: number;
  reconnects: number;
  /** 游戏机发来的画面尺寸 */
  streamWidth: number;
  streamHeight: number;
  /** 游戏机上从游戏交出画面到发出的平均耗时（ms） */
  consoleAgeMs: number;
  /** 游戏机是否接受手柄输入（以后的版本用） */
  consoleTakesInput: boolean;
  /** 游戏机说明的“没有画面的原因”，0 表示正常 */
  consoleStatusReason: number;
  consoleStatusHead: string;
  consoleStatusDetail: string;
  /** 解码器按多大的画面配置 */
  decoderWidth: number;
  decoderHeight: number;

  // ---- 播放
  framesRendered: number;
  videoDropped: number;
  lastCatchUpMs: number;
  netOpt: boolean;
  gopPackets: number;
  gopBytes: number;
  audioEnabled: boolean;
  audioFastMode: boolean;
  audioUnderruns: number;
  audioBufferedMs: number;
  audioTargetMs: number;
  decoderError: string;

  // ---- 丢帧与上屏
  freezeOnLoss: boolean;
  frozen: boolean;
  /** 序号断档次数 */
  lossGap: number;
  lossResync: number;
  lossOversize: number;
  /** 断档里跳过的帧数 */
  lostFrames: number;
  frameIntervalUs: number;
  keyframeIntervalMs: number;
  freezeEvents: number;
  freezeTotalMs: number;
  freezeGiveUps: number;
  lastFreezeMs: number;
  vsyncPeriodUs: number;
  vsyncDeferred: number;
  vsyncDropped: number;
  stutters: number;
  renderJitterMs: number;
  renderMaxGapMs: number;

  // ---- 画质增强
  enhanceRequested: number;
  enhanceLevel: number;
  enhanceLatencyUs: number;
  enhanceError: string;
  // 开着画质增强，但画面已接近显示区域大小、不需要放大，这条链路没用它（不是错误）
  enhanceIdle: string;
}

/** 开始监听 UDP 9951 上游戏机的广播；端口被占用时返回 false */
export const startDiscovery: () => boolean;
export const stopDiscovery: () => void;
/** 最近 5 秒内广播过的游戏机（有客户端连着时游戏机不广播） */
export const getDevices: () => DeviceInfo[];

export interface ConnectConfig {
  /** XComponent 的 surfaceId */
  surfaceId: string;
  /** 网络：游戏机地址；USB 时不用填 */
  host?: string;
  /** 默认 9950 */
  port?: number;
  /** true：走 USB（下面几个 usb 字段），否则走网络 */
  usb?: boolean;
  /** USB：usbManager.getFileDescriptor() 返回的描述符和接口、端点地址 */
  usbFd?: number;
  usbInterface?: number;
  usbEpIn?: number;
  usbEpOut?: number;
  /** USB：true 表示用 ArkTS bulkTransfer 兼容传输，此时必须提供 onUsbWrite */
  usbPump?: boolean;
  onUsbWrite?: () => void;
  audio?: boolean;
  /** TCP 快速确认 */
  netOpt?: boolean;
  freezeOnLoss?: boolean;
  /** 画质增强 0 关闭 / 1 标准 / 2 高 */
  enhanceLevel?: number;
  /** true：只录制，不显示画面也不播放声音（surfaceId 可以为空） */
  recordOnly?: boolean;
}

/** 返回空串表示已开始连接，否则为错误信息 */
export const connect: (config: ConnectConfig) => string;

// ---------------------------------------------------------------- 录像（边收边压，见 recorder.h）

export interface RecordSupport {
  /** 硬件 H.264 解码器最多能同时开几个：边播边录要 2 个，只录制要 1 个 */
  decoders: number;
  /** 有硬件 H.265 编码器（没有时用 H.264） */
  hevc: boolean;
  avc: boolean;
  /** 有视频处理引擎：省空间档把 1080p 缩到 720p 要用 */
  scaler: boolean;
}

export interface RecordConfig {
  /** 录像目录（沙箱路径） */
  dir: string;
  /** 文件名，不含扩展名；画面尺寸中途变了会另起 name_2.mp4… */
  name: string;
  /** 输出画面高度上限：1080 或 720 */
  maxHeight: number;
  /** 输出 1080p 时的码率；输出 720p 时按 0.6 倍（fixedBitrate 为 true 时不折算） */
  bitrateKbps: number;
  fixedBitrate?: boolean;
}

export interface RecordStats {
  active: boolean;
  /** 还在等关键帧（刚开始或刚换文件） */
  waitingKeyframe: boolean;
  durationMs: number;
  bytes: number;
  framesIn: number;
  framesEncoded: number;
  /** 等关键帧、积压时没录进去的帧 */
  framesDropped: number;
  width: number;
  height: number;
  bitrateKbps: number;
  hevc: boolean;
  /** 用视频处理引擎缩小了画面 */
  scaled: boolean;
  /** 非空时应停止录制 */
  error: string;
  /** 已写完和正在写的文件（完整路径） */
  files: string[];
}

export const recordSupport: () => RecordSupport;
/** 返回空串表示已开始 */
export const startRecording: (config: RecordConfig) => string;
/** 收尾并写完文件；结果里的 files 是录好的文件 */
export const stopRecording: () => Promise<RecordStats>;
export const getRecordStats: () => RecordStats;
export const disconnect: () => void;

// 手柄（SFT 0.7.20 起，游戏机上打开 “Controls from the viewer”）：本机手柄和键盘合成游戏机上的一个手柄
export interface PadConfig {
  /** 用户打开了手柄功能，并且播放页在前台 */
  enabled: boolean;
  /** A/B/X/Y 按标签对应；默认按位置（下面那个是 B） */
  faceByLabel: boolean;
  /** 摇杆死区 0..0.5 */
  deadZone: number;
  /** 扳机按下点 0.05..0.95 */
  triggerPoint: number;
}

export interface PadStatus {
  /** 游戏机接受手柄 */
  takesInput: boolean;
  /** 游戏机上已接上这个虚拟手柄 */
  attached: boolean;
  sent: number;
  /** 正在按的键，例如 “A ZL ↑” */
  buttons: string;
  lx: number;
  ly: number;
  rx: number;
  ry: number;
}

export const padConfigure: (config: PadConfig) => void;
export const padDevicePresent: (present: boolean) => void;
export const padPlaying: (on: boolean) => void;
/** 返回 true：这个键交给了游戏机，界面别再处理 */
export const padKey: (keyCode: number, down: boolean) => boolean;
/** 摇杆 -1..1（y 向下为正）、扳机 0..1、十字键 -1..1；这次没报的轴传 NaN */
export const padAxes: (lx: number, ly: number, rx: number, ry: number, lt: number, rt: number, hx: number,
  hy: number) => boolean;
export const padReset: () => void;
/** 触屏手柄显示着（显示着就算有手柄，接上游戏机） */
export const padTouchShown: (shown: boolean) => void;
/** 触屏手柄的整体状态：按键位（HidNpadButton 位）、两个摇杆 -1..1（y 向下为正） */
export const padTouch: (buttons: number, lx: number, ly: number, rx: number, ry: number) => void;
export const getPadStatus: () => PadStatus;
/** 切后台：释放解码器和音频，照常接收 */
export const pauseVideo: () => void;
/** 回前台：重建解码器并重放缓存的画面；返回空串表示成功 */
export const resumeVideo: (surfaceId: string) => string;
/** 返回空串表示成功 */
export const setAudioEnabled: (enabled: boolean) => string;
export const setNetOptimization: (enabled: boolean) => void;
export const setFreezeOnLoss: (on: boolean) => void;
/** 播放时请求的屏幕刷新率，0 = 交还系统决定 */
export const setRefreshRateHint: (fps: number) => void;
/** 返回空串表示成功，否则为原因（已退回直出） */
export const setEnhanceLevel: (level: number) => string;

export interface SocketFlow {
  localAddress: string;
  localPort: number;
  remoteAddress: string;
  remotePort: number;
}

/** 当前的 TCP 连接（给网络加速标记高优先级） */
export const getSocketFlows: () => SocketFlow[];
export const getStats: () => SessionStats;
/** 原生层状态文字的语言：0 简体 / 1 繁體 / 2 English */
export const setLanguage: (lang: number) => void;

export interface UsbProbeResult {
  /** true：可以直接对 usbfs 描述符发 ioctl */
  ok: boolean;
  /** 设备的序列号字符串，没有就是空串 */
  serial: string;
  error: string;
  /** 系统拒绝对 bulk 端点发 ioctl（EACCES 等），应改走兼容传输 */
  bulkRefused: boolean;
}

/** 在 fd 上 claim 接口并读设备描述符：成功说明可以直接对 usbfs 发 ioctl */
export const usbProbe: (fd: number, interfaceId: number, epIn?: number) => UsbProbeResult;
/** 兼容传输：把 ArkTS 读到的 IN 端点数据交给 native */
export const usbFeed: (data: ArrayBuffer, length: number) => void;
/** 兼容传输：设备断开或读取出错 */
export const usbFeedError: () => void;
/** 兼容传输：取出待写入 OUT 端点的数据（onUsbWrite 回调里调用） */
export const usbTakeWrite: () => ArrayBuffer | undefined;
/** 兼容传输：bulkTransfer 的返回值（写入字节数，<0 失败） */
export const usbWriteDone: (result: number) => void;
