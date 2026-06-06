import { ProxyGroup } from '../models/ClashConfig';
import { TrafficData } from '../models/TrafficData';
import { LogEntry } from '../models/LogEntry';
import { ConnectState, ConnectionMode } from '../models/ClashConfig';

export interface IClashService {
  start(configPath: string): Promise<void>;
  startCore(configPath: string): Promise<void>;
  stop(): Promise<void>;
  reload(configPath: string): Promise<void>;
  getProxyGroups(): ProxyGroup[];
  getProxyGroupsAsync(): Promise<ProxyGroup[]>;
  selectProxy(groupName: string, proxyName: string): Promise<void>;
  testLatency(proxyName: string): Promise<number>;
  testGroupLatency(groupName: string): Promise<Map<string, number>>;
  getTraffic(): TrafficData;
  getTrafficAsync(): Promise<TrafficData>;
  getConnections(): LogEntry[];
  closeConnection(id: string): Promise<void>;
  closeAllConnections(): Promise<void>;
  isCoreRunning(): boolean;
  setVpnConnected(connected: boolean): void;
  getState(): ConnectState;
  getMode(): ConnectionMode;
  setMode(mode: ConnectionMode): Promise<void>;
}

let _clashServiceInstance: IClashService | null = null;

export function setClashService(service: IClashService): void {
  _clashServiceInstance = service;
}

export function getClashService(): IClashService {
  if (_clashServiceInstance === null) {
    throw new Error('ClashService not initialized. Call setClashService() first.');
  }
  return _clashServiceInstance;
}
