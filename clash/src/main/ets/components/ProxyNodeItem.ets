import { ProxyNodeModel } from './ProxyGroupCard';
import { Constants } from '../common/Constants';

@Component
export struct ProxyNodeItem {
  @ObjectLink node: ProxyNodeModel;
  @Prop isSelected: boolean = false;
  onTap: () => void = () => {};

  private getLatencyColor(): ResourceColor {
    if (this.node.latency < 0) {
      return $r('app.color.text_secondary');
    }
    if (this.node.latency === 0) {
      return $r('app.color.latency_timeout');
    }
    if (this.node.latency <= Constants.LATENCY_GOOD) {
      return $r('app.color.latency_good');
    }
    if (this.node.latency <= Constants.LATENCY_MEDIUM) {
      return $r('app.color.latency_medium');
    }
    return $r('app.color.latency_bad');
  }

  private getLatencyText(): ResourceStr {
    if (this.node.latency < 0) {
      return '--';
    }
    if (this.node.latency === 0) {
      return $r('app.string.timeout');
    }
    return `${this.node.latency} ms`;
  }

  build() {
    Row({ space: 12 }) {
      Row()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(this.isSelected ? $r('app.color.primary') : $r('app.color.divider'))

      Column({ space: 2 }) {
        Text(this.node.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.node.type.toUpperCase())
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.getLatencyText())
        .fontSize(12)
        .fontColor(this.getLatencyColor())
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.End)
        .width(72)
    }
    .width('100%')
    .height(50)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.isSelected ? '#102563EB' : Color.Transparent)
    .onClick(() => {
      this.onTap();
    })
  }
}
