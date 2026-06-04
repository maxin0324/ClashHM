import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';

const DOMAIN = 0x0001;
const TAG = 'ClashHM';

export default class ClashAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'ClashAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onDestroy');

    // Stop mihomo engine via NAPI
    try {
      const clashNapi = (globalThis as Record<string, Object>)['clashNapi'];
      if (clashNapi && typeof (clashNapi as Record<string, Function>)['stop'] === 'function') {
        (clashNapi as Record<string, Function>)['stop']();
      }
    } catch (_e) {
      // engine may not be running
    }

    // Stop VPN Extension
    try {
      const want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'ClashVpnAbility',
      };
      vpnExtension.stopVpnExtensionAbility(want);
    } catch (_e) {
      // vpn may not be running
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Content loaded successfully');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onBackground');
  }
}
