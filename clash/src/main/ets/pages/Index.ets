import { HomePage } from './HomePage';
import { ProxyPage } from './ProxyPage';
import { SubscriptionPage } from './SubscriptionPage';
import { SettingsPage } from './SettingsPage';
import { NapiClashService } from '../services/NapiClashService';
import { setClashService } from '../services/ClashService';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  private tabsController: TabsController = new TabsController();
  private tabTitles: string[] = ['Home', 'Proxy', 'Subscribe', 'Settings'];
  private tabIcons: string[] = ['⌂', '⇋', '☰', '⚙'];

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const service = new NapiClashService(context);
    setClashService(service);
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
    .onChange((index: number) => {
      this.currentIndex = index;
    })
  }
}
