import clashNapi from 'libclash.so';
import { IClashService } from './ClashService';
import { ProxyGroup, ProxyNode, ConnectState, ConnectionMode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { LogEntry, LogType } from '../models/LogEntry';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';
import { common } from '@kit.AbilityKit';

interface NapiProxyNode {
  name: string;
  type: string;
  alive: boolean;
  latency: number;
}

interface NapiGroupInfo {
  name: string;
  type: string;
  now: string;
  all: string[];
  nodes: NapiProxyNode[];
}

interface NapiTraffic {
  uploadSpeed: number;
  downloadSpeed: number;
  uploadTotal: number;
  downloadTotal: number;
}

interface NapiConnection {
  id: string;
  host: string;
  destinationIP: string;
  destinationPort: number;
  sourceIP: string;
  sourcePort: number;
  network: string;
  type: string;
  rule: string;
  rulePayload: string;
  proxyChain: string[];
  uploadBytes: number;
  downloadBytes: number;
}

interface NapiResult {
  status: string;
  error: string;
}

export class NapiClashService implements IClashService {
  private context: common.UIAbilityContext;
  private state: ConnectState = ConnectState.DISCONNECTED;
  private mode: ConnectionMode = ConnectionMode.RULE;
  private cachedGroups: ProxyGroup[] = [];
  private lastTraffic: TrafficData = createEmptyTraffic();
  private prevUpload: number = 0;
  private prevDownload: number = 0;
  private sessionUpload: number = 0;
  private sessionDownload: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    const homeDir = context.filesDir;
    const result = clashNapi.init(homeDir);
    Logger.info('ClashNapi init: %{public}s', result);
  }

  async start(configPath: string): Promise<void> {
    this.state = ConnectState.CONNECTING;
    try {
      const result = clashNapi.startFile(configPath);
      const parsed: NapiResult = JSON.parse(result) as NapiResult;
      if (parsed.error) {
        this.state = ConnectState.DISCONNECTED;
        throw new Error(parsed.error);
      }
      this.state = ConnectState.CONNECTED;
      this.prevUpload = 0;
      this.prevDownload = 0;
      this.sessionUpload = 0;
      this.sessionDownload = 0;
      this.refreshMode();
      Logger.info('Clash engine started');
    } catch (e) {
      this.state = ConnectState.DISCONNECTED;
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  async stop(): Promise<void> {
    clashNapi.stop();
    this.state = ConnectState.DISCONNECTED;
    this.lastTraffic = createEmptyTraffic();
    Logger.info('Clash engine stopped');
  }

  async reload(configPath: string): Promise<void> {
    clashNapi.stop();
    const result = clashNapi.startFile(configPath);
    const parsed: NapiResult = JSON.parse(result) as NapiResult;
    if (parsed.error) {
      throw new Error(parsed.error);
    }
  }

  getProxyGroups(): ProxyGroup[] {
    try {
      const json = clashNapi.getProxies();
      const groups: NapiGroupInfo[] = JSON.parse(json) as NapiGroupInfo[];
      this.cachedGroups = groups.map((g: NapiGroupInfo): ProxyGroup => {
        return {
          name: g.name,
          type: g.type,
          now: g.now,
          all: g.all || [],
          nodes: (g.nodes || []).map((n: NapiProxyNode): ProxyNode => {
            return {
              name: n.name,
              type: n.type,
              server: '',
              port: 0,
              latency: n.latency || -1,
              alive: n.alive,
            };
          }),
          expanded: false,
        };
      });
      return this.cachedGroups;
    } catch (e) {
      Logger.error('Failed to get proxies: %{public}s', String(e));
      return this.cachedGroups;
    }
  }

  async selectProxy(groupName: string, proxyName: string): Promise<void> {
    const result = clashNapi.selectProxy(groupName, proxyName);
    if (result !== 0) {
      Logger.error('Failed to select proxy: %{public}s', String(result));
    }
  }

  async testLatency(proxyName: string): Promise<number> {
    const delay = clashNapi.testDelay(proxyName, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT);
    return delay;
  }

  async testGroupLatency(groupName: string): Promise<Map<string, number>> {
    const result = new Map<string, number>();
    const groups = this.getProxyGroups();
    for (const group of groups) {
      if (group.name === groupName) {
        for (const node of group.nodes) {
          const delay = clashNapi.testDelay(node.name, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT);
          result.set(node.name, delay);
        }
        break;
      }
    }
    return result;
  }

  getTraffic(): TrafficData {
    try {
      const json = clashNapi.getTraffic();
      const t: NapiTraffic = JSON.parse(json) as NapiTraffic;

      let uploadSpeed = 0;
      let downloadSpeed = 0;
      if (this.prevUpload > 0) {
        uploadSpeed = t.uploadTotal - this.prevUpload;
        downloadSpeed = t.downloadTotal - this.prevDownload;
        if (uploadSpeed < 0) uploadSpeed = 0;
        if (downloadSpeed < 0) downloadSpeed = 0;
      }
      this.sessionUpload += uploadSpeed;
      this.sessionDownload += downloadSpeed;
      this.prevUpload = t.uploadTotal;
      this.prevDownload = t.downloadTotal;

      this.lastTraffic = {
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed,
        sessionUpload: this.sessionUpload,
        sessionDownload: this.sessionDownload,
        activeConnections: 0,
      };

      try {
        const connJson = clashNapi.getConnections();
        const conns: NapiConnection[] = JSON.parse(connJson) as NapiConnection[];
        this.lastTraffic.activeConnections = conns.length;
      } catch (_e) {
        // ignore
      }

      return this.lastTraffic;
    } catch (_e) {
      return this.lastTraffic;
    }
  }

  getConnections(): LogEntry[] {
    try {
      const json = clashNapi.getConnections();
      const conns: NapiConnection[] = JSON.parse(json) as NapiConnection[];
      return conns.map((c: NapiConnection): LogEntry => {
        return {
          id: c.id,
          timestamp: Date.now(),
          type: this.mapLogType(c.network),
          network: c.network,
          sourceIP: c.sourceIP,
          sourcePort: c.sourcePort || 0,
          destinationIP: c.destinationIP,
          destinationPort: c.destinationPort || 0,
          host: c.host,
          rule: c.rule,
          rulePayload: c.rulePayload,
          proxyChain: c.proxyChain || [],
          downloadBytes: c.downloadBytes,
          uploadBytes: c.uploadBytes,
        };
      });
    } catch (_e) {
      return [];
    }
  }

  async closeConnection(id: string): Promise<void> {
    clashNapi.closeConnection(id);
  }

  async closeAllConnections(): Promise<void> {
    clashNapi.closeAllConnections();
  }

  getState(): ConnectState {
    if (this.state === ConnectState.CONNECTED) {
      const running = clashNapi.isRunning();
      if (running === 0) {
        this.state = ConnectState.DISCONNECTED;
      }
    }
    return this.state;
  }

  getMode(): ConnectionMode {
    this.refreshMode();
    return this.mode;
  }

  async setMode(mode: ConnectionMode): Promise<void> {
    clashNapi.setMode(mode);
    this.mode = mode;
  }

  setTunFd(fd: number): void {
    clashNapi.setTunFd(fd);
  }

  private refreshMode(): void {
    try {
      const modeStr = clashNapi.getMode();
      if (modeStr === 'global') {
        this.mode = ConnectionMode.GLOBAL;
      } else if (modeStr === 'direct') {
        this.mode = ConnectionMode.DIRECT;
      } else {
        this.mode = ConnectionMode.RULE;
      }
    } catch (_e) {
      // ignore
    }
  }

  private mapLogType(network: string): LogType {
    if (network.toUpperCase() === 'UDP') {
      return LogType.UDP;
    }
    return LogType.TCP;
  }
}
