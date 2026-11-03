import { UsbLink } from './UsbConsole';

/** 要连接的主机：首页卡片、手动输入、USB、桌面快捷方式都汇总成这个 */
export interface StreamTarget {
  /** 网络：游戏机地址；USB 时为空串 */
  host: string;
  /** 播放页和实况窗上显示的名字（备注名、地址或 “USB”） */
  label: string;
  /** 广播里看到的 SFT 版本，记进“最近连接”；手动输入和 USB 时为空 */
  version: string;
  /** USB 连接（已申请权限、打开端点）；网络时为 null */
  usb: UsbLink | null;
  /** true：只录制，不显示画面也不出声（首页主机卡片菜单里的“只录制”） */
  recordOnly?: boolean;
}
