import { commonEventManager } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';

interface NativeCoreResultParams {
  commandId?: string;
  commandType?: string;
  code?: number;
  ok?: boolean;
}

export class NativeCoreCommandResult {
  commandId: string = '';
  commandType: string = '';
  code: number = 0;
  ok: boolean = false;
  data: string = '';
  error: string = '';
}

class NativeCoreCommandPayload {
  commandId: string = '';
  commandType: string = '';
  groupName: string = '';
  proxyName: string = '';
  mode: string = '';
  url: string = '';
  timeoutMs: number = 0;
}

export class NativeCoreExtensionService {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async getStatus(): Promise<NativeCoreCommandResult> {
    return this.sendCommand('status', '', '', Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 3000);
  }

  async getProxies(): Promise<NativeCoreCommandResult> {
    return this.sendCommand('getProxies', '', '', Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 5000);
  }

  async selectProxy(groupName: string, proxyName: string): Promise<NativeCoreCommandResult> {
    return this.sendCommand('selectProxy', groupName, proxyName, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 8000);
  }

  async setMode(mode: string): Promise<NativeCoreCommandResult> {
    return this.sendCommandWithMode('setMode', mode, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 8000);
  }

  async testDelay(proxyName: string): Promise<NativeCoreCommandResult> {
    return this.sendCommand('testDelay', '', proxyName, Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, Constants.LATENCY_TEST_TIMEOUT + 2000);
  }

  async getTraffic(): Promise<NativeCoreCommandResult> {
    return this.sendCommand('getTraffic', '', '', Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 3000);
  }

  async getConnections(): Promise<NativeCoreCommandResult> {
    return this.sendCommand('getConnections', '', '', Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 3000);
  }

  async stop(): Promise<NativeCoreCommandResult> {
    return this.sendCommand('stop', '', '', Constants.LATENCY_TEST_URL, Constants.LATENCY_TEST_TIMEOUT, 3000);
  }

  private sendCommand(commandType: string, groupName: string, proxyName: string, url: string, timeoutMs: number, waitMs: number): Promise<NativeCoreCommandResult> {
    return this.sendCommandWithMode(commandType, '', url, timeoutMs, waitMs, groupName, proxyName);
  }

  private sendCommandWithMode(commandType: string, mode: string, url: string, timeoutMs: number, waitMs: number, groupName: string = '', proxyName: string = ''): Promise<NativeCoreCommandResult> {
    const commandId = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
    return new Promise((resolve, reject) => {
      let finished = false;
      let subscriber: commonEventManager.CommonEventSubscriber | null = null;
      const finish = (result: NativeCoreCommandResult | null, error: Error | null): void => {
        if (finished) {
          return;
        }
        finished = true;
        if (subscriber) {
          commonEventManager.unsubscribe(subscriber);
          subscriber = null;
        }
        if (error) {
          reject(error);
          return;
        }
        if (result) {
          resolve(result);
        }
      };

      try {
        const payload = new NativeCoreCommandPayload();
        payload.commandId = commandId;
        payload.commandType = commandType;
        payload.groupName = groupName;
        payload.proxyName = proxyName;
        payload.mode = mode;
        payload.url = url;
        payload.timeoutMs = timeoutMs;

        subscriber = commonEventManager.createSubscriberSync({
          events: ['com.mx.clashhm.NATIVE_CORE_RESULT'],
        });
        commonEventManager.subscribe(subscriber, (err, data) => {
          if (err) {
            finish(null, new Error(this.describeError(err)));
            return;
          }
          if (!data.parameters) {
            return;
          }
          const params = data.parameters as NativeCoreResultParams;
          if ((params.commandId || '') !== commandId) {
            return;
          }
          const result = new NativeCoreCommandResult();
          result.commandId = params.commandId || '';
          result.commandType = params.commandType || '';
          result.code = params.code === undefined ? 0 : params.code;
          result.ok = params.ok === undefined ? false : params.ok;
          result.data = data.data || '';
          result.error = result.ok ? '' : result.data;
          finish(result, null);
        });

        commonEventManager.publish('com.mx.clashhm.NATIVE_CORE_COMMAND', {
          bundleName: this.context.abilityInfo.bundleName,
          parameters: payload,
        }, (err) => {
          if (err) {
            finish(null, new Error(this.describeError(err)));
          }
        });
      } catch (e) {
        finish(null, new Error(this.describeError(e)));
        return;
      }

      setTimeout(() => {
        finish(null, new Error(`Native core command ${commandType} timed out after ${waitMs}ms`));
      }, waitMs);
    });
  }

  private describeError(error: Object | string): string {
    if (error instanceof Error) {
      return error.message;
    }
    const text = String(error);
    if (text !== '[object Object]') {
      return text;
    }
    try {
      return JSON.stringify(error);
    } catch (_e) {
      return text;
    }
  }
}
