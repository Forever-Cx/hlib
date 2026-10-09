/*
 * ProxySetupDialog.ets
 *
 * 代理配置弹窗。存在的意义：**应用启动阶段网络不通时，用户根本进不去设置页**，
 * 必须在启动屏就能先把代理配好。
 *
 * 复用关系：
 *   - 持久化走 ProxyStore（账号密码经 SecretStore 加密）
 *   - 连通性测试与结果文案走 ProxyTester（与设置页共用同一套判定和提示，避免两处不一致）
 *   - 保存后立即 HttpClient.instance.setProxyConfig()，无需重启应用
 */

import { promptAction } from '@kit.ArkUI';
import { AppColors } from '../theme/AppColors';
import { AppFontSize, AppRadius, AppSpace } from '../theme/AppTextStyles';
import { HttpClient } from '../api/HttpClient';
import { ProxyStore } from '../api/ProxyStore';
import { ProxyTester, ProxyTestResult } from '../api/ProxyTester';
import {
  ProxyConfig,
  ProxyScheme,
  PROXY_DEFAULT_TIMEOUT_MS,
} from '../api/ProxyConfig';
import { I18n } from '../utils/I18n';
import { Logger } from '../utils/Logger';

const TAG: string = 'ProxySetupDialog';

@CustomDialog
export struct ProxySetupDialog {
  controller?: CustomDialogController;
  /** 保存并应用后的回调（启动页据此重新走一遍 bootstrap）。 */
  onApplied: () => void = (): void => {};

  @State private proxyOn: boolean = true;
  @State private scheme: ProxyScheme = 'http';
  @State private host: string = '';
  @State private portStr: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private testing: boolean = false;
  @State private hint: string = '';

  aboutToAppear(): void {
    this.loadSaved().catch((e: Object): void => {
      Logger.w(TAG, `loadSaved failed: ${(e as Error).message}`);
    });
  }

  private async loadSaved(): Promise<void> {
    const cfg: ProxyConfig = await ProxyStore.load();
    this.scheme = cfg.scheme;
    this.host = cfg.host;
    this.portStr = cfg.port > 0 ? cfg.port.toString() : '';
    this.username = cfg.username;
    this.password = cfg.password;
    // 弹窗是"为了联网才打开的"，默认直接给启用态；用户已存过配置时沿用其开关状态
    this.proxyOn = cfg.host.length > 0 ? cfg.enabled : true;
  }

  /** 把界面输入组装成一份配置（不写盘）。 */
  private draft(): ProxyConfig {
    const n: number = parseInt(this.portStr, 10);
    const cfg: ProxyConfig = {
      enabled: this.proxyOn,
      scheme: this.scheme,
      host: this.host,
      port: isNaN(n) ? 0 : n,
      username: this.username,
      password: this.password,
      connectTimeoutMs: PROXY_DEFAULT_TIMEOUT_MS,
    };
    return cfg;
  }

  private async save(): Promise<void> {
    const cfg: ProxyConfig = this.draft();
    await ProxyStore.save(cfg);
    HttpClient.instance.setProxyConfig(cfg);
    this.hint = I18n.ts('proxy_setup_saved');
    this.onApplied();
  }

