import { ConnectButton } from '../components/ConnectButton';
import { TrafficStats } from '../components/TrafficStats';
import { getClashService, IClashService } from '../services/ClashService';
import { NapiClashService } from '../services/NapiClashService';
import { ConnectState, ConnectionMode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { TrafficMonitor } from '../services/TrafficMonitor';
import { SubscriptionService } from '../services/SubscriptionService';
import { vpnExtension } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Logger } from '../common/Logger';

@Component
export struct HomePage {
  @State connectState: string = ConnectState.DISCONNECTED;
  @State traffic: TrafficData = createEmptyTraffic();
  @State currentMode: string = ConnectionMode.RULE;
  @State profileName: string = 'No Profile';
  @State errorMsg: string = '';
  private service: IClashService | null = null;
  private trafficMonitor: TrafficMonitor = new TrafficMonitor();

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.connectState = this.service.getState();
      this.currentMode = this.service.getMode();
    } catch (_e) {
      // service not ready
    }
    this.trafficMonitor.setCallback((data: TrafficData) => {
      this.traffic = data;
    });
  }

  aboutToDisappear(): void {
    this.trafficMonitor.stop();
  }

  private async toggleConnection(): Promise<void> {
    if (!this.service) {
      return;
    }

    if (this.connectState === ConnectState.DISCONNECTED) {
      this.connectState = ConnectState.CONNECTING;
      this.errorMsg = '';
      try {
        const context = getContext(this) as common.UIAbilityContext;

        // Find active subscription config first
        const subService = new SubscriptionService(context);
        await subService.init();
        const activeSub = subService.getActiveSubscription();
        if (!activeSub || !activeSub.filePath) {
          this.errorMsg = 'No active subscription. Add one first.';
          this.connectState = ConnectState.DISCONNECTED;
          return;
        }
        this.profileName = activeSub.name;

        // Start VPN Extension
        const want: Want = {
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'ClashVpnAbility',
        };
        try {
          await vpnExtension.startVpnExtensionAbility(want);
          Logger.info('VPN Extension started');
        } catch (e) {
          Logger.error('Failed to start VPN: %{public}s', String(e));
        }

        // Wait for VPN to create TUN and set fd via NAPI
        await new Promise<void>((resolve) => setTimeout(resolve, 1500));

        // Start engine with config
        await this.service.start(activeSub.filePath);
        this.connectState = ConnectState.CONNECTED;
        this.trafficMonitor.start();
      } catch (e) {
        this.errorMsg = `Connection failed: ${String(e)}`;
        Logger.error('Connection failed: %{public}s', String(e));
        this.connectState = ConnectState.DISCONNECTED;
      }
    } else if (this.connectState === ConnectState.CONNECTED) {
      await this.service.stop();
      this.trafficMonitor.stop();
      this.traffic = createEmptyTraffic();
      this.connectState = ConnectState.DISCONNECTED;

      // Stop VPN Extension
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const want: Want = {
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'ClashVpnAbility',
        };
        await vpnExtension.stopVpnExtensionAbility(want);
      } catch (e) {
        Logger.error('Failed to stop VPN: %{public}s', String(e));
      }
    }
  }

  private async switchMode(mode: ConnectionMode): Promise<void> {
    if (this.service) {
      await this.service.setMode(mode);
      this.currentMode = mode;
    }
  }

  build() {
    Column() {
      // Top bar
      Row() {
        Text('ClashHM')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Blank()

        Text('⋮')
          .fontSize(24)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/LogPage' });
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      // Profile name
      Row() {
        Text('▸')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text(this.profileName)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 6 })
      }
      .margin({ bottom: 8 })

      // Mode selector
      Row({ space: 0 }) {
        ForEach(
          [
            new ModeItem(ConnectionMode.RULE, 'Rule'),
            new ModeItem(ConnectionMode.GLOBAL, 'Global'),
            new ModeItem(ConnectionMode.DIRECT, 'Direct'),
          ] as ModeItem[],
          (item: ModeItem) => {
            Text(item.label)
              .fontSize(13)
              .fontWeight(this.currentMode === item.mode ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.currentMode === item.mode ? Color.White : $r('app.color.text_secondary'))
              .backgroundColor(this.currentMode === item.mode ? $r('app.color.primary') : Color.Transparent)
              .borderRadius(16)
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.switchMode(item.mode as ConnectionMode);
              })
          },
          (item: ModeItem) => item.mode
        )
      }
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(20)
      .padding(3)
      .margin({ bottom: 32 })

      // Connect button
      ConnectButton({
        state: this.connectState,
        onTap: () => {
          this.toggleConnection();
        }
      })

      if (this.errorMsg) {
        Text(this.errorMsg)
          .fontSize(13)
          .fontColor($r('app.color.error_color'))
          .textAlign(TextAlign.Center)
          .padding({ left: 20, right: 20, top: 12 })
          .maxLines(2)
      }

      Blank()
        .layoutWeight(1)

      // Traffic stats
      TrafficStats({
        uploadSpeed: this.traffic.uploadSpeed,
        downloadSpeed: this.traffic.downloadSpeed,
        sessionUpload: this.traffic.sessionUpload,
        sessionDownload: this.traffic.sessionDownload,
        activeConnections: this.traffic.activeConnections,
      })
      .padding({ left: 16, right: 16, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
  }
}

class ModeItem {
  mode: string;
  label: string;

  constructor(mode: string, label: string) {
    this.mode = mode;
    this.label = label;
  }
}
