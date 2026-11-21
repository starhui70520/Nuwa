import { socket } from '@kit.NetworkKit';

const LOOPBACK_HOST = '127.0.0.1';
const CALLBACK_PATH = '/oauth/callback';
const MAX_REQUEST_BYTES = 8 * 1024;
const MAX_OPEN_CONNECTIONS = 4;
const CONNECTION_TIMEOUT_MS = 5_000;
const AUTHORIZATION_TIMEOUT_MS = 180_000;

interface LoopbackClient {
  connection: socket.TCPSocketConnection;
  text: string;
  timer: number;
  handled: boolean;
  accepted: boolean;
}

export type NativeOAuthLoopbackEndReason = 'timeout' | 'unavailable';

function callbackFromRequest(request: string, authority: string): string | undefined {
  const end = request.indexOf('\r\n\r\n');
  if (end < 0 || end + 4 !== request.length) return undefined;
  const lines = request.slice(0, end).split('\r\n');
  if (lines.some((line: string): boolean => /[\r\n]/.test(line))) return undefined;
  const target = /^GET (\/oauth\/callback\?[\x21-\x7e]+) HTTP\/1\.[01]$/.exec(lines[0])?.[1];
  if (!target || /[#\\]|%(?![a-f0-9]{2})/i.test(target)) return undefined;

  let hasHost = false;
  let hasContentLength = false;
  for (let index = 1; index < lines.length; index++) {
    const field = /^([a-z0-9-]+):([\t\x20-\x7e]*)$/i.exec(lines[index]);
    if (!field) return undefined;
    const name = field[1].toLowerCase();
    const value = field[2].trim();
    if (name === 'host') {
      if (hasHost || value !== authority) return undefined;
      hasHost = true;
    } else if (name === 'content-length') {
      if (hasContentLength || value !== '0') return undefined;
      hasContentLength = true;
    } else if (name === 'transfer-encoding') {
      return undefined;
    }
  }
  return hasHost ? 'http://' + authority + target : undefined;
}

function responseText(accepted: boolean): string {
  const title = accepted ? 'Authorization received' : 'Invalid authorization callback';
  const text = accepted ? 'Return to Nuwa to finish signing in.' : 'This request did not complete authorization.';
  const chinese = accepted ? '&#24050;&#25910;&#21040;&#25480;&#26435;&#65292;&#35831;&#36820;&#22238; Nuwa&#12290;' :
    '&#25480;&#26435;&#22238;&#35843;&#26080;&#25928;&#12290;';
  // The page is ASCII so its byte length is exact even with the translated text.
  const body = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" ' +
    'content="width=device-width,initial-scale=1"><title>Nuwa</title><h1>' + title + '</h1><p>' + text +
    '</p><p lang="zh-CN">' + chinese + '</p></html>';
  return (accepted ? 'HTTP/1.1 200 OK' : 'HTTP/1.1 400 Bad Request') +
    '\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nPragma: no-cache' +
    '\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n' +
    "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n" +
    'Connection: close\r\nContent-Length: ' + body.length.toString() + '\r\n\r\n' + body;
}

function closeListener(listener: socket.TCPSocketServer): void {
  try {
    void listener.close().catch(() => {});
  } catch {
    // A failed bind can leave no listener to close.
  }
}

function closeConnection(connection: socket.TCPSocketConnection): void {
  try {
    void connection.close().catch(() => {});
  } catch {
    // A connection may close before its queued events are delivered.
  }
}

/** A browser callback listener active only for one in-memory PKCE attempt. */
export class NativeOAuthLoopbackServer {
  private listener?: socket.TCPSocketServer;
  private readonly clients = new Map<number, LoopbackClient>();
  private timeout: number = -1;
  private expiresAt: number = 0;
  private accepted: boolean = false;

  /**
   * onCallback returns true only after the caller validates and claims the current authorization attempt.
   * A rejected callback does not consume the listener.
   */
  async start(onCallback: (url: string) => boolean, onEnd?: (reason: NativeOAuthLoopbackEndReason) => void): Promise<string> {
    this.stop();
    const listener = socket.constructTCPSocketServerInstance();
    this.listener = listener;
    try {
      await listener.listen({ address: LOOPBACK_HOST, family: 1, port: 0 });
      if (this.listener !== listener) throw new Error('Authorization callback canceled');
      const bound = await listener.getLocalAddress();
      const port = bound.port ?? 0;
      if (this.listener !== listener || bound.address !== LOOPBACK_HOST || !Number.isSafeInteger(port) ||
        port < 1 || port > 65535) {
        throw new Error('Unable to bind the authorization callback to loopback');
      }
      const authority = LOOPBACK_HOST + ':' + port.toString();
      this.expiresAt = Date.now() + AUTHORIZATION_TIMEOUT_MS;
      listener.on('connect', (connection: socket.TCPSocketConnection): void => {
        this.acceptConnection(connection, listener, authority, onCallback, onEnd);
      });
      listener.on('error', (): void => { this.end(listener, 'unavailable', onEnd); });
      this.timeout = setTimeout((): void => { this.end(listener, 'timeout', onEnd); }, AUTHORIZATION_TIMEOUT_MS);
      return 'http://' + authority + CALLBACK_PATH;
    } catch (error) {
      if (this.listener === listener) {
        this.stop();
      } else {
        // A pending bind can complete after stop() first tried to close it.
        closeListener(listener);
      }
      throw error as Error;
    }
  }

  stop(): void {
    const listener = this.listener;
    this.listener = undefined;
    this.accepted = false;
    this.expiresAt = 0;
    if (this.timeout >= 0) clearTimeout(this.timeout);
    this.timeout = -1;
    for (const client of this.clients.values()) {
      clearTimeout(client.timer);
      closeConnection(client.connection);
    }
    this.clients.clear();
    if (listener) closeListener(listener);
  }

  private end(listener: socket.TCPSocketServer, reason: NativeOAuthLoopbackEndReason,
    onEnd?: (reason: NativeOAuthLoopbackEndReason) => void): void {
    if (this.listener !== listener) return;
    const accepted = this.accepted;
    this.stop();
    if (!accepted && onEnd) onEnd(reason);
  }

  private acceptConnection(connection: socket.TCPSocketConnection, listener: socket.TCPSocketServer, authority: string,
    onCallback: (url: string) => boolean, onEnd?: (reason: NativeOAuthLoopbackEndReason) => void): void {
    if (this.listener !== listener || this.accepted || this.clients.size >= MAX_OPEN_CONNECTIONS) {
      closeConnection(connection);
      return;
    }
    const client: LoopbackClient = { connection, text: '', timer: -1, handled: false, accepted: false };
    this.clients.set(connection.clientId, client);
    client.timer = setTimeout((): void => { this.finishConnection(client, listener); }, CONNECTION_TIMEOUT_MS);
    try {
      connection.on('close', (): void => { this.finishConnection(client, listener, false); });
      connection.on('error', (): void => { this.finishConnection(client, listener); });
      connection.on('message', (info: socket.SocketMessageInfo): void => {
        if (!client.handled && this.listener === listener && !this.accepted) {
          this.receive(client, listener, authority, info, onCallback, onEnd);
        }
      });
    } catch {
      this.finishConnection(client, listener);
    }
  }

  private receive(client: LoopbackClient, listener: socket.TCPSocketServer, authority: string, info: socket.SocketMessageInfo,
    onCallback: (url: string) => boolean, onEnd?: (reason: NativeOAuthLoopbackEndReason) => void): void {
    if (Date.now() >= this.expiresAt) {
      this.end(listener, 'timeout', onEnd);
      return;
    }
    try {
      if (info.remoteInfo.address !== LOOPBACK_HOST || info.message.byteLength > MAX_REQUEST_BYTES - client.text.length) {
        this.respond(client, listener, false);
        return;
      }
      for (const octet of new Uint8Array(info.message)) {
        if (octet !== 9 && octet !== 10 && octet !== 13 && (octet < 32 || octet > 126)) {
          this.respond(client, listener, false);
          return;
        }
        client.text += String.fromCharCode(octet);
      }
      if (!client.text.includes('\r\n\r\n')) return;
      const target = callbackFromRequest(client.text, authority);
      client.text = '';
      this.respond(client, listener, !!target && onCallback(target));
    } catch {
      this.respond(client, listener, false);
    }
  }

  private respond(client: LoopbackClient, listener: socket.TCPSocketServer, accepted: boolean): void {
    if (client.handled || this.listener !== listener) return;
    client.handled = true;
    client.accepted = accepted;
    this.accepted = accepted;
    try {
      void client.connection.send({ data: responseText(accepted) }).catch(() => {}).finally((): void => {
        this.finishConnection(client, listener);
      });
    } catch {
      this.finishConnection(client, listener);
    }
  }

  private finishConnection(client: LoopbackClient, listener: socket.TCPSocketServer, close: boolean = true): void {
    const key = client.connection.clientId;
    if (this.clients.get(key) !== client) return;
    this.clients.delete(key);
    clearTimeout(client.timer);
    client.text = '';
    if (close) closeConnection(client.connection);
    if (client.accepted && this.listener === listener) this.stop();
  }
}
