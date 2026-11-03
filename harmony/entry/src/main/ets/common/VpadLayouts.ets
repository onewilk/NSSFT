// 触屏手柄的键位。三种摆法：横屏（叠在画面上）、竖屏（叠在画面上）、分离（画面在上、按键在下）。
// 每种摆法有一个内置键位（按屏幕实时计算，不能改），另外可以基于现有键位新建自己的键位，每种摆法记住当前用哪一个。
// 自建键位按区域比例保存（换屏幕大小、转屏都能用）；新建时 units 为空就和内置一样（跟着屏幕大小走），编辑保存后才定下来。
import { tr } from './I18n';

export type VpadMode = 'landscape' | 'portrait' | 'split';
export const VPAD_MODES: VpadMode[] = ['landscape', 'portrait', 'split'];

/** 一个控件的键位：中心在区域里的比例位置、相对默认大小的倍数、是否隐藏 */
export interface UnitSave {
  id: string;
  x: number;
  y: number;
  s: number;
  h: boolean;
}

export interface PadLayout {
  id: string;
  name: string;
  mode: string;
  units: UnitSave[];
  updated: number;
}

interface ActiveMap {
  landscape: string;
  portrait: string;
  split: string;
}

PersistentStorage.persistProp('nssft.vpadLayouts', '[]');
PersistentStorage.persistProp('nssft.vpadActive', '{"landscape":"","portrait":"","split":""}');

/** 键位有变化（新建、改名、删除、保存、换当前）时加一，列表和播放页据此刷新（不用持久化） */
export const VPAD_LAYOUTS_EPOCH = 'vpad.layoutsEpoch';

function bump(): void {
  AppStorage.setOrCreate(VPAD_LAYOUTS_EPOCH, (AppStorage.get<number>(VPAD_LAYOUTS_EPOCH) ?? 0) + 1);
}

function readAll(): PadLayout[] {
  try {
    const v = JSON.parse(AppStorage.get<string>('nssft.vpadLayouts') ?? '[]') as PadLayout[];
    return Array.isArray(v) ? v.filter((l: PadLayout) => typeof l.id === 'string' && Array.isArray(l.units)) : [];
  } catch (e) {
    return [];
  }
}

function writeAll(list: PadLayout[]): void {
  AppStorage.setOrCreate('nssft.vpadLayouts', JSON.stringify(list));
  bump();
}

function readActive(): ActiveMap {
  try {
    const v = JSON.parse(AppStorage.get<string>('nssft.vpadActive') ?? '{}') as ActiveMap;
    const out: ActiveMap = {
      landscape: typeof v.landscape === 'string' ? v.landscape : '',
      portrait: typeof v.portrait === 'string' ? v.portrait : '',
      split: typeof v.split === 'string' ? v.split : ''
    };
    return out;
  } catch (e) {
    const empty: ActiveMap = { landscape: '', portrait: '', split: '' };
    return empty;
  }
}

function writeActive(a: ActiveMap): void {
  AppStorage.setOrCreate('nssft.vpadActive', JSON.stringify(a));
  bump();
}

export function vpadModeLabel(mode: string): string {
  if (mode === 'portrait') {
    return tr('vpad_mode_portrait');
  }
  return mode === 'split' ? tr('vpad_mode_split') : tr('vpad_mode_landscape');
}

/** 宽屏状态（阔折叠、折叠屏展开、三折的双屏/三屏）：短边够宽、长宽比不太长。强制竖屏和分离展示只在这时提供 */
export function isWideScreen(w: number, h: number): boolean {
  const s = Math.min(w, h);
  const l = Math.max(w, h);
  return s >= 440 && l / s <= 1.8;
}

export function listLayouts(mode: string): PadLayout[] {
  return readAll().filter((l: PadLayout) => l.mode === mode);
}

export function getLayout(id: string): PadLayout | undefined {
  if (id.length === 0) {
    return undefined;
  }
  return readAll().find((l: PadLayout) => l.id === id);
}

/** 这种摆法当前用的键位，空串表示内置 */
export function activeLayoutId(mode: string): string {
  const a = readActive();
  const id = mode === 'portrait' ? a.portrait : mode === 'split' ? a.split : a.landscape;
  return getLayout(id) !== undefined ? id : '';
}

export function setActiveLayout(mode: string, id: string): void {
  const a = readActive();
  if (mode === 'portrait') {
    a.portrait = id;
  } else if (mode === 'split') {
    a.split = id;
  } else {
    a.landscape = id;
  }
  writeActive(a);
}

export function layoutNameTaken(mode: string, name: string, exceptId: string): boolean {
  return listLayouts(mode).some((l: PadLayout) => l.id !== exceptId && l.name === name);
}

/** 给新键位起个默认名字：我的键位 1、2、3… */
export function suggestLayoutName(mode: string): string {
  for (let i = 1; i < 100; i++) {
    const name = tr('vpad_layout_default_name', i);
    if (!layoutNameTaken(mode, name, '')) {
      return name;
    }
  }
  return tr('vpad_layout_default_name', Date.now() % 1000);
}

/** 新建一个键位（units 为空：和内置一样），返回 id */
export function createLayout(mode: string, name: string, units: UnitSave[]): string {
  const id = `l${Date.now().toString(36)}${Math.floor(Math.random() * 10000)}`;
  const list = readAll();
  const layout: PadLayout = { id: id, name: name, mode: mode, units: units, updated: Date.now() };
  list.push(layout);
  writeAll(list);
  return id;
}

export function updateLayoutUnits(id: string, units: UnitSave[]): void {
  const list = readAll();
  const l = list.find((x: PadLayout) => x.id === id);
  if (l !== undefined) {
    l.units = units;
    l.updated = Date.now();
    writeAll(list);
  }
}

export function renameLayout(id: string, name: string): void {
  const list = readAll();
  const l = list.find((x: PadLayout) => x.id === id);
  if (l !== undefined) {
    l.name = name;
    l.updated = Date.now();
    writeAll(list);
  }
}

/** 删除；正在用它的摆法换回内置键位 */
export function deleteLayout(id: string): void {
  const l = getLayout(id);
  writeAll(readAll().filter((x: PadLayout) => x.id !== id));
  if (l !== undefined && activeLayoutId(l.mode) === '') {
    setActiveLayout(l.mode, '');
  }
}

interface OldStore {
  overlay: UnitSave[];
  split: UnitSave[];
}

/**
 * 第二版只有“叠加”“画面下方”两套可改的键位（存在 nssft.vpadLayout）：第一次用新版时转成自建键位“我的键位”并设为当前，
 * 改过的键位不会丢。转完清空旧数据，不会重复转
 */
export function migrateOldLayouts(): void {
  const raw = AppStorage.get<string>('nssft.vpadLayout') ?? '';
  if (raw.length === 0) {
    return;
  }
  let old: OldStore | null = null;
  try {
    old = JSON.parse(raw) as OldStore;
  } catch (e) {
    old = null;
  }
  if (old !== null) {
    if (Array.isArray(old.overlay) && old.overlay.length > 0) {
      setActiveLayout('landscape', createLayout('landscape', tr('vpad_layout_migrated_name'), old.overlay));
    }
    if (Array.isArray(old.split) && old.split.length > 0) {
      setActiveLayout('split', createLayout('split', tr('vpad_layout_migrated_name'), old.split));
    }
  }
  AppStorage.setOrCreate('nssft.vpadLayout', '');
}
