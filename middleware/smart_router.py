#!/usr/bin/env python3
"""
smart_router.py — Intelligent retry middleware for 1proxy2Xvpn

A lightweight forward proxy that sits in front of the HAProxy load balancer and:
  - Handles BOTH plain HTTP and HTTPS (CONNECT tunneling) — works with Burp,
    sqlmap, ffuf, nuclei, httpx against HTTPS targets (the common case).
  - Retries HTTP requests on 403/429/451/503, each retry over a FRESH upstream
    connection, so HAProxy round-robins to a different VPN IP on every attempt.
  - For HTTPS, opens a NEW upstream connection per CONNECT, so each tunnel exits
    through a different VPN IP.
  - Tracks per-upstream burn rate and exposes Prometheus metrics.

Pipeline:
    Client → smart_router (:9888) → HAProxy (:9999) → tinyproxy → tun0

Why a raw asyncio proxy (not aiohttp): a forward proxy must speak CONNECT and
must NOT reuse upstream connections (reuse would pin the IP and defeat rotation).
Raw asyncio gives us a fresh upstream connection per request/tunnel by design.

Usage:
    pip install prometheus_client
    python smart_router.py --upstream http://127.0.0.1:9999 --listen 0.0.0.0:9888
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import time
from collections import deque
from dataclasses import dataclass, field
from urllib.parse import urlparse

try:
    from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
    _HAVE_PROM = True
except ImportError:
    # Metrics are optional; the proxy works without prometheus_client installed.
    _HAVE_PROM = False

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("smart_router")

# ── Prometheus metrics (no-op shims if prometheus_client is absent) ───────────
if _HAVE_PROM:
    REQ_TOTAL = Counter("smart_router_requests_total", "Total requests", ["method", "result"])
    REQ_DURATION = Histogram("smart_router_request_duration_seconds", "Request duration")
    RETRY_COUNT = Counter("smart_router_retries_total", "Retries triggered", ["reason"])
    ACTIVE_REQUESTS = Gauge("smart_router_active_requests", "Currently active requests")
    CONNECT_TOTAL = Counter("smart_router_connect_total", "CONNECT tunnels", ["result"])
else:
    class _Noop:
        def labels(self, *a, **k): return self
        def inc(self, *a, **k): pass
        def dec(self, *a, **k): pass
        def observe(self, *a, **k): pass
    REQ_TOTAL = RETRY_COUNT = ACTIVE_REQUESTS = CONNECT_TOTAL = _Noop()
    REQ_DURATION = _Noop()


@dataclass
class CircuitBreaker:
    """Tracks recent failure rate (informational / for metrics)."""
    window_seconds: int = 60
    failure_threshold: int = 10
    samples: deque = field(default_factory=lambda: deque(maxlen=100))

    def record(self, success: bool) -> None:
        self.samples.append((time.time(), success))

    def is_burned(self) -> bool:
        cutoff = time.time() - self.window_seconds
        recent = [(t, s) for t, s in self.samples if t >= cutoff]
        if len(recent) < self.failure_threshold:
            return False
        return sum(1 for _, s in recent if not s) >= self.failure_threshold


class SmartProxy:
    """
    Raw asyncio forward proxy. The upstream is HAProxy (which load-balances the
    VPN pool). We add: HTTPS CONNECT tunneling, and HTTP retry-on-block where
    each attempt uses a fresh upstream connection (=> different VPN IP).
    """

    RETRY_STATUS_CODES = {403, 429, 451, 503}
    MAX_RETRIES = 5
    RETRY_DELAY = 1.0          # base seconds between retries (grows per attempt)
    IO_TIMEOUT = 30            # seconds for a single upstream read/connect
    RELAY_CHUNK = 65536

    def __init__(self, upstream_host: str, upstream_port: int, max_concurrent: int = 1000):
        self.up_host = upstream_host
        self.up_port = upstream_port
        self.semaphore = asyncio.Semaphore(max_concurrent)
        self.circuit = CircuitBreaker()
        self.shutting_down = False

    # ── Connection entry point ────────────────────────────────────────────────
    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        try:
            first_line = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
            if not first_line:
                return
            try:
                method, target, version = first_line.decode("latin-1").rstrip("\r\n").split(" ", 2)
            except ValueError:
                await self._reply(writer, 400, "Bad Request")
                return

            # Local endpoints (Prometheus scrape / health) use an origin-form path.
            if method == "GET" and target in ("/metrics", "/health"):
                await self._drain_headers(reader)
                await self._handle_local(writer, target)
                return

            if method == "CONNECT":
                await self._handle_connect(reader, writer, target)
            else:
                await self._handle_http(reader, writer, method, target, version)
        except asyncio.TimeoutError:
            log.debug("client %s timed out reading request", peer)
        except Exception as e:  # keep the proxy alive regardless of one client
            log.debug("client %s error: %s", peer, e)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    # ── HTTPS: CONNECT tunneling (new upstream connection per tunnel) ─────────
    async def _handle_connect(self, cr, cw, target: str) -> None:
        # Discard the remaining CONNECT request headers from the client.
        await self._drain_headers(cr)

        if self.shutting_down:
            await self._reply(cw, 503, "Shutting down")
            CONNECT_TOTAL.labels(result="rejected").inc()
            return

        async with self.semaphore:
            try:
                ur, uw = await asyncio.wait_for(
                    asyncio.open_connection(self.up_host, self.up_port),
                    timeout=self.IO_TIMEOUT,
                )
            except Exception as e:
                log.warning("CONNECT %s: upstream connect failed: %s", target, e)
                await self._reply(cw, 502, "Bad Gateway")
                CONNECT_TOTAL.labels(result="error").inc()
                return

            try:
                # Ask HAProxy→tinyproxy to establish the tunnel through the VPN.
                uw.write(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode("latin-1"))
                await uw.drain()

                status_line = await asyncio.wait_for(ur.readline(), timeout=self.IO_TIMEOUT)
                if b" 200 " not in status_line and not status_line.startswith(b"HTTP/1.1 200"):
                    log.info("CONNECT %s: upstream refused (%s)", target, status_line.decode("latin-1").strip())
                    await self._reply(cw, 502, "Bad Gateway")
                    CONNECT_TOTAL.labels(result="refused").inc()
                    return
                # Consume upstream's response headers up to the blank line.
                await self._drain_headers(ur)

                # Tell the client the tunnel is open, then relay raw bytes.
                cw.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
                await cw.drain()
                CONNECT_TOTAL.labels(result="established").inc()

                await self._relay(cr, cw, ur, uw)
            finally:
                for w in (uw,):
                    try:
                        w.close()
                    except Exception:
                        pass

    async def _relay(self, cr, cw, ur, uw) -> None:
        """Bidirectional byte pump between client and upstream until either closes."""
        async def pipe(src, dst):
            try:
                while True:
                    data = await src.read(self.RELAY_CHUNK)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
            except Exception:
                pass
            finally:
                try:
                    dst.close()
                except Exception:
                    pass

        await asyncio.gather(pipe(cr, uw), pipe(ur, cw), return_exceptions=True)

    # ── HTTP: forward with retry, fresh upstream connection per attempt ───────
    async def _handle_http(self, cr, cw, method: str, target: str, version: str) -> None:
        # Read client headers and (optional) body.
        headers = await self._read_headers(cr)
        body = await self._read_body(cr, headers)

        ACTIVE_REQUESTS.inc()
        start = time.time()
        try:
            async with self.semaphore:
                for attempt in range(self.MAX_RETRIES):
                    if self.shutting_down:
                        await self._reply(cw, 503, "Shutting down")
                        return
                    try:
                        status = await self._forward_once(cw, method, target, version, headers, body)
                    except Exception as e:
                        self.circuit.record(success=False)
                        if attempt < self.MAX_RETRIES - 1:
                            RETRY_COUNT.labels(reason="error").inc()
                            await asyncio.sleep(self.RETRY_DELAY * (attempt + 1))
                            continue
                        REQ_TOTAL.labels(method=method, result="error").inc()
                        await self._reply(cw, 502, f"Upstream error: {e}")
                        return

                    # status is None when the response was already streamed to the client.
                    if status is None:
                        REQ_TOTAL.labels(method=method, result="success").inc()
                        return

                    # status is an int only when it's a retryable code and we chose to retry.
                    RETRY_COUNT.labels(reason=f"status_{status}").inc()
                    log.info("retry %d/%d on %s (status=%d)", attempt + 1, self.MAX_RETRIES, target, status)
                    self.circuit.record(success=False)
                    await asyncio.sleep(self.RETRY_DELAY * (attempt + 1))

                REQ_TOTAL.labels(method=method, result="exhausted").inc()
                await self._reply(cw, 502, "All retries exhausted")
        finally:
            REQ_DURATION.observe(time.time() - start)
            ACTIVE_REQUESTS.dec()

    async def _forward_once(self, cw, method, target, version, headers, body):
        """
        Send one request over a FRESH upstream connection. Returns:
          - int status  → the response was a retryable code; caller may retry
                           (nothing written to the client yet).
          - None         → response already relayed to the client (done).
        Raises on connection/IO error (caller handles retry).
        """
        ur, uw = await asyncio.wait_for(
            asyncio.open_connection(self.up_host, self.up_port),
            timeout=self.IO_TIMEOUT,
        )
        try:
            # Force upstream to close after the response so we can read body to EOF,
            # and never reuse a connection (which would pin the VPN IP).
            sent_headers = self._rewrite_headers(headers, connection_close=True)
            req = [f"{method} {target} {version}\r\n"]
            for k, v in sent_headers:
                req.append(f"{k}: {v}\r\n")
            req.append("\r\n")
            uw.write("".join(req).encode("latin-1"))
            if body:
                uw.write(body)
            await uw.drain()

            status_line = await asyncio.wait_for(ur.readline(), timeout=self.IO_TIMEOUT)
            if not status_line:
                raise ConnectionError("empty upstream response")
            try:
                status = int(status_line.split(b" ", 2)[1])
            except (IndexError, ValueError):
                status = 0
            self.circuit.record(success=status < 500)

            # Read the upstream response headers block (keep them to relay verbatim).
            resp_header_lines = []
            while True:
                line = await asyncio.wait_for(ur.readline(), timeout=self.IO_TIMEOUT)
                if line in (b"\r\n", b"\n", b""):
                    break
                resp_header_lines.append(line)

            # Retry decision happens BEFORE writing anything to the client.
            if status in self.RETRY_STATUS_CODES:
                return status  # caller may retry over a fresh connection (new IP)

            # Relay: status line + headers + body (to EOF, since Connection: close).
            cw.write(status_line)
            for line in resp_header_lines:
                cw.write(line)
            cw.write(b"\r\n")
            await cw.drain()
            while True:
                chunk = await ur.read(self.RELAY_CHUNK)
                if not chunk:
                    break
                cw.write(chunk)
                await cw.drain()
            return None
        finally:
            try:
                uw.close()
            except Exception:
                pass

    # ── Header/body helpers ───────────────────────────────────────────────────
    async def _read_headers(self, reader) -> list[tuple[str, str]]:
        headers = []
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
            if line in (b"\r\n", b"\n", b""):
                break
            try:
                k, v = line.decode("latin-1").rstrip("\r\n").split(":", 1)
                headers.append((k.strip(), v.strip()))
            except ValueError:
                continue
        return headers

    async def _drain_headers(self, reader) -> None:
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
            if line in (b"\r\n", b"\n", b""):
                break

    async def _read_body(self, reader, headers) -> bytes:
        length = 0
        for k, v in headers:
            if k.lower() == "content-length":
                try:
                    length = int(v)
                except ValueError:
                    length = 0
                break
        if length <= 0:
            return b""
        return await asyncio.wait_for(reader.readexactly(length), timeout=self.IO_TIMEOUT)

    @staticmethod
    def _rewrite_headers(headers, connection_close: bool) -> list[tuple[str, str]]:
        out = []
        for k, v in headers:
            lk = k.lower()
            if lk in ("connection", "proxy-connection", "keep-alive"):
                continue  # we control connection semantics
            out.append((k, v))
        if connection_close:
            out.append(("Connection", "close"))
        return out

    # ── Local + tiny replies ──────────────────────────────────────────────────
    async def _handle_local(self, writer, target: str) -> None:
        if target == "/health":
            body = b"ok\n"
            ctype = "text/plain"
        else:  # /metrics
            if _HAVE_PROM:
                body = generate_latest()
                ctype = CONTENT_TYPE_LATEST.split(";")[0]
            else:
                body = b"prometheus_client not installed\n"
                ctype = "text/plain"
        writer.write(
            f"HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode("latin-1")
        )
        writer.write(body)
        try:
            await writer.drain()
        except Exception:
            pass

    @staticmethod
    async def _reply(writer, status: int, text: str) -> None:
        reason = {400: "Bad Request", 502: "Bad Gateway", 503: "Service Unavailable"}.get(status, "Error")
        body = f"{text}\n".encode("latin-1")
        try:
            writer.write(
                f"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain\r\n"
                f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode("latin-1")
            )
            writer.write(body)
            await writer.drain()
        except Exception:
            pass


async def main_async(args) -> None:
    parsed = urlparse(args.upstream if "://" in args.upstream else f"http://{args.upstream}")
    up_host = parsed.hostname or "127.0.0.1"
    up_port = parsed.port or 9999

    proxy = SmartProxy(up_host, up_port)
    log.info("Upstream (HAProxy): %s:%d", up_host, up_port)

    host, port = args.listen.rsplit(":", 1)
    server = await asyncio.start_server(proxy.handle_client, host, int(port))
    log.info("Smart router listening on %s (HTTP + HTTPS CONNECT, retry with IP rotation)", args.listen)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    async with server:
        await server.start_serving()
        await stop_event.wait()
        log.info("Shutting down...")
        proxy.shutting_down = True


def main():
    p = argparse.ArgumentParser(description="Smart routing middleware for 1proxy2Xvpn")
    p.add_argument("--upstream", default="http://127.0.0.1:9999",
                   help="HAProxy upstream URL or host:port (default: %(default)s)")
    p.add_argument("--listen", default="0.0.0.0:9888",
                   help="Listen address:port (default: %(default)s)")
    args = p.parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
