// 设置项与共用常量。设置用 PersistentStorage 持久化，设置页和播放页快捷面板通过 @StorageLink 共用，重启 App 后保留。
import { LANGUAGE_INDEX_KEY, tr } from './I18n';

PersistentStorage.persistProp('nssft.enableAudio', true);
PersistentStorage.persistProp('nssft.netOpt', true);
// 切到后台时转入小窗（画中画）继续播放，默认开启；设备不支持时不显示
PersistentStorage.persistProp('nssft.pipAuto', true);
// 播放时请求 60Hz 屏幕刷新率（游戏画面最高 60 帧，高刷屏省电），默认开启
PersistentStorage.persistProp('nssft.lowRefresh', true);
// 最近连接过的主机（见 RecentHosts.ets）
PersistentStorage.persistProp('nssft.recentHosts', '');
// 旧版的“丢帧定格”开关已经去掉（原生层一直开着）：从持久化文件里删掉（deleteProp 只删 persistProp 过的键）
PersistentStorage.persistProp('nssft.freezeOnLoss', true);
PersistentStorage.deleteProp('nssft.freezeOnLoss');
// 画质增强：0 关闭 / 1 标准 / 2 高
PersistentStorage.persistProp('nssft.enhanceLevel', 0);
// 播放页统计浮层
PersistentStorage.persistProp('nssft.showStats', false);
// 第一次进播放页时提示一次“点右上角的菜单按钮”
PersistentStorage.persistProp('nssft.menuHintShown', false);
// 智慧屏第一次进播放页时弹窗说明遥控器按键
PersistentStorage.persistProp('nssft.tvGuideShown', false);
// 专用热点的名称和密码固定下来，游戏机记住一次后下次自动连上
PersistentStorage.persistProp('nssft.hotspotSsid', 'DIRECT-NSSFT');
PersistentStorage.persistProp('nssft.hotspotPass', '');
// 打开 App 时自动开启专用热点
PersistentStorage.persistProp('nssft.hotspotAuto', false);
// 深色模式：-1 跟随系统 / 0 深色 / 1 浅色（与 ConfigurationConstant.ColorMode 取值一致）
PersistentStorage.persistProp('nssft.colorMode', -1);
// 界面语言：LANGUAGE_OPTIONS 的下标（0 跟随系统 / 1 简体中文 / 2 繁體中文 / 3 English）
PersistentStorage.persistProp(LANGUAGE_INDEX_KEY, 0);

export const APP_NAME = 'NSSFT';
// 本应用的开源仓库
export const PROJECT_GITHUB = 'https://github.com/onewilk/NSSFT';
// SFT 的项目主页（界面上只显示“SFT 项目主页”，不直接露出网址）
export const SFT_PROJECT_URL = 'https://github.com/TomasUribe/switch-frame-tap';
export const SFT_PORT = 9950;

// 画质增强档位：标准速度快、延迟低；高效果更好，处理更慢
export function enhanceLabels(): string[] {
  return [tr('app_off'), tr('app_enhance_standard'), tr('app_enhance_high')];
}

/**
 * 画质增强靠系统的视频处理引擎（VPE）：系统声明了这项能力才可用。
 * 声明了却没有库的设备，打开后由 native 层提示“本机不支持”并退回直出
 */
export function enhanceAvailable(): boolean {
  return canIUse('SystemCapability.Multimedia.VideoProcessingEngine');
}

/** 部分 PC、平板没有 Wi-Fi 直连能力，专用热点要置灰并说明原因 */
export function hotspotSupported(): boolean {
  return canIUse('SystemCapability.Communication.WiFi.P2P');
}

/** 窗口宽度断点（vp）：sm 手机竖屏；md 折叠屏展开、平板竖屏；lg 平板横屏、PC */
export type Breakpoint = 'sm' | 'md' | 'lg';

export function breakpointOf(widthVp: number): Breakpoint {
  if (widthVp < 600) {
    return 'sm';
  }
  return widthVp < 840 ? 'md' : 'lg';
}

export function isValidIPv4(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p) || Number(p) > 255) {
      return false;
    }
  }
  return true;
}

/**
 * 主机名（手动输入地址时也可以填，由系统 DNS 解析，见 core/sft_net_source.cpp）：字母、数字、连字符组成的若干段，
 * 段之间用点隔开，每段 1–63 个字符、不以连字符开头或结尾，总长不超过 253；至少要有一个字母，免得把输了一半的 IP（192.168.1）当成主机名
 */
export function isValidHostname(name: string): boolean {
  if (name.length === 0 || name.length > 253 || !/[A-Za-z]/.test(name)) {
    return false;
  }
  const labels = (name.endsWith('.') ? name.slice(0, -1) : name).split('.');
  return labels.every((l: string) => /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(l));
}

/** 手动输入的主机地址：IPv4 或主机名 */
export function isValidHostAddress(v: string): boolean {
  return isValidIPv4(v) || isValidHostname(v);
}

export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s < 10 ? '0' : ''}${s}`;
}

/** 广播名称里的 SFT 版本号（例如 “… 0.7.20” → “0.7.20”），没有就返回空串 */
export function sftVersionOf(name: string): string {
  const m = name.match(/(\d+\.\d+(?:\.\d+)*)\s*$/);
  return m !== null ? m[1] : '';
}
