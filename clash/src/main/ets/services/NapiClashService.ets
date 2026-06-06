import clashNapi, { ClashNativeModule } from 'libclash.so';
import { IClashService } from './ClashService';
import { ProxyGroup, ProxyNode, ConnectState, ConnectionMode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { LogEntry, LogType } from '../models/LogEntry';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';

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

function getNativeModule(): ClashNativeModule {
  if (clashNapi === undefined) {
    throw new Error('libclash.so import is undefined; native initializer was not called');
  }
  if (clashNapi.default) {
    return clashNapi.default;
  }
  return clashNapi;
}

function callInit(dir: string): string {
  return getNativeModule().init(dir);
}

function callLoadEngine(libDir: string): string {
  return getNativeModule().loadEngine(libDir);
}

function callStartFile(path: string): string {
  return getNativeModule().startFile(path);
}

function callGetProxies(): string {
  return getNativeModule().getProxies();
}

function callGetTraffic(): string {
  return getNativeModule().getTraffic();
}

function callGetConnections(): string {
  return getNativeModule().getConnections();
}

function callGetMode(): string {
  return getNativeModule().getMode();
}

function callStop(): void {
  getNativeModule().stop();
}

function callIsRunning(): number {
  return getNativeModule().isRunning();
}

function callSelectProxy(group: string, proxy: string): number {
  return getNativeModule().selectProxy(group, proxy);
}

function callTestDelay(name: string, url: string, timeout: number): number {
  return getNativeModule().testDelay(name, url, timeout);
}

function callCloseConnection(id: string): void {
  getNativeModule().closeConnection(id);
}

function callCloseAllConnections(): void {
  getNativeModule().closeAllConnections();
}

function callSetMode(mode: string): void {
  getNativeModule().setMode(mode);
}

function callSetTunFd(fd: number): void {
  getNativeModule().setTunFd(fd);
}

function parseNapiResult(raw: string, action: string): NapiResult {
  try {
    return JSON.parse(raw) as NapiResult;
  } catch (e) {
    throw new Error(`${action} returned invalid JSON: ${String(e)}; raw=${raw}`);
  }
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

    const searchDirs: string[] = [
      '',
      context.bundleCodeDir + '/libs/arm64',
      context.bundleCodeDir + '/libs/arm64-v8a',
      '/data/storage/el1/bundle/libs/arm64',
      '/data/storage/el1/bundle/libs/arm64-v8a',
      context.bundleCodeDir,
    ];

    let loaded: boolean = false;
    let lastLoadResult: string = '';
    for (const dir of searchDirs) {
      const loadResult: string = callLoadEngine(dir);
      Logger.info('ClashNapi loadEngine(%{public}s): %{public}s', dir, loadResult);
      lastLoadResult = loadResult;
      if (loadResult.startsWith('loaded')) {
        loaded = true;
        break;
      }
    }
    if (!loaded) {
      throw new Error('mihomo engine not available: ' + lastLoadResult);
    }

    const homeDir: string = context.filesDir;
    this.ensureGeoDatabase(homeDir);
    const initResult: string = callInit(homeDir);
    Logger.info('ClashNapi init: %{public}s', initResult);
    const initParsed: NapiResult = parseNapiResult(initResult, 'init');
    if (initParsed.error) {
      throw new Error(initParsed.error);
    }
  }

  private ensureGeoDatabase(homeDir: string): void {
    const targetPath: string = `${homeDir}/geoip.metadb`;
    try {
      const mgr: resourceManager.ResourceManager = this.context.resourceManager;
      const data: Uint8Array = mgr.getRawFileContentSync('geoip.metadb');

      let shouldCopy: boolean = true;
      try {
        const stat = fileIo.statSync(targetPath);
        shouldCopy = stat.size !== data.length;
      } catch (_e) {
        shouldCopy = true;
      }

      if (!shouldCopy) {
        Logger.info('GeoIP database already present: %{public}s', targetPath);
        return;
      }

      const file = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const buf = data.buffer as ArrayBuffer;
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      Logger.info('GeoIP database copied to %{public}s (%{public}s bytes)', targetPath, String(data.length));
    } catch (e) {
      Logger.error('Failed to prepare GeoIP database: %{public}s', String(e));
    }
  }

  async start(configPath: string): Promise<void> {
    this.state = ConnectState.CONNECTING;
    try {
      await this.startCoreInternal(configPath, 'startFile');
      this.setVpnConnected(true);
      Logger.info('Clash engine started');
    } catch (e) {
      this.state = ConnectState.DISCONNECTED;
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  async startCore(configPath: string): Promise<void> {
    await this.startCoreInternal(configPath, 'startCore');
  }

  private async startCoreInternal(configPath: string, action: string): Promise<void> {
    const resultStr: string = callStartFile(configPath);
    Logger.info('ClashNapi %{public}s: %{public}s', action, resultStr);
    const parsed: NapiResult = parseNapiResult(resultStr, action);
    if (parsed.error) {
      throw new Error(parsed.error);
    }
    this.refreshMode();
  }

  async stop(): Promise<void> {
    callStop();
    this.state = ConnectState.DISCONNECTED;
    this.lastTraffic = createEmptyTraffic();
    Logger.info('Clash engine stopped');
  }

  isCoreRunning(): boolean {
    try {
      return callIsRunning() !== 0;
    } catch (_e) {
      return false;
    }
  }

  setVpnConnected(connected: boolean): void {
    this.state = connected ? ConnectState.CONNECTED : ConnectState.DISCONNECTED;
    if (connected) {
      this.prevUpload = 0;
      this.prevDownload = 0;
      this.sessionUpload = 0;
      this.sessionDownload = 0;
      this.lastTraffic = createEmptyTraffic();
    }
  }

  async reload(configPath: string): Promise<void> {
    callStop();
    const resultStr: string = callStartFile(configPath);
    Logger.info('ClashNapi reload startFile: %{public}s', resultStr);
    const parsed: NapiResult = parseNapiResult(resultStr, 'reload');
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

  async getProxyGroupsAsync(): Promise<ProxyGroup[]> {
    return this.getProxyGroups();
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

  async getTrafficAsync(): Promise<TrafficData> {
    return this.getTraffic();
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
    callCloseConnection(id);
  }

  async closeAllConnections(): Promise<void> {
    callCloseAllConnections();
  }

  getState(): ConnectState {
    if (this.state === ConnectState.CONNECTED) {
      if (!this.isCoreRunning()) {
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
    callSetMode(mode);
    this.mode = mode;
  }

  setTunFd(fd: number): void {
    callSetTunFd(fd);
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