  private async test(): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testing = true;
    this.hint = I18n.ts('settings_proxy_testing');
    try {
      const cfg: ProxyConfig = this.draft();
      cfg.enabled = true; // 测试时强制按启用处理
      const r: ProxyTestResult = await ProxyTester.test(cfg);
      this.hint = ProxyTester.messageOf(r);
      if (!r.ok && r.probeUrl.length > 0) {
        this.hint = `${this.hint}\n${I18n.format('proxy_setup_probe_fmt', [r.probeUrl])}`;
      }
    } catch (e) {
      Logger.w(TAG, `test failed: ${(e as Error).message}`);
      this.hint = I18n.ts('settings_proxy_err_connect');
    } finally {
      this.testing = false;
    }
  }

  private static toast(msg: string): void {
    try {
      const opts: promptAction.ShowToastOptions = { message: msg, duration: 1500 };
      promptAction.openToast(opts);
    } catch (e) {
      Logger.w(TAG, 'toast failed');
    }
  }

  @Builder
  private schemePill(value: ProxyScheme, label: string) {
    Button() {
      Text(label)
        .fontSize(AppFontSize.bodySm)
        .fontWeight(this.scheme === value ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.scheme === value ? AppColors.textOnPrimary : AppColors.textPrimary);
    }
    .layoutWeight(1)
    .height(36)
    .backgroundColor(this.scheme === value ? AppColors.brandPrimary : AppColors.surfaceAlt)
    .borderRadius(AppRadius.sm)
    .onClick((): void => {
      this.scheme = value;
    });
  }

  @Builder
  private fieldLabel(text: ResourceStr) {
    Text(text)
      .fontSize(AppFontSize.caption)
      .fontColor(AppColors.textSecondary)
      .alignSelf(ItemAlign.Start);
  }

  build() {
    Column({ space: 14 }) {
      Text($r('app.string.proxy_setup_title'))
        .fontSize(AppFontSize.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.textPrimary)
        .alignSelf(ItemAlign.Start);

      Text($r('app.string.proxy_setup_hint'))
        .fontSize(AppFontSize.caption)
        .fontColor(AppColors.textTertiary)
        .alignSelf(ItemAlign.Start);

      // 启用开关
      Row() {
        Text($r('app.string.settings_proxy_enable'))
          .fontSize(AppFontSize.body)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.proxyOn })
          .onChange((on: boolean): void => {
            this.proxyOn = on;
          });
      }
      .width('100%');

      // 协议
      Column({ space: 6 }) {
        this.fieldLabel($r('app.string.settings_proxy_scheme'));
        Row({ space: 8 }) {
          this.schemePill('http', 'HTTP');
          this.schemePill('https', 'HTTPS');
          this.schemePill('socks5', 'SOCKS5');
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);

      // 主机 + 端口
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.fieldLabel($r('app.string.settings_proxy_host'));
          TextInput({ placeholder: $r('app.string.settings_proxy_host_hint'), text: this.host })
            .height(40)
            .borderRadius(AppRadius.sm)
            .backgroundColor(AppColors.surfaceAlt)
            .fontSize(AppFontSize.bodySm)
            .onChange((v: string): void => {
              this.host = v;
            });
        }
        .layoutWeight(2)
        .alignItems(HorizontalAlign.Start);

        Column({ space: 4 }) {
          this.fieldLabel($r('app.string.settings_proxy_port'));
          TextInput({ placeholder: $r('app.string.settings_proxy_port_hint'), text: this.portStr })
            .type(InputType.Number)
            .height(40)
            .borderRadius(AppRadius.sm)
            .backgroundColor(AppColors.surfaceAlt)
            .fontSize(AppFontSize.bodySm)
            .onChange((v: string): void => {
              this.portStr = v;
            });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%');

      // 账号 + 密码（密码默认掩码）
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.fieldLabel($r('app.string.settings_proxy_username'));
          TextInput({ placeholder: $r('app.string.settings_proxy_username_hint'), text: this.username })
            .height(40)
            .borderRadius(AppRadius.sm)
            .backgroundColor(AppColors.surfaceAlt)
            .fontSize(AppFontSize.bodySm)
            .onChange((v: string): void => {
              this.username = v;
            });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Column({ space: 4 }) {
          this.fieldLabel($r('app.string.settings_proxy_password'));
          TextInput({ placeholder: $r('app.string.settings_proxy_password_hint'), text: this.password })
            .type(InputType.Password)
            .height(40)
            .borderRadius(AppRadius.sm)
            .backgroundColor(AppColors.surfaceAlt)
            .fontSize(AppFontSize.bodySm)
            .onChange((v: string): void => {
              this.password = v;
            });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%');

      // 测试 / 保存
      Row({ space: 8 }) {
        Button($r('app.string.settings_proxy_test'))
          .layoutWeight(1)
          .height(40)
          .fontSize(AppFontSize.bodySm)
          .backgroundColor(AppColors.surfaceAlt)
          .fontColor(AppColors.textPrimary)
          .borderRadius(AppRadius.sm)
          .enabled(!this.testing)
          .onClick((): void => {
            this.test().catch((e: Object): void => {
              Logger.w(TAG, `test: ${(e as Error).message}`);
            });
          });
        Button($r('app.string.settings_proxy_save'))
          .layoutWeight(1)
          .height(40)
          .fontSize(AppFontSize.bodySm)
          .backgroundColor(AppColors.brandPrimary)
          .fontColor(AppColors.textOnPrimary)
          .borderRadius(AppRadius.sm)
          .onClick((): void => {
            this.save().then((): void => {
              ProxySetupDialog.toast(I18n.ts('proxy_setup_saved'));
            }).catch((e: Object): void => {
              Logger.w(TAG, `save: ${(e as Error).message}`);
            });
          });
      }
      .width('100%');

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(AppFontSize.caption)
          .fontColor(AppColors.textTertiary)
          .alignSelf(ItemAlign.Start)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      Row({ space: 12 }) {
        Button($r('app.string.common_cancel'))
          .layoutWeight(1)
          .height(40)
          .backgroundColor(AppColors.surfaceAlt)
          .fontColor(AppColors.textPrimary)
          .borderRadius(AppRadius.pill)
          .onClick((): void => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          });
        Button($r('app.string.common_ok'))
          .layoutWeight(1)
          .height(40)
          .backgroundColor(AppColors.brandPrimary)
          .fontColor(AppColors.textOnPrimary)
          .borderRadius(AppRadius.pill)
          .onClick((): void => {
            this.save().then((): void => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
            }).catch((e: Object): void => {
              Logger.w(TAG, `save&close: ${(e as Error).message}`);
            });
          });
      }
      .width('100%');
    }
    .padding(AppSpace.s20)
    .width('90%')
    .constraintSize({ maxWidth: 460, maxHeight: '80%' })
    .backgroundColor(AppColors.surface)
    .borderRadius(AppRadius.lg);
  }
}
