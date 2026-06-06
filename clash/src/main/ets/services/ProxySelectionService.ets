import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

export class ProxySelection {
  groupName: string = '';
  proxyName: string = '';

  constructor(groupName: string, proxyName: string) {
    this.groupName = groupName;
    this.proxyName = proxyName;
  }
}

export class ProxySelectionService {
  private store: preferences.Preferences | null = null;
  private selections: ProxySelection[] = [];

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, 'proxy_selection_store');
      await this.load();
    } catch (e) {
      Logger.error('Failed to init proxy selections: %{public}s', String(e));
    }
  }

  private async load(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      const data = await this.store.get('proxy_selections', '[]') as string;
      const parsed = JSON.parse(data) as ProxySelection[];
      this.selections = parsed.map((item: ProxySelection): ProxySelection => {
        return new ProxySelection(item.groupName, item.proxyName);
      });
    } catch (e) {
      Logger.error('Failed to load proxy selections: %{public}s', String(e));
      this.selections = [];
    }
  }

  async saveSelection(groupName: string, proxyName: string): Promise<void> {
    let foundIndex = -1;
    for (let i = 0; i < this.selections.length; i++) {
      const item = this.selections[i];
      if (item.groupName === groupName) {
        foundIndex = i;
        break;
      }
    }
    if (foundIndex >= 0) {
      this.selections.splice(foundIndex, 1);
    }
    this.selections.unshift(new ProxySelection(groupName, proxyName));
    await this.save();
  }

  getSelection(groupName: string): string {
    for (const item of this.selections) {
      if (item.groupName === groupName) {
        return item.proxyName;
      }
    }
    return '';
  }

  getSelections(): ProxySelection[] {
    return this.selections;
  }

  private async save(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put('proxy_selections', JSON.stringify(this.selections));
      await this.store.flush();
    } catch (e) {
      Logger.error('Failed to save proxy selections: %{public}s', String(e));
    }
  }
}
