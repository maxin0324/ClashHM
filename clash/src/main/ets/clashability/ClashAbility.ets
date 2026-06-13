import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';
import { getClashService } from '../services/ClashService';

const DOMAIN = 0x0001;
const TAG = 'ClashHM';

export default class ClashAbility extends UIAbility {
  private cleanupStarted: boolean = false;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'ClashAbility onCreate');
  }

  async onDestroy(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'ClashAbility onDestroy');
    await this.cleanupRuntime('destroy');
  }

  private async cleanupRuntime(reason: string): Promise<void> {
    if (this.cleanupStarted) {
      hilog.info(DOMAIN, TAG, 'ClashAbility cleanup skipped, reason=%{public}s', reason);
      return;
    }
    this.cleanupStarted = true;
    hilog.info(DOMAIN, TAG, 'ClashAbility cleanup started, reason=%{public}s', reason);
    try {
      const service = getClashService();
      await service.stop().catch((_e: Error) => {
        // service may already be stopped
      });
    } catch (_e) {
      // service not initialized or engine not running
    }

    try {
      const want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        moduleName: 'clash',
        abilityName: 'ClashVpnAbility',
      };
      await vpnExtension.stopVpnExtensionAbility(want).catch((_e: Error) => {
        // vpn may not be running
      });
    } catch (_e) {
      // vpn may not be running
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageCreate');

    try {
      windowStage.getMainWindow((err, mainWindow) => {
        if (err.code) {
          hilog.warn(DOMAIN, TAG, 'Failed to get main window: %{public}s', JSON.stringify(err));
          return;
        }
        try {
          mainWindow.setWindowLayoutFullScreen(true);
          mainWindow.setWindowSystemBarProperties({
            statusBarColor: '#00000000',
            navigationBarColor: '#00000000',
            statusBarContentColor: '#000000',
            navigationBarContentColor: '#000000',
          });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'Immersive window setup skipped: %{public}s', JSON.stringify(e));
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Immersive window setup unavailable: %{public}s', JSON.stringify(e));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Content loaded successfully');
    });
  }

  onWindowStageWillDestroy(_windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageWillDestroy');
    this.cleanupRuntime('windowStageWillDestroy').catch((_e: Error) => {
      // cleanup may already be in progress
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageDestroy');
    this.cleanupRuntime('windowStageDestroy').catch((_e: Error) => {
      // cleanup may already be in progress
    });
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onBackground');
  }
}
