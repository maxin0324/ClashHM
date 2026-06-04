import { Subscription, formatBytes, formatTimestamp } from '../models/Subscription';

@Component
export struct SubscriptionCard {
  @Prop sub: SubscriptionCardModel = new SubscriptionCardModel();
  onTap: () => void = () => {};
  onUpdate: () => void = () => {};
  onEdit: () => void = () => {};
  onDelete: () => void = () => {};

  private getUsagePercent(): number {
    if (this.sub.totalData <= 0) {
      return 0;
    }
    const used = this.sub.uploadUsed + this.sub.downloadUsed;
    return Math.min(used / this.sub.totalData * 100, 100);
  }

  build() {
    Column({ space: 8 }) {
      // Header row
      Row() {
        Column({ space: 2 }) {
          Row({ space: 8 }) {
            Text(this.sub.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.sub.isActive) {
              Text('IN USE')
                .fontSize(10)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.connected_color'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
          }
          .width('100%')

          Text(this.sub.url)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
      }
      .width('100%')

      // Info row
      Row() {
        Text(`${this.sub.nodeCount} nodes`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        Text('·')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 8, right: 8 })

        Text(formatTimestamp(this.sub.lastUpdate))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        if (this.sub.expireDate > 0) {
          Text('·')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 8, right: 8 })
          Text(`Exp: ${formatTimestamp(this.sub.expireDate)}`)
            .fontSize(12)
            .fontColor(this.sub.expireDate < Date.now() ? $r('app.color.error_color') : $r('app.color.text_secondary'))
        }
      }
      .width('100%')

      // Data usage bar
      if (this.sub.totalData > 0) {
        Column({ space: 4 }) {
          Progress({ value: this.getUsagePercent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.divider'))
            .borderRadius(2)

          Row() {
            Text(`${formatBytes(this.sub.uploadUsed + this.sub.downloadUsed)} / ${formatBytes(this.sub.totalData)}`)
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

      // Action buttons
      Row({ space: 8 }) {
        Blank()

        Button($r('app.string.update_subscription'))
          .type(ButtonType.Normal)
          .height(30)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.primary'))
          .borderRadius(15)
          .padding({ left: 14, right: 14 })
          .onClick(() => this.onUpdate())

        Button($r('app.string.edit_subscription'))
          .type(ButtonType.Normal)
          .height(30)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.divider'))
          .borderRadius(15)
          .padding({ left: 14, right: 14 })
          .onClick(() => this.onEdit())

        Button($r('app.string.delete_subscription'))
          .type(ButtonType.Normal)
          .height(30)
          .fontSize(12)
          .fontColor($r('app.color.error_color'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.error_color'))
          .borderRadius(15)
          .padding({ left: 14, right: 14 })
          .onClick(() => this.onDelete())
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
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
    model.id = sub.id;
    model.name = sub.name;
    model.url = sub.url;
    model.nodeCount = sub.nodeCount;
    model.lastUpdate = sub.lastUpdate;
    model.expireDate = sub.expireDate;
    model.uploadUsed = sub.uploadUsed;
    model.downloadUsed = sub.downloadUsed;
    model.totalData = sub.totalData;
    model.isActive = sub.isActive;
    return model;
  }
}
