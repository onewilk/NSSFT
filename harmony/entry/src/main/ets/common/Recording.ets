// 录像：画质档位、能不能录、开始/停止、剩余空间、录像文件列表、存到图库。
// 录制本身在原生层（recorder.h）：收到的画面另起一路硬件解码 → 硬件编码（H.265）→ MP4，和屏幕显示互不影响。
// 文件先写在应用沙箱的 files/recordings 里，用户在“录像文件”里选择存到图库（系统弹窗确认）或删除。
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, statfs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import nssft from 'libentry.so';
import { RecordStats, RecordSupport } from 'libentry.so';
import { tr } from './I18n';

// 录制画质：0 高画质 / 1 标准 / 2 省空间
PersistentStorage.persistProp('nssft.recordQuality', 1);
// 录像文件的附加信息（主机名、时长），JSON 数组：[{ file, label, durationMs }]
PersistentStorage.persistProp('nssft.recordingsMeta', '[]');

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

/** 一个画质档位：输出高度上限和码率（1080p 时；输出 720p 时原生层按 0.6 倍折算，fixed 为 true 时不折算） */
interface RecordPreset {
  maxHeight: number;
  bitrateKbps: number;
  fixed: boolean;
}

export const RECORD_PRESETS: RecordPreset[] = [
  { maxHeight: 1080, bitrateKbps: 12000, fixed: false },
  { maxHeight: 1080, bitrateKbps: 8000, fixed: false },
  { maxHeight: 720, bitrateKbps: 4000, fixed: true }
];

// 开始录制要求的剩余空间；录制中低于后者就自动停止，免得把存储写满
const MIN_FREE_TO_START = 1024 * 1024 * 1024;
const MIN_FREE_TO_CONTINUE = 300 * 1024 * 1024;

export function recordQualityLabels(): string[] {
  return [tr('record_quality_high'), tr('record_quality_standard'), tr('record_quality_small')];
}

/** 档位说明：分辨率、码率、每分钟大约多大 */
export function recordQualityDesc(index: number): string {
  return [tr('record_quality_high_desc'), tr('record_quality_standard_desc'), tr('record_quality_small_desc')][index] ?? '';
}

let supportCache: RecordSupport | null = null;

export function recordSupport(): RecordSupport {
  if (supportCache === null) {
    try {
      supportCache = nssft.recordSupport();
    } catch (e) {
      supportCache = { decoders: 0, hevc: false, avc: false, scaler: false };
    }
  }
  return supportCache;
}

/** 本机不能录制的原因，能录时返回空串。withDisplay：边播边录（要两路硬件解码），否则是只录制（一路） */
export function recordUnsupportedReason(withDisplay: boolean): string {
  const s = recordSupport();
  if (!s.hevc && !s.avc) {
    return tr('record_unsupported_encoder');
  }
  if (s.decoders < (withDisplay ? 2 : 1)) {
    return withDisplay ? tr('record_unsupported_two_decoders') : tr('record_unsupported_decoder');
  }
  return '';
}

export function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
  return `${Math.max(0, Math.round(bytes / 1024 / 1024))} MB`;
}

/** 录像时长：m:ss，满一小时 h:mm:ss */
export function formatClock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n: number): string => (n < 10 ? '0' : '') + n;
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

export function recordingsDir(ctx: common.Context): string {
  return `${ctx.filesDir}/recordings`;
}

function freeBytes(dir: string): number {
  try {
    return statfs.getFreeSizeSync(dir);
  } catch (e) {
    return Number.MAX_SAFE_INTEGER;  // 查不到就不拦着
  }
}

function timestampName(): string {
  const d = new Date();
  const two = (n: number): string => (n < 10 ? '0' : '') + n;
  return `NSSFT_${d.getFullYear()}${two(d.getMonth() + 1)}${two(d.getDate())}_${two(d.getHours())}${two(d.getMinutes())}${two(d.getSeconds())}`;
}

interface RecordingMeta {
  file: string;
  label: string;
  durationMs: number;
}

function readMeta(): RecordingMeta[] {
  try {
    const v = JSON.parse(AppStorage.get<string>('nssft.recordingsMeta') ?? '[]') as RecordingMeta[];
    return Array.isArray(v) ? v : [];
  } catch (e) {
    return [];
  }
}

function writeMeta(meta: RecordingMeta[]): void {
  AppStorage.setOrCreate('nssft.recordingsMeta', JSON.stringify(meta));
}

function findMeta(meta: RecordingMeta[], file: string): RecordingMeta | undefined {
  return meta.find((m: RecordingMeta): boolean => m.file === file);
}

// 录像文件有变化（录完、删除、存到图库）时加一，首页的录像卡片据此刷新
export const RECORDINGS_EPOCH_KEY = 'rec.epoch';

function bumpRecordings(): void {
  AppStorage.setOrCreate(RECORDINGS_EPOCH_KEY, (AppStorage.get<number>(RECORDINGS_EPOCH_KEY) ?? 0) + 1);
}

function baseName(path: string): string {
  return path.substring(path.lastIndexOf('/') + 1);
}

