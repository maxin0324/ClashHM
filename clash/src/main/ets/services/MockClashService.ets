import { IClashService } from './ClashService';
import { ProxyGroup, ProxyNode, ConnectState, ConnectionMode } from '../models/ClashConfig';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { LogEntry, LogType } from '../models/LogEntry';
import { Logger } from '../common/Logger';

export class MockClashService implements IClashService {
  private state: ConnectState = ConnectState.DISCONNECTED;
  private mode: ConnectionMode = ConnectionMode.RULE;
  private mockGroups: ProxyGroup[] = [];
  private mockTraffic: TrafficData = createEmptyTraffic();
  private mockLogs: LogEntry[] = [];
  private trafficTimer: number = -1;

  constructor() {
    this.initMockData();
  }

  private initMockData(): void {
    const globalNodes: ProxyNode[] = [
      { name: 'HK-01 IPLC', type: 'ss', server: '1.2.3.4', port: 443, latency: -1, alive: true },
      { name: 'HK-02 BGP', type: 'vmess', server: '1.2.3.5', port: 443, latency: -1, alive: true },
      { name: 'JP-01 Tokyo', type: 'trojan', server: '2.3.4.5', port: 443, latency: -1, alive: true },
      { name: 'JP-02 Osaka', type: 'ss', server: '2.3.4.6', port: 443, latency: -1, alive: true },
      { name: 'US-01 LA', type: 'vmess', server: '3.4.5.6', port: 443, latency: -1, alive: true },
      { name: 'US-02 SJ', type: 'vless', server: '3.4.5.7', port: 443, latency: -1, alive: true },
      { name: 'SG-01', type: 'trojan', server: '4.5.6.7', port: 443, latency: -1, alive: true },
      { name: 'TW-01', type: 'ss', server: '5.6.7.8', port: 443, latency: -1, alive: true },
      { name: 'KR-01 Seoul', type: 'vmess', server: '6.7.8.9', port: 443, latency: -1, alive: true },
    ];

    this.mockGroups = [
      {
        name: 'Proxy',
        type: 'select',
        now: 'HK-01 IPLC',
        all: globalNodes.map(n => n.name),
        nodes: globalNodes,
        expanded: false,
      },
      {
        name: 'Auto',
        type: 'url-test',
        now: 'JP-01 Tokyo',
        all: globalNodes.map(n => n.name),
        nodes: globalNodes,
        expanded: false,
      },
      {
        name: 'Streaming',
        type: 'select',
        now: 'SG-01',
        all: ['Proxy', 'Auto', ...globalNodes.filter(n => ['SG-01', 'HK-01 IPLC', 'HK-02 BGP', 'US-01 LA', 'JP-01 Tokyo'].includes(n.name)).map(n => n.name)],
        nodes: globalNodes.filter(n => ['SG-01', 'HK-01 IPLC', 'HK-02 BGP', 'US-01 LA', 'JP-01 Tokyo'].includes(n.name)),
        expanded: false,
      },
      {
        name: 'Telegram',
        type: 'select',
        now: 'SG-01',
        all: ['Proxy', 'Auto', 'SG-01', 'HK-01 IPLC', 'US-01 LA'],
        nodes: globalNodes.filter(n => ['SG-01', 'HK-01 IPLC', 'US-01 LA'].includes(n.name)),
        expanded: false,
      },
      {
        name: 'Apple',
        type: 'select',
        now: 'DIRECT',
        all: ['DIRECT', 'Proxy', 'Auto'],
        nodes: [],
        expanded: false,
      },
      {
        name: 'Microsoft',
        type: 'select',
        now: 'DIRECT',
        all: ['DIRECT', 'Proxy', 'Auto'],
        nodes: [],
        expanded: false,
      },
      {
        name: 'Final',
        type: 'select',
        now: 'Proxy',
        all: ['DIRECT', 'Proxy', 'Auto'],
        nodes: [],
        expanded: false,
      }
    ];

    this.mockLogs = this.generateMockLogs();
  }

