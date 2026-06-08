import { AppSettings, createDefaultSettings } from '../models/AppSettings';
import { SettingsService } from '../services/SettingsService';
import { common } from '@kit.AbilityKit';

@Component
export struct SettingsPage {
  @State settings: AppSettings = createDefaultSettings();
  @State isLoaded: boolean = false;
  private settingsService: SettingsService = new SettingsService();

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.settingsService.init(context);
    this.settings = this.settingsService.getSettings();
    this.isLoaded = true;
  }

  private async updateSetting(key: string, value: string | boolean | number): Promise<void> {
    await this.settingsService.update(key, value);
    this.settings = this.settingsService.getSettings();
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text($r('app.string.tab_settings'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('Core, network, and app preferences')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      List({ space: 0 }) {
        ListItem() {
          this.sectionHeader($r('app.string.settings_core'))
        }

        ListItem() {
          this.toggleItem($r('app.string.settings_tun'), this.settings.tunMode, (val: boolean) => {
            this.updateSetting('tunMode', val);
          })
        }

        ListItem() {
          this.selectorItem($r('app.string.settings_dns'), this.settings.dnsMode, ['fake-ip', 'redir-host'], (val: string) => {
            this.updateSetting('dnsMode', val);
          })
        }

        ListItem() {
          this.selectorItem($r('app.string.settings_log_level'), this.settings.logLevel, ['silent', 'error', 'warning', 'info', 'debug'], (val: string) => {
            this.updateSetting('logLevel', val);
          })
        }

        ListItem() {
          this.selectorItem('TLS Client', this.settings.tlsClientMode, ['chrome', 'rustls'], (val: string) => {
            this.updateSetting('tlsClientMode', val);
          })
        }

        ListItem() {
          this.sectionHeader($r('app.string.settings_network'))
        }

        ListItem() {
          this.valueItem($r('app.string.settings_port'), `${this.settings.mixedPort}`)
        }

        ListItem() {
          this.toggleItem($r('app.string.settings_allow_lan'), this.settings.allowLan, (val: boolean) => {
            this.updateSetting('allowLan', val);
          })
        }

        ListItem() {
          this.selectorItem($r('app.string.settings_routing'), this.settings.routingMode, ['rule', 'global', 'direct'], (val: string) => {
            this.updateSetting('routingMode', val);
          })
        }

        ListItem() {
          this.sectionHeader($r('app.string.settings_general'))
        }

        ListItem() {
          this.toggleItem($r('app.string.settings_auto_start'), this.settings.autoStart, (val: boolean) => {
            this.updateSetting('autoStart', val);
          })
        }

        ListItem() {
          this.selectorItem($r('app.string.settings_theme'), this.settings.theme, ['system', 'light', 'dark'], (val: string) => {
            this.updateSetting('theme', val);
          })
        }

        ListItem() {
          this.selectorItem($r('app.string.settings_language'), this.settings.language, ['system', 'zh_CN', 'en_US'], (val: string) => {
            this.updateSetting('language', val);
          })
        }

        ListItem() {
          this.sectionHeader($r('app.string.settings_about'))
        }

        ListItem() {
          this.valueItem($r('app.string.settings_version'), '1.0.0')
        }

        ListItem() {
          this.valueItem('Core', 'Extension native-core')
        }

        ListItem() {
          this.valueItem('Platform', 'HarmonyOS NEXT')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 14 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  sectionHeader(title: Resource) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.primary'))
      .width('100%')
      .padding({ left: 2, top: 18, bottom: 8 })
  }

  @Builder
  toggleItem(title: Resource, value: boolean, onChange: (val: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor($r('app.color.primary'))
        .onChange((isOn: boolean) => {
          onChange(isOn);
        })
    }
    .width('100%')
    .height(54)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  selectorItem(title: ResourceStr, current: string, options: string[], onChange: (val: string) => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Select(options.map((opt: string): SelectOption => { return { value: opt } as SelectOption; }))
        .value(current)
        .font({ size: 14 })
        .fontColor($r('app.color.text_secondary'))
        .selectedOptionFont({ size: 14 })
        .optionFont({ size: 14 })
        .onSelect((_index: number, value: string) => {
          onChange(value);
        })
    }
    .width('100%')
    .height(54)
    .padding({ left: 16, right: 8 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  valueItem(title: ResourceStr, value: string) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height(54)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
  }
}
