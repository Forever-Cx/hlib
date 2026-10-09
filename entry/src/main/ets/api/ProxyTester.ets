/*
 * ProxyTester.ets
 *
 * 代理连通性测试：用当前配置向若干探测地址发一个轻量 GET，并按失败原因分类。
 *
 * 【重要】测试通道必须与真实请求通道一致，否则会出现"代理实际可用、测试却失败"的误判：
 *   - http / https 代理 → 用 @kit.NetworkKit 的 http 模块 + usingProxy（与 HttpClient 业务请求同一条路）
 *   - socks5 代理       → 用 @kit.RemoteCommunicationKit（RCP），因为 http 模块无法表达 socks5
 *
 * 【探测地址】不能用业务域名（如 Z-Library 镜像）做探针：代理通、但业务域名本身被阻断时，
 * 会误报成"代理不可达"。默认用两个与业务无关的中立地址依次尝试，任一成功即判定代理可用。
 *
 * 错误分类思路：
 *   http 模块错误码形如 2300007，RCP 错误码形如 1007900007，
 *   两者后 5 位都是 libcurl 错误码（7=无法连接 / 28=超时 / 5=无法解析代理 / 6=无法解析主机 …），
 *   因此统一取 `code % 100000` 即可共用一张映射表；部分 ROM 不带错误码时用错误消息兜底。
 */

