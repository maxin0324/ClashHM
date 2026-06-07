declare module 'libclash.so' {
  export interface ClashNativeModule {
    default?: ClashNativeModule;
    nativeCoreInit: (homeDir: string) => number;
    nativeCoreStartTun: (tunFd: number, configText: string) => number;
    nativeCoreStop: () => number;
    nativeCoreIsRunning: () => number;
    nativeCoreGetProxies: () => string;
    nativeCoreLoadConfig: (configText: string) => number;
    nativeCoreParseProxies: (configText: string) => string;
    nativeCoreSelectProxy: (groupName: string, proxyName: string) => number;
    nativeCoreTestDelay: (proxyName: string, url: string, timeout: number) => number;
    nativeCoreGetTraffic: () => string;
    nativeCoreGetConnections: () => string;
    nativeCoreGetStatus: () => string;
  }

  export const nativeCoreInit: (homeDir: string) => number;
  export const nativeCoreStartTun: (tunFd: number, configText: string) => number;
  export const nativeCoreStop: () => number;
  export const nativeCoreIsRunning: () => number;
  export const nativeCoreGetProxies: () => string;
  export const nativeCoreLoadConfig: (configText: string) => number;
  export const nativeCoreParseProxies: (configText: string) => string;
  export const nativeCoreSelectProxy: (groupName: string, proxyName: string) => number;
  export const nativeCoreTestDelay: (proxyName: string, url: string, timeout: number) => number;
  export const nativeCoreGetTraffic: () => string;
  export const nativeCoreGetConnections: () => string;
  export const nativeCoreGetStatus: () => string;

  const defaultExport: ClashNativeModule;
  export default defaultExport;
}
