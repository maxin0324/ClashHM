import clashNapi, { ClashNativeModule } from 'libclash.so';

function getNativeModule(): ClashNativeModule {
  if (clashNapi === undefined) {
    throw new Error('libclash.so import is undefined; native initializer was not called');
  }
  if (clashNapi.default) {
    return clashNapi.default;
  }
  return clashNapi;
}

export function callNativeCoreInit(homeDir: string): number {
  return getNativeModule().nativeCoreInit(homeDir);
}

export function callNativeCoreStartTun(tunFd: number, configText: string): number {
  return getNativeModule().nativeCoreStartTun(tunFd, configText);
}

export function callNativeCoreStop(): number {
  return getNativeModule().nativeCoreStop();
}

export function callNativeCoreIsRunning(): number {
  return getNativeModule().nativeCoreIsRunning();
}

export function callNativeCoreGetProxies(): string {
  return getNativeModule().nativeCoreGetProxies();
}

export function callNativeCoreLoadConfig(configText: string): number {
  return getNativeModule().nativeCoreLoadConfig(configText);
}

export function callNativeCoreParseProxies(configText: string): string {
  return getNativeModule().nativeCoreParseProxies(configText);
}

export function callNativeCoreSelectProxy(groupName: string, proxyName: string): number {
  return getNativeModule().nativeCoreSelectProxy(groupName, proxyName);
}

export function callNativeCoreTestDelay(proxyName: string, url: string, timeout: number): number {
  return getNativeModule().nativeCoreTestDelay(proxyName, url, timeout);
}

export function callNativeCoreGetTraffic(): string {
  return getNativeModule().nativeCoreGetTraffic();
}

export function callNativeCoreGetConnections(): string {
  return getNativeModule().nativeCoreGetConnections();
}

export function callNativeCoreGetStatus(): string {
  return getNativeModule().nativeCoreGetStatus();
}
