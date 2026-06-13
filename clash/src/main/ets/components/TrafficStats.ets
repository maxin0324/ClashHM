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
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.statCard($r('app.string.upload'), formatSpeed(this.uploadSpeed), $r('app.color.upload_color'))

        this.statCard($r('app.string.download'), formatSpeed(this.downloadSpeed), $r('app.color.download_color'))
      }
      .width('100%')

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.data_usage'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Text(`↑ ${formatBytes(this.sessionUpload)}  ↓ ${formatBytes(this.sessionDownload)}`)
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 2 }) {
          Text($r('app.string.active_connections'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Text(`${this.activeConnections}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .height(58)
      .padding({ left: 14, right: 14 })
      .backgroundColor($r('app.color.surface_glass'))
      .backgroundBlurStyle(BlurStyle.Thin)
      .borderRadius(14)
      .border({ width: 1, color: $r('app.color.divider') })
    }
    .width('100%')
  }

  @Builder
  private statCard(label: ResourceStr, value: string, color: ResourceColor) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(76)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.surface_glass'))
    .backgroundBlurStyle(BlurStyle.Thin)
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.divider') })
  }
}
