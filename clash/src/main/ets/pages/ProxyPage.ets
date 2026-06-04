import { getClashService, IClashService } from '../services/ClashService';
import { ProxyGroup, ConnectState } from '../models/ClashConfig';
import { ProxyGroupCard, ProxyGroupModel } from '../components/ProxyGroupCard';
import { Logger } from '../common/Logger';

@Component
export struct ProxyPage {
  @State groups: ProxyGroupModel[] = [];
  @State isLoading: boolean = false;
  @State isTesting: boolean = false;
  @State statusMsg: string = '';
  private service: IClashService | null = null;

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.loadProxyGroups();
    } catch (_e) {
      this.statusMsg = 'Service not ready';
    }
  }

  private loadProxyGroups(): void {
    if (!this.service) {
      return;
    }
    if (this.service.getState() !== ConnectState.CONNECTED) {
      this.statusMsg = 'Connect first to view proxies';
      this.groups = [];
      return;
    }
    this.statusMsg = '';
    const rawGroups = this.service.getProxyGroups();
    this.groups = rawGroups.map((g: ProxyGroup) => new ProxyGroupModel(g));
    if (this.groups.length === 0) {
      this.statusMsg = 'No proxy groups found';
    }
  }

  private async selectProxy(groupName: string, proxyName: string): Promise<void> {
    if (!this.service) {
      return;
    }
    try {
      await this.service.selectProxy(groupName, proxyName);
      for (const group of this.groups) {
        if (group.name === groupName) {
          group.now = proxyName;
          break;
        }
      }
    } catch (e) {
      Logger.error('Select proxy failed: %{public}s', String(e));
    }
  }

  private async testGroupLatency(groupName: string): Promise<void> {
    if (!this.service || this.isTesting) {
      return;
    }
    this.isTesting = true;
    try {
      const results = await this.service.testGroupLatency(groupName);
      for (const group of this.groups) {
        if (group.name === groupName) {
          for (const node of group.nodes) {
            const latency = results.get(node.name);
            if (latency !== undefined) {
              node.latency = latency;
              node.alive = latency > 0 && latency < 3000;
            }
          }
          break;
        }
      }
    } catch (e) {
      Logger.error('Test latency failed: %{public}s', String(e));
    } finally {
      this.isTesting = false;
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Text($r('app.string.tab_proxy'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Blank()

        // Refresh button
        Button('↻')
          .type(ButtonType.Normal)
          .height(32)
          .fontSize(16)
          .fontColor($r('app.color.primary'))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.loadProxyGroups();
          })
          .margin({ right: 8 })

        Button($r('app.string.test_all'))
          .type(ButtonType.Normal)
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.primary'))
          .borderRadius(16)
          .padding({ left: 16, right: 16 })
          .enabled(!this.isTesting)
          .onClick(async () => {
            for (const group of this.groups) {
              await this.testGroupLatency(group.name);
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      if (this.statusMsg) {
        Column({ space: 12 }) {
          Text('⇋')
            .fontSize(48)
            .fontColor($r('app.color.text_secondary'))
            .opacity(0.4)
          Text(this.statusMsg)
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // Proxy groups list
        List({ space: 12 }) {
          ForEach(this.groups, (group: ProxyGroupModel) => {
            ListItem() {
              ProxyGroupCard({
                group: group,
                onSelectProxy: (gName: string, pName: string) => {
                  this.selectProxy(gName, pName);
                },
                onTestLatency: (gName: string) => {
                  this.testGroupLatency(gName);
                }
              })
            }
          }, (group: ProxyGroupModel) => group.name)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
