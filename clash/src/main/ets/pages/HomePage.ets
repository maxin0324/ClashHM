import { ConnectButton } from '../components/ConnectButton';
import { TrafficStats } from '../components/TrafficStats';
import { getClashService, IClashService } from '../services/ClashService';
import { ConnectState, ConnectionMode, ProxyGroup, ProxyNode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { TrafficMonitor } from '../services/TrafficMonitor';
import { SubscriptionService } from '../services/SubscriptionService';
import { ConfigManager } from '../services/ConfigManager';
import { ProxySelectionService } from '../services/ProxySelectionService';
import { NativeCoreExtensionService } from '../services/NativeCoreExtensionService';
import { SettingsService } from '../services/SettingsService';
import { callNativeCoreParseProxies } from '../services/NativeClash';
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

interface ParsedProxyNode {
  name?: string;
  type?: string;
  alive?: boolean;
  latency?: number;
}

interface ParsedProxyGroup {
  name?: string;
  type?: string;
  now?: string;
  all?: string[];
  nodes?: ParsedProxyNode[];
}

@Component
export struct HomePage {
  @State connectState: string = ConnectState.DISCONNECTED;
  @State traffic: TrafficData = createEmptyTraffic();
  @State currentMode: string = ConnectionMode.RULE;
  @State profileName: ResourceStr = $r('app.string.no_profile');
  @State selectedProxyGroup: string = 'Proxy';
  @State selectedProxyName: ResourceStr = $r('app.string.not_selected');
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
        await this.delay(300);

        const nativeCoreConfig = await this.generateNativeCoreConfig(context, activeSub.filePath);
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
          const configSubscriberReady = await this.waitForVpnStatusOrFile(vpnStatusMessages, vpnStatusPath, 'config subscriber ready', 2000);
          for (let i = 0; i < coreChunkCount; i++) {
            const chunk = nativeCoreConfig.substring(i * chunkSize, Math.min(nativeCoreConfig.length, (i + 1) * chunkSize));
            if (configSubscriberReady) {
              await this.publishConfigChunk(context.abilityInfo.bundleName, configSession, i, coreChunkCount, chunk, 'core');
              this.writeConnectionStatus(vpnStatusPath, `ui core config chunk published ${i + 1}/${coreChunkCount}`);
            } else {
              await this.sendConfigChunkByWant(context, activeSub.filePath, vpnStatusPath, vpnStatusEvent, vpnStartConfigPath, configSession, i, coreChunkCount, chunk);
              this.writeConnectionStatus(vpnStatusPath, `ui core config chunk sent by request ${i + 1}/${coreChunkCount}`);
            }
          }
          Logger.info('VPN Extension started and config chunks published');
          this.writeConnectionStatus(vpnStatusPath, 'ui native-core config chunks published');
          await this.waitForVpnStartResult(vpnStatusMessages, vpnStatusPath, context, 15000);
          await this.applySavedProxySelectionsToExtension(context);
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

  private async generateNativeCoreConfig(context: common.UIAbilityContext, configPath: string): Promise<string> {
    const nativeCoreConfig = new ConfigManager(context).generateMergedConfig(configPath);
    if (!nativeCoreConfig) {
      return nativeCoreConfig;
    }
    const settingsService = new SettingsService();
    await settingsService.init(context);
    const tlsClientMode = settingsService.getSettings().tlsClientMode === 'rustls' ? 'rustls' : 'chrome';
    return `clashhm:\n  tls-client: ${tlsClientMode}\n` + nativeCoreConfig;
  }

  private async refreshProfileSummary(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const subService = new SubscriptionService(context);
      await subService.init();
      const activeSub = subService.getActiveSubscription();
      if (!activeSub || !activeSub.filePath) {
        this.profileName = $r('app.string.no_profile');
        this.selectedProxyGroup = 'Proxy';
        this.selectedProxyName = $r('app.string.not_selected');
        return;
      }

      this.profileName = activeSub.name;

      if (this.service && this.service.getState() === ConnectState.CONNECTED) {
        const extensionGroups = await this.loadExtensionProxyGroupsForSummary(context);
        const extensionGroup = this.pickPrimaryProxyGroup(extensionGroups);
        if (extensionGroup) {
          this.selectedProxyGroup = extensionGroup.name;
          this.selectedProxyName = extensionGroup.now || (extensionGroup.all.length > 0 ? extensionGroup.all[0] : $r('app.string.not_selected'));
          return;
        }
      }

      const selectionService = new ProxySelectionService();
      await selectionService.init(context);
      const selections = selectionService.getSelections();
      const configManager = new ConfigManager(context);
      const mergedConfig = configManager.generateMergedConfig(activeSub.filePath);
      const groups = this.parseProxyGroupsForSummary(mergedConfig, configManager);
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
      this.selectedProxyName = selectedProxy || $r('app.string.not_selected');
    } catch (e) {
      Logger.error('Failed to refresh profile summary: %{public}s', String(e));
    }
  }

  private parseProxyGroupsForSummary(configText: string, configManager: ConfigManager): ProxyGroup[] {
    if (configText) {
      try {
        const data = callNativeCoreParseProxies(configText);
        if (data) {
          const parsed = JSON.parse(data) as ParsedProxyGroup[];
          const groups = this.mapParsedProxyGroups(parsed);
          if (groups.length > 0) {
            return groups;
          }
        }
      } catch (e) {
        Logger.info('Native proxy summary parser unavailable: %{public}s', String(e));
      }
    }
    return configManager.parseProxyGroupsFromContent(configText);
  }

  private async loadExtensionProxyGroupsForSummary(context: common.UIAbilityContext): Promise<ProxyGroup[]> {
    try {
      const result = await new NativeCoreExtensionService(context).getProxies();
      if (!result.ok || !result.data) {
        return [];
      }
      const parsed = JSON.parse(result.data) as ParsedProxyGroup[];
      return this.mapParsedProxyGroups(parsed);
    } catch (e) {
      Logger.info('Extension proxy summary unavailable: %{public}s', String(e));
      return [];
    }
  }

  private mapParsedProxyGroups(groups: ParsedProxyGroup[]): ProxyGroup[] {
    const mapped: ProxyGroup[] = [];
    for (const group of groups) {
      const groupName = group.name === undefined ? '' : group.name;
      const all = group.all === undefined ? [] : group.all;
      if (!groupName || all.length === 0) {
        continue;
      }
      const parsedNodes = group.nodes === undefined ? [] : group.nodes;
      const nodes: ProxyNode[] = parsedNodes.map((node: ParsedProxyNode) => {
        const mappedNode: ProxyNode = {
          name: node.name === undefined ? '' : node.name,
          type: node.type === undefined || node.type === '' ? 'proxy' : node.type,
          server: '',
          port: 0,
          latency: node.latency === undefined ? -1 : node.latency,
          alive: node.alive === undefined ? true : node.alive,
        };
        return mappedNode;
      });
      const mappedGroup: ProxyGroup = {
        name: groupName,
        type: group.type === undefined || group.type === '' ? 'select' : group.type,
        now: group.now === undefined || group.now === '' ? all[0] : group.now,
        all,
        nodes,
        expanded: false,
      };
      mapped.push(mappedGroup);
    }
    return mapped;
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

  private async sendConfigChunkByWant(
    context: common.UIAbilityContext,
    configPath: string,
    statusPath: string,
    statusEvent: string,
    startConfigPath: string,
    configSession: string,
    index: number,
    count: number,
    data: string
  ): Promise<void> {
    const want: Want = {
      deviceId: '',
      bundleName: context.abilityInfo.bundleName,
      moduleName: 'clash',
      abilityName: 'ClashVpnAbility',
      parameters: {
        configPath,
        statusPath,
        statusEvent,
        startConfigPath,
        configSession,
        configChunkIndex: index,
        configChunkData: data,
        coreConfigChunkCount: count,
      },
    };
    await vpnExtension.startVpnExtensionAbility(want);
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private async waitForVpnStatusOrFile(messages: string[], statusPath: string, expected: string, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const message of messages) {
        if (message.indexOf(expected) >= 0) {
          return true;
        }
      }
      const statusText = statusPath ? this.readTextFile(statusPath) : '';
      if (statusText.indexOf(expected) >= 0) {
        return true;
      }
      await this.delay(100);
    }
    return false;
  }

  private async waitForVpnStartResult(messages: string[], statusPath: string, context: common.UIAbilityContext, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    const extensionService = new NativeCoreExtensionService(context);
    let lastProbeError = '';
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
      const statusText = statusPath ? this.readTextFile(statusPath) : '';
      const fileResultIndex = statusText.indexOf('start result:');
      if (fileResultIndex >= 0) {
        const result = statusText.substring(fileResultIndex).trim();
        if (result.indexOf('start result: started') >= 0 ||
          result.indexOf('start result: already_running') >= 0 ||
          result.indexOf('start result: native_core_started') >= 0) {
          return;
        }
        throw new Error(result);
      }
      try {
        const statusResult = await extensionService.getStatus();
        if (statusResult.ok && statusResult.data.indexOf('"running":true') >= 0) {
          this.writeConnectionStatus(statusPath, `ui native-core status probe running ${statusResult.data}`);
          return;
        }
        if (statusResult.data) {
          lastProbeError = statusResult.data;
        }
      } catch (e) {
        lastProbeError = this.describeError(e);
      }
      await this.delay(100);
    }
    const recent = messages.length > 0 ? messages.slice(Math.max(0, messages.length - 30)).join('\n') : 'no vpn status events received';
    const statusText = statusPath ? this.readTextFile(statusPath) : '';
    const recentStatus = statusText || recent;
    const probe = lastProbeError ? `\nstatusProbe=${lastProbeError}` : '';
    throw new Error(`VPN Extension did not report start result within ${timeoutMs}ms; recentVpnStatus=\n${recentStatus}${probe}`);
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

        Button($r('app.string.logs'))
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

          Text($r('app.string.proxy'))
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
              Text($r('app.string.connection_error'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.error_color'))
                .layoutWeight(1)

              Button($r('app.string.copy'))
                .height(28)
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(7)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.copyError();
                })

              Button(this.showErrorDetail ? $r('app.string.hide') : $r('app.string.details'))
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
              new ModeItem(ConnectionMode.RULE, $r('app.string.rule_mode')),
              new ModeItem(ConnectionMode.GLOBAL, $r('app.string.global_mode')),
              new ModeItem(ConnectionMode.DIRECT, $r('app.string.direct_mode')),
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
  label: ResourceStr;

  constructor(mode: string, label: ResourceStr) {
    this.mode = mode;
    this.label = label;
  }
}
