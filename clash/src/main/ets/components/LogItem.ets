import { LogEntry, LogType } from '../models/LogEntry';
import { formatBytes } from '../models/Subscription';

@Component
export struct LogItem {
  @Prop entry: LogItemModel = new LogItemModel();

  private getTypeColor(): ResourceColor {
    switch (this.entry.type) {
      case LogType.HTTPS:
        return $r('app.color.connected_color');
      case LogType.HTTP:
        return $r('app.color.connecting_color');
      case LogType.DNS:
        return $r('app.color.upload_color');
      default:
        return $r('app.color.primary');
    }
  }

  private formatTime(ts: number): string {
    const d = new Date(ts);
    const h = String(d.getHours()).padStart(2, '0');
    const m = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  build() {
    Row() {
      Text(this.entry.network)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.getTypeColor())
        .borderRadius(4)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .width(40)
        .textAlign(TextAlign.Center)

      Column({ space: 2 }) {
        Text(this.entry.host || `${this.entry.destinationIP}:${this.entry.destinationPort}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 4 }) {
          Text(this.entry.rule)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))

          Text('→')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))

          Text(this.entry.proxyChain.join(' → '))
            .fontSize(10)
            .fontColor($r('app.color.primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .margin({ left: 10 })
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.formatTime(this.entry.timestamp))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))

        Text(`↓${formatBytes(this.entry.downloadBytes)}`)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16, bottom: 8 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
  }
}

export class LogItemModel {
  id: string = '';
  timestamp: number = 0;
  type: LogType = LogType.TCP;
  network: string = 'TCP';
  sourceIP: string = '';
  sourcePort: number = 0;
  destinationIP: string = '';
  destinationPort: number = 0;
  host: string = '';
  rule: string = '';
  rulePayload: string = '';
  proxyChain: string[] = [];
  downloadBytes: number = 0;
  uploadBytes: number = 0;

  static fromLogEntry(entry: LogEntry): LogItemModel {
    const model = new LogItemModel();
    model.id = entry.id;
    model.timestamp = entry.timestamp;
    model.type = entry.type;
    model.network = entry.network;
    model.sourceIP = entry.sourceIP;
    model.sourcePort = entry.sourcePort;
    model.destinationIP = entry.destinationIP;
    model.destinationPort = entry.destinationPort;
    model.host = entry.host;
    model.rule = entry.rule;
    model.rulePayload = entry.rulePayload;
    model.proxyChain = entry.proxyChain;
    model.downloadBytes = entry.downloadBytes;
    model.uploadBytes = entry.uploadBytes;
    return model;
  }
}
