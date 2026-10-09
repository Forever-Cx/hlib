/*
 * ProxyConfig.ets
 *
 * 「应用内加密代理」的数据模型层。只负责：类型 + 归一化 + 校验 + 脱敏 + 传输层结构转换。
 * 不做持久化（见 ProxyStore.ets），不做网络 IO（见 ProxyTester.ets / RcpTransport.ets）。
 *
 * 协议支持策略（HarmonyOS API 能力边界决定）：
 *   - http / https：走 @kit.NetworkKit 的 http.createHttp() + HttpRequestOptions.usingProxy。
 *     connection.HttpProxy 自 API 12 起带 username / password 字段，可直接完成代理认证。
 *     也就是说：http / https 代理「不需要任何新依赖」，沿用现有网络封装即可带认证。
 *   - socks5：@kit.NetworkKit 的 http 模块没有协议（scheme）概念，无法表达 socks5；
 *     改由 @kit.RemoteCommunicationKit（RCP）承载 —— rcp.WebProxy.url 支持 socks5://，
 *     且 WebProxy.security.serverAuthentication 可携带代理账号密码。
 *
 * 安全约定：
 *   1. ProxyConfig 只活在内存里，username / password 是明文（传输层需要）。
 *   2. 落盘一律经 ProxyStore → SecretStore（HUKS AES-256-GCM，前缀 sec1:）。
 *   3. 任何需要打印代理信息的日志，必须调用 describeProxy()——它绝不输出密码。
 */

import { connection } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';

/** 支持的代理协议。 */
export type ProxyScheme = 'http' | 'https' | 'socks5';

/** 代理配置（内存态）。 */
export interface ProxyConfig {
  /** 总开关。false → 所有网络请求的行为与本次改动前完全一致。 */
  enabled: boolean;
  /** 代理协议。socks5 走 RCP，http/https 走 http 模块。 */
  scheme: ProxyScheme;
  /** 主机名或 IP，不含协议前缀、不含路径。 */
  host: string;
  /** 1-65535；0 表示未填写。 */
  port: number;
  /** 代理认证账号，可为空（无认证代理）。 */
  username: string;
  /** 代理认证密码，可为空。禁止进入任何日志。 */
  password: string;
  /** 连接超时（ms），同时用于连通性测试。 */
  connectTimeoutMs: number;
}

/** 协议胶囊的展示顺序。 */
export const PROXY_SCHEMES: ProxyScheme[] = ['http', 'https', 'socks5'];

/** 默认连接超时（ms）。 */
export const PROXY_DEFAULT_TIMEOUT_MS: number = 10000;
/** 连接超时下限，避免用户填 0 导致立即失败。 */
const MIN_TIMEOUT_MS: number = 1000;
/** 连接超时上限。 */
const MAX_TIMEOUT_MS: number = 120000;

/** 连通性测试的失败原因分类（UI 据此给出不同提示）。 */
export type ProxyErrorKind =
  'none'        // 成功
  | 'invalid'   // 配置不完整（缺主机 / 端口非法）
  | 'auth'      // 代理认证失败（407 / 凭据被拒 / 握手被拒）
  | 'connect'   // 代理不可达（连接被拒 / 主机不可达 / 握手失败）
  | 'timeout'   // 连接或读取超时
  | 'dns'       // 代理主机名无法解析
  | 'unsupported' // 协议不被系统支持
  | 'unknown';  // 其它

/** 代理错误（带分类，便于 UI 分情况提示）。 */
export class ProxyError extends Error {
  kind: ProxyErrorKind;
  /** 原始错误码。http 模块为 23000xxx，RCP 为 1007900xxx，后 5 位同为 curl 错误码。 */
  code: number;

  constructor(kind: ProxyErrorKind, message: string, code: number = 0) {
    super(message);
    this.name = 'ProxyError';
    this.kind = kind;
    this.code = code;
  }
}

/** 各协议的常见默认端口（仅用于 UI 提示，不做强制）。 */
export function defaultPortFor(scheme: ProxyScheme): number {
  if (scheme === 'socks5') {
    return 1080;
  }
  return 8080;
}

/** 全空配置（未启用）。 */
export function emptyProxyConfig(): ProxyConfig {
  const cfg: ProxyConfig = {
    enabled: false,
    scheme: 'http',
    host: '',
    port: 0,
    username: '',
    password: '',
    connectTimeoutMs: PROXY_DEFAULT_TIMEOUT_MS,
  };
  return cfg;
}

