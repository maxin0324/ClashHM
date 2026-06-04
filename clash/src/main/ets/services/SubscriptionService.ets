import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { Subscription, createDefaultSubscription } from '../models/Subscription';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export class SubscriptionService {
  private context: common.UIAbilityContext;
  private store: preferences.Preferences | null = null;
  private subscriptions: Subscription[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async init(): Promise<void> {
    this.store = await preferences.getPreferences(this.context, 'subscriptions_store');
    await this.loadSubscriptions();
  }

  private async loadSubscriptions(): Promise<void> {
    if (!this.store) {
      return;
    }
    const data = await this.store.get(Constants.SUBSCRIPTIONS_KEY, '[]') as string;
    try {
      this.subscriptions = JSON.parse(data) as Subscription[];
    } catch (e) {
      Logger.error('Failed to parse subscriptions: %{public}s', String(e));
      this.subscriptions = [];
    }
  }

  private async saveSubscriptions(): Promise<void> {
    if (!this.store) {
      return;
    }
    await this.store.put(Constants.SUBSCRIPTIONS_KEY, JSON.stringify(this.subscriptions));
    await this.store.flush();
  }

  getSubscriptions(): Subscription[] {
    return this.subscriptions;
  }

  getActiveSubscription(): Subscription | null {
    return this.subscriptions.find(s => s.isActive) || null;
  }

  async addSubscription(name: string, url: string): Promise<Subscription> {
    const sub = createDefaultSubscription();
    sub.id = this.generateId();
    sub.name = name;
    sub.url = url;
    sub.isActive = this.subscriptions.length === 0;

    const configDir = `${this.context.filesDir}/${Constants.CONFIG_DIR}`;
    try {
      fileIo.mkdirSync(configDir, true);
    } catch (_e) {
      // directory may exist
    }
    sub.filePath = `${configDir}/${sub.id}.yaml`;

    await this.fetchSubscriptionContent(sub);
    this.subscriptions.push(sub);
    await this.saveSubscriptions();
    return sub;
  }

  async updateSubscription(id: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (!sub) {
      return;
    }
    await this.fetchSubscriptionContent(sub);
    sub.lastUpdate = Date.now();
    await this.saveSubscriptions();
  }

  async deleteSubscription(id: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (sub) {
      try {
        fileIo.unlinkSync(sub.filePath);
      } catch (_e) {
        // file may not exist
      }
      this.subscriptions = this.subscriptions.filter(s => s.id !== id);
      if (sub.isActive && this.subscriptions.length > 0) {
        this.subscriptions[0].isActive = true;
      }
      await this.saveSubscriptions();
    }
  }

  async setActive(id: string): Promise<void> {
    for (const sub of this.subscriptions) {
      sub.isActive = sub.id === id;
    }
    await this.saveSubscriptions();
  }

  async editSubscription(id: string, name: string, url: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (sub) {
      sub.name = name;
      sub.url = url;
      await this.saveSubscriptions();
    }
  }

  private async fetchSubscriptionContent(sub: Subscription): Promise<void> {
    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(sub.url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'ClashHM/1.0.0 (HarmonyOS)',
        },
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      if (response.responseCode === http.ResponseCode.OK) {
        let content = response.result as string;

        const subInfo = response.header as Record<string, string>;
        this.parseSubscriptionInfo(sub, subInfo);

        if (this.isBase64(content)) {
          const decoder = new util.Base64Helper();
          const textDecoder = util.TextDecoder.create('utf-8');
          const decoded = decoder.decodeSync(content);
          content = textDecoder.decodeToString(decoded);
        }

        const file = fileIo.openSync(sub.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, content);
        fileIo.closeSync(file);

        sub.lastUpdate = Date.now();
        this.countNodes(sub, content);
      }
      httpRequest.destroy();
    } catch (e) {
      Logger.error('Failed to fetch subscription: %{public}s', String(e));
      throw e;
    }
  }

  private parseSubscriptionInfo(sub: Subscription, headers: Record<string, string>): void {
    const userInfo = headers['subscription-userinfo'] || headers['Subscription-Userinfo'] || '';
    if (userInfo) {
      const parts = userInfo.split(';');
      for (const part of parts) {
        const kv = part.trim().split('=');
        if (kv.length === 2) {
          const key = kv[0].trim();
          const value = parseInt(kv[1].trim());
          if (key === 'upload') sub.uploadUsed = value;
          else if (key === 'download') sub.downloadUsed = value;
          else if (key === 'total') sub.totalData = value;
          else if (key === 'expire') sub.expireDate = value * 1000;
        }
      }
    }
  }

  private countNodes(sub: Subscription, content: string): void {
    const lines = content.split('\n');
    let count = 0;
    let inProxies = false;
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed === 'proxies:') {
        inProxies = true;
        continue;
      }
      if (inProxies) {
        if (trimmed.startsWith('- {') || trimmed.startsWith('- name:')) {
          count++;
        } else if (!trimmed.startsWith('-') && !trimmed.startsWith('#') && trimmed.length > 0 && !trimmed.startsWith(' ')) {
          inProxies = false;
        }
      }
    }
    sub.nodeCount = count;
  }

  private isBase64(str: string): boolean {
    const trimmed = str.trim();
    if (trimmed.length === 0 || trimmed.includes('proxies:')) {
      return false;
    }
    const base64Regex = /^[A-Za-z0-9+/\n\r]+=*$/;
    return base64Regex.test(trimmed.replace(/\s/g, ''));
  }

  private generateId(): string {
    return `sub_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
  }
}
