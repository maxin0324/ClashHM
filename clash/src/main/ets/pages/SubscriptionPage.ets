import { SubscriptionCard, SubscriptionCardModel } from '../components/SubscriptionCard';
import { Subscription } from '../models/Subscription';
import { SubscriptionService } from '../services/SubscriptionService';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

@Component
export struct SubscriptionPage {
  @State subscriptions: SubscriptionCardModel[] = [];
  @State isLoading: boolean = false;
  @State showAddDialog: boolean = false;
  @State dialogName: string = '';
  @State dialogUrl: string = '';
  @State editingId: string = '';
  @State errorMsg: string = '';
  private subService: SubscriptionService | null = null;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.subService = new SubscriptionService(context);
    this.loadSubscriptions();
  }

  private async loadSubscriptions(): Promise<void> {
    if (!this.subService) {
      return;
    }
    try {
      await this.subService.init();
      this.refreshList();
    } catch (e) {
      Logger.error('Failed to load subscriptions: %{public}s', String(e));
    }
  }

  private refreshList(): void {
    if (!this.subService) {
      return;
    }
    const subs = this.subService.getSubscriptions();
    this.subscriptions = subs.map((s: Subscription): SubscriptionCardModel => {
      return SubscriptionCardModel.fromSubscription(s);
    });
  }

  private showAddSubscriptionDialog(isEdit: boolean = false): void {
    if (!isEdit) {
      this.dialogName = '';
      this.dialogUrl = '';
      this.editingId = '';
    }
    this.errorMsg = '';
    this.showAddDialog = true;
  }

  private async confirmAdd(): Promise<void> {
    if (!this.dialogName.trim() || !this.dialogUrl.trim()) {
      this.errorMsg = 'Please fill in all fields';
      return;
    }

    if (!this.subService) {
      return;
    }

    this.isLoading = true;
    this.errorMsg = '';

    try {
      if (this.editingId) {
        await this.subService.editSubscription(this.editingId, this.dialogName, this.dialogUrl);
      } else {
        await this.subService.addSubscription(this.dialogName, this.dialogUrl);
      }
      this.showAddDialog = false;
      this.dialogName = '';
      this.dialogUrl = '';
      this.editingId = '';
      this.refreshList();
    } catch (e) {
      this.errorMsg = `Failed: ${String(e)}`;
      Logger.error('Subscription operation failed: %{public}s', String(e));
    } finally {
      this.isLoading = false;
    }
  }

  private async deleteSubscription(id: string): Promise<void> {
    if (!this.subService) {
      return;
    }
    try {
      await this.subService.deleteSubscription(id);
      this.refreshList();
    } catch (e) {
      Logger.error('Delete failed: %{public}s', String(e));
    }
  }

  private async setActive(id: string): Promise<void> {
    if (!this.subService) {
      return;
    }
    try {
      await this.subService.setActive(id);
      this.refreshList();
    } catch (e) {
      Logger.error('Set active failed: %{public}s', String(e));
    }
  }

  private async updateSubscription(id: string): Promise<void> {
    if (!this.subService) {
      return;
    }
    this.isLoading = true;
    try {
      await this.subService.updateSubscription(id);
      this.refreshList();
    } catch (e) {
      Logger.error('Update failed: %{public}s', String(e));
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Stack() {
      Column() {
        // Header
        Row() {
          Text($r('app.string.tab_subscription'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Blank()

          if (this.isLoading) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color($r('app.color.primary'))
          }

          Button() {
            Text('+')
              .fontSize(22)
              .fontColor(Color.White)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor($r('app.color.primary'))
          .margin({ left: 8 })
          .onClick(() => {
            this.showAddSubscriptionDialog();
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 8 })

        if (this.subscriptions.length === 0) {
          Column({ space: 16 }) {
            Text('📂')
              .fontSize(48)
              .opacity(0.5)

            Text($r('app.string.no_subscription'))
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))

            Button($r('app.string.add_subscription'))
              .type(ButtonType.Normal)
              .height(40)
              .fontSize(14)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.primary'))
              .borderRadius(20)
              .padding({ left: 24, right: 24 })
              .onClick(() => {
                this.showAddSubscriptionDialog();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 12 }) {
            ForEach(this.subscriptions, (sub: SubscriptionCardModel) => {
              ListItem() {
                SubscriptionCard({
                  sub: sub,
                  onTap: () => {
                    this.setActive(sub.id);
                  },
                  onUpdate: () => {
                    this.updateSubscription(sub.id);
                  },
                  onEdit: () => {
                    this.dialogName = sub.name;
                    this.dialogUrl = sub.url;
                    this.editingId = sub.id;
                    this.showAddSubscriptionDialog(true);
                  },
                  onDelete: () => {
                    this.deleteSubscription(sub.id);
                  }
                })
              }
            }, (sub: SubscriptionCardModel) => sub.id + '_' + sub.lastUpdate.toString())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, bottom: 16 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      // Add/Edit dialog
      if (this.showAddDialog) {
        Column() {
          Column({ space: 20 }) {
            Text(this.editingId ? $r('app.string.edit_subscription') : $r('app.string.add_subscription'))
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Column({ space: 8 }) {
              Text($r('app.string.subscription_name'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .alignSelf(ItemAlign.Start)
              TextInput({ placeholder: 'My Subscription', text: this.dialogName })
                .height(44)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_bg'))
                .onChange((value: string) => {
                  this.dialogName = value;
                })
            }

            Column({ space: 8 }) {
              Text($r('app.string.subscription_url'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .alignSelf(ItemAlign.Start)
              TextInput({ placeholder: 'https://...', text: this.dialogUrl })
                .height(44)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_bg'))
                .type(InputType.URL)
                .onChange((value: string) => {
                  this.dialogUrl = value;
                })
            }

            if (this.errorMsg) {
              Text(this.errorMsg)
                .fontSize(12)
                .fontColor($r('app.color.error_color'))
                .width('100%')
            }

            Row({ space: 12 }) {
              Button($r('app.string.cancel'))
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(44)
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(22)
                .onClick(() => {
                  this.showAddDialog = false;
                })

              Button($r('app.string.confirm'))
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(44)
                .fontSize(16)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.primary'))
                .borderRadius(22)
                .enabled(!this.isLoading)
                .onClick(() => {
                  this.confirmAdd();
                })
            }
            .width('100%')
          }
          .width('90%')
          .padding(24)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 4 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (!this.isLoading) {
            this.showAddDialog = false;
          }
        })
      }
    }
  }
}
