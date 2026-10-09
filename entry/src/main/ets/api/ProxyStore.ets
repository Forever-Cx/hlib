/*
 * ProxyStore.ets
 *
 * 代理配置的持久化层：非敏感字段走 PreferencesStore('settings')，
 * 账号 / 密码经 SecretStore（HUKS AES-256-GCM）加密后落盘。
 *
 * 设计要点：
 *   1. 本类不依赖 HttpClient（避免与 api 层循环 import）；"读到就应用"由调用方
 *      （EntryAbility / SettingsPage）自行执行 HttpClient.instance.setProxyConfig()。
 *   2. 写盘永不打印密码；日志统一走 describeProxy()。
 *   3. SecretStore 在 HUKS 不可用时存在既有降级行为（encrypt 回退原文 / decrypt 返回空串）。
 *      本类不做额外兜底，但保证：即便降级为明文，也不会有任何一行日志把它打出来。
 *   4. 向后兼容：旧版本只存了 enabled / host / port，缺失的协议与凭证字段读为空，
 *      归一化后等价于 "http 无认证代理"，行为与旧版一致。
 */

import { PreferencesStore } from '../storage/PreferencesStore';
import { AppStorageKeys } from '../storage/AppStorageKeys';
import { SecretStore } from '../utils/SecretStore';
import { Logger } from '../utils/Logger';
import { HttpClient } from './HttpClient';
import {
  ProxyConfig,
  ProxyScheme,
  emptyProxyConfig,
  normalizeProxy,
  describeProxy,
  shouldUseOfficialDomain,
} from './ProxyConfig';

const TAG: string = 'ProxyStore';

export class ProxyStore {
  /** 读取完整配置（账号密码自动解密）。失败时返回未启用的空配置。 */
  static async load(): Promise<ProxyConfig> {
    const enabled: boolean = await PreferencesStore.getBoolean(
      'settings', AppStorageKeys.PROXY_ENABLED, false,
    );
    const schemeRaw: string = await PreferencesStore.getString(
      'settings', AppStorageKeys.PROXY_SCHEME, 'http',
    );
    const host: string = await PreferencesStore.getString(
      'settings', AppStorageKeys.PROXY_HOST, '',
    );
    const port: number = await PreferencesStore.getNumber(
      'settings', AppStorageKeys.PROXY_PORT, 0,
    );
    const timeoutMs: number = await PreferencesStore.getNumber(
      'settings', AppStorageKeys.PROXY_TIMEOUT_MS, 0,
    );
    const useOfficial: boolean = await PreferencesStore.getBoolean(
      'settings', AppStorageKeys.PROXY_USE_OFFICIAL, false,
    );
    const officialDomain: string = await PreferencesStore.getString(
      'settings', AppStorageKeys.ZLIB_OFFICIAL_DOMAIN, '',
    );
    const userCipher: string = await PreferencesStore.getString(
      'settings', AppStorageKeys.PROXY_USERNAME, '',
    );
    const passCipher: string = await PreferencesStore.getString(
      'settings', AppStorageKeys.PROXY_PASSWORD, '',
    );

    let scheme: ProxyScheme = 'http';
    if (schemeRaw === 'https' || schemeRaw === 'socks5' || schemeRaw === 'http') {
      scheme = schemeRaw;
    }

    const username: string = await ProxyStore.decryptField(userCipher);
    const password: string = await ProxyStore.decryptField(passCipher);

    const raw: ProxyConfig = {
      enabled: enabled,
      scheme: scheme,
      host: host,
      port: port,
      username: username,
      password: password,
      useOfficialDomain: useOfficial,
      officialDomain: officialDomain,
      connectTimeoutMs: timeoutMs,
    };
    const cfg: ProxyConfig = normalizeProxy(raw);
    // 读取不打印：只在启用且需要排查时由调用方按需 describeProxy()
    Logger.d(TAG, `loaded: enabled=${cfg.enabled} scheme=${cfg.scheme} host=${cfg.host} port=${cfg.port}`);
    return cfg;
  }

