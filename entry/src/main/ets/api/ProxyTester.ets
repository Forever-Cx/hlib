/*
 * ProxyTester.ets
 *
 * 代理连通性测试：用当前配置向目标站点发一个轻量 GET，并按失败原因分类。
 *
 * 为什么用 RCP 而不是 http 模块做测试：
 *   - RCP 一套 API 同时覆盖 http / https / socks5，测试器只需一份代码；
 *   - 且 rcp.WebProxy 能携带代理认证，测出来的结论与真实请求路径一致。
 *
 * 错误分类思路：
 *   http 模块错误码形如 2300007，RCP 错误码形如 1007900007，
 *   两者后 5 位都是 libcurl 错误码（7=无法连接 / 28=超时 / 5=无法解析代理 / 6=无法解析主机 …），
 *   因此统一取 `code % 100000` 即可共用一张映射表；部分 ROM 不带错误码时用错误消息兜底。
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import { HttpClient } from './HttpClient';
import {
  ProxyConfig,
  ProxyErrorKind,
  normalizeProxy,
  validateProxy,
  describeProxy,
  toWebProxy,
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
}

export class ProxyTester {
  /**
   * 用给定代理配置访问 targetUrl。
   * @param cfg 待测试的代理配置（enabled 不参与判定——即使未启用也照测，方便"先测再启用"）
   * @param targetUrl 目标 URL，一般用当前镜像域的 /eapi/info/languages
   */
  static async test(cfg: ProxyConfig, targetUrl: string): Promise<ProxyTestResult> {
    const n: ProxyConfig = normalizeProxy(cfg);
    const valid: ProxyErrorKind = validateProxy(n);
    if (valid !== 'none') {
      const bad: ProxyTestResult = {
        ok: false, latencyMs: 0, statusCode: 0, kind: 'invalid', detail: '',
      };
      return bad;
    }

    const timeoutMs: number = n.connectTimeoutMs;
    const started: number = Date.now();
    let session: rcp.Session | null = null;

    try {
      const timeout: rcp.Timeout = { connectMs: timeoutMs, transferMs: timeoutMs };
      const transfer: rcp.TransferConfiguration = { timeout: timeout };
      const configuration: rcp.Configuration = { proxy: toWebProxy(n), transfer: transfer };
      const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: configuration };
      session = rcp.createSession(sessionConfig);

      const reqHeaders: rcp.RequestHeaders = {
        'User-Agent': HttpClient.instance.defaultUserAgent(),
        'Accept': 'application/json, text/plain, */*',
      };
      const req: rcp.Request = new rcp.Request(targetUrl, 'GET', reqHeaders);
      const resp: rcp.Response = await session.fetch(req);

      const latency: number = Date.now() - started;
      const status: number = resp.statusCode;

      // 407 Proxy Authentication Required / 401：一定是凭据问题
      if (status === 407 || status === 401) {
        const denied: ProxyTestResult = {
          ok: false, latencyMs: latency, statusCode: status, kind: 'auth', detail: `HTTP ${status}`,
        };
        ProxyTester.logResult(n, denied);
        return denied;
      }

      if (status >= 200 && status < 400) {
        const good: ProxyTestResult = {
          ok: true, latencyMs: latency, statusCode: status, kind: 'none', detail: '',
        };
        ProxyTester.logResult(n, good);
        return good;
      }

      const other: ProxyTestResult = {
        ok: false, latencyMs: latency, statusCode: status, kind: 'unknown', detail: `HTTP ${status}`,
      };
      ProxyTester.logResult(n, other);
      return other;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const result: ProxyTestResult = ProxyTester.classify(e, Date.now() - started);
      ProxyTester.logResult(n, result);
      return result;
    } finally {
      if (session !== null) {
        try {
          session.close();
        } catch {
          // 忽略关闭异常
        }
      }
    }
  }

  // ─── 内部 ───

  private static classify(e: BusinessError, latency: number): ProxyTestResult {
    const code: number = typeof e.code === 'number' ? e.code : 0;
    const msg: string = e.message !== undefined && e.message !== null ? e.message : '';
    const lower: string = msg.toLowerCase();
    const curl: number = code > 0 ? code % 100000 : -1;

    let kind: ProxyErrorKind = 'unknown';
    if (curl === 5 || curl === 6) {
      // 5=无法解析代理名；6=无法解析主机
      kind = 'dns';
    } else if (curl === 7 || curl === 16 || curl === 56) {
      // 7=无法连接服务器；16=HTTP/2 帧错误；56=接收数据失败
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
      `test ${describeProxy(cfg)} -> ok=${r.ok} status=${r.statusCode} `
      + `kind=${r.kind} ${r.latencyMs}ms`,
    );
  }
}
