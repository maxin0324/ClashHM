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
import { HdsEffects } from '../common/HdsEffects';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State engineMode: string = '';
  @State errorDetail: string = '';
  @State showErrorDetail: boolean = false;
  @State copyStatus: string = '';
  private tabsController: TabsController = new TabsController();
  private tabTitles: Resource[] = [$r('app.string.tab_home'), $r('app.string.tab_proxy'), $r('app.string.tab_subscription'), $r('app.string.tab_settings')];

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

  private isCurrentTab(index: number): boolean {
    return this.currentIndex === index;
  }

  private getTabColor(index: number): ResourceColor {
    return this.isCurrentTab(index) ? $r('app.color.primary') : $r('app.color.text_secondary');
  }

  @Builder
  tabIcon(index: number) {
    Stack() {
      if (index === 0) {
        Column({ space: 2 }) {
          Row()
            .width(18)
            .height(7)
            .borderRadius(3)
            .backgroundColor(this.getTabColor(index))
          Row()
            .width(14)
            .height(11)
            .borderRadius(3)
            .backgroundColor(this.getTabColor(index))
        }
        .alignItems(HorizontalAlign.Center)
      } else if (index === 1) {
        Stack() {
          Row()
            .width(24)
            .height(3)
            .borderRadius(2)
            .backgroundColor(this.getTabColor(index))
          Row() {
            Circle()
              .width(9)
              .height(9)
              .fill(this.getTabColor(index))
            Blank()
            Circle()
              .width(9)
              .height(9)
              .fill(this.getTabColor(index))
          }
          .width(28)
        }
      } else if (index === 2) {
        Column({ space: 4 }) {
          Row()
            .width(22)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.getTabColor(index))
          Row()
            .width(18)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.getTabColor(index))
          Row()
            .width(22)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.getTabColor(index))
        }
        .alignItems(HorizontalAlign.Center)
      } else {
        Stack() {
          Circle()
            .width(22)
            .height(22)
            .fill(this.getTabColor(index))
          Circle()
            .width(8)
            .height(8)
            .fill($r('app.color.nav_bg'))
        }
      }
    }
    .width(34)
    .height(24)
    .alignContent(Alignment.Center)
  }

  @Builder
  tabBuilder(title: ResourceStr, index: number) {
    Column({ space: 3 }) {
      this.tabIcon(index)
      Text(title)
        .width('100%')
        .height(14)
        .fontSize(10)
        .lineHeight(14)
        .fontWeight(this.isCurrentTab(index) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.getTabColor(index))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.isCurrentTab(index) ? $r('app.color.surface_tint') : Color.Transparent)
    .borderRadius(16)
    .visualEffect(HdsEffects.createCardLight(this.getTabColor(index)))
    .onClick(() => {
      this.currentIndex = index;
      this.tabsController.changeIndex(index);
    })
  }

  build() {
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

      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() {
          HomePage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[0], 0))

        TabContent() {
          ProxyPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[1], 1))

        TabContent() {
          SubscriptionPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[2], 2))

        TabContent() {
          SettingsPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[3], 3))
      }
      .scrollable(false)
      .barHeight(70)
      .barOverlap(true)
      .divider(null)
      .barBackgroundColor($r('app.color.nav_bg'))
      .barBackgroundBlurStyle(BlurStyle.Regular)
      .backgroundColor($r('app.color.page_bg'))
      .layoutWeight(1)
      .onChange((index: number) => {
        this.currentIndex = index;
      })
    }
    .width('100%')
    .height('100%')
  }
}
