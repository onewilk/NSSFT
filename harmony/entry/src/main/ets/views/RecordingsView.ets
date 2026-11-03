// 录像管理（首页“录像”卡片进入）：应用里录好的视频（files/recordings，图库里看不到），
// 点一条用系统的视频播放器打开；可以存到图库（系统弹窗确认，存好后从这里移走）或删除
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { FOCUS_BOX } from '../common/Focus';
import { tr } from '../common/I18n';
import {
  deleteRecording, formatBytes, formatClock, listRecordings, openRecording, RecordingFile, saveRecordingToGallery
} from '../common/Recording';
import { Card, IconTile } from './Widgets';

function two(n: number): string {
  return (n < 10 ? '0' : '') + n;
}

function timeText(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
}

@Component
export struct RecordingsView {
  @State files: RecordingFile[] = [];
  // 正在存到图库的文件（显示转圈，避免重复点）
  @State saving: string = '';
  @StorageProp('ui.safeBottom') safeBottom: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.files = listRecordings(getContext(this) as common.UIAbilityContext);
  }

  private totalBytes(): number {
    let n = 0;
    for (const f of this.files) {
      n += f.bytes;
    }
    return n;
  }

  private subtitle(f: RecordingFile): string {
    const parts: string[] = [];
    if (f.label.length > 0) {
      parts.push(f.label);
    }
    if (f.durationMs >= 0) {
      parts.push(formatClock(f.durationMs));
    }
    parts.push(formatBytes(f.bytes));
    return parts.join(' · ');
  }

  // 点一条录像：用系统的视频播放器打开
  private async play(f: RecordingFile): Promise<void> {
    const err = await openRecording(getContext(this) as common.UIAbilityContext, f);
    if (err.length > 0) {
      promptAction.showToast({ message: tr('recordings_play_failed', err), duration: 4000 });
    }
  }

  private async save(f: RecordingFile): Promise<void> {
    if (this.saving.length > 0) {
      return;
    }
    this.saving = f.path;
    const r = await saveRecordingToGallery(getContext(this) as common.UIAbilityContext, f);
    this.saving = '';
    if (r === 'ok') {
      promptAction.showToast({ message: tr('recordings_saved') });
      this.reload();
    } else if (r !== 'cancel') {
      promptAction.showToast({ message: tr('recordings_save_failed', r), duration: 4000 });
    }
  }

  private confirmDelete(f: RecordingFile): void {
    promptAction.showDialog({
      title: tr('recordings_delete_title'),
      message: tr('recordings_delete_message', timeText(f.time), formatBytes(f.bytes)),
      buttons: [
        { text: tr('common_cancel'), color: '#99000000' },
        { text: tr('recordings_delete'), color: '#E5484D' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        deleteRecording(f.path);
        this.reload();
      }
    }).catch(() => {
    });
  }

  // 一条录像：整行点了用系统播放器打开；右边的“存到图库”“删除”按钮各自响应，点它们不会触发播放
  @Builder
  FileRow(f: RecordingFile) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 4 }) {
        Row({ space: 12 }) {
          IconTile($r('sys.symbol.play_fill'), false)
          Column({ space: 2 }) {
            Text(timeText(f.time))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Text(this.subtitle(f))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .layoutWeight(1)

        if (this.saving === f.path) {
          LoadingProgress().width(36).height(36).padding(6).color($r('app.color.accent'))
        } else {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.square_and_arrow_down')).fontSize(18).fontColor([$r('app.color.accent')])
          }
          .width(36)
          .height(36)
          .backgroundColor(Color.Transparent)
          .focusBox(FOCUS_BOX)
          .accessibilityText(tr('recordings_save'))
          .onClick(() => {
            this.save(f);
          })
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .focusBox(FOCUS_BOX)
        .accessibilityText(tr('recordings_delete'))
        .onClick(() => {
          this.confirmDelete(f);
        })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 10, bottom: 10 })
    }
    .width('100%')
    .height('auto')
    .borderRadius(16)
    .backgroundColor(Color.Transparent)
    .focusBox(FOCUS_BOX)
    .accessibilityText(`${tr('recordings_play')} ${timeText(f.time)}`)
    .onClick(() => {
      this.play(f);
    })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.files.length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.film')).fontSize(40).fontColor([$r('app.color.text_tertiary')])
            Text(tr('recordings_empty')).fontSize(15).fontColor($r('app.color.text_secondary'))
            Text(tr('recordings_empty_hint'))
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: 48, bottom: 24 })
        } else {
          Card({ title: tr('recordings_summary', this.files.length, formatBytes(this.totalBytes())) }) {
            ForEach(this.files, (f: RecordingFile) => {
              this.FileRow(f)
            }, (f: RecordingFile) => `${f.path}|${f.bytes}`)
          }
        }
        Text(tr('recordings_note'))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 4, right: 4 })
      }
      .padding({ left: 16, right: 16, top: 8, bottom: this.safeBottom + 24 })
      .constraintSize({ maxWidth: 720 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
