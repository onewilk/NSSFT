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
}

/** 返回空串表示已开始连接，否则为错误信息 */
export const connect: (config: ConnectConfig) => string;
export const disconnect: () => void;
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
