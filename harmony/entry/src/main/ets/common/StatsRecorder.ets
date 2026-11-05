import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

/**
 * 每秒把统计写进应用沙箱的 files/stats.csv，便于连着电脑用 hdc 拉出来对比不同设置的效果：
 *   hdc file recv -b wilk.sft.next /data/storage/el2/base/haps/entry/files/stats.csv ./
 * 每次连接追加一段，以 “# session” 行分隔；文件超过 4MB 时清空重写。
 */
export class StatsRecorder {
  static readonly HEADER = 't_s,bg,recv_fps,show_fps,video_kbps,audio_kbps,dropped,' +
    'audio_on,audio_buf_ms,audio_target_ms,underruns,net_opt,reconnects,resyncs,' +
    // 画面尺寸、游戏机端耗时（ms）、关键帧数和关键帧请求数（增量）
    'width,height,console_age_ms,keyframes,key_requests,' +
    // 丢帧（每秒增量）：序号断档次数、断档跳过的帧数、包头失步、超大包
    'loss_gap,lost_frames,loss_resync,loss_oversize,' +
    // 定格：开关、此刻是否定格、次数/时长/超时放弃（增量）；帧间隔、关键帧间隔
    'freeze_on,frozen,freezes,freeze_ms,freeze_giveups,frame_ms,keyframe_ms,' +
    // 上屏：刷新周期、顺延/跳过/卡顿（增量）、最近一秒抖动与最长间隔
    'vsync_ms,vsync_deferred,vsync_dropped,stutters,jitter_ms,max_gap_ms,' +
    // 画质增强实际档位与耗时；专用热点信道、手机 WLAN 信道
    'enhance_level,enhance_ms,hs_channel,sta_channel';

  private file: fileIo.File | null = null;
  private startMs: number = 0;

  start(filesDir: string, note: string): void {
    this.stop();
    const path = `${filesDir}/stats.csv`;
    try {
      let flags = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND;
      if (fileIo.accessSync(path) && fileIo.statSync(path).size > 4 * 1024 * 1024) {
        flags = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC;
      }
      this.file = fileIo.openSync(path, flags);
      this.startMs = Date.now();
      fileIo.writeSync(this.file.fd, `# session ${new Date().toISOString()} ${note}\n${StatsRecorder.HEADER}\n`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open stats.csv failed: %{public}s', JSON.stringify(e));
      this.file = null;
    }
  }

  write(fields: number[]): void {
    const f = this.file;
    if (f === null) {
      return;
    }
    const t = ((Date.now() - this.startMs) / 1000).toFixed(0);
    try {
      fileIo.writeSync(f.fd, `${t},${fields.join(',')}\n`);
    } catch (e) {
      this.stop();
    }
  }

  stop(): void {
    const f = this.file;
    if (f !== null) {
      try {
        fileIo.closeSync(f);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close stats.csv failed');
      }
      this.file = null;
    }
  }
}