  private generateMockLogs(): LogEntry[] {
    const entries: LogEntry[] = [];
    const hosts = ['www.google.com', 'api.telegram.org', 'github.com', 'youtube.com', 'twitter.com',
      'cdn.jsdelivr.net', 'raw.githubusercontent.com', 'api.openai.com'];
    const rules = ['DOMAIN-SUFFIX', 'GEOSITE', 'GEOIP', 'MATCH'];
    const chains = [['HK-01 IPLC'], ['JP-01 Tokyo'], ['Auto', 'JP-01 Tokyo'], ['Proxy', 'HK-01 IPLC'], ['DIRECT']];
    const now = Date.now();
    for (let i = 0; i < 20; i++) {
      entries.push({
        id: `conn_${i}`,
        timestamp: now - (20 - i) * 3000,
        type: i % 3 === 0 ? LogType.UDP : LogType.TCP,
        network: i % 3 === 0 ? 'UDP' : 'TCP',
        sourceIP: '192.168.1.100',
        sourcePort: 50000 + i,
        destinationIP: `${100 + i}.${i}.${i}.${i}`,
        destinationPort: i % 2 === 0 ? 443 : 80,
        host: hosts[i % hosts.length],
        rule: rules[i % rules.length],
        rulePayload: hosts[i % hosts.length],
        proxyChain: chains[i % chains.length],
        downloadBytes: Math.floor(Math.random() * 1024 * 100),
        uploadBytes: Math.floor(Math.random() * 1024 * 10),
      });
    }
    return entries;
  }

  async start(_configPath: string): Promise<void> {
    Logger.info('MockClashService: starting...');
    this.state = ConnectState.CONNECTING;
    await this.delay(800);
    this.state = ConnectState.CONNECTED;
    this.startTrafficSimulation();
    Logger.info('MockClashService: started');
  }

  async startCore(_configPath: string): Promise<void> {
    Logger.info('MockClashService: core ready');
  }

  async stop(): Promise<void> {
    Logger.info('MockClashService: stopping...');
    this.stopTrafficSimulation();
    this.state = ConnectState.DISCONNECTED;
    this.mockTraffic = createEmptyTraffic();
    Logger.info('MockClashService: stopped');
  }

  async reload(_configPath: string): Promise<void> {
    Logger.info('MockClashService: reloading config');
    await this.delay(300);
  }

  getProxyGroups(): ProxyGroup[] {
    return this.mockGroups;
  }

  async getProxyGroupsAsync(): Promise<ProxyGroup[]> {
    return this.getProxyGroups();
  }

  async selectProxy(groupName: string, proxyName: string): Promise<void> {
    for (const group of this.mockGroups) {
      if (group.name === groupName) {
        group.now = proxyName;
        break;
      }
    }
  }

  async testLatency(proxyName: string): Promise<number> {
    await this.delay(200 + Math.floor(Math.random() * 800));
    const latency = 50 + Math.floor(Math.random() * 400);
    for (const group of this.mockGroups) {
      for (const node of group.nodes) {
        if (node.name === proxyName) {
          node.latency = latency;
          break;
        }
      }
    }
    return latency;
  }

  async testGroupLatency(groupName: string): Promise<Map<string, number>> {
    const result = new Map<string, number>();
    for (const group of this.mockGroups) {
      if (group.name === groupName) {
        for (const node of group.nodes) {
          const latency = 30 + Math.floor(Math.random() * 500);
          node.latency = latency;
          node.alive = latency < 1000;
          result.set(node.name, latency);
        }
        break;
      }
    }
    return result;
  }

  getTraffic(): TrafficData {
    return this.mockTraffic;
  }

  async getTrafficAsync(): Promise<TrafficData> {
    return this.getTraffic();
  }

  getConnections(): LogEntry[] {
    return this.mockLogs;
  }

  async closeConnection(_id: string): Promise<void> {
    this.mockLogs = this.mockLogs.filter(l => l.id !== _id);
  }

  async closeAllConnections(): Promise<void> {
    this.mockLogs = [];
  }

  isCoreRunning(): boolean {
    return true;
  }

  setVpnConnected(connected: boolean): void {
    this.state = connected ? ConnectState.CONNECTED : ConnectState.DISCONNECTED;
    if (connected) {
      this.startTrafficSimulation();
    } else {
      this.stopTrafficSimulation();
      this.mockTraffic = createEmptyTraffic();
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

  private startTrafficSimulation(): void {
    this.trafficTimer = setInterval(() => {
      this.mockTraffic = {
        uploadSpeed: Math.floor(Math.random() * 1024 * 50),
        downloadSpeed: Math.floor(Math.random() * 1024 * 500),
        sessionUpload: this.mockTraffic.sessionUpload + Math.floor(Math.random() * 1024 * 50),
        sessionDownload: this.mockTraffic.sessionDownload + Math.floor(Math.random() * 1024 * 500),
        activeConnections: 5 + Math.floor(Math.random() * 20),
      };
    }, 1000);
  }

  private stopTrafficSimulation(): void {
    if (this.trafficTimer !== -1) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }
}
