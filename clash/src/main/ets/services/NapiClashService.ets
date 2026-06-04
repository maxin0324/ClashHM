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

function callInit(dir: string): string {
  return clashNapi.init(dir);
}

function callLoadEngine(libDir: string): string {
  return clashNapi.loadEngine(libDir);
}

function callStartFile(path: string): string {
  return clashNapi.startFile(path);
}

function callGetProxies(): string {
  return clashNapi.getProxies();
}

function callGetTraffic(): string {
  return clashNapi.getTraffic();
}

function callGetConnections(): string {
  return clashNapi.getConnections();
}

function callGetMode(): string {
  return clashNapi.getMode();
}

function callIsRunning(): number {
  return clashNapi.isRunning();
}

function callSelectProxy(group: string, proxy: string): number {
  return clashNapi.selectProxy(group, proxy);
}

function callTestDelay(name: string, url: string, timeout: number): number {
  return clashNapi.testDelay(name, url, timeout);
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

    // Try multiple directories to find libmihomo.so
    const searchDirs: string[] = [
      context.bundleCodeDir,
      context.bundleCodeDir + '/libs/arm64',
      context.bundleCodeDir + '/libs/arm64-v8a',
      '/data/storage/el1/bundle/libs/arm64',
      context.filesDir,
    ];

    let loaded: boolean = false;
    for (const dir of searchDirs) {
      const result: string = callLoadEngine(dir);
      Logger.info('ClashNapi loadEngine(%{public}s): %{public}s', dir, result);
      if (result.startsWith('loaded')) {
        loaded = true;
        break;
      }
    }

    if (!loaded) {
      Logger.error('Failed to load mihomo engine from any path');
    }

    const homeDir: string = context.filesDir;
    const initResult: string = callInit(homeDir);
    Logger.info('ClashNapi init: %{public}s', initResult);
  }

  async start(configPath: string): Promise<void> {
    this.state = ConnectState.CONNECTING;
    try {
      const resultStr: string = callStartFile(configPath);
      const parsed: NapiResult = JSON.parse(resultStr) as NapiResult;
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
    const resultStr: string = callStartFile(configPath);
    const parsed: NapiResult = JSON.parse(resultStr) as NapiResult;
    if (parsed.error) {
      throw new Error(parsed.error);
    }
  }

  getProxyGroups(): ProxyGroup[] {
    try {
      const jsonStr: string = callGetProxies();
      const groups: NapiGroupInfo[] = JSON.parse(jsonStr) as NapiGroupInfo[];
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
    const ret: number = callSelectProxy(groupName, proxyName);
    if (ret !== 0) {
      Logger.error('Failed to select proxy: %{public}s', String(ret));
    }
  }

  async testLatency(proxyName: string): Promise<number> {
    const delay: number = callTestDelay(proxyName, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT);
    return delay;
  }

  async testGroupLatency(groupName: string): Promise<Map<string, number>> {
    const result = new Map<string, number>();
    const groups = this.getProxyGroups();
    for (const group of groups) {
      if (group.name === groupName) {
        for (const node of group.nodes) {
          const delay: number = callTestDelay(node.name, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT);
          result.set(node.name, delay);
        }
        break;
      }
    }
    return result;
  }

  getTraffic(): TrafficData {
    try {
      const jsonStr: string = callGetTraffic();
      const t: NapiTraffic = JSON.parse(jsonStr) as NapiTraffic;

      let uploadSpeed: number = 0;
      let downloadSpeed: number = 0;
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
        const connStr: string = callGetConnections();
        const conns: NapiConnection[] = JSON.parse(connStr) as NapiConnection[];
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
      const jsonStr: string = callGetConnections();
      const conns: NapiConnection[] = JSON.parse(jsonStr) as NapiConnection[];
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
      const running: number = callIsRunning();
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
      const modeStr: string = callGetMode();
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
