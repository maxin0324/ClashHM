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
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(this.sub.name)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.sub.isActive) {
              Text('Active')
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

      Row({ space: 8 }) {
        Blank()

        Button('Update')
          .type(ButtonType.Normal)
          .height(32)
          .width(64)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(7)
          .onClick(() => this.onUpdate())

        Button('Edit')
          .type(ButtonType.Normal)
          .height(32)
          .width(52)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(7)
          .onClick(() => this.onEdit())

        Button('Delete')
          .type(ButtonType.Normal)
          .height(32)
          .width(60)
          .fontSize(12)
          .fontColor($r('app.color.error_color'))
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(7)
          .onClick(() => this.onDelete())
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: this.sub.isActive ? $r('app.color.primary') : $r('app.color.divider') })
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
