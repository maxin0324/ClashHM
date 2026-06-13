import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';
import { getClashService } from '../services/ClashService';

const DOMAIN = 0x0001;
const TAG = 'ClashHM';

export default class ClashAbility extends UIAbility {
  private cleanupStarted: boolean = false;

  private describeError(err: Error | Object | string | null | undefined): string {
    if (err === null || err === undefined) {
      return '';
    }
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode: %{public}s', this.describeError(err));
    }
    hilog.info(DOMAIN, TAG, 'ClashAbility onCreate');
  }

  async onDestroy(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'ClashAbility onDestroy');
    try {
      await this.cleanupRuntime('destroy');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ClashAbility cleanup failed: %{public}s', this.describeError(err));
    }
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
      await service.stop();
    } catch (_e) {
      // service not initialized or engine not running
    }

    try {
      const want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        moduleName: 'clash',
        abilityName: 'ClashVpnAbility',
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (_e) {
      // vpn may not be running
    }
  }

  private cleanupRuntimeLater(reason: string): void {
    try {
      this.cleanupRuntime(reason);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ClashAbility cleanup schedule failed: %{public}s', this.describeError(err));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageCreate');

    try {
      windowStage.getMainWindow((err, mainWindow) => {
        if (err.code) {
          hilog.warn(DOMAIN, TAG, 'Failed to get main window: %{public}s', this.describeError(err));
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
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'Immersive window setup skipped: %{public}s', this.describeError(err));
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Immersive window setup unavailable: %{public}s', this.describeError(err));
    }

    try {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', this.describeError(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Content loaded successfully');
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to start content load: %{public}s', this.describeError(err));
    }
  }

  onWindowStageWillDestroy(_windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageWillDestroy');
    this.cleanupRuntimeLater('windowStageWillDestroy');
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onWindowStageDestroy');
    this.cleanupRuntimeLater('windowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'ClashAbility onBackground');
  }
}
