import { ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

/**
 * 深色模式与系统栏：
 * - 应用级颜色模式用 ApplicationContext.setColorMode（-1 跟随系统 / 0 深色 / 1 浅色），资源自动切到 dark 目录；
 * - 状态栏、导航条文字颜色随当前深浅色调整，让顶部状态栏和底部小白条区域和页面融为一体。
 */
export function applyColorMode(ctx: Context, mode: number): void {
  try {
    ctx.getApplicationContext().setColorMode(mode as ConfigurationConstant.ColorMode);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
  }
}

export function updateSystemBarColors(win: window.Window, dark: boolean): void {
  const content = dark ? '#FFFFFF' : '#000000';
  // PC/2in1 和智慧屏不支持这个接口，可能直接抛 801
  try {
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: content,
      navigationBarContentColor: content
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
    });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties threw: %{public}s', JSON.stringify(e));
  }
}

/**
 * 取安全区（vp），存进 AppStorage：ui.safeTop / ui.safeBottom 是系统栏；
 * ui.safeLeft / ui.safeRight 是横屏时摄像头挖孔（以及侧边的系统栏）占掉的宽度，竖屏时一般为 0
 */
export function updateSafeArea(win: window.Window, uiContext: UIContext): void {
  try {
    const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const top = system.topRect.height;
    const bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
    const winWidth = win.getWindowProperties().windowRect.width;
    // 左侧：避让区的右边缘；右侧：窗口宽度减去避让区的左边缘（没有避让区时 width 为 0）
    const leftEdge = (r: window.Rect): number => r.width > 0 ? r.left + r.width : 0;
    const rightEdge = (r: window.Rect): number => r.width > 0 ? Math.max(0, winWidth - r.left) : 0;
    const left = Math.max(leftEdge(cutout.leftRect), leftEdge(system.leftRect));
    const right = Math.max(rightEdge(cutout.rightRect), rightEdge(system.rightRect));
    AppStorage.setOrCreate('ui.safeTop', uiContext.px2vp(top));
    AppStorage.setOrCreate('ui.safeBottom', uiContext.px2vp(bottom));
    AppStorage.setOrCreate('ui.safeLeft', uiContext.px2vp(left));
    AppStorage.setOrCreate('ui.safeRight', uiContext.px2vp(right));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea failed: %{public}s', JSON.stringify(e));
  }
}
