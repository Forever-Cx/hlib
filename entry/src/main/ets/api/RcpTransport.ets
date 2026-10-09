/*
 * RcpTransport.ets
 *
 * 基于 @kit.RemoteCommunicationKit（RCP）的 HTTP 传输实现，
 * 仅在「代理启用且协议为 socks5」时被 HttpClient 使用——因为 @kit.NetworkKit 的 http
 * 模块的 usingProxy（connection.HttpProxy）没有协议字段，无法表达 socks5。
 *
 * RCP 好处：
 *   - rcp.WebProxy.url 支持 socks5://host:port（也支持 http/https）；
 *   - WebProxy.security.serverAuthentication 可携带代理账号密码完成代理认证；
 *   - 响应结构（statusCode / headers / body）与 http 模块一一对应，便于归一。
 *
 * 边界：
 *   - 代理禁用时本文件整个不参与调用，行为与改动前 100% 一致。
 *   - 返回的 RawResponse 头统一为 Record<string, string | string[]>，
 *     与 http.HttpResponse.header 的使用方式保持一致，CookieJar / CloudflareDetector 无需改动。
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { ProxyConfig, toWebProxy } from './ProxyConfig';

/** 归一化的原始响应（不含任何业务判定）。 */
export interface RawResponse {
  statusCode: number;
  headers: Record<string, string | string[]>;
  body: string;
}

/** RCP 请求入参。用对象传参避免长参数列表。 */
export interface RcpFetchParams {
  url: string;
  /** 'GET' / 'POST'，其它值一律按 GET 处理。 */
  method: string;
  headers: Record<string, string>;
  /** 请求体（仅 POST 需要）。 */
  body?: string;
  connectMs: number;
  transferMs: number;
  proxy: ProxyConfig;
}

export class RcpTransport {
  /** 发起一次请求。网络层异常直接向上抛（BusinessError），由调用方统一归一。 */
  static async fetch(p: RcpFetchParams): Promise<RawResponse> {
    const timeout: rcp.Timeout = {
      connectMs: p.connectMs,
      transferMs: p.transferMs,
    };
    const transfer: rcp.TransferConfiguration = { timeout: timeout };
    const configuration: rcp.Configuration = {
      proxy: toWebProxy(p.proxy),
      transfer: transfer,
    };
    const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: configuration };
    const session: rcp.Session = rcp.createSession(sessionConfig);

    try {
      const method: rcp.HttpMethod = p.method === 'POST' ? 'POST' : 'GET';

      const reqHeaders: rcp.RequestHeaders = {};
      const keys: string[] = Object.keys(p.headers);
      for (let i = 0; i < keys.length; i++) {
        reqHeaders[keys[i]] = p.headers[keys[i]];
      }

      let content: rcp.RequestContent | undefined = undefined;
      if (p.body !== undefined && p.body.length > 0) {
        content = p.body;
      }

      const req: rcp.Request = new rcp.Request(p.url, method, reqHeaders, content);
      const resp: rcp.Response = await session.fetch(req);

      const headersOut: Record<string, string | string[]> = {};
      const respHeaders: rcp.ResponseHeaders = resp.headers;
      const hKeys: string[] = Object.keys(respHeaders);
      for (let i = 0; i < hKeys.length; i++) {
        const v: string | string[] | undefined = respHeaders[hKeys[i]];
        if (v !== undefined) {
          headersOut[hKeys[i]] = v;
        }
      }

      const out: RawResponse = {
        statusCode: resp.statusCode,
        headers: headersOut,
        body: RcpTransport.decodeUtf8(resp.body),
      };
      return out;
    } finally {
      try {
        session.close();
      } catch {
        // close 失败不影响请求结果，忽略
      }
    }
  }

  private static decodeUtf8(buf: ArrayBuffer | undefined): string {
    if (buf === undefined) {
      return '';
    }
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch {
      return '';
    }
  }
}
