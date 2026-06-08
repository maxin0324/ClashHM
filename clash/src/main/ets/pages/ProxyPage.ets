import { getClashService, IClashService } from '../services/ClashService';
import { ConnectState, ProxyGroup, ProxyNode } from '../models/ClashConfig';
import { ProxyGroupCard, ProxyGroupModel } from '../components/ProxyGroupCard';
import { SubscriptionService } from '../services/SubscriptionService';
import { ConfigManager } from '../services/ConfigManager';
import { ProxySelectionService } from '../services/ProxySelectionService';
import { NativeCoreExtensionService } from '../services/NativeCoreExtensionService';
import { common } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

interface ExtensionProxyNode {
  name?: string;
  type?: string;
  alive?: boolean;
  latency?: number;
}

interface ExtensionProxyGroup {
  name?: string;
  type?: string;
  now?: string;
  all?: string[];
  nodes?: ExtensionProxyNode[];
}

class ProxyLoadResult {
  groups: ProxyGroup[] = [];
  source: string = '';
  detail: string = '';
  fromExtension: boolean = false;
}

@Component
export struct ProxyPage {
  @State groups: ProxyGroupModel[] = [];
  @State statusMsg: string = '';
  @State sourceMsg: string = '';
  @State testingGroup: string = '';
  @State isLoading: boolean = false;
  private service: IClashService | null = null;
  private selectionService: ProxySelectionService | null = null;
  private loadedFromExtension: boolean = false;

  aboutToAppear(): void {
    try {
      this.service = getClashService();
    } catch (e) {
      this.service = null;
      Logger.info('Clash service not ready on Proxy page appear: %{public}s', String(e));
    }
    this.loadProxyGroups();
  }

