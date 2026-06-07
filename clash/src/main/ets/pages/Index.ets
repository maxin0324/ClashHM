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

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State engineMode: string = '';
  @State errorDetail: string = '';
  @State showErrorDetail: boolean = false;
  @State copyStatus: string = '';
  private tabsController: TabsController = new TabsController();
  private tabTitles: string[] = ['Home', 'Proxy', 'Subscribe', 'Settings'];
  private tabIcons: string[] = ['⌂', '⇄', '☰', '⋯'];

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
  tabBuilder(title: string, icon: string, index: number) {
    Column() {
      Text(icon)
        .fontSize(index === 3 ? 25 : 21)
        .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.currentIndex === index ? $r('app.color.primary') : $r('app.color.text_secondary'))
      Text(title)
        .fontSize(10)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
            Text(this.engineMode === 'mock' ? 'Engine unavailable' : `Engine: ${this.engineMode}`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.error_color'))
              .layoutWeight(1)
            Button('Copy')
              .height(28)
              .fontSize(12)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(7)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.copyDiagnostic();
              })
            Button(this.showErrorDetail ? 'Hide' : 'Details')
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
        .tabBar(this.tabBuilder(this.tabTitles[0], this.tabIcons[0], 0))

        TabContent() {
          ProxyPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[1], this.tabIcons[1], 1))

        TabContent() {
          SubscriptionPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[2], this.tabIcons[2], 2))

        TabContent() {
          SettingsPage()
        }
        .tabBar(this.tabBuilder(this.tabTitles[3], this.tabIcons[3], 3))
      }
      .scrollable(false)
      .barHeight(58)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.currentIndex = index;
      })
    }
    .width('100%')
    .height('100%')
  }
}
