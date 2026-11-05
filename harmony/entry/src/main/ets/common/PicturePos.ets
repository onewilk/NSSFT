// 画面位置：播放区比 16:9 画面高的时候（竖着用平板、折叠屏展开、三折叠、阔折叠等），画面上下有空白，
// 用户可以在“画面位置”里把画面拖到顶部、中间或底部（靠近这三个位置时吸附），触屏手柄放在画面下方的空白里。
// 位置是画面上方空白占全部空白的比例（0 顶部 / 0.5 居中 / 1 底部），按播放区的高宽比分档各记一个：
// 折叠、展开、转屏、PC 窗口改变比例后，各自用自己的位置；没记过的形态用默认位置（见 Index.picPosNow）。

PersistentStorage.persistProp('nssft.picPos', '{}');

/** 吸附点：顶部、居中、底部 */
export const PIC_ANCHORS: number[] = [0, 0.5, 1];

/** 这种屏幕形态的键：播放区高宽比，按 0.05 分档（例如 "0.90"、"1.35"） */
export function picPosKey(w: number, h: number): string {
  if (w <= 0 || h <= 0) {
    return '';
  }
  return (Math.round(h / w * 20) / 20).toFixed(2);
}

function readAll(): Record<string, number> {
  try {
    const v = JSON.parse(AppStorage.get<string>('nssft.picPos') ?? '{}') as Record<string, number>;
    return v !== null && typeof v === 'object' ? v : {};
  } catch (e) {
    return {};
  }
}

/** 记住的位置（0..1）；没记过返回 -1 */
export function loadPicPos(key: string): number {
  if (key.length === 0) {
    return -1;
  }
  const v = readAll()[key];
  return typeof v === 'number' && v >= 0 && v <= 1 ? v : -1;
}

export function savePicPos(key: string, pos: number): void {
  if (key.length === 0) {
    return;
  }
  const all = readAll();
  all[key] = Math.round(Math.max(0, Math.min(1, pos)) * 1000) / 1000;
  AppStorage.setOrCreate('nssft.picPos', JSON.stringify(all));
}

/** 位置的名字：顶部 / 居中 / 底部，其他是“自定义” */
export function picPosName(pos: number, top: string, center: string, bottom: string, custom: string): string {
  if (pos <= 0.001) {
    return top;
  }
  if (Math.abs(pos - 0.5) <= 0.001) {
    return center;
  }
  if (pos >= 0.999) {
    return bottom;
  }
  return custom;
}