  private async loadProxyGroups(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.statusMsg = '';
      this.sourceMsg = '';
      this.loadedFromExtension = false;
      this.selectionService = new ProxySelectionService();
      await this.selectionService.init(context);

      const result = await this.loadProxyGroupsFromSources(context);
      if (result.groups.length > 0) {
        this.groups = result.groups.map((g: ProxyGroup) => new ProxyGroupModel(g));
        this.applySavedSelections();
        this.statusMsg = '';
        this.sourceMsg = result.source;
        this.loadedFromExtension = result.fromExtension;
        this.expandLargestGroup();
        return;
      }

      this.groups = [];
      this.statusMsg = 'No proxy groups found. Update the active subscription, then refresh.';
      this.sourceMsg = '';
    } catch (e) {
      this.statusMsg = `Failed to load proxy groups: ${String(e)}`;
      this.sourceMsg = '';
      this.groups = [];
      this.loadedFromExtension = false;
    } finally {
      this.isLoading = false;
    }
  }

  private async loadProxyGroupsFromSources(context: common.UIAbilityContext): Promise<ProxyLoadResult> {
    const loadResult = new ProxyLoadResult();
    const details: string[] = [];

    const localGroups = await this.loadProxyGroupsFromActiveSubscription(context, details);
    if (localGroups.groups.length > 0) {
      localGroups.fromExtension = this.isServiceConnected();
      if (localGroups.fromExtension) {
        details.push('extension: connected; using local config list for stable display');
      } else {
        details.push('extension: skipped while disconnected');
      }
      localGroups.detail = details.join('\n');
      return localGroups;
    }

    if (this.isServiceConnected()) {
      const extensionGroups = await this.loadProxyGroupsFromExtension(context, details);
      if (extensionGroups.length > 0) {
        loadResult.groups = extensionGroups;
        loadResult.source = 'VPN Extension';
        loadResult.detail = details.join('\n');
        loadResult.fromExtension = true;
        return loadResult;
      }
    } else {
      details.push('extension: skipped while disconnected');
    }

    loadResult.detail = details.join('\n');
    return loadResult;
  }

  private isServiceConnected(): boolean {
    return this.service !== null && this.service.getState() === ConnectState.CONNECTED;
  }

  private async loadProxyGroupsFromActiveSubscription(context: common.UIAbilityContext, details: string[]): Promise<ProxyLoadResult> {
    const loadResult = new ProxyLoadResult();
    const subService = new SubscriptionService(context);
    await subService.init();
    const activeSub = subService.getActiveSubscription();
    if (!activeSub || !activeSub.filePath) {
      details.push('subscription: none');
      return loadResult;
    }

    const configManager = new ConfigManager(context);
    const rawConfig = configManager.readConfigFile(activeSub.filePath);
    const rawGroups = configManager.parseProxyGroupsFromContent(rawConfig);
    details.push(`raw subscription: ${rawGroups.length} groups, ${this.countProxyOptions(rawGroups)} options`);
    if (rawGroups.length > 0) {
      loadResult.groups = rawGroups;
      loadResult.source = `${activeSub.name} · raw config`;
      loadResult.detail = details.join('\n');
      return loadResult;
    }

    const mergedConfig = configManager.generateMergedConfig(activeSub.filePath);
    const mergedGroups = configManager.parseProxyGroupsFromContent(mergedConfig);
    details.push(`merged config: ${mergedGroups.length} groups, ${this.countProxyOptions(mergedGroups)} options`);
    if (mergedGroups.length > 0) {
      loadResult.groups = mergedGroups;
      loadResult.source = `${activeSub.name} · merged config`;
      loadResult.detail = details.join('\n');
      return loadResult;
    }

    loadResult.detail = details.join('\n');
    return loadResult;
  }

  private async loadProxyGroupsFromExtension(context: common.UIAbilityContext, details: string[]): Promise<ProxyGroup[]> {
    try {
      const result = await new NativeCoreExtensionService(context).getProxies();
      if (!result.ok || !result.data) {
        details.push(`extension: unavailable ${result.error || result.data || ''}`);
        return [];
      }
      const groups = JSON.parse(result.data) as ExtensionProxyGroup[];
      const mapped = this.mapExtensionGroups(groups);
      details.push(`extension: ${mapped.length} groups, ${this.countProxyOptions(mapped)} options`);
      return mapped;
    } catch (e) {
      Logger.info('Proxy groups from VPN Extension unavailable: %{public}s', String(e));
      details.push(`extension: ${String(e)}`);
      return [];
    }
  }

  private mapExtensionGroups(groups: ExtensionProxyGroup[]): ProxyGroup[] {
    const mapped: ProxyGroup[] = [];
    for (const group of groups) {
      const groupName = group.name === undefined ? '' : group.name;
      const groupType = group.type === undefined ? 'select' : group.type;
      const groupAll = group.all === undefined ? [] : group.all;
      const groupNodes = group.nodes === undefined ? [] : group.nodes;
      if (!groupName || groupAll.length === 0) {
        continue;
      }
      const mappedGroup: ProxyGroup = {
        name: groupName,
        type: groupType,
        now: group.now === undefined || group.now === '' ? groupAll[0] : group.now,
        all: groupAll,
        nodes: groupNodes.map((node: ExtensionProxyNode): ProxyNode => {
          const mappedNode: ProxyNode = {
            name: node.name === undefined ? '' : node.name,
            type: node.type === undefined || node.type === '' ? 'proxy' : node.type,
            server: '',
            port: 0,
            latency: node.latency === undefined ? -1 : node.latency,
            alive: node.alive === undefined ? true : node.alive,
          };
          return mappedNode;
        }),
        expanded: false,
      };
      mapped.push(mappedGroup);
    }
    return mapped;
  }

  private countProxyOptions(groups: ProxyGroup[]): number {
    let count = 0;
    for (const group of groups) {
      count += group.all.length > 0 ? group.all.length : group.nodes.length;
    }
    return count;
  }

  private applySavedSelections(): void {
    if (!this.selectionService) {
      return;
    }
    for (const group of this.groups) {
      const selected = this.selectionService.getSelection(group.name);
      if (selected && group.all.indexOf(selected) >= 0) {
        group.now = selected;
      }
    }
  }

  private expandLargestGroup(): void {
    let maxIndex = -1;
    let maxCount = 0;
    for (let i = 0; i < this.groups.length; i++) {
      this.groups[i].expanded = false;
      const count = this.getGroupOptionCount(this.groups[i]);
      if (count > maxCount) {
        maxIndex = i;
        maxCount = count;
      }
    }
    if (maxIndex >= 0) {
      this.groups[maxIndex].expanded = true;
    }
  }

  private getNodeCount(): number {
    let count = 0;
    for (const group of this.groups) {
      count += this.getGroupOptionCount(group);
    }
    return count;
  }

  private getGroupOptionCount(group: ProxyGroupModel): number {
    return group.all.length > 0 ? group.all.length : group.nodes.length;
  }

  private async selectProxy(groupName: string, proxyName: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!this.selectionService) {
        this.selectionService = new ProxySelectionService();
        await this.selectionService.init(context);
      }
      if (this.selectionService) {
        await this.selectionService.saveSelection(groupName, proxyName);
      }
      if (this.isServiceConnected()) {
        try {
          await new NativeCoreExtensionService(context).selectProxy(groupName, proxyName);
        } catch (e) {
          Logger.error('Select proxy in VPN Extension failed: %{public}s', String(e));
        }
      }
      for (const group of this.groups) {
        if (group.name === groupName) {
          group.now = proxyName;
          break;
        }
      }
      this.sourceMsg = `${groupName}: ${proxyName}`;
      this.publishSelectionChanged(context, groupName, proxyName);
    } catch (e) {
      Logger.error('Select proxy failed: %{public}s', String(e));
    }
  }

  private async testGroupLatency(groupName: string): Promise<void> {
    if (!this.isServiceConnected()) {
      this.sourceMsg = 'Connect VPN to test latency';
      return;
    }
    if (this.testingGroup) {
      return;
    }
    this.testingGroup = groupName;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const extensionService = new NativeCoreExtensionService(context);
      for (const group of this.groups) {
        if (group.name !== groupName) {
          continue;
        }
        for (const node of group.nodes) {
          const delay = await extensionService.testDelay(node.name);
          node.latency = delay.code;
          node.alive = delay.ok && delay.code > 0;
        }
        break;
      }
      await this.syncGroupStateFromExtension(context, extensionService, groupName);
      this.sourceMsg = 'Latency updated';
    } catch (e) {
      this.sourceMsg = `Latency test failed: ${String(e)}`;
      Logger.error('Latency test failed: %{public}s', String(e));
    } finally {
      this.testingGroup = '';
    }
  }

  private async syncGroupStateFromExtension(context: common.UIAbilityContext, extensionService: NativeCoreExtensionService, groupName: string): Promise<void> {
    try {
      const result = await extensionService.getProxies();
      if (!result.ok || !result.data) {
        return;
      }
      await this.syncGroupStateFromNativeJson(context, result.data, groupName);
    } catch (e) {
      Logger.info('Sync proxy group from Extension failed: %{public}s', String(e));
    }
  }

  private async syncGroupStateFromNativeJson(context: common.UIAbilityContext, jsonText: string, groupName: string): Promise<void> {
    try {
      if (!jsonText) {
        return;
      }
      const extensionGroups = JSON.parse(jsonText) as ExtensionProxyGroup[];
      const mappedGroups = this.mapExtensionGroups(extensionGroups);
      for (const mappedGroup of mappedGroups) {
        if (mappedGroup.name !== groupName) {
          continue;
        }
        for (const group of this.groups) {
          if (group.name !== groupName) {
            continue;
          }
          group.now = mappedGroup.now;
          for (const mappedNode of mappedGroup.nodes) {
            for (const node of group.nodes) {
              if (node.name === mappedNode.name) {
                node.latency = mappedNode.latency;
                node.alive = mappedNode.alive;
                break;
              }
            }
          }
          if (this.selectionService && mappedGroup.now && group.all.indexOf(mappedGroup.now) >= 0) {
            await this.selectionService.saveSelection(group.name, mappedGroup.now);
            this.publishSelectionChanged(context, group.name, mappedGroup.now);
          }
          return;
        }
      }
    } catch (e) {
      Logger.info('Sync proxy group from native JSON failed: %{public}s', String(e));
    }
  }

  private publishSelectionChanged(context: common.UIAbilityContext, groupName: string, proxyName: string): void {
    commonEventManager.publish('com.mx.clashhm.PROXY_SELECTION_CHANGED', {
      bundleName: context.abilityInfo.bundleName,
      data: `${groupName}:${proxyName}`,
      parameters: {
        groupName,
        proxyName,
      },
    }, (_err) => {
    });
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text($r('app.string.tab_proxy'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          if (!this.statusMsg) {
            Text(`${this.groups.length} groups · ${this.getNodeCount()} options · ${this.sourceMsg}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.isLoading ? 'Loading' : 'Refresh')
          .type(ButtonType.Normal)
          .height(34)
          .fontSize(13)
          .fontColor(this.isLoading ? $r('app.color.text_secondary') : $r('app.color.primary'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(8)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 12, right: 12 })
          .enabled(!this.isLoading)
          .onClick(() => {
            this.loadProxyGroups();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      if (this.statusMsg) {
        Column({ space: 10 }) {
          Text('No proxy data')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.statusMsg)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('90%')
        .padding(24)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(8)
        .border({ width: 1, color: $r('app.color.divider') })
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.groups, (group: ProxyGroupModel) => {
            ListItem() {
              ProxyGroupCard({
                group: group,
                canTestLatency: this.isServiceConnected() && group.nodes.length > 0,
                isTesting: this.testingGroup === group.name,
                onSelectProxy: (gName: string, pName: string) => {
                  this.selectProxy(gName, pName);
                },
                onTestGroup: (gName: string) => {
                  this.testGroupLatency(gName);
                }
              })
            }
          }, (group: ProxyGroupModel) => group.name)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 14 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
  }
}
