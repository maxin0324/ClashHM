import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { fileIo } from '@kit.CoreFileKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import {
  callGetTun2SocksStatus,
  callStartTun2SocksContent,
  callStopTun2Socks
} from '../services/NativeClash';

interface ConfigChunkEventParams {
  configSession?: string;
  configChunkIndex?: number;
  configChunkCount?: number;
  configKind?: string;
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private engineLoaded: boolean = false;
  private statusPath: string = '';
  private statusEvent: string = '';
  private configSession: string = '';
  private configChunks: string[] = [];
  private configChunkCount: number = 0;
  private configReady: boolean = false;
  private statusWritable: boolean = true;
  private configSubscriber: commonEventManager.CommonEventSubscriber | null = null;
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
      if (this.engineLoaded) {
        callStopTun2Socks();
        Logger.info('Clash engine stopped in VPN Extension');
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
    this.tunFd = -1;
    super.onDestroy();
  }

  private async startEngine(want: Want, tunFd: number): Promise<void> {
    if (this.engineStarting) {
      this.engineStartRequested = true;
      this.writeStatus('engine start skipped: already starting');
      return;
    }
    if (this.engineRunning) {
      this.writeStatus('engine start skipped: already running');
      return;
    }
    this.engineStartRequested = false;
    this.engineStarting = true;
    try {
      this.writeStatus('loading engine');
      if (!this.configReady) {
        Logger.info('VPN engine waiting for config chunks');
        this.writeStatus('waiting for tun2socks config chunks');
        return;
      }
      const configContent = this.getConfigContent(want);
      if (!configContent) {
        Logger.error('VPN start missing config content');
        this.writeStatus('start failed: missing config content');
        return;
      }

      this.writeStatus(`starting config content length=${configContent.length}`);
      this.writeStatus('starting native tun2socks');
      const startResult: string = callStartTun2SocksContent(configContent, tunFd);
      Logger.info('VPN tun2socks start: %{public}s', startResult);
      this.writeStatus(`start result: ${startResult}`);
      this.engineRunning = startResult.startsWith('started') || startResult === 'already_running';
      this.engineLoaded = this.engineRunning;
      if (this.engineRunning) {
        setTimeout(() => {
          try {
            this.writeStatus(`tun2socks status: ${callGetTun2SocksStatus()}`);
          } catch (e) {
            this.writeStatus(`tun2socks status failed: ${String(e)}`);
          }
        }, 1000);
      }
    } catch (e) {
      Logger.error('VPN engine start failed: %{public}s', String(e));
      this.writeStatus(`engine start failed: ${String(e)}`);
    } finally {
      this.engineStarting = false;
      if (this.engineStartRequested && this.configReady && !this.engineRunning && this.tunFd > 0 && this.pendingStartWant) {
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

  private requestStartEngine(reason: string): void {
    if (!this.pendingStartWant) {
      this.writeStatus(`engine start deferred: no want reason=${reason}`);
      return;
    }
    if (this.tunFd <= 0) {
      this.writeStatus(`engine start deferred: no tun reason=${reason}`);
      return;
    }
    if (!this.configReady) {
      this.writeStatus(`engine start deferred: no config reason=${reason}`);
      return;
    }
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
    const count = this.getNumberParam(want, 'configChunkCount');
    const index = this.getNumberParam(want, 'configChunkIndex');
    const data = this.getStringParam(want, 'configChunkData');
    if (session && count > 0 && !data) {
      if (session !== this.configSession || count !== this.configChunkCount) {
        this.configSession = session;
        this.configChunkCount = count;
        this.configChunks = new Array<string>(count);
        this.configReady = false;
        this.engineRunning = false;
        this.writeStatus(`config session prepared count=${count}`);
      }
    } else if (session && count > 0 && data) {
      this.collectConfigChunkValues(session, count, index, data, 'want');
    }

  }

  private collectConfigChunkValues(session: string, count: number, index: number, data: string, source: string): void {
    if (!session || count <= 0 || !data) {
      return;
    }
    if (session !== this.configSession || count !== this.configChunkCount) {
      this.configSession = session;
      this.configChunkCount = count;
      this.configChunks = new Array<string>(count);
      this.configReady = false;
      this.engineRunning = false;
    }
    if (index < 0 || index >= this.configChunkCount) {
      Logger.error('VPN config chunk index out of range: %{public}s/%{public}s', String(index), String(this.configChunkCount));
      return;
    }
    this.configChunks[index] = data;
    let received = 0;
    for (let i = 0; i < this.configChunkCount; i++) {
      if (this.configChunks[i]) {
        received++;
      }
    }
    Logger.info('VPN config chunk received from %{public}s: %{public}s/%{public}s session=%{public}s', source, String(received), String(this.configChunkCount), session);
    this.configReady = received === this.configChunkCount;
    if (this.configReady) {
      this.writeStatus(`config ready chunks=${this.configChunkCount} source=${source}`);
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
        const chunk = data.data || '';
        Logger.info('VPN config event received index=%{public}s count=%{public}s length=%{public}s', String(index), String(count), String(chunk.length));
        this.collectConfigChunkValues(session, count, index, chunk, 'event');
      });
      Logger.info('VPN config subscriber ready');
      this.writeStatus('config subscriber ready');
    } catch (e) {
      Logger.error('VPN config subscriber failed: %{public}s', String(e));
      this.writeStatus(`config subscriber failed: ${String(e)}`);
    }
  }

  private getConfigContent(want: Want): string {
    const configText = this.getStringParam(want, 'configText');
    if (configText) {
      return configText;
    }
    if (this.configReady && this.configChunkCount > 0) {
      return this.configChunks.join('');
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