import { connection, http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import { I18n } from '../utils/I18n';
import { HttpClient } from './HttpClient';
import {
  ProxyConfig,
  ProxyErrorKind,
  normalizeProxy,
  validateProxy,
  describeProxy,
  toHttpProxy,
  toWebProxy,
  PROXY_TEST_URLS,
} from './ProxyConfig';

const TAG: string = 'ProxyTester';

/** 展示用 detail 的最大长度，避免超长系统错误串撑爆 UI。 */
const MAX_DETAIL_LEN: number = 120;

export interface ProxyTestResult {
  /** 代理可用（拿到 2xx/3xx 响应）。 */
  ok: boolean;
  /** 往返耗时（ms）；失败时为已耗时。 */
  latencyMs: number;
  /** HTTP 状态码；未拿到响应时为 0。 */
  statusCode: number;
  /** 失败原因分类；ok=true 时为 'none'。 */
  kind: ProxyErrorKind;
  /** 可直接展示的补充信息（已脱敏、已截断）。 */
  detail: string;
  /** 实际使用的探测地址，便于对照排查（失败时展示）。 */
  probeUrl: string;
  /** 实际使用的通道：'http' = 系统 http 模块，'rcp' = RCP。 */
  channel: string;
}

export class ProxyTester {
  /**
   * 用给定代理配置依次访问探测地址，任一成功即视为代理可用。
   * @param cfg 待测试的代理配置（enabled 不参与判定——即使未启用也照测，方便"先测再启用"）
   * @param targetUrls 可选：自定义探测地址；不传则用 PROXY_TEST_URLS
   */
  static async test(cfg: ProxyConfig, targetUrls?: string[]): Promise<ProxyTestResult> {
    const n: ProxyConfig = normalizeProxy(cfg);
    const valid: ProxyErrorKind = validateProxy(n);
    if (valid !== 'none') {
      const bad: ProxyTestResult = {
        ok: false, latencyMs: 0, statusCode: 0, kind: 'invalid',
        detail: '', probeUrl: '', channel: '-',
      };
      return bad;
    }

    const urls: string[] = targetUrls !== undefined && targetUrls.length > 0
      ? targetUrls
      : PROXY_TEST_URLS;

    let firstFail: ProxyTestResult | null = null;
    for (let i = 0; i < urls.length; i++) {
      const r: ProxyTestResult = await ProxyTester.testOne(n, urls[i]);
      if (r.ok) {
        return r;
      }
      if (firstFail === null) {
        firstFail = r;
      }
    }
    if (firstFail !== null) {
      return firstFail;
    }
    const unknown: ProxyTestResult = {
      ok: false, latencyMs: 0, statusCode: 0, kind: 'unknown',
      detail: '', probeUrl: '', channel: '-',
    };
    return unknown;
  }

  // ─── 文案（设置页与启动页弹窗共用，避免两处各写一份） ───

  /** 把测试结果翻译成面向用户的文案（区分认证失败 / 不可达 / 超时 / 解析失败等）。 */
  static messageOf(r: ProxyTestResult): string {
    if (r.ok) {
      return I18n.format('settings_proxy_test_ok_fmt', [r.latencyMs]);
    }
    const kind: ProxyErrorKind = r.kind;
    if (kind === 'invalid') {
      return I18n.ts('settings_proxy_err_invalid');
    }
    if (kind === 'auth') {
      return I18n.ts('settings_proxy_err_auth');
    }
    if (kind === 'timeout') {
      return I18n.ts('settings_proxy_err_timeout');
    }
    if (kind === 'dns') {
      return I18n.ts('settings_proxy_err_dns');
    }
    if (kind === 'unsupported') {
      return I18n.ts('settings_proxy_err_unsupported');
    }
    if (kind === 'connect') {
      return I18n.ts('settings_proxy_err_connect');
    }
    return r.detail.length > 0
      ? I18n.format('settings_proxy_err_unknown_fmt', [r.detail])
      : I18n.ts('settings_proxy_err_connect');
  }

  // ─── 内部 ───

  /** 按协议选择通道：socks5 走 RCP，http/https 走系统 http 模块（与业务请求一致）。 */
  private static async testOne(cfg: ProxyConfig, url: string): Promise<ProxyTestResult> {
    if (cfg.scheme === 'socks5') {
      return await ProxyTester.viaRcp(cfg, url);
    }
    return await ProxyTester.viaHttp(cfg, url);
  }

  /** 走 @kit.NetworkKit：与 HttpClient.attemptOnce 完全同一条路，含代理认证。 */
  private static async viaHttp(cfg: ProxyConfig, url: string): Promise<ProxyTestResult> {
    const timeoutMs: number = cfg.connectTimeoutMs;
    const started: number = Date.now();
    const req: http.HttpRequest = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': HttpClient.instance.defaultUserAgent(), 'Accept': '*/*' },
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
      };
      const proxy: connection.HttpProxy | undefined = toHttpProxy(cfg);
      if (proxy !== undefined) {
        opts.usingProxy = proxy;
      }
      const resp: http.HttpResponse = await req.request(url, opts);
      const latency: number = Date.now() - started;
      const out: ProxyTestResult = ProxyTester.judge(resp.responseCode, latency, url, 'http');
      ProxyTester.logResult(cfg, out);
      return out;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const out: ProxyTestResult = ProxyTester.classify(e, Date.now() - started, url, 'http');
      ProxyTester.logResult(cfg, out);
      return out;
    } finally {
      req.destroy();
    }
  }

  /** 走 RCP：仅 socks5 使用（http 模块无法表达 socks5）。 */
  private static async viaRcp(cfg: ProxyConfig, url: string): Promise<ProxyTestResult> {
    const timeoutMs: number = cfg.connectTimeoutMs;
    const started: number = Date.now();
    let session: rcp.Session | null = null;
    try {
      const timeout: rcp.Timeout = { connectMs: timeoutMs, transferMs: timeoutMs };
      const transfer: rcp.TransferConfiguration = { timeout: timeout };
      const configuration: rcp.Configuration = { proxy: toWebProxy(cfg), transfer: transfer };
      const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: configuration };
      const created: rcp.Session = rcp.createSession(sessionConfig);
      session = created;

      const reqHeaders: rcp.RequestHeaders = {
        'User-Agent': HttpClient.instance.defaultUserAgent(),
        'Accept': '*/*',
      };
      const req: rcp.Request = new rcp.Request(url, 'GET', reqHeaders);
      const resp: rcp.Response = await created.fetch(req);
      const latency: number = Date.now() - started;
      const out: ProxyTestResult = ProxyTester.judge(resp.statusCode, latency, url, 'rcp');
      ProxyTester.logResult(cfg, out);
      return out;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const out: ProxyTestResult = ProxyTester.classify(e, Date.now() - started, url, 'rcp');
      ProxyTester.logResult(cfg, out);
      return out;
    } finally {
      if (session !== null) {
        const opened: rcp.Session = session;
        try {
          opened.close();
        } catch {
          // 忽略关闭异常
        }
      }
    }
  }

  /** 按状态码判定成功 / 认证失败 / 其它。 */
  private static judge(
    status: number,
    latency: number,
    url: string,
    channel: string
  ): ProxyTestResult {
    // 407 Proxy Authentication Required / 401：一定是凭据问题
    if (status === 407 || status === 401) {
      return {
        ok: false, latencyMs: latency, statusCode: status, kind: 'auth',
        detail: `HTTP ${status}`, probeUrl: url, channel: channel,
      };
    }
    if (status >= 200 && status < 400) {
      return {
        ok: true, latencyMs: latency, statusCode: status, kind: 'none',
        detail: '', probeUrl: url, channel: channel,
      };
    }
    return {
      ok: false, latencyMs: latency, statusCode: status, kind: 'unknown',
      detail: `HTTP ${status}`, probeUrl: url, channel: channel,
    };
  }

  private static classify(
    e: BusinessError,
    latency: number,
    url: string,
    channel: string
  ): ProxyTestResult {
    const code: number = typeof e.code === 'number' ? e.code : 0;
    const msg: string = e.message !== undefined && e.message !== null ? e.message : '';
    const lower: string = msg.toLowerCase();
    const curl: number = code > 0 ? code % 100000 : -1;

    let kind: ProxyErrorKind = 'unknown';
    if (curl === 5 || curl === 6) {
      // 5=无法解析代理名；6=无法解析主机
      kind = 'dns';
    } else if (curl === 7 || curl === 16 || curl === 56) {
      // 7=无法连接（代理或目标）；16=HTTP/2 帧错误；56=接收数据失败
      kind = 'connect';
    } else if (curl === 28) {
      kind = 'timeout';
    } else if (curl === 94 || curl === 97 || curl === 67) {
      // 94=认证函数错误；97=代理握手失败（多为 407 凭据被拒）；67=登录被拒
      kind = 'auth';
    } else if (curl === 1 || curl === 996) {
      // 1=不支持的协议；996=不支持的代理类型
      kind = 'unsupported';
    }

    // 错误码缺失/未命中时的文本兜底
    if (kind === 'unknown') {
      if (lower.indexOf('timed out') >= 0 || lower.indexOf('timeout') >= 0) {
        kind = 'timeout';
      } else if (lower.indexOf('407') >= 0 || lower.indexOf('authentication') >= 0
        || lower.indexOf('credential') >= 0 || lower.indexOf('auth') >= 0) {
        kind = 'auth';
      } else if (lower.indexOf('resolve') >= 0 || lower.indexOf('nodename') >= 0
        || lower.indexOf('not known') >= 0) {
        kind = 'dns';
      } else if (lower.indexOf('refused') >= 0 || lower.indexOf('unreachable') >= 0
        || lower.indexOf('connect') >= 0) {
        kind = 'connect';
      }
    }

    const out: ProxyTestResult = {
      ok: false,
      latencyMs: latency,
      statusCode: 0,
      kind: kind,
      detail: ProxyTester.brief(msg, code),
      probeUrl: url,
      channel: channel,
    };
    return out;
  }

  /** 截断 + 拼上错误码；不含密码（代理凭据不会出现在系统错误串里）。 */
  private static brief(msg: string, code: number): string {
    const base: string = msg.length > MAX_DETAIL_LEN ? msg.substring(0, MAX_DETAIL_LEN) : msg;
    if (code > 0) {
      return `${base} (${code})`;
    }
    return base;
  }

  /** 统一日志出口：只打脱敏后的代理描述。 */
  private static logResult(cfg: ProxyConfig, r: ProxyTestResult): void {
    Logger.i(
      TAG,
      `test ${describeProxy(cfg)} via ${r.channel} -> ok=${r.ok} status=${r.statusCode} `
      + `kind=${r.kind} ${r.latencyMs}ms probe=${r.probeUrl}`,
    );
  }
}
