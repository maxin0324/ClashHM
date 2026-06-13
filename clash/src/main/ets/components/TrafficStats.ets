import { TrafficData, formatSpeed } from '../models/TrafficData';
import { formatBytes } from '../models/Subscription';
import { HdsEffects } from '../common/HdsEffects';

@Component
export struct TrafficStats {
  @Prop uploadSpeed: number = 0;
  @Prop downloadSpeed: number = 0;
  @Prop sessionUpload: number = 0;
  @Prop sessionDownload: number = 0;
  @Prop activeConnections: number = 0;

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 6 }) {
          Text($r('app.string.upload'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Text(formatSpeed(this.uploadSpeed))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.upload_color'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Divider()
          .vertical(true)
          .height(42)
          .color($r('app.color.divider'))

        Column({ space: 6 }) {
          Text($r('app.string.download'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Text(formatSpeed(this.downloadSpeed))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.download_color'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .backgroundColor($r('app.color.surface_glass'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.divider') })
      .shadow({ radius: 16, color: '#10000000', offsetX: 0, offsetY: 8 })
      .visualEffect(HdsEffects.createCardLight($r('app.color.download_color')))

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
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
  }
}
