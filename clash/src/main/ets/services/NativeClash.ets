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

export function callLoadEngine(libDir: string): string {
  return getNativeModule().loadEngine(libDir);
}

export function callInit(homeDir: string): string {
  return getNativeModule().init(homeDir);
}

export function callStartContent(configText: string): string {
  return getNativeModule().startContent(configText);
}

export function callStop(): void {
  getNativeModule().stop();
}

export function callSelectProxy(groupName: string, proxyName: string): number {
  return getNativeModule().selectProxy(groupName, proxyName);
}

export function callSetTunFd(fd: number): void {
  getNativeModule().setTunFd(fd);
}

export function callStartTun2SocksContent(configText: string, tunFd: number): string {
  return getNativeModule().startTun2SocksContent(configText, tunFd);
}

export function callStopTun2Socks(): void {
  getNativeModule().stopTun2Socks();
}

export function callGetTun2SocksStatus(): string {
  return getNativeModule().getTun2SocksStatus();
}
