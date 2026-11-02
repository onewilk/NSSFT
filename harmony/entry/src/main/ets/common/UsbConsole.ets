// 通过 USB 连接的游戏机（SFT 选 “USB - PC viewer”，掌机模式，用数据线连到本机）：
// 找设备、申请权限、打开端点；系统不让直接对 usbfs 发 ioctl 时，退回 ArkTS 的 bulkTransfer 兼容传输
import { usbManager, commonEventManager, BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import nssft from 'libentry.so';
import { UsbProbeResult } from 'libentry.so';
import { tr } from './I18n';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

// SFT 游戏机端 USB 设备的 ID（与 SFT 的 PC / Android 接收端一致）
export const SFT_VID = 0x1209;
export const SFT_PID = 0x5F1E;
// 接口 0：IN 0x81 收 SFTR 包，OUT 0x01 发请求（SFTK 等）
const SFT_EP_IN = 0x81;
const SFT_EP_OUT = 0x01;
const BULK = 2;
const DIR_IN = 0x80;
// usbManager.bulkTransfer 单次（含参数）要求 < 200KB；取 512 的整数倍
const PUMP_CHUNK = 128 * 1024;

/** 打开后的 USB 连接 */
export interface UsbLink {
  device: usbManager.USBDevice;
  pipe: usbManager.USBDevicePipe;
  iface: usbManager.USBInterface;
  epIn: usbManager.USBEndpoint;
  epOut: usbManager.USBEndpoint;
  fd: number;
  /** true：系统不允许直接 ioctl，改用 usbManager.bulkTransfer 兼容传输 */
  pump: boolean;
  /** 给用户看的传输方式说明 */
  transport: string;
}

export interface UsbOpenResult {
  link: UsbLink | null;
  error: string;
}

function errText(e: Object): string {
  const err = e as BusinessError;
  return err.code !== undefined ? `${err.code} ${err.message}` : JSON.stringify(e);
}

function hex4(n: number): string {
  return ('0000' + n.toString(16).toUpperCase()).slice(-4);
}

/** 本机有没有 USB 主机能力（部分 PC、平板没有）：没有时首页的 USB 入口置灰并说明 */
export function usbHostSupported(): boolean {
  return canIUse('SystemCapability.USB.USBManager');
}

/**
 * USB 诊断日志：写到应用沙箱 files/usb.log（正式版手机上看不到 App 的 hilog）。拉取：
 *   hdc file recv -b wilk.sft.next /data/storage/el2/base/haps/entry/files/usb.log ./
 */
export class UsbLog {
  private static dir: string = '';

  static init(filesDir: string): void {
    UsbLog.dir = filesDir;
  }

  static write(line: string): void {
    hilog.info(DOMAIN, TAG, 'usb: %{public}s', line);
    if (UsbLog.dir.length === 0) {
      return;
    }
    const path = `${UsbLog.dir}/usb.log`;
    try {
      let flags = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND;
      if (fileIo.accessSync(path) && fileIo.statSync(path).size > 512 * 1024) {
        flags = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC;
      }
      const f = fileIo.openSync(path, flags);
      fileIo.writeSync(f.fd, `${new Date().toISOString()} ${line}\n`);
      fileIo.closeSync(f);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write usb.log failed');
    }
  }
}

export class UsbConsole {
  /** 当前插着的 SFT 设备 */
  static find(): usbManager.USBDevice | undefined {
    try {
      return usbManager.getDevices().find((d: usbManager.USBDevice) =>
      d.vendorId === SFT_VID && d.productId === SFT_PID);
    } catch (e) {
      // 不支持 USB 主机的设备会抛 801
      return undefined;
    }
  }

  /** 没检测到设备时的说明：手机、平板常被协商成“从设备”，PC 的 USB 口本来就是主机口 */
  static notFoundHint(): string {
    let devices: usbManager.USBDevice[] = [];
    try {
      devices = usbManager.getDevices();
    } catch (e) {
      return tr('usb_hint_unsupported');
    }
    if (devices.length > 0) {
      // 有别的 USB 设备：多半是游戏机上的 SFT 没选 “USB - PC viewer”（例如选了摄像头模式或网络）
      return tr('usb_hint_wrong_mode');
    }
    return deviceInfo.deviceType === '2in1' ? tr('usb_hint_no_device_pc') : tr('usb_hint_no_device');
  }

  /** 申请授权（系统弹窗）→ 打开设备 → 找到 bulk 端点 → 探测能否直接 ioctl，不能就准备兼容传输 */
  static async open(device: usbManager.USBDevice): Promise<UsbOpenResult> {
    try {
      UsbLog.write(`open ${hex4(device.vendorId)}:${hex4(device.productId)} ${device.name} configs=${device.configs.length}`);
      if (!usbManager.hasRight(device.name)) {
        const granted = await usbManager.requestRight(device.name);
        UsbLog.write(`requestRight → ${granted}`);
        if (!granted) {
          return { link: null, error: tr('usb_err_no_right') };
        }
      }
      const config = device.configs.length > 0 ? device.configs[0] : undefined;
      const iface = config?.interfaces.find((i: usbManager.USBInterface) => i.id === 0) ?? config?.interfaces[0];
      if (iface === undefined) {
        return { link: null, error: tr('usb_err_no_iface') };
      }
      UsbLog.write(`iface id=${iface.id} class=${iface.clazz} endpoints=` +
        iface.endpoints.map((e: usbManager.USBEndpoint) =>
        `0x${e.address.toString(16)}/type${e.type}/dir${e.direction}/mps${e.maxPacketSize}`).join(','));
      const epIn = iface.endpoints.find((e: usbManager.USBEndpoint) =>
      e.address === SFT_EP_IN && e.type === BULK && e.direction === DIR_IN);
      const epOut = iface.endpoints.find((e: usbManager.USBEndpoint) =>
      e.address === SFT_EP_OUT && e.type === BULK && e.direction !== DIR_IN);
      if (epIn === undefined || epOut === undefined) {
        // 摄像头模式（UVC）没有这两个 bulk 端点
        return { link: null, error: tr('usb_err_webcam_mode') };
      }
      const pipe = usbManager.connectDevice(device);
      if (pipe === undefined) {
        return { link: null, error: tr('usb_err_open_service') };
      }
      const fd = usbManager.getFileDescriptor(pipe);
      UsbLog.write(`connectDevice ok, getFileDescriptor → ${fd}`);

      // 1) 直接对 usbfs 描述符发 ioctl：零拷贝、没有跨进程开销
      const noFd: UsbProbeResult = { ok: false, serial: '', error: `fd=${fd}`, bulkRefused: false };
      let probe: UsbProbeResult = fd >= 0 ? nssft.usbProbe(fd, iface.id, epIn.address) : noFd;
      let pump = false;
      let transport = tr('usb_transport_direct');
      UsbLog.write(`usbfs probe → ok=${probe.ok} serial="${probe.serial}" error="${probe.error}"`);
      if (!probe.ok) {
        // 2) 先让 USB 服务 claim 接口，再试一次（有的系统要求先经服务声明接口）；bulk 被系统拒绝（EACCES）时重试也没用
        const claim = usbManager.claimInterface(pipe, iface, true);
        const retry = fd >= 0 && claim === 0 && !probe.bulkRefused ? nssft.usbProbe(fd, iface.id, epIn.address) : probe;
        UsbLog.write(`claimInterface → ${claim}; retry probe ok=${retry.ok} error="${retry.error}"`);
        if (retry.ok) {
          probe = retry;
        } else {
          // 3) 兼容传输：ArkTS 调 bulkTransfer 收发
          pump = true;
          transport = tr('usb_transport_compat');
          UsbLog.write('fallback to bulkTransfer pump');
        }
      }
      const link: UsbLink = {
        device: device, pipe: pipe, iface: iface, epIn: epIn, epOut: epOut, fd: fd, pump: pump, transport: transport
      };
      return { link: link, error: '' };
    } catch (e) {
      UsbLog.write(`open failed: ${errText(e)}`);
      return { link: null, error: tr('usb_err_open', errText(e)) };
    }
  }

  static close(link: UsbLink): void {
    try {
      if (link.pump) {
        usbManager.releaseInterface(link.pipe, link.iface);
      }
      usbManager.closePipe(link.pipe);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'usb close failed: %{public}s', errText(e));
    }
  }
}

