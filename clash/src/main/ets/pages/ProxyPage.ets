import { getClashService, IClashService } from '../services/ClashService';
import { ProxyGroup } from '../models/ClashConfig';
import { ProxyGroupCard, ProxyGroupModel } from '../components/ProxyGroupCard';
import { SubscriptionService } from '../services/SubscriptionService';
import { ConfigManager } from '../services/ConfigManager';
import { ProxySelectionService } from '../services/ProxySelectionService';
import { common } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

@Component
export struct ProxyPage {
  @State groups: ProxyGroupModel[] = [];
  @State statusMsg: string = '';
  @State sourceMsg: string = '';
  @State testingGroup: string = '';
  private service: IClashService | null = null;
  private selectionService: ProxySelectionService | null = null;

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.loadProxyGroups();
    } catch (_e) {
      this.statusMsg = 'Service not ready';
    }
  }

  private async loadProxyGroups(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.selectionService = new ProxySelectionService();
      await this.selectionService.init(context);

      if (this.service) {
        try {
          await this.ensureCoreForProxy();
          const rawGroups = await this.service.getProxyGroupsAsync();
          if (rawGroups.length > 0) {
            this.groups = rawGroups.map((g: ProxyGroup) => new ProxyGroupModel(g));
            this.applySavedSelections();
            this.statusMsg = '';
            this.sourceMsg = 'Live from mihomo';
            this.expandLargestGroup();
            return;
          }
        } catch (e) {
          Logger.error('Load live proxy groups failed: %{public}s', String(e));
        }
      }

      {
        const subService = new SubscriptionService(context);
        await subService.init();
        const activeSub = subService.getActiveSubscription();
        if (!activeSub || !activeSub.filePath) {
          this.statusMsg = 'No active subscription. Add one first.';
          this.sourceMsg = '';
          this.groups = [];
          return;
        }
        const configManager = new ConfigManager(context);
        const rawGroups = configManager.parseProxyGroupsFromFile(activeSub.filePath);
        this.groups = rawGroups.map((g: ProxyGroup) => new ProxyGroupModel(g));
        this.applySavedSelections();
        this.statusMsg = this.groups.length === 0 ? 'No proxy groups found in the active subscription.' : '';
        this.sourceMsg = activeSub.name;
      }

      this.expandLargestGroup();
      if (this.groups.length === 0 && !this.statusMsg) {
        this.statusMsg = 'No proxy groups found. Update the active subscription, then refresh.';
      }
    } catch (e) {
      this.statusMsg = `Failed to load proxy groups: ${String(e)}`;
      this.sourceMsg = '';
      this.groups = [];
    }
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
      const count = this.groups[i].nodes.length;
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
      count += group.nodes.length;
    }
    return count;
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
      if (this.service && this.service.isCoreRunning()) {
        await this.service.selectProxy(groupName, proxyName);
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
    if (!this.service) {
      return;
    }
    this.testingGroup = groupName;
    try {
      await this.ensureCoreForProxy();
      const results = await this.service.testGroupLatency(groupName);
      for (const group of this.groups) {
        if (group.name !== groupName) {
          continue;
        }
        for (const node of group.nodes) {
          if (results.has(node.name)) {
            const latency = results.get(node.name) as number;
            node.latency = latency;
            node.alive = latency > 0;
          }
        }
        break;
      }
      this.sourceMsg = 'Latency updated';
    } catch (e) {
      this.sourceMsg = `Latency test failed: ${String(e)}`;
      Logger.error('Latency test failed: %{public}s', String(e));
    } finally {
      this.testingGroup = '';
    }
  }

  private async ensureCoreForProxy(): Promise<void> {
    if (!this.service || this.service.isCoreRunning()) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const subService = new SubscriptionService(context);
    await subService.init();
    const activeSub = subService.getActiveSubscription();
    if (!activeSub || !activeSub.filePath) {
      throw new Error('No active subscription. Add one first.');
    }
    const configPath = `${context.filesDir}/proxy-preview-core.yaml`;
    const configText = new ConfigManager(context).generateMergedConfig(activeSub.filePath);
    this.writeTextFile(configPath, configText);
    await this.service.startCore(configPath);

    if (this.selectionService) {
      const selections = this.selectionService.getSelections();
      for (const selection of selections) {
        if (selection.groupName && selection.proxyName) {
          await this.service.selectProxy(selection.groupName, selection.proxyName);
        }
      }
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

  private writeTextFile(path: string, text: string): void {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (e) {
      Logger.error('Failed to write proxy preview config: %{public}s', String(e));
    }
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
            Text(`${this.groups.length} groups · ${this.getNodeCount()} nodes · ${this.sourceMsg}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('Refresh')
          .type(ButtonType.Normal)
          .height(34)
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(8)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 12, right: 12 })
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
                canTestLatency: this.service !== null,
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
