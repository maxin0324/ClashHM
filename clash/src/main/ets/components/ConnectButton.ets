import { ConnectState } from '../models/ClashConfig';

@Component
export struct ConnectButton {
  @Prop state: string = ConnectState.DISCONNECTED;
  onTap: () => void = () => {};

  @State private btnScale: number = 1.0;
  @State private rippleOpacity: number = 0;
  @State private rippleSize: number = 0.8;
  @State private rotation: number = 0;

  private getCircleColor(): Resource {
    if (this.state === ConnectState.CONNECTED) {
      return $r('app.color.connected_color');
    } else if (this.state === ConnectState.CONNECTING) {
      return $r('app.color.connecting_color');
    }
    return $r('app.color.disconnected_color');
  }

  private getStatusText(): Resource {
    if (this.state === ConnectState.CONNECTED) {
      return $r('app.string.tap_to_disconnect');
    } else if (this.state === ConnectState.CONNECTING) {
      return $r('app.string.connecting');
    }
    return $r('app.string.tap_to_connect');
  }

  private getStateText(): Resource {
    if (this.state === ConnectState.CONNECTED) {
      return $r('app.string.connected');
    } else if (this.state === ConnectState.CONNECTING) {
      return $r('app.string.connecting');
    }
    return $r('app.string.disconnected');
  }

  @Builder
  private powerIcon() {
    Image($r('app.media.power_icon'))
      .width(76)
      .height(76)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  private loadingIcon() {
    Row({ space: 7 }) {
      Circle()
        .width(9)
        .height(9)
        .fill(Color.White)
        .opacity(0.55)
      Circle()
        .width(9)
        .height(9)
        .fill(Color.White)
        .opacity(0.85)
      Circle()
        .width(9)
        .height(9)
        .fill(Color.White)
        .opacity(0.55)
    }
    .width(76)
    .height(76)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 10 }) {
      Stack() {
        Circle()
          .width(154)
          .height(154)
          .fill(this.getCircleColor())
          .opacity(this.state === ConnectState.CONNECTED ? 0.15 : 0.10)

        Circle()
          .width(138)
          .height(138)
          .fill($r('app.color.surface_glass'))
          .opacity(0.88)

        Row()
          .width(128)
          .height(128)
          .borderRadius(64)
          .backgroundColor(this.getCircleColor())
          .opacity(this.state === ConnectState.CONNECTING ? 0.84 : 1)
          .shadow({ radius: 24, color: '#26000000', offsetX: 0, offsetY: 12 })

        Circle()
          .width(92)
          .height(92)
          .fill(Color.White)
          .opacity(this.state === ConnectState.DISCONNECTED ? 0.10 : 0.18)
          .position({ x: 18, y: 14 })

        if (this.state === ConnectState.CONNECTING) {
          this.loadingIcon()
        } else {
          this.powerIcon()
        }
      }
      .width(156)
      .height(156)
      .scale({ x: this.btnScale, y: this.btnScale })
      .onClick(() => {
        if (this.state === ConnectState.CONNECTING) {
          return;
        }
        this.playTapAnimation();
        this.onTap();
      })

      Text(this.getStateText())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Text(this.getStatusText())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private playTapAnimation(): void {
    this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
      this.btnScale = 0.92;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
        this.btnScale = 1.0;
        this.rippleOpacity = 0.6;
      });
      setTimeout(() => {
        this.getUIContext().animateTo({ duration: 400, curve: Curve.EaseOut }, () => {
          this.rippleOpacity = 0;
        });
      }, 300);
    }, 100);
  }
}
