// 单行输入弹窗：手动输入主机地址、给主机起备注名共用
@CustomDialog
export struct TextPromptDialog {
  controller?: CustomDialogController;
  title: string = '';
  placeholder: string = '';
  confirmText: string = '';
  @State text: string = '';
  @State error: string = '';
  numeric: boolean = false;
  /** 返回空串表示通过并关闭弹窗，否则显示为错误提示 */
  onConfirm: (value: string) => string = () => '';

  private confirm(): void {
    const err = this.onConfirm(this.text.trim());
    if (err.length > 0) {
      this.error = err;
      return;
    }
    this.controller?.close();
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      TextInput({ text: this.text, placeholder: this.placeholder })
        .type(this.numeric ? InputType.NUMBER_DECIMAL : InputType.Normal)
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
            this.controller?.close();
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
