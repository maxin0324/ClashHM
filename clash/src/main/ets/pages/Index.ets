import { HomePage } from './HomePage';
import { ProxyPage } from './ProxyPage';
import { SubscriptionPage } from './SubscriptionPage';
import { SettingsPage } from './SettingsPage';
import { NapiClashService } from '../services/NapiClashService';
import { MockClashService } from '../services/MockClashService';
import { setClashService } from '../services/ClashService';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State engineMode: string = '';
  @State errorDetail: string = '';
  private tabsController: TabsController = new TabsController();
  private tabTitles: string[] = ['Home', 'Proxy', 'Subscribe', 'Settings'];
  private tabIcons: string[] = ['⌂', '⇋', '☰', '⚙'];

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const service = new NapiClashService(context);
      setClashService(service);
      this.engineMode = 'mihomo';
      Logger.info('Using NapiClashService (mihomo engine)');
    } catch (e) {
      const errMsg = (e instanceof Error) ? e.message : String(e);
      Logger.error('NapiClashService failed: %{public}s', errMsg);
      this.errorDetail = errMsg;
      const mockService = new MockClashService();
      setClashService(mockService);
      this.engineMode = 'mock';
    }
  }

  @Builder
  tabBuilder(title: string, icon: string, index: number) {
    Column() {
      Text(icon)
        .fontSize(22)
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
      if (this.engineMode === 'mock') {
        Column() {
          Text('Mock Mode — native engine not loaded')
            .fontSize(11)
            .fontColor(Color.White)
          if (this.errorDetail) {
            Text(this.errorDetail)
              .fontSize(9)
              .fontColor(Color.White)
              .opacity(0.8)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.connecting_color'))
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 4, bottom: 4, left: 8, right: 8 })
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
      .barHeight(56)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.currentIndex = index;
      })
    }
    .width('100%')
    .height('100%')
  }
}
