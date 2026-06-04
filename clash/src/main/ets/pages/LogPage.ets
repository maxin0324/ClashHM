import { getClashService, IClashService } from '../services/ClashService';
import { LogEntry } from '../models/LogEntry';
import { LogItem, LogItemModel } from '../components/LogItem';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct LogPage {
  @State logs: LogItemModel[] = [];
  @State filterText: string = '';
  @State isLive: boolean = true;
  private service: IClashService | null = null;
  private pollTimer: number = -1;
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.loadLogs();
      this.startPolling();
    } catch (_e) {
      // service not ready
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private loadLogs(): void {
    if (!this.service) {
      return;
    }
    const rawLogs = this.service.getConnections();
    let filtered = rawLogs;
    if (this.filterText.length > 0) {
      const keyword = this.filterText.toLowerCase();
      filtered = rawLogs.filter((l: LogEntry) =>
        l.host.toLowerCase().includes(keyword) ||
        l.rule.toLowerCase().includes(keyword) ||
        l.proxyChain.join(' ').toLowerCase().includes(keyword)
      );
    }
    this.logs = filtered.map((l: LogEntry) => LogItemModel.fromLogEntry(l));
  }

  private startPolling(): void {
    this.pollTimer = setInterval(() => {
      if (this.isLive) {
        this.loadLogs();
      }
    }, 2000);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async clearConnections(): Promise<void> {
    if (this.service) {
      await this.service.closeAllConnections();
      this.logs = [];
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.logs'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()

        // Live toggle
        Row({ space: 4 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.isLive ? $r('app.color.connected_color') : $r('app.color.text_secondary'))
          Text('Live')
            .fontSize(12)
            .fontColor(this.isLive ? $r('app.color.connected_color') : $r('app.color.text_secondary'))
        }
        .onClick(() => {
          this.isLive = !this.isLive;
        })
        .margin({ right: 16 })

        Button($r('app.string.close_all'))
          .type(ButtonType.Normal)
          .height(28)
          .fontSize(12)
          .fontColor($r('app.color.error_color'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.error_color'))
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.clearConnections();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // Search bar
      Row() {
        Text('🔍')
          .fontSize(14)

        TextInput({ placeholder: 'Filter by host, rule, proxy...', text: this.filterText })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .margin({ left: 8 })
          .onChange((value: string) => {
            this.filterText = value;
            this.loadLogs();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .margin({ left: 16, right: 16, bottom: 8 })
      .height(40)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(10)

      // Connection count
      Row() {
        Text(`${this.logs.length} connections`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 4 })

      // Log list
      List({ scroller: this.listScroller }) {
        ForEach(this.logs, (log: LogItemModel) => {
          ListItem() {
            LogItem({ entry: log })
          }
        }, (log: LogItemModel) => log.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .divider({
        strokeWidth: 0.5,
        color: $r('app.color.divider'),
        startMargin: 12,
        endMargin: 12,
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
