import { preferences } from '@kit.ArkData';
import { AppSettings, createDefaultSettings } from '../models/AppSettings';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';

export class SettingsService {
  private store: preferences.Preferences | null = null;
  private settings: AppSettings = createDefaultSettings();

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, 'settings_store');
    } catch (e) {
      Logger.error('Failed to get settings store: %{public}s', String(e));
      return;
    }
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
        this.settings = this.mergeDefaults(parsed);
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

  private mergeDefaults(parsed: AppSettings): AppSettings {
    const defaults = createDefaultSettings();
    return {
      tunMode: parsed.tunMode === false ? false : (parsed.tunMode === true ? true : defaults.tunMode),
      tunStack: parsed.tunStack || defaults.tunStack,
      dnsMode: parsed.dnsMode || defaults.dnsMode,
      routingMode: parsed.routingMode || defaults.routingMode,
      mixedPort: parsed.mixedPort || defaults.mixedPort,
      allowLan: parsed.allowLan === true,
      autoStart: parsed.autoStart === true,
      autoConnect: parsed.autoConnect === true,
      showNotification: parsed.showNotification === false ? false : defaults.showNotification,
      theme: parsed.theme || defaults.theme,
      language: parsed.language || defaults.language,
      logLevel: parsed.logLevel || defaults.logLevel,
      tlsClientMode: parsed.tlsClientMode || defaults.tlsClientMode,
    };
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
    else if (key === 'tlsClientMode') this.settings.tlsClientMode = value as string;
    await this.save();
  }
}
