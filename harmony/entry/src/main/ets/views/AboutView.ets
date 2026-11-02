// 关于：图标、版本、开源地址、应用市场、隐私与免责声明
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { productViewManager } from '@kit.StoreKit';
import { tr } from '../common/I18n';
import { APP_NAME, PROJECT_GITHUB, SFT_PROJECT_URL } from '../common/Prefs';
import { Card, NavRow } from './Widgets';

const DOMAIN = 0x5346;
const TAG = 'NSSFT';

@Component
export struct AboutView {
  @StorageProp('ui.safeBottom') safeBottom: number = 0;
  @State version: string = '';
  private bundleName: string = '';

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
      this.bundleName = info.name;
    } catch (e) {
      this.version = '';
    }
  }

  private open(url: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.openLink(url, { appLinkingOnly: false }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: tr('about_open_failed', url) });
    });
  }

  private openStore(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      productViewManager.loadProduct(ctx, { parameters: { bundleName: this.bundleName } }, {
        onError: (err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'loadProduct failed: %{public}d %{public}s', err.code, err.message);
          promptAction.showToast({ message: tr('about_store_unavailable') });
        }
      });
    } catch (e) {
      promptAction.showToast({ message: tr('about_store_unavailable') });
    }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          // 分层图标（layered_image）Image 组件画不出来，这里用合成好的平面图标
          Image($r('app.media.icon'))
            .width(84)
            .height(84)
            .borderRadius(20)
            .clip(true)
          Text(APP_NAME)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          if (this.version.length > 0) {
            Text(tr('about_version', this.version))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          Text(tr('about_desc'))
            .fontSize(14)
            .lineHeight(22)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width('100%')
        .padding({ top: 12, bottom: 4 })

        Card({ title: tr('about_group_project') }) {
          NavRow({
            title: tr('about_source'),
            desc: tr('about_source_desc'),
            icon: $r('sys.symbol.link'),
            external: true,
            onTap: () => {
              this.open(PROJECT_GITHUB);
            }
          })
          NavRow({
            title: tr('about_sft'),
            desc: tr('about_sft_desc'),
            icon: $r('sys.symbol.person'),
            external: true,
            onTap: () => {
              this.open(SFT_PROJECT_URL);
            }
          })
          NavRow({
            title: tr('about_store'),
            desc: tr('about_store_desc'),
            icon: $r('sys.symbol.star'),
            onTap: () => {
              this.openStore();
            }
          })
        }

        Card({ title: tr('about_group_notes') }) {
          Text(tr('about_privacy'))
            .fontSize(13)
            .lineHeight(21)
            .fontColor($r('app.color.text_secondary'))
          Divider().color($r('app.color.divider'))
          Text(tr('about_disclaimer'))
            .fontSize(13)
            .lineHeight(21)
            .fontColor($r('app.color.text_secondary'))
          Divider().color($r('app.color.divider'))
          Text(tr('about_license'))
            .fontSize(13)
            .lineHeight(21)
            .fontColor($r('app.color.text_secondary'))
        }
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
