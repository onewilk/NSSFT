// 连过的主机：首页卡片、桌面快捷方式“连接上次”用。存成多行文本：地址|最后连接时间|备注名|SFT 版本
import { tr } from './I18n';

export const RECENT_HOSTS_KEY = 'nssft.recentHosts';
const MAX_HOSTS = 6;

export interface RecentHost {
  host: string;
  /** 最后一次连上的时间（毫秒） */
  at: number;
  /** 用户起的备注名，没起过为空 */
  alias: string;
  /** 连接时广播里看到的 SFT 版本，没看到为空 */
  version: string;
}

function clean(s: string): string {
  return s.replace(/[|\n]/g, ' ').trim();
}

export function parseRecentHosts(raw: string): RecentHost[] {
  const out: RecentHost[] = [];
  for (const line of raw.split('\n')) {
    const parts: string[] = line.split('|');
    if (parts.length < 2 || parts[0].length === 0) {
      continue;
    }
    const at = Number(parts[1]);
    if (isNaN(at)) {
      continue;
    }
    out.push({ host: parts[0], at: at, alias: parts[2] ?? '', version: parts[3] ?? '' });
  }
  return out.sort((a: RecentHost, b: RecentHost): number => b.at - a.at);
}

function save(list: RecentHost[]): void {
  const lines: string[] = list.map((h: RecentHost): string =>
  `${clean(h.host)}|${h.at}|${clean(h.alias)}|${clean(h.version)}`);
  AppStorage.setOrCreate<string>(RECENT_HOSTS_KEY, lines.join('\n'));
}

function current(): RecentHost[] {
  return parseRecentHosts(AppStorage.get<string>(RECENT_HOSTS_KEY) ?? '');
}

/** 连接成功后调用：同一地址只保留最新一条，备注名沿用 */
export function rememberHost(host: string, version: string): void {
  const list = current();
  const old = list.find((h: RecentHost): boolean => h.host === host);
  const rest = list.filter((h: RecentHost): boolean => h.host !== host).slice(0, MAX_HOSTS - 1);
  const entry: RecentHost = {
    host: host,
    at: Date.now(),
    alias: old !== undefined ? old.alias : '',
    version: version.length > 0 ? version : (old !== undefined ? old.version : '')
  };
  save([entry].concat(rest));
}

export function renameHost(host: string, alias: string): void {
  save(current().map((h: RecentHost): RecentHost => h.host === host ?
    { host: h.host, at: h.at, alias: alias.trim(), version: h.version } : h));
}

export function forgetHost(host: string): void {
  save(current().filter((h: RecentHost): boolean => h.host !== host));
}

export function findRecentHost(raw: string, host: string): RecentHost | undefined {
  return parseRecentHosts(raw).find((h: RecentHost): boolean => h.host === host);
}

/** 最近一次连上的主机，桌面快捷方式“连接上次”用 */
export function lastRecentHost(): RecentHost | null {
  const list = current();
  return list.length > 0 ? list[0] : null;
}

/** “3 分钟前”这类相对时间 */
export function agoText(at: number): string {
  const minutes = Math.floor((Date.now() - at) / 60000);
  if (minutes < 1) {
    return tr('recent_just_now');
  }
  if (minutes < 60) {
    return tr('recent_minutes_ago', minutes);
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return tr('recent_hours_ago', hours);
  }
  return tr('recent_days_ago', Math.floor(hours / 24));
}