/** 把任意来源（UI 输入 / 旧版只读到 host+port）的配置整理成规范形态。 */
export function normalizeProxy(input: ProxyConfig): ProxyConfig {
  let scheme: ProxyScheme = input.scheme;
  if (scheme !== 'http' && scheme !== 'https' && scheme !== 'socks5') {
    scheme = 'http';
  }

  // 允许用户在主机框里粘贴 "http://1.2.3.4:8080" / "socks5://host" 这类整串
  let host: string = input.host.trim();
  host = host.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '');
  host = host.replace(/\/+$/, '');
  const slash: number = host.indexOf('/');
  if (slash >= 0) {
    host = host.substring(0, slash);
  }

  let port: number = Math.floor(input.port);
  if (!Number.isFinite(port) || port <= 0 || port > 65535) {
    port = 0;
  }

  let timeoutMs: number = Math.floor(input.connectTimeoutMs);
  if (!Number.isFinite(timeoutMs) || timeoutMs < MIN_TIMEOUT_MS) {
    timeoutMs = PROXY_DEFAULT_TIMEOUT_MS;
  }
  if (timeoutMs > MAX_TIMEOUT_MS) {
    timeoutMs = MAX_TIMEOUT_MS;
  }

  const out: ProxyConfig = {
    enabled: input.enabled === true,
    scheme: scheme,
    host: host,
    port: port,
    username: input.username.trim(),
    password: input.password,
    connectTimeoutMs: timeoutMs,
  };
  return out;
}

/** 配置是否足以发起请求（不含 enabled 之外其它业务判断）。 */
export function isProxyUsable(cfg: ProxyConfig): boolean {
  return cfg.enabled && cfg.host.length > 0 && cfg.port > 0 && cfg.port <= 65535;
}

/** 校验配置完整性：返回 'none' 表示可用，'invalid' 表示缺主机或端口非法。 */
export function validateProxy(cfg: ProxyConfig): ProxyErrorKind {
  if (cfg.host.length === 0) {
    return 'invalid';
  }
  if (cfg.port <= 0 || cfg.port > 65535) {
    return 'invalid';
  }
  return 'none';
}

/** 是否需要代理认证（填了账号即视为需要；部分代理允许空密码）。 */
export function needsAuth(cfg: ProxyConfig): boolean {
  return cfg.username.length > 0;
}

/**
 * 脱敏摘要，唯一允许进日志的代理描述形式：
 *   socks5://alice:***@1.2.3.4:1080    （有账号）
 *   http://1.2.3.4:8080                （无账号）
 * 密码永不出现在返回值中。
 */
export function describeProxy(cfg: ProxyConfig): string {
  const endpoint: string = `${cfg.host}:${cfg.port}`;
  if (needsAuth(cfg)) {
    return `${cfg.scheme}://${cfg.username}:***@${endpoint}`;
  }
  return `${cfg.scheme}://${endpoint}`;
}

/** 转成 RCP 的代理结构（socks5 与 http/https 都能表达，且支持代理认证）。 */
export function toWebProxy(cfg: ProxyConfig): rcp.WebProxy {
  const url: string = `${cfg.scheme}://${cfg.host}:${cfg.port}`;
  const webProxy: rcp.WebProxy = {
    url: url,
    createTunnel: 'auto',
  };
  if (needsAuth(cfg)) {
    const credential: rcp.Credential = {
      username: cfg.username,
      password: cfg.password,
    };
    const serverAuthentication: rcp.ServerAuthentication = {
      credential: credential,
      authenticationType: 'basic',
    };
    const security: rcp.SecurityConfiguration = {
      serverAuthentication: serverAuthentication,
    };
    webProxy.security = security;
  }
  return webProxy;
}

/**
 * 转成 @kit.NetworkKit 的 HttpProxy（仅 http / https 语义）。
 * socks5 无法用 http 模块表达，调用方需先判断 scheme，其它情况返回 undefined。
 */
export function toHttpProxy(cfg: ProxyConfig): connection.HttpProxy | undefined {
  if (cfg.scheme === 'socks5') {
    return undefined;
  }
  const proxy: connection.HttpProxy = {
    host: cfg.host,
    port: cfg.port,
    exclusionList: [],
  };
  if (needsAuth(cfg)) {
    proxy.username = cfg.username;
    proxy.password = cfg.password;
  }
  return proxy;
}

/** 与旧版（只有 host+port）行为对齐：true 表示应走 http 模块的 usingProxy。 */
export function supportsHttpModule(cfg: ProxyConfig): boolean {
  return cfg.scheme !== 'socks5';
}
