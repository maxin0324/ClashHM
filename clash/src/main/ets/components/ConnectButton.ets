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

  private getIconText(): string {
    if (this.state === ConnectState.CONNECTED) {
      return '⚡';
    }
    return '▶';
  }

  build() {
    Column({ space: 16 }) {
      Stack() {
        // Ripple effect
        Circle()
          .width(160)
          .height(160)
          .fill(Color.Transparent)
          .stroke(this.getCircleColor())
          .strokeWidth(1.5)
          .opacity(this.rippleOpacity)

        // Outer ring
        Circle()
          .width(140)
          .height(140)
          .fill(Color.Transparent)
          .stroke(this.getCircleColor())
          .strokeWidth(2)
          .opacity(0.3)

        // Main circle
        Circle()
          .width(120)
          .height(120)
          .fill(this.getCircleColor())
          .shadow({
            radius: 20,
            color: this.getCircleColor(),
            offsetX: 0,
            offsetY: 4,
          })

        // Icon text
        Text(this.getIconText())
          .fontSize(40)
          .fontColor(Color.White)
      }
      .width(160)
      .height(160)
      .scale({ x: this.btnScale, y: this.btnScale })
      .onClick(() => {
        if (this.state === ConnectState.CONNECTING) {
          return;
        }
        this.playTapAnimation();
        this.onTap();
      })

      Text(this.getStateText())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Text(this.getStatusText())
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
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