/** 一次录制（开始到停止） */
export class RecordingSession {
  private dir: string = '';
  private label: string = '';
  private lastSpaceCheck: number = 0;

  /** 开始录制；返回空串表示已开始，否则为原因 */
  start(ctx: common.Context, label: string): string {
    this.dir = recordingsDir(ctx);
    this.label = label;
    try {
      if (!fileIo.accessSync(this.dir)) {
        fileIo.mkdirSync(this.dir, true);
      }
    } catch (e) {
      return tr('record_error_dir', (e as BusinessError).message ?? '');
    }
    const free = freeBytes(this.dir);
    if (free < MIN_FREE_TO_START) {
      return tr('record_error_space', formatBytes(free));
    }
    const quality = AppStorage.get<number>('nssft.recordQuality') ?? 1;
    const preset = RECORD_PRESETS[quality] ?? RECORD_PRESETS[1];
    return nssft.startRecording({
      dir: this.dir,
      name: timestampName(),
      maxHeight: preset.maxHeight,
      bitrateKbps: preset.bitrateKbps,
      fixedBitrate: preset.fixed
    });
  }

  /** 录制中剩余空间是不是快不够了（十秒查一次） */
  lowSpace(): boolean {
    const now = Date.now();
    if (now - this.lastSpaceCheck < 10000) {
      return false;
    }
    this.lastSpaceCheck = now;
    return freeBytes(this.dir) < MIN_FREE_TO_CONTINUE;
  }

  /** 停止并写完文件（原生层在工作线程收尾），记下主机名和时长 */
  async stop(): Promise<RecordStats> {
    const r = await nssft.stopRecording();
    if (r.files.length > 0) {
      const names = r.files.map((f: string): string => baseName(f));
      const meta = readMeta().filter((m: RecordingMeta): boolean => names.indexOf(m.file) < 0);
      for (const name of names) {
        // 中途换过文件时只有合计时长：列表里只在单个文件时显示时长
        meta.push({ file: name, label: this.label, durationMs: names.length === 1 ? r.durationMs : -1 });
      }
      writeMeta(meta);
      bumpRecordings();
    }
    hilog.info(DOMAIN, TAG, 'recording saved: %{public}d file(s), %{public}d ms', r.files.length, r.durationMs);
    return r;
  }
}

/** 录像文件列表里的一项 */
export interface RecordingFile {
  path: string;
  name: string;
  bytes: number;
  /** 修改时间（毫秒） */
  time: number;
  label: string;
  /** -1 表示不知道（录制中途换过文件） */
  durationMs: number;
}

export function listRecordings(ctx: common.Context): RecordingFile[] {
  const dir = recordingsDir(ctx);
  const out: RecordingFile[] = [];
  try {
    if (!fileIo.accessSync(dir)) {
      return out;
    }
    const meta = readMeta();
    for (const name of fileIo.listFileSync(dir)) {
      if (!name.endsWith('.mp4')) {
        continue;
      }
      const path = `${dir}/${name}`;
      const st = fileIo.statSync(path);
      const m = findMeta(meta, name);
      out.push({
        path: path, name: name, bytes: st.size, time: st.mtime * 1000,
        label: m !== undefined ? m.label : '', durationMs: m !== undefined ? m.durationMs : -1
      });
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'list recordings failed: %{public}s', JSON.stringify(e));
  }
  return out.sort((a: RecordingFile, b: RecordingFile): number => b.time - a.time);
}

export function deleteRecording(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'delete recording failed: %{public}s', JSON.stringify(e));
  }
  const name = baseName(path);
  writeMeta(readMeta().filter((m: RecordingMeta): boolean => m.file !== name));
  bumpRecordings();
}

/**
 * 用系统的视频播放器打开（录像在应用沙箱里，图库看不到）：按文件类型拉起默认的打开方式，
 * 没有默认应用时系统弹出选择框；只授权读这一个文件。返回空串表示已拉起，否则为错误信息
 */
export async function openRecording(ctx: common.UIAbilityContext, file: RecordingFile): Promise<string> {
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: fileUri.getUriFromPath(file.path),
    type: 'general.mpeg-4',
    flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
  };
  try {
    await ctx.startAbility(want);
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'open recording failed: %{public}d %{public}s', err.code, err.message);
    return err.message ?? String(err.code);
  }
}

/**
 * 存到图库：系统弹窗让用户确认后把文件拷进图库，成功后删掉沙箱里的这一份（存进去就不占两份空间）。
 * 返回 'ok' / 'cancel' / 错误信息
 */
export async function saveRecordingToGallery(ctx: common.Context, file: RecordingFile): Promise<string> {
  try {
    const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: file.name.replace(/\.mp4$/, ''),
      fileNameExtension: 'mp4',
      photoType: photoAccessHelper.PhotoType.VIDEO
    };
    const uris = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(file.path)], [config]);
    if (uris.length === 0) {
      return 'cancel';
    }
    const dst = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY);
    try {
      await fileIo.copyFile(file.path, dst.fd);
    } finally {
      fileIo.closeSync(dst);
    }
    deleteRecording(file.path);
    return 'ok';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'save to gallery failed: %{public}s', JSON.stringify(err));
    return err.message ?? String(err.code);
  }
}
