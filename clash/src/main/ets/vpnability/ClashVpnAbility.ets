import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { fileIo } from '@kit.CoreFileKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import {
  callNativeCoreGetConnections,
  callNativeCoreGetProxies,
  callNativeCoreGetStatus,
  callNativeCoreGetTraffic,
  callNativeCoreInit,
  callNativeCoreSelectProxy,
  callNativeCoreSetMode,
  callNativeCoreStartTun,
  callNativeCoreStop,
  callNativeCoreTestDelay
} from '../services/NativeClash';

interface ConfigChunkEventParams {
  configSession?: string;
  configChunkIndex?: number;
  configChunkCount?: number;
  configKind?: string;
  coreConfigChunkCount?: number;
}

interface NativeCoreCommandEventParams {
  commandId?: string;
  commandType?: string;
  groupName?: string;
  proxyName?: string;
  mode?: string;
  url?: string;
  timeoutMs?: number;
}

class NativeCoreCommandResultPayload {
  commandId: string = '';
  commandType: string = '';
  code: number = 0;
  ok: boolean = false;
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private nativeCoreLoaded: boolean = false;
  private statusPath: string = '';
  private statusEvent: string = '';
  private configSession: string = '';
  private coreConfigChunks: string[] = [];
  private coreConfigChunkCount: number = 0;
  private coreConfigReady: boolean = false;
  private statusWritable: boolean = true;
  private configSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private commandSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private pendingStartWant: Want | null = null;
  private engineStarting: boolean = false;
  private engineRunning: boolean = false;
  private engineStartRequested: boolean = false;

