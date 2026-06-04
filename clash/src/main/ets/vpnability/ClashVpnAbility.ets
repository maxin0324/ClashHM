import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import clashNapi from 'libclash.so';

export default class ClashVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;

  onCreate(want: Want): void {
    Logger.info('ClashVpnAbility onCreate');

    this.startBackgroundTask();

    this.vpnConnection = vpnExtension.createVpnConnection(this.context);

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: '10.249.0.1' },
        prefixLength: 30,
      }],
      routes: [{
        interface: 'tun0',
        destination: {
          address: { address: '0.0.0.0' },
          prefixLength: 0,
        },
        gateway: { address: '10.249.0.2' },
        hasGateway: true,
        isDefaultRoute: true,
      }],
      dnsAddresses: ['1.1.1.1', '8.8.8.8'],
      mtu: 9000,
      trustedApplications: [],
      blockedApplications: [],
    };

    this.vpnConnection.create(vpnConfig).then((tunFd: number) => {
      this.tunFd = tunFd;
      Logger.info('VPN TUN created, fd=%{public}d', String(tunFd));
      clashNapi.setTunFd(tunFd);
    }).catch((err: Error) => {
      Logger.error('Failed to create VPN: %{public}s', err.message);
    });
  }

  onDestroy(): void {
    Logger.info('ClashVpnAbility onDestroy');
    this.stopBackgroundTask();
    if (this.vpnConnection) {
      this.vpnConnection.destroy();
      this.vpnConnection = null;
    }
    this.tunFd = -1;
  }

  private startBackgroundTask(): void {
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: 'ClashAbility',
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };

      wantAgent.getWantAgent(wantAgentInfo).then((agent: WantAgent) => {
        backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        Logger.info('Background task started');
      }).catch((err: Error) => {
        Logger.error('Failed to get want agent: %{public}s', err.message);
      });
    } catch (e) {
      Logger.error('Failed to start background task: %{public}s', String(e));
    }
  }

  private stopBackgroundTask(): void {
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (_e) {
      // ignore
    }
  }
}
