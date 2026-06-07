import { IClashService } from './ClashService';
import { ProxyGroup } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { LogEntry } from '../models/LogEntry';
import { ConnectState, ConnectionMode } from '../models/ClashConfig';
import { NativeCoreExtensionService } from './NativeCoreExtensionService';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

interface NativeCoreTraffic {
  uploadSpeed: number;
  downloadSpeed: number;
  uploadTotal: number;
  downloadTotal: number;
}

export class NapiClashService implements IClashService {
  private context: common.UIAbilityContext;
  private state: ConnectState = ConnectState.DISCONNECTED;
  private mode: ConnectionMode = ConnectionMode.RULE;
  private cachedGroups: ProxyGroup[] = [];
  private lastTraffic: TrafficData = createEmptyTraffic();
  private prevUpload: number = 0;
  private prevDownload: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    Logger.info('Clash service initialized in Extension native-core mode');
  }

  async start(_configPath: string): Promise<void> {
    this.setVpnConnected(true);
  }

  async startCore(_configPath: string): Promise<void> {
    throw new Error('UI core has been removed. Start VPN Extension native-core instead.');
  }

  async stop(): Promise<void> {
    try {
      await new NativeCoreExtensionService(this.context).stop();
    } catch (e) {
      Logger.error('Stop native core through Extension failed: %{public}s', String(e));
    }
    this.state = ConnectState.DISCONNECTED;
    this.lastTraffic = createEmptyTraffic();
    this.prevUpload = 0;
    this.prevDownload = 0;
  }

  async reload(_configPath: string): Promise<void> {
    throw new Error('Reload is handled by restarting VPN Extension native-core.');
  }

  getProxyGroups(): ProxyGroup[] {
    return this.cachedGroups;
  }

  async getProxyGroupsAsync(): Promise<ProxyGroup[]> {
    if (this.state !== ConnectState.CONNECTED) {
      return this.cachedGroups;
    }
    try {
      const result = await new NativeCoreExtensionService(this.context).getProxies();
      if (result.ok && result.data) {
        this.cachedGroups = JSON.parse(result.data) as ProxyGroup[];
      }
    } catch (e) {
      Logger.error('Get proxy groups through Extension failed: %{public}s', String(e));
    }
    return this.cachedGroups;
  }

  async selectProxy(groupName: string, proxyName: string): Promise<void> {
    if (this.state !== ConnectState.CONNECTED) {
      return;
    }
    await new NativeCoreExtensionService(this.context).selectProxy(groupName, proxyName);
  }

  async testLatency(proxyName: string): Promise<number> {
    if (this.state !== ConnectState.CONNECTED) {
      return 0;
    }
    const result = await new NativeCoreExtensionService(this.context).testDelay(proxyName);
    return result.ok ? result.code : 0;
  }

  async testGroupLatency(groupName: string): Promise<Map<string, number>> {
    const result = new Map<string, number>();
    if (this.state !== ConnectState.CONNECTED) {
      return result;
    }
    const groups = await this.getProxyGroupsAsync();
    const extensionService = new NativeCoreExtensionService(this.context);
    for (const group of groups) {
      if (group.name !== groupName) {
        continue;
      }
      for (const node of group.nodes) {
        const delay = await extensionService.testDelay(node.name);
        result.set(node.name, delay.ok ? delay.code : 0);
      }
      break;
    }
    return result;
  }

  getTraffic(): TrafficData {
    return this.lastTraffic;
  }

  async getTrafficAsync(): Promise<TrafficData> {
    if (this.state !== ConnectState.CONNECTED) {
      return this.lastTraffic;
    }
    try {
      const result = await new NativeCoreExtensionService(this.context).getTraffic();
      if (result.ok && result.data) {
        const traffic = JSON.parse(result.data) as NativeCoreTraffic;
        this.lastTraffic = this.updateTrafficFromTotals(traffic);
      }
    } catch (e) {
      Logger.error('Get traffic through Extension failed: %{public}s', String(e));
    }
    return this.lastTraffic;
  }

  getConnections(): LogEntry[] {
    return [];
  }

  async closeConnection(_id: string): Promise<void> {
  }

  async closeAllConnections(): Promise<void> {
  }

  isCoreRunning(): boolean {
    return this.state === ConnectState.CONNECTED;
  }

  setVpnConnected(connected: boolean): void {
    this.state = connected ? ConnectState.CONNECTED : ConnectState.DISCONNECTED;
    if (!connected) {
      this.lastTraffic = createEmptyTraffic();
      this.prevUpload = 0;
      this.prevDownload = 0;
    }
  }

  getState(): ConnectState {
    return this.state;
  }

  getMode(): ConnectionMode {
    return this.mode;
  }

  async setMode(mode: ConnectionMode): Promise<void> {
    this.mode = mode;
  }

  private updateTrafficFromTotals(t: NativeCoreTraffic): TrafficData {
    let uploadSpeed = t.uploadSpeed;
    let downloadSpeed = t.downloadSpeed;
    if (uploadSpeed < 0) {
      uploadSpeed = 0;
    }
    if (downloadSpeed < 0) {
      downloadSpeed = 0;
    }
    if (uploadSpeed === 0 && downloadSpeed === 0 && this.prevUpload > 0) {
      uploadSpeed = t.uploadTotal - this.prevUpload;
      downloadSpeed = t.downloadTotal - this.prevDownload;
      if (uploadSpeed < 0) {
        uploadSpeed = 0;
      }
      if (downloadSpeed < 0) {
        downloadSpeed = 0;
      }
    }
    this.prevUpload = t.uploadTotal;
    this.prevDownload = t.downloadTotal;
    return {
      uploadSpeed,
      downloadSpeed,
      sessionUpload: t.uploadTotal,
      sessionDownload: t.downloadTotal,
      activeConnections: this.lastTraffic.activeConnections,
    };
  }
}
