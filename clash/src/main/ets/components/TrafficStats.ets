import { TrafficData, formatSpeed } from '../models/TrafficData';
import { formatBytes } from '../models/Subscription';

@Component
export struct TrafficStats {
  @Prop uploadSpeed: number = 0;
  @Prop downloadSpeed: number = 0;
  @Prop sessionUpload: number = 0;
  @Prop sessionDownload: number = 0;
  @Prop activeConnections: number = 0;

  build() {
    Column({ space: 12 }) {
      // Speed display
      Row() {
        // Upload
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Image($r('sys.media.ohos_ic_public_arrow_up'))
              .width(14)
              .height(14)
              .fillColor($r('app.color.upload_color'))
            Text($r('app.string.upload'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }

          Text(formatSpeed(this.uploadSpeed))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.upload_color'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Divider()
          .vertical(true)
          .height(36)
          .color($r('app.color.divider'))

        // Download
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Image($r('sys.media.ohos_ic_public_arrow_down'))
              .width(14)
              .height(14)
              .fillColor($r('app.color.download_color'))
            Text($r('app.string.download'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }

          Text(formatSpeed(this.downloadSpeed))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.download_color'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(12)

      // Session stats
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.data_usage'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Text(`↑ ${formatBytes(this.sessionUpload)}  ↓ ${formatBytes(this.sessionDownload)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 2 }) {
          Text($r('app.string.active_connections'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Text(`${this.activeConnections}`)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
  }
}
