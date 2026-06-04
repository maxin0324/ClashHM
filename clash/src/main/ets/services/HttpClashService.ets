import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { IClashService } from './ClashService';
import { ProxyGroup, ProxyNode, ConnectState, ConnectionMode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { LogEntry, LogType } from '../models/LogEntry';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import clashNapi from 'libclash.so';

const API_BASE = `http://127.0.0.1:${Constants.CLASH_API_PORT}`;

function callStartProcess(bin: string, dir: string): string {
  return clashNapi.startProcess(bin, dir);
}

function callStopProcess(): void {
  clashNapi.stopProcess();
}

function callIsRunning(): number {
  return clashNapi.isProcessRunning();
}

interface ClashProxyItem {
  name: string;
  type: string;
  alive: boolean;
  now: string;
  all: string[];
  history: ClashDelayHistory[];
}

interface ClashDelayHistory {
  delay: number;
}

interface ClashProxiesResponse {
  proxies: Record<string, ClashProxyItem>;
}

interface ClashConnectionMeta {
  host: string;
  destinationIP: string;
  destinationPort: string;
  sourceIP: string;
  sourcePort: string;
  network: string;
  type: string;
}

interface ClashConnectionItem {
  id: string;
  metadata: ClashConnectionMeta;
  rule: string;
  rulePayload: string;
  chains: string[];
  upload: number;
  download: number;
  start: string;
}

interface ClashConnectionsResponse {
  connections: ClashConnectionItem[];
  uploadTotal: number;
  downloadTotal: number;
}

interface ClashDelayResponse {
  delay: number;
}

interface ClashConfigResponse {
  mode: string;
}

function callTestDlopen(path: string): string {
  return clashNapi.testDlopen(path);
}

export class HttpClashService implements IClashService {
  private context: common.UIAbilityContext;
  private state: ConnectState = ConnectState.DISCONNECTED;
  private mode: ConnectionMode = ConnectionMode.RULE;
  private mihomoPath: string = '';
  private prevUpload: number = 0;
  private prevDownload: number = 0;
  private sessionUpload: number = 0;
  private sessionDownload: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.mihomoPath = `${context.filesDir}/mihomo`;
    this.extractBinary();

    // Test if libmihomo.so can be dlopen'd (TLS compatibility check)
    const testPaths: string[] = [
      '/data/storage/el1/bundle/libs/arm64/libmihomo.so',
      context.bundleCodeDir + '/libs/arm64/libmihomo.so',
      'libmihomo.so',
    ];
    for (const tp of testPaths) {
      const result: string = callTestDlopen(tp);
      Logger.info('testDlopen(%{public}s): %{public}s', tp, result);
      if (result.startsWith('success')) {
        break;
      }
    }
  }

  private extractBinary(): void {
    try {
      if (fileIo.accessSync(this.mihomoPath)) {
        return;
      }
    } catch (_e) {
      // file doesn't exist, extract it
    }

    try {
      const mgr: resourceManager.ResourceManager = this.context.resourceManager;
      const data: Uint8Array = mgr.getRawFileContentSync('mihomo');
      const file = fileIo.openSync(this.mihomoPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const buf = data.buffer as ArrayBuffer;
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      Logger.info('Extracted mihomo binary (%{public}d bytes)', String(data.length));
    } catch (e) {
      Logger.error('Failed to extract mihomo: %{public}s', String(e));
    }
  }

  async start(configPath: string): Promise<void> {
    this.state = ConnectState.CONNECTING;

    // Copy config to config dir
    const configDir = `${this.context.filesDir}/mihomo-config`;
    try {
      fileIo.mkdirSync(configDir, true);
    } catch (_e) {
      // exists
    }

    // Check if source config exists
    let sourceExists = false;
    try {
      sourceExists = fileIo.accessSync(configPath);
    } catch (_e) {
      sourceExists = false;
    }

    if (!sourceExists) {
      Logger.error('Config file not found: %{public}s', configPath);
      this.state = ConnectState.DISCONNECTED;
      throw new Error('Config file not found. Update subscription first.');
    }

    try {
      fileIo.copyFileSync(configPath, `${configDir}/config.yaml`);
      Logger.info('Config copied to %{public}s', configDir);
    } catch (e) {
      Logger.error('Failed to copy config: %{public}s', String(e));
      this.state = ConnectState.DISCONNECTED;
      throw new Error('Failed to copy config: ' + String(e));
    }

    // Start mihomo process
    const result: string = callStartProcess(this.mihomoPath, configDir);
    Logger.info('Start process result: %{public}s', result);

    if (result === 'fork_failed') {
      this.state = ConnectState.DISCONNECTED;
      throw new Error('Failed to start mihomo process');
    }

    // Wait for API to be ready
    let ready = false;
    for (let i = 0; i < 10; i++) {
      await this.delay(500);
      try {
        const resp = await this.apiGet('/configs');
        if (resp) {
          ready = true;
          break;
        }
      } catch (_e) {
        // not ready yet
      }
    }

    if (!ready) {
      this.state = ConnectState.DISCONNECTED;
      callStopProcess();
      throw new Error('mihomo failed to start (API not responding)');
    }

    this.state = ConnectState.CONNECTED;
    this.prevUpload = 0;
    this.prevDownload = 0;
    this.sessionUpload = 0;
    this.sessionDownload = 0;
    this.refreshMode();
  }

  async stop(): Promise<void> {
    callStopProcess();
    this.state = ConnectState.DISCONNECTED;
  }

  async reload(configPath: string): Promise<void> {
    await this.stop();
    await this.start(configPath);
  }

  getProxyGroups(): ProxyGroup[] {
    return [];
  }

  async getProxyGroupsAsync(): Promise<ProxyGroup[]> {
    try {
      const json = await this.apiGet('/proxies');
      if (!json) return [];
      const resp: ClashProxiesResponse = JSON.parse(json) as ClashProxiesResponse;
      const groups: ProxyGroup[] = [];

      const keys = Object.keys(resp.proxies);
      for (const key of keys) {
        const p = resp.proxies[key];
        if (p.all && p.all.length > 0) {
          const nodes: ProxyNode[] = [];
          for (const nodeName of p.all) {
            const nodeData = resp.proxies[nodeName];
            if (nodeData) {
              const lastDelay = (nodeData.history && nodeData.history.length > 0) ?
                nodeData.history[nodeData.history.length - 1].delay : -1;
              nodes.push({
                name: nodeName,
                type: nodeData.type,
                server: '',
                port: 0,
                latency: lastDelay,
                alive: nodeData.alive,
              });
            }
          }
          groups.push({
            name: key,
            type: p.type,
            now: p.now || '',
            all: p.all,
            nodes: nodes,
            expanded: false,
          });
        }
      }
      return groups;
    } catch (e) {
      Logger.error('getProxyGroups failed: %{public}s', String(e));
      return [];
    }
  }

  async selectProxy(groupName: string, proxyName: string): Promise<void> {
    await this.apiPut(`/proxies/${encodeURIComponent(groupName)}`, `{"name":"${proxyName}"}`);
  }

  async testLatency(proxyName: string): Promise<number> {
    try {
      const json = await this.apiGet(
        `/proxies/${encodeURIComponent(proxyName)}/delay?url=${encodeURIComponent(Constants.LATENCY_TEST_URL)}&timeout=${Constants.LATENCY_TEST_TIMEOUT}`
      );
      if (json) {
        const resp: ClashDelayResponse = JSON.parse(json) as ClashDelayResponse;
        return resp.delay || 0;
      }
    } catch (_e) {
      // timeout or error
    }
    return 0;
  }

  async testGroupLatency(groupName: string): Promise<Map<string, number>> {
    const result = new Map<string, number>();
    const groups = await this.getProxyGroupsAsync();
    for (const group of groups) {
      if (group.name === groupName) {
        for (const node of group.nodes) {
          const delay = await this.testLatency(node.name);
          result.set(node.name, delay);
        }
        break;
      }
    }
    return result;
  }

  getTraffic(): TrafficData {
    return createEmptyTraffic();
  }

  async getTrafficAsync(): Promise<TrafficData> {
    try {
      const json = await this.apiGet('/connections');
      if (json) {
        const resp: ClashConnectionsResponse = JSON.parse(json) as ClashConnectionsResponse;

        let uploadSpeed = 0;
        let downloadSpeed = 0;
        if (this.prevUpload > 0) {
          uploadSpeed = resp.uploadTotal - this.prevUpload;
          downloadSpeed = resp.downloadTotal - this.prevDownload;
          if (uploadSpeed < 0) uploadSpeed = 0;
          if (downloadSpeed < 0) downloadSpeed = 0;
        }
        this.sessionUpload += uploadSpeed;
        this.sessionDownload += downloadSpeed;
        this.prevUpload = resp.uploadTotal;
        this.prevDownload = resp.downloadTotal;

        return {
          uploadSpeed: uploadSpeed,
          downloadSpeed: downloadSpeed,
          sessionUpload: this.sessionUpload,
          sessionDownload: this.sessionDownload,
          activeConnections: resp.connections ? resp.connections.length : 0,
        };
      }
    } catch (_e) {
      // error
    }
    return createEmptyTraffic();
  }

  getConnections(): LogEntry[] {
    return [];
  }

  async getConnectionsAsync(): Promise<LogEntry[]> {
    try {
      const json = await this.apiGet('/connections');
      if (!json) return [];
      const resp: ClashConnectionsResponse = JSON.parse(json) as ClashConnectionsResponse;
      if (!resp.connections) return [];

      return resp.connections.map((c: ClashConnectionItem): LogEntry => {
        return {
          id: c.id,
          timestamp: Date.now(),
          type: c.metadata.network === 'UDP' ? LogType.UDP : LogType.TCP,
          network: c.metadata.network,
          sourceIP: c.metadata.sourceIP,
          sourcePort: parseInt(c.metadata.sourcePort) || 0,
          destinationIP: c.metadata.destinationIP,
          destinationPort: parseInt(c.metadata.destinationPort) || 0,
          host: c.metadata.host,
          rule: c.rule,
          rulePayload: c.rulePayload,
          proxyChain: c.chains || [],
          downloadBytes: c.download,
          uploadBytes: c.upload,
        };
      });
    } catch (_e) {
      return [];
    }
  }

  async closeConnection(id: string): Promise<void> {
    await this.apiDelete(`/connections/${id}`);
  }

  async closeAllConnections(): Promise<void> {
    await this.apiDelete('/connections');
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
    return this.mode;
  }

  async setMode(mode: ConnectionMode): Promise<void> {
    await this.apiPatch('/configs', `{"mode":"${mode}"}`);
    this.mode = mode;
  }

  private async refreshMode(): Promise<void> {
    try {
      const json = await this.apiGet('/configs');
      if (json) {
        const cfg: ClashConfigResponse = JSON.parse(json) as ClashConfigResponse;
        if (cfg.mode === 'global') this.mode = ConnectionMode.GLOBAL;
        else if (cfg.mode === 'direct') this.mode = ConnectionMode.DIRECT;
        else this.mode = ConnectionMode.RULE;
      }
    } catch (_e) {
      // ignore
    }
  }

  private async apiGet(path: string): Promise<string | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${API_BASE}${path}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 10000,
      });
      req.destroy();
      if (resp.responseCode === 200) {
        return resp.result as string;
      }
    } catch (e) {
      req.destroy();
      throw new Error(String(e));
    }
    return null;
  }

  private async apiPut(path: string, body: string): Promise<void> {
    const req = http.createHttp();
    try {
      await req.request(`${API_BASE}${path}`, {
        method: http.RequestMethod.PUT,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: 3000,
        readTimeout: 5000,
      });
    } catch (_e) {
      // ignore
    }
    req.destroy();
  }

  private async apiPatch(path: string, body: string): Promise<void> {
    const req = http.createHttp();
    try {
      await req.request(`${API_BASE}${path}`, {
        method: http.RequestMethod.PUT,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: 3000,
        readTimeout: 5000,
      });
    } catch (_e) {
      // ignore
    }
    req.destroy();
  }

  private async apiDelete(path: string): Promise<void> {
    const req = http.createHttp();
    try {
      await req.request(`${API_BASE}${path}`, {
        method: http.RequestMethod.DELETE,
        connectTimeout: 3000,
        readTimeout: 5000,
      });
    } catch (_e) {
      // ignore
    }
    req.destroy();
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }
}
