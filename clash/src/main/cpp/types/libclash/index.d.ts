export interface ClashNativeModule {
  default?: ClashNativeModule;
  loadEngine: (libDir: string) => string;
  init: (homeDir: string) => string;
  startFile: (configPath: string) => string;
  startContent: (configText: string) => string;
  stop: () => void;
  isRunning: () => number;
  getProxies: () => string;
  selectProxy: (groupName: string, proxyName: string) => number;
  testDelay: (proxyName: string, url: string, timeout: number) => number;
  getTraffic: () => string;
  getConnections: () => string;
  closeConnection: (id: string) => void;
  closeAllConnections: () => void;
  getMode: () => string;
  setMode: (mode: string) => void;
  setTunFd: (fd: number) => void;
  startTun2SocksContent: (configText: string, tunFd: number) => string;
  stopTun2Socks: () => void;
  getTun2SocksStatus: () => string;
  testDlopen: (libPath: string) => string;
}

export const loadEngine: (libDir: string) => string;
export const init: (homeDir: string) => string;
export const startFile: (configPath: string) => string;
export const startContent: (configText: string) => string;
export const stop: () => void;
export const isRunning: () => number;
export const getProxies: () => string;
export const selectProxy: (groupName: string, proxyName: string) => number;
export const testDelay: (proxyName: string, url: string, timeout: number) => number;
export const getTraffic: () => string;
export const getConnections: () => string;
export const closeConnection: (id: string) => void;
export const closeAllConnections: () => void;
export const getMode: () => string;
export const setMode: (mode: string) => void;
export const setTunFd: (fd: number) => void;
export const startTun2SocksContent: (configText: string, tunFd: number) => string;
export const stopTun2Socks: () => void;
export const getTun2SocksStatus: () => string;
export const testDlopen: (libPath: string) => string;

declare const defaultExport: ClashNativeModule;
export default defaultExport;
