import { HomePage } from './HomePage';
import { ProxyPage } from './ProxyPage';
import { SubscriptionPage } from './SubscriptionPage';
import { SettingsPage } from './SettingsPage';
import { NapiClashService } from '../services/NapiClashService';
import { MockClashService } from '../services/MockClashService';
import { setClashService } from '../services/ClashService';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { DividerMode, HdsTabs, HdsTabsController } from '@hms.hds.hdsBaseComponent';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State engineMode: string = '';
  @State errorDetail: string = '';
  @State showErrorDetail: boolean = false;
  @State copyStatus: string = '';
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const service = new NapiClashService(context);
      setClashService(service);
      this.engineMode = 'native-extension-core';
      Logger.info('Using Extension native-core service bridge');
    } catch (e) {
      const errMsg = (e instanceof Error) ? e.message : String(e);
      Logger.error('NapiClashService failed: %{public}s', errMsg);
      this.errorDetail = errMsg;
      const mockService = new MockClashService();
      setClashService(mockService);
      this.engineMode = 'mock';
    }
  }

  private getDiagnosticText(): string {
    return `engineMode=${this.engineMode}\n${this.errorDetail}`;
  }

  private async copyDiagnostic(): Promise<void> {
    const text = this.getDiagnosticText();
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copyStatus = 'Copied';
      Logger.info('Diagnostic copied to pasteboard');
    } catch (e) {
      this.copyStatus = `Copy failed: ${String(e)}`;
      Logger.error('Copy diagnostic failed: %{public}s', String(e));
    }
  }

  @Builder
  tabContent(pageIndex: number) {
    Stack() {
      if (pageIndex === 0) {
        HomePage()
      } else if (pageIndex === 1) {
        ProxyPage()
      } else if (pageIndex === 2) {
        SubscriptionPage()
      } else {
        SettingsPage()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 104 })
  }

  @Builder
  layeredBackdrop() {
    Column() {
      Row()
        .width('100%')
        .height('30%')
        .backgroundColor('#F8FBFF')
      Row()
        .width('100%')
        .height('36%')
        .backgroundColor('#EEF5FF')
      Row()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#F7F8FA')
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      this.layeredBackdrop()

      Column() {
        if (this.errorDetail) {
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Text(this.engineMode === 'mock' ? $r('app.string.engine_unavailable') : `Engine: ${this.engineMode}`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.error_color'))
                .layoutWeight(1)
              Button($r('app.string.copy'))
                .height(28)
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(7)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.copyDiagnostic();
                })
              Button(this.showErrorDetail ? $r('app.string.hide') : $r('app.string.details'))
                .height(28)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(7)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.showErrorDetail = !this.showErrorDetail;
                })
            }

            if (this.errorDetail && !this.showErrorDetail) {
              Text(this.errorDetail)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .maxLines(this.showErrorDetail ? 6 : 2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .copyOption(CopyOptions.LocalDevice)
            }

            if (this.copyStatus) {
              Text(this.copyStatus)
                .fontSize(10)
                .fontColor(this.copyStatus === 'Copied' ? $r('app.color.connected_color') : $r('app.color.error_color'))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }

            if (this.showErrorDetail) {
              TextArea({ text: this.getDiagnosticText() })
                .width('100%')
                .height(96)
                .fontSize(11)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(8)
                .copyOption(CopyOptions.LocalDevice)
                .enabled(true)
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .margin({ left: 16, right: 16, top: 10, bottom: 4 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(8)
          .border({ width: 1, color: $r('app.color.divider') })
        }

        HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
          TabContent() {
            this.tabContent(0)
          }
          .tabBar($r('app.string.tab_home'))

          TabContent() {
            this.tabContent(1)
          }
          .tabBar($r('app.string.tab_proxy'))

          TabContent() {
            this.tabContent(2)
          }
          .tabBar($r('app.string.tab_subscription'))

          TabContent() {
            this.tabContent(3)
          }
          .tabBar($r('app.string.tab_settings'))
        }
        .width('100%')
        .layoutWeight(1)
        .barOverlap(true)
        .barHeight(78)
        .animationDuration(260)
        .scrollable(false)
        .divider({ mode: DividerMode.NONE })
        .barBackgroundColor(Color.Transparent)
        .barBackgroundBlurStyle(BlurStyle.Thin)
        .barBackgroundEffect({
          radius: 28,
          color: '#66FFFFFF',
          brightness: 1.04,
          saturation: 1.35,
        })
        .barBackgroundStyle({
          maskColor: $r('app.color.page_bg'),
          maskHeight: 124,
        })
        .onChange((index: number) => {
          this.currentIndex = index;
        })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .systemBarEffect()
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
