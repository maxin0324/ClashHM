import { ConnectButton } from '../components/ConnectButton';
import { TrafficStats } from '../components/TrafficStats';
import { getClashService, IClashService } from '../services/ClashService';
import { ConnectState, ConnectionMode, ProxyGroup } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { TrafficMonitor } from '../services/TrafficMonitor';
import { SubscriptionService } from '../services/SubscriptionService';
import { ConfigManager } from '../services/ConfigManager';
import { ProxySelectionService } from '../services/ProxySelectionService';
import { NativeCoreExtensionService } from '../services/NativeCoreExtensionService';
import { vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { common, Want } from '@kit.AbilityKit';
import { pasteboard, commonEventManager } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';

class NativeCoreStatusInfo {
  running: boolean = false;
  engine: string = '';
  status: string = '';
}

@Component
export struct HomePage {
  @State connectState: string = ConnectState.DISCONNECTED;
  @State traffic: TrafficData = createEmptyTraffic();
  @State currentMode: string = ConnectionMode.RULE;
  @State profileName: string = 'No Profile';
  @State selectedProxyGroup: string = 'Proxy';
  @State selectedProxyName: string = 'Not selected';
  @State errorMsg: string = '';
  @State showErrorDetail: boolean = false;
  @State copyStatus: string = '';
  private service: IClashService | null = null;
  private trafficMonitor: TrafficMonitor = new TrafficMonitor();
  private proxySelectionSubscriber: commonEventManager.CommonEventSubscriber | null = null;

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.connectState = this.service.getState();
      this.currentMode = this.service.getMode();
    } catch (_e) {
      // service not ready
    }
    this.refreshProfileSummary();
    this.refreshExtensionConnectionState();
    this.subscribeProxySelectionChanged();
    this.trafficMonitor.setCallback((data: TrafficData) => {
      this.traffic = data;
    });
  }

  aboutToDisappear(): void {
    this.trafficMonitor.stop();
    this.unsubscribeProxySelectionChanged();
  }

  private subscribeProxySelectionChanged(): void {
    if (this.proxySelectionSubscriber) {
      return;
    }
    try {
      const subscriber = commonEventManager.createSubscriberSync({
        events: ['com.mx.clashhm.PROXY_SELECTION_CHANGED'],
      });
      this.proxySelectionSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (_err, _data) => {
        this.refreshProfileSummary();
      });
    } catch (e) {
      Logger.error('Subscribe proxy selection failed: %{public}s', String(e));
    }
  }

  private unsubscribeProxySelectionChanged(): void {
    if (!this.proxySelectionSubscriber) {
      return;
    }
    commonEventManager.unsubscribe(this.proxySelectionSubscriber);
    this.proxySelectionSubscriber = null;
  }

  private async toggleConnection(): Promise<void> {
    if (!this.service) {
      return;
    }

    if (this.connectState === ConnectState.DISCONNECTED) {
      this.connectState = ConnectState.CONNECTING;
      this.errorMsg = '';
      this.copyStatus = '';
      this.showErrorDetail = false;
      let context: common.UIAbilityContext | null = null;
      try {
        context = this.getUIContext().getHostContext() as common.UIAbilityContext;

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

        // Check if config file exists, update if not
        let configExists = false;
        try {
          configExists = fileIo.accessSync(activeSub.filePath);
        } catch (_e) {
          configExists = false;
        }
        if (!configExists) {
          Logger.info('Config file missing, updating subscription...');
          await subService.updateSubscription(activeSub.id);
        }

        // Start VPN Extension
        const vpnStatusPath = `${context.filesDir}/vpn-engine-status.txt`;
        const vpnStartConfigPath = `${context.filesDir}/vpn-start-config.txt`;
        await this.stopVpnExtension(context);

        const nativeCoreConfig = new ConfigManager(context).generateMergedConfig(activeSub.filePath);
        if (!nativeCoreConfig) {
          throw new Error(`Failed to read active subscription config: ${activeSub.filePath}`);
        }
        const configSession = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
        const vpnStatusEvent = `com.mx.clashhm.VPN_STATUS_${configSession}`;
        const vpnStatusMessages: string[] = [];
        const vpnStatusSubscriber = commonEventManager.createSubscriberSync({
          events: [vpnStatusEvent],
        });
        commonEventManager.subscribe(vpnStatusSubscriber, (err, data) => {
          if (err) {
            this.writeConnectionStatus(vpnStatusPath, `ui vpn status event error: ${this.describeError(err)}`);
            return;
          }
          const message = data.data || '';
          if (message) {
            vpnStatusMessages.push(message);
            this.writeConnectionStatus(vpnStatusPath, `vpn ${message}`);
          }
        });
        const chunkSize = 30000;
        const coreChunkCount = Math.ceil(nativeCoreConfig.length / chunkSize);
        this.writeTextFile(vpnStartConfigPath, activeSub.filePath);
        this.writeTextFile(vpnStatusPath, `${new Date().toISOString()} ui starting vpn extension config=${activeSub.filePath} nativeCoreChunks=${coreChunkCount}`);
        try {
          const want: Want = {
            deviceId: '',
            bundleName: context.abilityInfo.bundleName,
            moduleName: 'clash',
            abilityName: 'ClashVpnAbility',
            parameters: {
              configPath: activeSub.filePath,
              statusPath: vpnStatusPath,
              statusEvent: vpnStatusEvent,
              startConfigPath: vpnStartConfigPath,
              configSession,
              configChunkCount: 0,
              coreConfigChunkCount: coreChunkCount,
            },
          };
          await vpnExtension.startVpnExtensionAbility(want);
          this.writeConnectionStatus(vpnStatusPath, 'ui startVpnExtensionAbility returned');
          await this.waitForVpnStatus(vpnStatusMessages, 'config subscriber ready', 5000);
          for (let i = 0; i < coreChunkCount; i++) {
            const chunk = nativeCoreConfig.substring(i * chunkSize, Math.min(nativeCoreConfig.length, (i + 1) * chunkSize));
            await this.publishConfigChunk(context.abilityInfo.bundleName, configSession, i, coreChunkCount, chunk, 'core');
            this.writeConnectionStatus(vpnStatusPath, `ui core config chunk published ${i + 1}/${coreChunkCount}`);
          }
          Logger.info('VPN Extension started and config chunks published');
          this.writeConnectionStatus(vpnStatusPath, 'ui native-core config chunks published');
          await this.waitForVpnStartResult(vpnStatusMessages, 15000);
          if (this.hasNativeCoreStarted(vpnStatusMessages)) {
            await this.applySavedProxySelectionsToExtension(context);
          }
        } catch (e) {
          const startError = this.describeError(e);
          this.writeConnectionStatus(vpnStatusPath, `ui startVpnExtensionAbility failed: ${startError}`);
          Logger.error('Failed to start VPN: %{public}s', startError);
          throw new Error(`Failed to start VPN Extension: ${startError}`);
        } finally {
          commonEventManager.unsubscribe(vpnStatusSubscriber);
        }

        this.service.setVpnConnected(true);
        this.connectState = this.service.getState();
        this.refreshProfileSummary();
        this.trafficMonitor.start();
      } catch (e) {
        if (context) {
          await this.stopVpnExtension(context);
        }
        if (this.service) {
          this.service.setVpnConnected(false);
        }
        const errorText = this.describeError(e);
        this.errorMsg = `Connection failed: ${errorText}`;
        Logger.error('Connection failed: %{public}s', errorText);
        this.connectState = this.service ? this.service.getState() : ConnectState.DISCONNECTED;
      }
    } else if (this.connectState === ConnectState.CONNECTED) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await this.stopVpnExtension(context);
      } catch (e) {
        Logger.error('Failed to stop VPN: %{public}s', String(e));
      }

      this.service.setVpnConnected(false);
      this.trafficMonitor.stop();
      this.traffic = createEmptyTraffic();
      this.connectState = this.service.getState();
      this.copyStatus = '';
      this.refreshProfileSummary();
    }
  }

  private async refreshProfileSummary(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const subService = new SubscriptionService(context);
      await subService.init();
      const activeSub = subService.getActiveSubscription();
      if (!activeSub || !activeSub.filePath) {
        this.profileName = 'No Profile';
        this.selectedProxyGroup = 'Proxy';
        this.selectedProxyName = 'Not selected';
        return;
      }

      this.profileName = activeSub.name;
      const selectionService = new ProxySelectionService();
      await selectionService.init(context);
      const selections = selectionService.getSelections();
      const configManager = new ConfigManager(context);
      const mergedConfig = configManager.generateMergedConfig(activeSub.filePath);
      const groups = configManager.parseProxyGroupsFromContent(mergedConfig);
      let selectedGroup = '';
      let selectedProxy = '';

      for (const group of groups) {
        const saved = selectionService.getSelection(group.name);
        if (saved && group.all.indexOf(saved) >= 0) {
          selectedGroup = group.name;
          selectedProxy = saved;
          if (this.isPrimaryProxyGroup(group.name)) {
            break;
          }
        }
      }

      if (!selectedProxy) {
        const group = this.pickPrimaryProxyGroup(groups);
        if (group) {
          selectedGroup = group.name;
          selectedProxy = group.now || (group.all.length > 0 ? group.all[0] : '');
        }
      }

      if (!selectedProxy && selections.length > 0) {
        selectedGroup = selections[0].groupName;
        selectedProxy = selections[0].proxyName;
      }

      this.selectedProxyGroup = selectedGroup || 'Proxy';
      this.selectedProxyName = selectedProxy || 'Not selected';
    } catch (e) {
      Logger.error('Failed to refresh profile summary: %{public}s', String(e));
    }
  }

  private async refreshExtensionConnectionState(): Promise<void> {
    if (!this.service) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await new NativeCoreExtensionService(context).getStatus();
      if (!result.ok || !result.data) {
        return;
      }
      const status = JSON.parse(result.data) as NativeCoreStatusInfo;
      if (status.running) {
        this.service.setVpnConnected(true);
        this.connectState = this.service.getState();
        this.trafficMonitor.start();
      }
    } catch (e) {
      Logger.info('VPN Extension status unavailable on page appear: %{public}s', this.describeError(e));
    }
  }

  private pickPrimaryProxyGroup(groups: ProxyGroup[]): ProxyGroup | null {
    let best: ProxyGroup | null = null;
    let bestScore = -1;
    for (const group of groups) {
      let score = group.nodes.length;
      if (this.isPrimaryProxyGroup(group.name)) {
        score += 10000;
      }
      if (score > bestScore) {
        best = group;
        bestScore = score;
      }
    }
    return best;
  }

  private isPrimaryProxyGroup(name: string): boolean {
    const lower = name.toLowerCase();
    return lower === 'proxy' ||
      lower === 'global' ||
      lower.indexOf('select') >= 0 ||
      lower.indexOf('node') >= 0 ||
      name.indexOf('节点') >= 0 ||
      name.indexOf('选择') >= 0;
  }

  private async applySavedProxySelectionsToExtension(context: common.UIAbilityContext): Promise<void> {
    try {
      const selectionService = new ProxySelectionService();
      await selectionService.init(context);
      const selections = selectionService.getSelections();
      const extensionService = new NativeCoreExtensionService(context);
      for (const selection of selections) {
        if (selection.groupName && selection.proxyName) {
          await extensionService.selectProxy(selection.groupName, selection.proxyName);
        }
      }
    } catch (e) {
      Logger.error('Failed to apply extension proxy selections: %{public}s', String(e));
    }
  }

  private async stopVpnExtension(context: common.UIAbilityContext): Promise<void> {
    try {
      const want: Want = {
        deviceId: '',
        bundleName: context.abilityInfo.bundleName,
        moduleName: 'clash',
        abilityName: 'ClashVpnAbility',
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      Logger.error('Failed to stop VPN Extension: %{public}s', this.describeError(e));
    }
  }

  private async switchMode(mode: ConnectionMode): Promise<void> {
    if (this.service) {
      await this.service.setMode(mode);
      this.currentMode = mode;
    }
  }

  private async copyError(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.errorMsg);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copyStatus = 'Copied';
    } catch (e) {
      this.copyStatus = `Copy failed: ${String(e)}`;
      Logger.error('Copy connection error failed: %{public}s', String(e));
    }
  }

  private publishConfigChunk(bundleName: string, session: string, index: number, count: number, data: string, kind: string): Promise<void> {
    return new Promise((resolve, reject) => {
      commonEventManager.publish('com.mx.clashhm.CONFIG_CHUNK', {
        bundleName,
        data,
        parameters: {
          configSession: session,
          configChunkIndex: index,
          configChunkCount: count,
          configKind: kind,
        },
      }, (err) => {
        if (err) {
          reject(new Error(this.describeError(err)));
          return;
        }
        resolve();
      });
    });
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private async waitForVpnStatus(messages: string[], expected: string, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const message of messages) {
        if (message.indexOf(expected) >= 0) {
          return;
        }
      }
      await this.delay(100);
    }
    const recent = messages.length > 0 ? messages.slice(Math.max(0, messages.length - 30)).join('\n') : 'no vpn status events received';
    throw new Error(`VPN Extension did not report "${expected}" within ${timeoutMs}ms; recentVpnStatus=\n${recent}`);
  }

  private async waitForVpnStartResult(messages: string[], timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const message of messages) {
        const resultIndex = message.indexOf('start result:');
        if (resultIndex < 0) {
          continue;
        }
        const result = message.substring(resultIndex).trim();
        if (result.indexOf('start result: started') >= 0 ||
          result.indexOf('start result: already_running') >= 0 ||
          result.indexOf('start result: native_core_started') >= 0) {
          return;
        }
        throw new Error(result);
      }
      await this.delay(100);
    }
    const recent = messages.length > 0 ? messages.slice(Math.max(0, messages.length - 30)).join('\n') : 'no vpn status events received';
    throw new Error(`VPN Extension did not report start result within ${timeoutMs}ms; recentVpnStatus=\n${recent}`);
  }

  private hasNativeCoreStarted(messages: string[]): boolean {
    for (const message of messages) {
      if (message.indexOf('start result: native_core_started') >= 0) {
        return true;
      }
    }
    return false;
  }

  private describeError(error: Object | string): string {
    if (error instanceof Error) {
      return error.message;
    }
    const text = String(error);
    if (text !== '[object Object]') {
      return text;
    }
    try {
      return JSON.stringify(error);
    } catch (_e) {
      return text;
    }
  }

  private writeConnectionStatus(path: string, message: string): void {
    const oldText = this.readTextFile(path);
    const nextText = oldText ? `${oldText}\n${new Date().toISOString()} ${message}` : `${new Date().toISOString()} ${message}`;
    this.writeTextFile(path, nextText);
  }

  private writeTextFile(path: string, text: string): void {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (e) {
      Logger.error('Failed to write file: %{public}s', this.describeError(e));
    }
  }

  private readTextFile(path: string): string {
    try {
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const bytes = new Uint8Array(buffer);
      let text = '';
      for (let i = 0; i < bytes.length; i++) {
        text += String.fromCharCode(bytes[i]);
      }
      return text;
    } catch (_e) {
      return '';
    }
  }

  build() {
    Column() {
      Row() {
        Image($r('app.media.app_logo'))
          .width(42)
          .height(42)
          .borderRadius(10)
          .margin({ right: 12 })

        Column({ space: 4 }) {
          Text('ClashHM')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.profileName)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('Logs')
          .height(34)
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(8)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/LogPage' });
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      Column({ space: 18 }) {
        ConnectButton({
          state: this.connectState,
          onTap: () => {
            this.toggleConnection();
          }
        })

        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.selectedProxyGroup)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selectedProxyName)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('Proxy')
            .fontSize(12)
            .fontColor($r('app.color.primary'))
            .height(30)
            .padding({ left: 12, right: 12, top: 7 })
            .backgroundColor($r('app.color.page_bg'))
            .borderRadius(7)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.page_bg'))
        .borderRadius(8)

        if (this.errorMsg) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text('Connection error')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.error_color'))
                .layoutWeight(1)

              Button('Copy')
                .height(28)
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(7)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.copyError();
                })

              Button(this.showErrorDetail ? 'Hide' : 'Details')
                .height(28)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(7)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.showErrorDetail = !this.showErrorDetail;
                })
            }

            if (!this.showErrorDetail) {
              Text(this.errorMsg)
                .fontSize(12)
                .fontColor($r('app.color.error_color'))
                .width('100%')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .copyOption(CopyOptions.LocalDevice)
            }

            if (this.copyStatus) {
              Text(this.copyStatus)
                .fontSize(10)
                .fontColor(this.copyStatus === 'Copied' ? $r('app.color.connected_color') : $r('app.color.error_color'))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }

            if (this.showErrorDetail) {
              TextArea({ text: this.errorMsg })
                .width('100%')
                .height(112)
                .fontSize(11)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(8)
                .copyOption(CopyOptions.LocalDevice)
                .enabled(true)
            }
          }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.page_bg'))
            .borderRadius(8)
        }

        Row({ space: 8 }) {
          ForEach(
            [
              new ModeItem(ConnectionMode.RULE, 'Rule'),
              new ModeItem(ConnectionMode.GLOBAL, 'Global'),
              new ModeItem(ConnectionMode.DIRECT, 'Direct'),
            ] as ModeItem[],
            (item: ModeItem) => {
              Text(item.label)
                .fontSize(13)
                .fontWeight(this.currentMode === item.mode ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.currentMode === item.mode ? Color.White : $r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(34)
                .padding({ top: 8 })
                .backgroundColor(this.currentMode === item.mode ? $r('app.color.primary') : $r('app.color.page_bg'))
                .borderRadius(7)
                .onClick(() => {
                  this.switchMode(item.mode as ConnectionMode);
                })
            },
            (item: ModeItem) => item.mode
          )
        }
        .width('100%')
      }
      .width('100%')
      .padding(18)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(8)
      .border({ width: 1, color: $r('app.color.divider') })
      .margin({ left: 16, right: 16, bottom: 14 })

      TrafficStats({
        uploadSpeed: this.traffic.uploadSpeed,
        downloadSpeed: this.traffic.downloadSpeed,
        sessionUpload: this.traffic.sessionUpload,
        sessionDownload: this.traffic.sessionDownload,
        activeConnections: this.traffic.activeConnections,
      })
      .padding({ left: 16, right: 16 })

      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
    .onAppear(() => {
      this.refreshProfileSummary();
    })
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
