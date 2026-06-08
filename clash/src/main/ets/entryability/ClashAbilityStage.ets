import { AbilityConstant, AbilityStage, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';

const DOMAIN = 0x0001;
const TAG = 'ClashHM';

export default class ClashAbilityStage extends AbilityStage {
  onCreate(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbilityStage onCreate');
  }

  onPrepareTermination(): AbilityConstant.PrepareTermination {
    hilog.info(DOMAIN, TAG, 'ClashAbilityStage onPrepareTermination');
    this.stopVpnExtension('stagePrepareTermination').catch((_e: Error) => {
      // vpn may already be stopped
    });
    return AbilityConstant.PrepareTermination.TERMINATE_IMMEDIATELY;
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbilityStage onDestroy');
    this.stopVpnExtension('stageDestroy').catch((_e: Error) => {
      // vpn may already be stopped
    });
  }

  private async stopVpnExtension(reason: string): Promise<void> {
    try {
      const want: Want = {
        bundleName: this.context.applicationInfo.name,
        moduleName: this.context.currentHapModuleInfo.name,
        abilityName: 'ClashVpnAbility',
      };
      await vpnExtension.stopVpnExtensionAbility(want);
      hilog.info(DOMAIN, TAG, 'ClashAbilityStage stopped VPN Extension, reason=%{public}s', reason);
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'ClashAbilityStage stop VPN skipped, reason=%{public}s error=%{public}s', reason, JSON.stringify(e));
    }
  }
}