  onCreate(want: Want): void {
    super.onCreate(want);
    Logger.info('ClashVpnAbility onCreate');
    this.updateStatusPath(want);
    this.pendingStartWant = want;
    this.ensureConfigSubscriber(want.bundleName || 'com.mx.clashhm');
    this.ensureCommandSubscriber(want.bundleName || 'com.mx.clashhm');
    this.collectConfigChunk(want);
    const moduleName = want.moduleName || '';
    const hasParameters = want.parameters ? 'yes' : 'no';
    this.writeStatus(`onCreate module=${moduleName} params=${hasParameters}`);

    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    const bundleName: string = want.bundleName || 'com.mx.clashhm';

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: '10.249.0.1', family: 1 },
        prefixLength: 30,
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: { address: '0.0.0.0', family: 1 },
          prefixLength: 0,
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true,
      }],
      dnsAddresses: ['1.1.1.1', '8.8.8.8'],
      mtu: 1400,
      trustedApplications: [],
      blockedApplications: [bundleName],
    };

    this.vpnConnection.create(vpnConfig).then((tunFd: number) => {
      this.tunFd = tunFd;
      Logger.info('VPN TUN created, fd=%{public}d', String(tunFd));
      this.writeStatus(`tun created fd=${tunFd}`);
      this.requestStartEngine('tun');
    }).catch((err: Error) => {
      Logger.error('Failed to create VPN: %{public}s', err.message);
      this.writeStatus(`create vpn failed: ${err.message}`);
    });
  }

  onRequest(want: Want, startId: number): void {
    Logger.info('ClashVpnAbility onRequest startId=%{public}s', String(startId));
    this.updateStatusPath(want);
    this.pendingStartWant = want;
    this.collectConfigChunk(want);
    this.writeStatus(`onRequest startId=${startId} tunFd=${this.tunFd}`);
    this.requestStartEngine('request');
  }

  onDestroy(): void {
    Logger.info('ClashVpnAbility onDestroy');
    try {
      if (this.nativeCoreLoaded) {
        callNativeCoreStop();
        Logger.info('Native core stopped in VPN Extension');
      }
    } catch (e) {
      Logger.error('Failed to stop Clash engine in VPN Extension: %{public}s', String(e));
    }
    if (this.vpnConnection) {
      try {
        this.vpnConnection.destroy();
      } catch (e) {
        Logger.error('Failed to destroy VPN connection: %{public}s', String(e));
      }
      this.vpnConnection = null;
    }
    if (this.configSubscriber) {
      try {
        commonEventManager.unsubscribe(this.configSubscriber);
      } catch (e) {
        Logger.error('Failed to unsubscribe VPN config event: %{public}s', String(e));
      }
      this.configSubscriber = null;
    }
    if (this.commandSubscriber) {
      try {
        commonEventManager.unsubscribe(this.commandSubscriber);
      } catch (e) {
        Logger.error('Failed to unsubscribe native core command event: %{public}s', String(e));
      }
      this.commandSubscriber = null;
    }
    this.tunFd = -1;
    super.onDestroy();
  }

  private async startEngine(want: Want, tunFd: number): Promise<void> {
    Logger.info('VPN startEngine entered tunFd=%{public}s starting=%{public}s running=%{public}s coreReady=%{public}s',
      String(tunFd), String(this.engineStarting), String(this.engineRunning), String(this.coreConfigReady));
    if (this.engineStarting) {
      Logger.info('VPN startEngine skipped because another start is in progress');
      this.engineStartRequested = true;
      this.writeStatus('engine start skipped: already starting');
      return;
    }
    if (this.engineRunning) {
      Logger.info('VPN startEngine skipped because engine is already running');
      this.writeStatus('engine start skipped: already running');
      return;
    }
    this.engineStartRequested = false;
    this.engineStarting = true;
    try {
      this.writeStatus('loading engine');
      if (!this.coreConfigReady) {
        Logger.info('VPN engine waiting for native-core config chunks');
        this.writeStatus('waiting for native-core config chunks');
        return;
      }

      const coreConfigContent = this.getCoreConfigContent(want);
      Logger.info('VPN startEngine core config content length=%{public}s', String(coreConfigContent.length));
      if (!coreConfigContent) {
        this.writeStatus('engine start deferred: waiting for native-core config content');
        return;
      }
      this.writeStatus(`starting core config content length=${coreConfigContent.length}`);
      const nativeCoreResult = this.tryStartNativeCore(tunFd, coreConfigContent);
      Logger.info('VPN native core start finished ret=%{public}s', String(nativeCoreResult));
      if (nativeCoreResult >= 0) {
        this.engineRunning = true;
        this.nativeCoreLoaded = true;
        this.writeStatus(`start result: native_core_started ret=${nativeCoreResult}`);
        this.writeStatus(`native core status: ${this.getNativeCoreStatus()}`);
        return;
      }
      const nativeStatus = this.getNativeCoreStatus();
      Logger.error('VPN native core start failed ret=%{public}s status=%{public}s', String(nativeCoreResult), nativeStatus);
      this.writeStatus(`start result: native_core_failed ret=${nativeCoreResult} status=${nativeStatus}`);
    } catch (e) {
      Logger.error('VPN engine start failed: %{public}s', String(e));
      this.writeStatus(`engine start failed: ${String(e)}`);
    } finally {
      this.engineStarting = false;
      if (this.engineStartRequested && this.coreConfigReady && !this.engineRunning && this.tunFd > 0 && this.pendingStartWant) {
        this.engineStartRequested = false;
        setTimeout(() => {
          if (this.pendingStartWant) {
            this.startEngine(this.pendingStartWant, this.tunFd).catch((e: Error) => {
              this.writeStatus(`engine pending rejected: ${e.message}`);
            });
          }
        }, 0);
      }
    }
  }

  private tryStartNativeCore(tunFd: number, configContent: string): number {
    try {
      Logger.info('Native core init begin home=%{public}s', this.context.filesDir);
      const homeRet = callNativeCoreInit(this.context.filesDir);
      Logger.info('Native core init end ret=%{public}s', String(homeRet));
      this.writeStatus(`native core init ret=${homeRet}`);
      if (homeRet < 0) {
        return homeRet;
      }
      Logger.info('Native core startTun begin tunFd=%{public}s configLength=%{public}s', String(tunFd), String(configContent.length));
      const startRet = callNativeCoreStartTun(tunFd, configContent);
      Logger.info('Native core startTun end ret=%{public}s', String(startRet));
      this.writeStatus(`native core start ret=${startRet}`);
      return startRet;
    } catch (e) {
      Logger.error('Native core start exception: %{public}s', String(e));
      this.writeStatus(`native core start failed: ${String(e)}`);
      return -9999;
    }
  }

  private getNativeCoreStatus(): string {
    try {
      return callNativeCoreGetStatus();
    } catch (e) {
      return String(e);
    }
  }

  private requestStartEngine(reason: string): void {
    Logger.info('VPN requestStartEngine reason=%{public}s hasWant=%{public}s tunFd=%{public}s coreReady=%{public}s starting=%{public}s running=%{public}s',
      reason, String(!!this.pendingStartWant), String(this.tunFd), String(this.coreConfigReady), String(this.engineStarting), String(this.engineRunning));
    if (!this.pendingStartWant) {
      this.writeStatus(`engine start deferred: no want reason=${reason}`);
      return;
    }
    if (this.tunFd <= 0) {
      this.writeStatus(`engine start deferred: no tun reason=${reason}`);
      return;
    }
    if (!this.coreConfigReady) {
      this.writeStatus(`engine start deferred: no native-core config reason=${reason}`);
      return;
    }
    Logger.info('VPN requestStartEngine scheduling start reason=%{public}s', reason);
    this.startEngine(this.pendingStartWant, this.tunFd).catch((e: Error) => {
      this.writeStatus(`engine ${reason} rejected: ${e.message}`);
    });
  }

  private writeStatus(message: string): void {
    this.publishStatus(message);
    if (!this.statusWritable) {
      return;
    }
    const statusPath = this.statusPath || `${this.context.filesDir}/vpn-engine-status.txt`;
    const oldText = this.readTextFile(statusPath, false);
    const nextText = oldText ? `${oldText}\n${new Date().toISOString()} ${message}` : `${new Date().toISOString()} ${message}`;
    try {
      const file = fileIo.openSync(statusPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, nextText);
      fileIo.closeSync(file);
    } catch (e) {
      this.statusWritable = false;
      Logger.error('Failed to write VPN status: %{public}s', String(e));
    }
  }

  private publishStatus(message: string): void {
    if (!this.statusEvent) {
      return;
    }
    try {
      commonEventManager.publish(this.statusEvent, {
        data: `${new Date().toISOString()} ${message}`,
        parameters: {
          configSession: this.configSession,
        },
      }, (_err) => {
        // File status is best-effort too; avoid recursive logging here.
      });
    } catch (_e) {
      // Status events are diagnostic only.
    }
  }

  private updateStatusPath(want: Want): void {
    const path = this.getStringParam(want, 'statusPath');
    if (path) {
      this.statusPath = path;
    }
    const event = this.getStringParam(want, 'statusEvent');
    if (event) {
      this.statusEvent = event;
    }
  }

  private getStringParam(want: Want, key: string): string {
    if (!want.parameters) {
      return '';
    }
    const value = want.parameters[key];
    if (typeof value === 'string') {
      return value;
    }
    return '';
  }

  private getNumberParam(want: Want, key: string): number {
    if (!want.parameters) {
      return 0;
    }
    const value = want.parameters[key];
    if (typeof value === 'number') {
      return value;
    }
    return 0;
  }

  private collectConfigChunk(want: Want): void {
    const session = this.getStringParam(want, 'configSession');
    const coreCount = this.getNumberParam(want, 'coreConfigChunkCount');
    const index = this.getNumberParam(want, 'configChunkIndex');
    const data = this.getStringParam(want, 'configChunkData');
    if (session && coreCount > 0 && !data) {
      this.prepareConfigSession(session, coreCount, 'core');
    }
    if (session && coreCount > 0 && data) {
      this.collectConfigChunkValues(session, coreCount, index, data, 'core', 'want');
    }

  }

  private prepareConfigSession(session: string, count: number, kind: string): void {
    if (kind === 'core') {
      if (session !== this.configSession || count !== this.coreConfigChunkCount) {
        this.configSession = session;
        this.coreConfigChunkCount = count;
        this.coreConfigChunks = new Array<string>(count);
        this.coreConfigReady = false;
        this.engineRunning = false;
        this.writeStatus(`core config session prepared count=${count}`);
      }
      return;
    }
  }

  private collectConfigChunkValues(session: string, count: number, index: number, data: string, kind: string, source: string): void {
    if (!session || count <= 0 || !data) {
      return;
    }
    if (kind === 'core') {
      this.collectConfigChunkInto(session, count, index, data, 'core', source);
      return;
    }
    this.writeStatus(`config chunk ignored: unsupported kind=${kind}`);
  }

  private collectConfigChunkInto(session: string, count: number, index: number, data: string, kind: string, source: string): void {
    this.prepareConfigSession(session, count, kind);
    const targetCount = this.coreConfigChunkCount;
    if (index < 0 || index >= targetCount) {
      Logger.error('VPN %{public}s config chunk index out of range: %{public}s/%{public}s', kind, String(index), String(targetCount));
      return;
    }
    this.coreConfigChunks[index] = data;
    let received = 0;
    for (let i = 0; i < targetCount; i++) {
      const chunk = this.coreConfigChunks[i];
      if (chunk) {
        received++;
      }
    }
    Logger.info('VPN %{public}s config chunk received from %{public}s: %{public}s/%{public}s session=%{public}s', kind, source, String(received), String(targetCount), session);
    this.coreConfigReady = received === this.coreConfigChunkCount;
    if (this.coreConfigReady) {
      Logger.info('VPN %{public}s config ready chunks=%{public}s source=%{public}s session=%{public}s', kind, String(targetCount), source, session);
      this.writeStatus(`${kind} config ready chunks=${targetCount} source=${source}`);
      this.requestStartEngine('config');
    }
  }

  private ensureConfigSubscriber(bundleName: string): void {
    if (this.configSubscriber) {
      return;
    }
    try {
      const subscriber = commonEventManager.createSubscriberSync({
        events: ['com.mx.clashhm.CONFIG_CHUNK'],
        publisherBundleName: bundleName,
      });
      this.configSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err, data) => {
        if (err) {
          Logger.error('VPN config event error: %{public}s', String(err));
          this.writeStatus(`config event error: ${String(err)}`);
          return;
        }
        if (!data.parameters) {
          this.writeStatus('config event ignored: missing parameters');
          return;
        }
        const params = data.parameters as ConfigChunkEventParams;
        const session = params.configSession || '';
        const index = params.configChunkIndex === undefined ? 0 : params.configChunkIndex;
        const count = params.configChunkCount === undefined ? 0 : params.configChunkCount;
        const kind = params.configKind || 'core';
        const chunk = data.data || '';
        Logger.info('VPN config event received kind=%{public}s index=%{public}s count=%{public}s length=%{public}s', kind, String(index), String(count), String(chunk.length));
        this.collectConfigChunkValues(session, count, index, chunk, kind, 'event');
      });
      Logger.info('VPN config subscriber ready');
      this.writeStatus('config subscriber ready');
    } catch (e) {
      Logger.error('VPN config subscriber failed: %{public}s', String(e));
      this.writeStatus(`config subscriber failed: ${String(e)}`);
    }
  }

  private ensureCommandSubscriber(bundleName: string): void {
    if (this.commandSubscriber) {
      return;
    }
    try {
      const subscriber = commonEventManager.createSubscriberSync({
        events: ['com.mx.clashhm.NATIVE_CORE_COMMAND'],
        publisherBundleName: bundleName,
      });
      this.commandSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err, data) => {
        if (err) {
          Logger.error('Native core command event error: %{public}s', String(err));
          this.writeStatus(`native core command event error: ${String(err)}`);
          return;
        }
        if (!data.parameters) {
          this.writeStatus('native core command ignored: missing parameters');
          return;
        }
        const params = data.parameters as NativeCoreCommandEventParams;
        this.handleNativeCoreCommand(params);
      });
      Logger.info('Native core command subscriber ready');
      this.writeStatus('native core command subscriber ready');
    } catch (e) {
      Logger.error('Native core command subscriber failed: %{public}s', String(e));
      this.writeStatus(`native core command subscriber failed: ${String(e)}`);
    }
  }

  private handleNativeCoreCommand(params: NativeCoreCommandEventParams): void {
    const commandId = params.commandId || '';
    const commandType = params.commandType || '';
    let code = 0;
    let resultData = '';
    let error = '';
    try {
      if (commandType === 'status') {
        resultData = callNativeCoreGetStatus();
      } else if (commandType === 'getProxies') {
        resultData = callNativeCoreGetProxies();
      } else if (commandType === 'selectProxy') {
        code = callNativeCoreSelectProxy(params.groupName || '', params.proxyName || '');
        if (code < 0 && !this.nativeCoreLoaded) {
          error = 'native core is not running';
        }
      } else if (commandType === 'setMode') {
        code = callNativeCoreSetMode(params.mode || 'rule');
        if (code < 0 && !this.nativeCoreLoaded) {
          error = 'native core is not running';
        }
      } else if (commandType === 'testDelay') {
        code = callNativeCoreTestDelay(params.proxyName || '', params.url || '', params.timeoutMs || 5000);
      } else if (commandType === 'getTraffic') {
        resultData = callNativeCoreGetTraffic();
      } else if (commandType === 'getConnections') {
        resultData = callNativeCoreGetConnections();
      } else if (commandType === 'stop') {
        code = callNativeCoreStop();
        this.nativeCoreLoaded = false;
        this.engineRunning = false;
      } else {
        code = -1;
        error = `unrecognized command: ${commandType}`;
      }
    } catch (e) {
      code = -2;
      error = String(e);
    }
    this.publishNativeCoreCommandResult(commandId, commandType, code, resultData, error);
  }

  private publishNativeCoreCommandResult(commandId: string, commandType: string, code: number, resultData: string, error: string): void {
    const ok = code >= 0 && !error;
    const payload = new NativeCoreCommandResultPayload();
    payload.commandId = commandId;
    payload.commandType = commandType;
    payload.code = code;
    payload.ok = ok;
    try {
      commonEventManager.publish('com.mx.clashhm.NATIVE_CORE_RESULT', {
        data: error ? error : resultData,
        parameters: payload,
      }, (_err) => {
      });
    } catch (e) {
      this.writeStatus(`native core result publish failed: ${String(e)}`);
    }
  }

  private getCoreConfigContent(want: Want): string {
    const configText = this.getStringParam(want, 'coreConfigText');
    if (configText) {
      return configText;
    }
    if (this.coreConfigReady && this.coreConfigChunkCount > 0) {
      return this.coreConfigChunks.join('');
    }
    return '';
  }

  private readTextFile(path: string, logError: boolean = true): string {
    try {
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const bytes = new Uint8Array(buffer);
      let text = '';
      for (let i = 0; i < bytes.length; i++) {
        text += String.fromCharCode(bytes[i]);
      }
      return text.trim();
    } catch (e) {
      if (logError) {
        Logger.error('Failed to read text file %{public}s: %{public}s', path, String(e));
      }
      return '';
    }
  }
}
