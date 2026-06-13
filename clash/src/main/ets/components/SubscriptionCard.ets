import { Subscription, formatBytes, formatTimestamp } from '../models/Subscription';

@Component
export struct SubscriptionCard {
  @Prop name: string = '';
  @Prop url: string = '';
  @Prop nodeCount: number = 0;
  @Prop lastUpdate: number = 0;
  @Prop expireDate: number = 0;
  @Prop uploadUsed: number = 0;
  @Prop downloadUsed: number = 0;
  @Prop totalData: number = 0;
  @Prop isActive: boolean = false;
  onTap: () => void = () => {};
  onUpdate: () => void = () => {};
  onEdit: () => void = () => {};
  onDelete: () => void = () => {};

  private getUsagePercent(): number {
    if (this.totalData <= 0) {
      return 0;
    }
    const used = this.uploadUsed + this.downloadUsed;
    return Math.min(used / this.totalData * 100, 100);
  }

  private getNodesCountText(): string {
    return `${this.nodeCount} 个节点`;
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(this.name)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.isActive) {
              Text($r('app.string.active'))
                .fontSize(10)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.connected_color'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
          }
          .width('100%')

          Text(this.url)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text(this.getNodesCountText())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        Text('·')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 8, right: 8 })

        Text(formatTimestamp(this.lastUpdate))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        if (this.expireDate > 0) {
          Text('·')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 8, right: 8 })
          Text(`Exp: ${formatTimestamp(this.expireDate)}`)
            .fontSize(12)
            .fontColor(this.expireDate < Date.now() ? $r('app.color.error_color') : $r('app.color.text_secondary'))
        }
      }
      .width('100%')

      if (this.totalData > 0) {
        Column({ space: 4 }) {
          Progress({ value: this.getUsagePercent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.divider'))
            .borderRadius(2)

          Row() {
            Text(`${formatBytes(this.uploadUsed + this.downloadUsed)} / ${formatBytes(this.totalData)}`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.getUsagePercent().toFixed(1)}%`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
      }

      Row({ space: 8 }) {
        Blank()

        Button($r('app.string.update'))
          .type(ButtonType.Normal)
          .height(32)
          .width(64)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(9)
          .onClick(() => this.onUpdate())

        Button($r('app.string.edit'))
          .type(ButtonType.Normal)
          .height(32)
          .width(52)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(9)
          .onClick(() => this.onEdit())

        Button($r('app.string.delete'))
          .type(ButtonType.Normal)
          .height(32)
          .width(60)
          .fontSize(12)
          .fontColor($r('app.color.error_color'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(9)
          .onClick(() => this.onDelete())
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface_glass'))
    .backgroundBlurStyle(BlurStyle.Thin)
    .borderRadius(16)
    .border({ width: 1, color: this.isActive ? $r('app.color.primary') : $r('app.color.divider') })
    .shadow({ radius: 12, color: '#0D000000', offsetX: 0, offsetY: 6 })
    .onClick(() => this.onTap())
  }
}

export class SubscriptionCardModel {
  id: string = '';
  name: string = '';
  url: string = '';
  nodeCount: number = 0;
  lastUpdate: number = 0;
  expireDate: number = 0;
  uploadUsed: number = 0;
  downloadUsed: number = 0;
  totalData: number = 0;
  isActive: boolean = false;

  static fromSubscription(sub: Subscription): SubscriptionCardModel {
    const model = new SubscriptionCardModel();
    model.id = sub.id || '';
    model.name = sub.name || '';
    model.url = sub.url || '';
    model.nodeCount = sub.nodeCount || 0;
    model.lastUpdate = sub.lastUpdate || 0;
    model.expireDate = sub.expireDate || 0;
    model.uploadUsed = sub.uploadUsed || 0;
    model.downloadUsed = sub.downloadUsed || 0;
    model.totalData = sub.totalData || 0;
    model.isActive = sub.isActive === true;
    return model;
  }
}
