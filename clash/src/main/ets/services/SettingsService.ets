import { preferences } from '@kit.ArkData';
import { AppSettings, createDefaultSettings } from '../models/AppSettings';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';

export class SettingsService {
  private store: preferences.Preferences | null = null;
  private settings: AppSettings = createDefaultSettings();

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, 'settings_store');
    await this.load();
  }

  private async load(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      const data = await this.store.get(Constants.SETTINGS_KEY, '') as string;
      if (data) {
        const parsed = JSON.parse(data) as AppSettings;
        this.settings = parsed;
      }
    } catch (e) {
      Logger.error('Failed to load settings: %{public}s', String(e));
    }
  }

  async save(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(Constants.SETTINGS_KEY, JSON.stringify(this.settings));
      await this.store.flush();
    } catch (e) {
      Logger.error('Failed to save settings: %{public}s', String(e));
    }
  }

  getSettings(): AppSettings {
    return this.settings;
  }

  async update(key: string, value: string | boolean | number): Promise<void> {
    if (key === 'tunMode') this.settings.tunMode = value as boolean;
    else if (key === 'tunStack') this.settings.tunStack = value as string;
    else if (key === 'dnsMode') this.settings.dnsMode = value as string;
    else if (key === 'routingMode') this.settings.routingMode = value as string;
    else if (key === 'mixedPort') this.settings.mixedPort = value as number;
    else if (key === 'allowLan') this.settings.allowLan = value as boolean;
    else if (key === 'autoStart') this.settings.autoStart = value as boolean;
    else if (key === 'autoConnect') this.settings.autoConnect = value as boolean;
    else if (key === 'showNotification') this.settings.showNotification = value as boolean;
    else if (key === 'theme') this.settings.theme = value as string;
    else if (key === 'language') this.settings.language = value as string;
    else if (key === 'logLevel') this.settings.logLevel = value as string;
    await this.save();
  }
}