/**
 * 兼容传输：ArkTS 循环读 IN 端点，把数据交给 native 的 SftUsbSource 解析；
 * native 要写 OUT 端点时（关键帧请求、告别）通过 onWrite 回调通知这里来取数据发送。
 */
export class UsbPump {
  private link: UsbLink | null = null;
  private running: boolean = false;
  private buffer: Uint8Array = new Uint8Array(PUMP_CHUNK);

  start(link: UsbLink): void {
    this.link = link;
    this.running = true;
    this.readLoop();
  }

  stop(): void {
    this.running = false;
    this.link = null;
  }

  /** 传给 nssft.connect 的 onUsbWrite */
  onWrite = (): void => {
    const link = this.link;
    const data = nssft.usbTakeWrite();
    if (link === null || data === undefined) {
      return;
    }
    usbManager.bulkTransfer(link.pipe, link.epOut, new Uint8Array(data), 100).then((n: number) => {
      nssft.usbWriteDone(n);
    }).catch(() => {
      nssft.usbWriteDone(-1);
    });
  };

  private async readLoop(): Promise<void> {
    let failures = 0;
    while (this.running) {
      const link = this.link;
      if (link === null) {
        break;
      }
      let n = -1;
      try {
        n = await usbManager.bulkTransfer(link.pipe, link.epIn, this.buffer, 500);
      } catch (e) {
        n = -1;
      }
      if (!this.running) {
        break;
      }
      if (n > 0) {
        failures = 0;
        nssft.usbFeed(this.buffer.buffer, n);
      } else if (n < 0) {
        // 超时也返回 -1，连续多次失败再看设备还在不在
        failures++;
        if (failures % 10 === 0 && UsbConsole.find() === undefined) {
          nssft.usbFeedError();
        }
      }
    }
  }
}

/** 监听 USB 插拔（系统公共事件） */
export class UsbWatcher {
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;

  async start(onChange: () => void): Promise<void> {
    if (this.subscriber !== null) {
      return;
    }
    try {
      this.subscriber = await commonEventManager.createSubscriber({
        events: [commonEventManager.Support.COMMON_EVENT_USB_DEVICE_ATTACHED,
          commonEventManager.Support.COMMON_EVENT_USB_DEVICE_DETACHED]
      });
      commonEventManager.subscribe(this.subscriber, () => {
        onChange();
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'subscribe usb events failed: %{public}s', errText(e));
    }
  }

  stop(): void {
    const s = this.subscriber;
    if (s !== null) {
      commonEventManager.unsubscribe(s);
      this.subscriber = null;
    }
  }
}
