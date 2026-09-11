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
    CIRCUIT_STATE = Gauge("smart_router_circuit_throttling", "1 if the protective throttle is engaged, else 0")
    CIRCUIT_BURN_RATE = Gauge("smart_router_burn_rate", "Fraction of failed requests in the current window (0..1)")
    CIRCUIT_THROTTLE_TOTAL = Counter("smart_router_throttle_engaged_total", "Times the protective throttle engaged")
else:
    class _Noop:
        def labels(self, *a, **k): return self
        def inc(self, *a, **k): pass
        def dec(self, *a, **k): pass
        def observe(self, *a, **k): pass
        def set(self, *a, **k): pass
    REQ_TOTAL = RETRY_COUNT = ACTIVE_REQUESTS = CONNECT_TOTAL = _Noop()
    REQ_DURATION = _Noop()
    CIRCUIT_STATE = CIRCUIT_BURN_RATE = CIRCUIT_THROTTLE_TOTAL = _Noop()


@dataclass
class CircuitBreaker:
    """
    Tracks the recent request failure rate and, when it crosses a threshold,
    signals a protective throttle. This does NOT remove any backend from
    rotation (the router can't tell which VPN IP served a given request in
    HAProxy tcp mode) — it simply slows the pace of NEW requests so a target
    that is blocking everything doesn't burn the whole IP pool in seconds.

    Conservative by default and fully disableable, because legitimate testing
    (fuzzing, brute-force, rate-limit checks) can produce many 4xx by design.
    Tuned via environment variables (see main()).
    """
    window_seconds: int = 60
    failure_threshold: int = 20      # failures within the window to trip (conservative)
    throttle_seconds: float = 2.0    # delay applied to new requests while tripped
    enabled: bool = True
    samples: deque = field(default_factory=lambda: deque(maxlen=500))
    _tripped: bool = False           # current state, for edge-triggered logging

    def record(self, success: bool) -> None:
        self.samples.append((time.time(), success))

    def _recent(self):
        cutoff = time.time() - self.window_seconds
        return [(t, s) for t, s in self.samples if t >= cutoff]

    def burn_rate(self) -> float:
        recent = self._recent()
        if not recent:
            return 0.0
        return sum(1 for _, s in recent if not s) / len(recent)

    def is_burned(self) -> bool:
        if not self.enabled:
            return False
        recent = self._recent()
        if len(recent) < self.failure_threshold:
            return False
        return sum(1 for _, s in recent if not s) >= self.failure_threshold

    def throttle_delay(self) -> float:
        """Seconds to delay a new request right now (0 when healthy/disabled)."""
        return self.throttle_seconds if self.is_burned() else 0.0

    def refresh_state(self) -> None:
        """Update metrics and log only on state transitions (not every request)."""
        CIRCUIT_BURN_RATE.set(round(self.burn_rate(), 3))
        burned = self.is_burned()
        if burned and not self._tripped:
            self._tripped = True
            CIRCUIT_STATE.set(1)
            CIRCUIT_THROTTLE_TOTAL.inc()
            log.warning(
                "[circuit] high failure rate (%.0f%% in %ds) — throttling new requests by %.1fs "
                "to protect the IP pool. Set SMART_ROUTER_CIRCUIT=off to disable.",
                self.burn_rate() * 100, self.window_seconds, self.throttle_seconds,
            )
        elif not burned and self._tripped:
            self._tripped = False
            CIRCUIT_STATE.set(0)
            log.info("[circuit] failure rate back to normal — throttle released.")


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
    # Defensive limits against malformed/abusive clients (per connection).
    MAX_HEADER_LINE = 16384    # 16 KB per header line
    MAX_HEADERS = 200          # max number of header lines
    MAX_BODY = 100 * 1024 * 1024  # 100 MB request body cap

    def __init__(self, upstream_host: str, upstream_port: int, max_concurrent: int = 1000,
                 circuit: CircuitBreaker | None = None):
        self.up_host = upstream_host
        self.up_port = upstream_port
        self.semaphore = asyncio.Semaphore(max_concurrent)
        self.circuit = circuit if circuit is not None else CircuitBreaker()
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

        # Protective throttle: if the pool is burning (target blocking en masse),
        # slow the pace of NEW requests so we don't torch every IP. Reversible;
        # releases automatically once the failure rate drops. Never removes a
        # backend. Disable with SMART_ROUTER_CIRCUIT=off.
        self.circuit.refresh_state()
        delay = self.circuit.throttle_delay()
        if delay > 0:
            await asyncio.sleep(delay)

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
            sent_headers = self._rewrite_headers(headers, connection_close=True, body_len=len(body))
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
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
            except ValueError:
                # asyncio raises ValueError/LimitOverrunError when a line exceeds
                # the stream's buffer limit (set on start_server) — treat as abuse.
                raise ValueError("header line too large")
            if line in (b"\r\n", b"\n", b""):
                break
            if len(headers) >= self.MAX_HEADERS:
                raise ValueError("too many headers")
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
        # Prefer explicit Content-Length; otherwise handle chunked bodies, which
        # Burp and other tools commonly send. Enforce a size cap either way.
        content_length = None
        chunked = False
        for k, v in headers:
            lk = k.lower()
            if lk == "content-length":
                try:
                    content_length = int(v)
                except ValueError:
                    content_length = None
            elif lk == "transfer-encoding" and "chunked" in v.lower():
                chunked = True

        if chunked:
            return await self._read_chunked_body(reader)

        if not content_length or content_length <= 0:
            return b""
        if content_length > self.MAX_BODY:
            raise ValueError("request body too large")
        return await asyncio.wait_for(reader.readexactly(content_length), timeout=self.IO_TIMEOUT)

    async def _read_chunked_body(self, reader) -> bytes:
        """Read an HTTP/1.1 chunked body and return the de-chunked bytes."""
        body = bytearray()
        while True:
            size_line = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
            if not size_line:
                break
            # Chunk size is hex, optionally followed by ";extensions".
            size_str = size_line.split(b";", 1)[0].strip()
            try:
                size = int(size_str, 16)
            except ValueError:
                raise ValueError("malformed chunk size")
            if size == 0:
                # Consume trailing headers (up to the final blank line) and stop.
                while True:
                    trailer = await asyncio.wait_for(reader.readline(), timeout=self.IO_TIMEOUT)
                    if trailer in (b"\r\n", b"\n", b""):
                        break
                break
            if len(body) + size > self.MAX_BODY:
                raise ValueError("chunked body too large")
            chunk = await asyncio.wait_for(reader.readexactly(size), timeout=self.IO_TIMEOUT)
            body.extend(chunk)
            # Each chunk is followed by a CRLF.
            await asyncio.wait_for(reader.readexactly(2), timeout=self.IO_TIMEOUT)
        return bytes(body)

    @staticmethod
    def _rewrite_headers(headers, connection_close: bool, body_len: int = 0) -> list[tuple[str, str]]:
        out = []
        for k, v in headers:
            lk = k.lower()
            if lk in ("connection", "proxy-connection", "keep-alive"):
                continue  # we control connection semantics
            if lk in ("transfer-encoding", "content-length"):
                continue  # replaced below with our own fixed length (if any)
            out.append((k, v))
        # Only set Content-Length when there's an actual body, so bodyless
        # requests (typical GET) keep their original shape / fingerprint.
        if body_len > 0:
            out.append(("Content-Length", str(body_len)))
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

    # Protective throttle (circuit breaker) — conservative and disableable.
    circuit = CircuitBreaker(
        enabled=os.environ.get("SMART_ROUTER_CIRCUIT", "on").lower() not in ("off", "0", "false"),
        window_seconds=int(os.environ.get("SMART_ROUTER_CIRCUIT_WINDOW", "60")),
        failure_threshold=int(os.environ.get("SMART_ROUTER_CIRCUIT_THRESHOLD", "20")),
        throttle_seconds=float(os.environ.get("SMART_ROUTER_CIRCUIT_THROTTLE", "2.0")),
    )

    proxy = SmartProxy(up_host, up_port, circuit=circuit)
    log.info("Upstream (HAProxy): %s:%d", up_host, up_port)
    if circuit.enabled:
        log.info("Protective throttle: ON (trips at %d failures / %ds, delays new requests %.1fs). "
                 "Disable with SMART_ROUTER_CIRCUIT=off.",
                 circuit.failure_threshold, circuit.window_seconds, circuit.throttle_seconds)
    else:
        log.info("Protective throttle: OFF")

    host, port = args.listen.rsplit(":", 1)
    # limit bounds the per-line buffer, capping header/request-line size.
    server = await asyncio.start_server(
        proxy.handle_client, host, int(port), limit=SmartProxy.MAX_HEADER_LINE
    )
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
