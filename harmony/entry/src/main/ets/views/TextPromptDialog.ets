// 单行输入弹窗：手动输入主机地址（IP 或主机名）、给主机起备注名、给触屏手柄键位起名共用
import { inputMethod } from '@kit.IMEKit';

@CustomDialog
export struct TextPromptDialog {
  controller?: CustomDialogController;
  title: string = '';
  placeholder: string = '';
  confirmText: string = '';
  @State text: string = '';
  @State error: string = '';
  /** 输入主机地址：网址键盘（数字、字母和“.”都在上面），只允许数字、字母、点和连字符 */
  address: boolean = false;
  /** 返回空串表示通过并关闭弹窗，否则显示为错误提示 */
  onConfirm: (value: string) => string = () => '';

  private confirm(): void {
    const err = this.onConfirm(this.text.trim());
    if (err.length > 0) {
      this.error = err;
      return;
    }
    this.close();
  }

  // 关弹窗时把输入法键盘也收起来（有的设备上弹窗关了键盘还留着，挡住后面的页面）
  private close(): void {
    this.controller?.close();
    inputMethod.getController().stopInputSession().catch(() => {
    });
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.address) {
        // 原来用数字小数点键盘（NUMBER_DECIMAL）：只能输一个点，IP 的后两个点输不进去
        TextInput({ text: this.text, placeholder: this.placeholder })
          .type(InputType.URL)
          .inputFilter('[0-9A-Za-z.\\-]')
          .maxLength(253)
          .enterKeyType(EnterKeyType.Go)
          .enableAutoFill(false)
          .defaultFocus(true)
          .height(44)
          .borderRadius(12)
          .onChange((v: string) => {
            this.text = v;
            this.error = '';
          })
          .onSubmit(() => {
            this.confirm();
          })
      } else {
        TextInput({ text: this.text, placeholder: this.placeholder })
          .type(InputType.Normal)
          .enableAutoFill(false)
          .defaultFocus(true)
          .height(44)
          .borderRadius(12)
          .onChange((v: string) => {
            this.text = v;
            this.error = '';
          })
          .onSubmit(() => {
            this.confirm();
          })
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(12)
          .fontColor($r('app.color.warn'))
          .width('100%')
      }

      Row({ space: 12 }) {
        Button($r('app.string.common_cancel'))
          .layoutWeight(1)
          .height(40)
          .fontColor($r('app.color.accent'))
          .backgroundColor($r('app.color.accent_soft'))
          .onClick(() => {
            this.close();
          })
        Button(this.confirmText)
          .layoutWeight(1)
          .height(40)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
    }
    .padding(20)
    // 自定义样式弹窗的宽度由内容决定：屏宽 88%，横屏、平板、PC 上最宽 420vp，转屏时自动跟着变
    .width('88%')
    .constraintSize({ maxWidth: 420 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(24)
  }
}