  /** 保存完整配置（账号密码加密后写盘）。 */
  static async save(cfg: ProxyConfig): Promise<void> {
    const n: ProxyConfig = normalizeProxy(cfg);
    await PreferencesStore.putBoolean('settings', AppStorageKeys.PROXY_ENABLED, n.enabled);
    await PreferencesStore.putString('settings', AppStorageKeys.PROXY_SCHEME, n.scheme);
    await PreferencesStore.putString('settings', AppStorageKeys.PROXY_HOST, n.host);
    await PreferencesStore.putNumber('settings', AppStorageKeys.PROXY_PORT, n.port);
    await PreferencesStore.putNumber('settings', AppStorageKeys.PROXY_TIMEOUT_MS, n.connectTimeoutMs);
    await PreferencesStore.putBoolean('settings', AppStorageKeys.PROXY_USE_OFFICIAL, n.useOfficialDomain);
    await PreferencesStore.putString('settings', AppStorageKeys.ZLIB_OFFICIAL_DOMAIN, n.officialDomain);
    await PreferencesStore.putString(
      'settings', AppStorageKeys.PROXY_USERNAME, await SecretStore.encrypt(n.username),
    );
    await PreferencesStore.putString(
      'settings', AppStorageKeys.PROXY_PASSWORD, await SecretStore.encrypt(n.password),
    );
    if (!SecretStore.isUsable()) {
      // 只提示状态，不打印任何凭证内容
      Logger.w(TAG, 'SecretStore unavailable: proxy credentials are NOT encrypted on disk');
    }
    Logger.i(TAG, `saved: enabled=${n.enabled} ${n.enabled ? describeProxy(n) : ''}`);
  }

  /** 只改总开关（保留已保存的主机 / 端口 / 凭证）。 */
  static async setEnabled(on: boolean): Promise<void> {
    const cur: ProxyConfig = await ProxyStore.load();
    if (cur.enabled === on) {
      return;
    }
    cur.enabled = on;
    await ProxyStore.save(cur);
  }

  /** 清空全部代理配置（含加密凭证）。设置页"关闭并清除"用。 */
  static async clear(): Promise<void> {
    await ProxyStore.save(emptyProxyConfig());
    Logger.i(TAG, 'cleared');
  }

  /**
   * 应用域名策略（设置页与启动页弹窗共用，避免两处各写一份）：
   *   开启「经代理直连官方站」→ 当前线路切到官方域名，并先把原镜像域名记下来；
   *   关闭 → 切回记录的镜像域名。
   */
  static async applyDomainPolicy(cfg: ProxyConfig): Promise<void> {
    if (shouldUseOfficialDomain(cfg)) {
      const mirror: string = AppStorage.get<string>(AppStorageKeys.DOMAIN) ?? '';
      if (mirror.length > 0 && mirror !== cfg.officialDomain) {
        await PreferencesStore.putString('settings', AppStorageKeys.ZLIB_MIRROR_DOMAIN, mirror);
        AppStorage.setOrCreate<string>(AppStorageKeys.DOMAIN, cfg.officialDomain);
        HttpClient.instance.setDomain(cfg.officialDomain);
        Logger.i(TAG, `domain -> official: ${cfg.officialDomain} (mirror ${mirror} saved)`);
      }
      return;
    }
    const savedMirror: string =
      await PreferencesStore.getString('settings', AppStorageKeys.ZLIB_MIRROR_DOMAIN, '');
    const cur: string = AppStorage.get<string>(AppStorageKeys.DOMAIN) ?? '';
    if (savedMirror.length > 0 && cur !== savedMirror) {
      AppStorage.setOrCreate<string>(AppStorageKeys.DOMAIN, savedMirror);
      HttpClient.instance.setDomain(savedMirror);
      Logger.i(TAG, `domain -> mirror: ${savedMirror}`);
    }
  }

  // ─── 内部 ───

  /** 空串直接返回；其余交 SecretStore（非密文原样返回，密文解密）。 */
  private static async decryptField(value: string): Promise<string> {
    if (value.length === 0) {
      return '';
    }
    return await SecretStore.decrypt(value);
  }
}
