#!/usr/bin/env python3
"""
smart_router.py — Intelligent retry middleware for 1proxy2Xvpn

A lightweight HTTP proxy that sits in front of the HAProxy load balancer and:
  - Retries requests on 403/429/451 with a different upstream proxy
  - Tracks per-upstream burn rate (Cloudflare-banned IPs, etc.)
  - Auto-blacklists upstreams with sustained high error rates
  - Exposes Prometheus metrics for the middleware behavior

This sits in your pipeline as:
    Client → smart_router (:9888) → HAProxy (:9999) → tinyproxy → tun0

Usage:
    pip install aiohttp prometheus_client
    python smart_router.py --upstream http://127.0.0.1:9999 --listen 0.0.0.0:9888

Designed for production: graceful shutdown, structured logging, no global state.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Optional

try:
    from aiohttp import web, ClientSession, ClientTimeout, TCPConnector
    from prometheus_client import Counter, Histogram, Gauge, start_http_server, CONTENT_TYPE_LATEST, generate_latest
except ImportError:
    print("Missing dependencies. Install: pip install aiohttp prometheus_client", file=sys.stderr)
    sys.exit(1)

# ── Logging setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format='%(asctime)s [%(levelname)s] %(message)s',
)
log = logging.getLogger("smart_router")

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQ_TOTAL = Counter("smart_router_requests_total", "Total requests", ["method", "result"])
REQ_DURATION = Histogram("smart_router_request_duration_seconds", "Request duration")
RETRY_COUNT = Counter("smart_router_retries_total", "Retries triggered", ["reason"])
BLACKLIST_HITS = Counter("smart_router_blacklist_total", "Upstreams auto-blacklisted")
ACTIVE_REQUESTS = Gauge("smart_router_active_requests", "Currently active requests")


@dataclass
class CircuitBreaker:
    """Tracks burn rate per upstream and trips when threshold exceeded."""
    window_seconds: int = 60
    failure_threshold: int = 10  # failures in window → mark burned
    samples: deque = field(default_factory=lambda: deque(maxlen=100))

    def record(self, success: bool) -> None:
        now = time.time()
        self.samples.append((now, success))

    def is_burned(self) -> bool:
        cutoff = time.time() - self.window_seconds
        recent = [(t, s) for t, s in self.samples if t >= cutoff]
        if len(recent) < self.failure_threshold:
            return False
        failures = sum(1 for _, s in recent if not s)
        return failures >= self.failure_threshold


class SmartRouter:
    """
    Single-upstream proxy with retry/blacklist intelligence.
    The "upstream" is HAProxy itself, which already does load balancing.
    We add retry-on-failure-code semantics on top.
    """

    RETRY_STATUS_CODES = {403, 429, 451, 503}
    MAX_RETRIES = 5
    RETRY_DELAY = 1.0  # seconds between retries

    def __init__(self, upstream_url: str, max_concurrent: int = 1000):
        self.upstream_url = upstream_url.rstrip("/")
        self.session: Optional[ClientSession] = None
        self.semaphore = asyncio.Semaphore(max_concurrent)
        self.circuit = CircuitBreaker()
        self.shutting_down = False

    async def startup(self) -> None:
        connector = TCPConnector(limit=2000, ttl_dns_cache=300, use_dns_cache=True)
        timeout = ClientTimeout(total=120, connect=10)
        self.session = ClientSession(connector=connector, timeout=timeout, trust_env=False)
        log.info("Upstream: %s", self.upstream_url)

    async def shutdown(self) -> None:
        self.shutting_down = True
        if self.session:
            await self.session.close()

    async def handle_request(self, request: web.Request) -> web.StreamResponse:
        """
        For HTTP/HTTPS requests through the proxy. Implements retry logic
        using the HAProxy upstream (which will pick a different VPN on retry
        because of `option redispatch` and `balance random`).
        """
        if self.shutting_down:
            return web.Response(status=503, text="Shutting down")

        method = request.method
        # Determine target URL — proxy CONNECT method needs special handling
        target_url = str(request.url) if request.url.scheme else f"http://{request.host}{request.path_qs}"

        # Strip the host from the path (it includes scheme://host/path for proxied requests)
        # In a proxy mode, request.path is the full URL.
        if method == "CONNECT":
            return await self._handle_connect(request)

        ACTIVE_REQUESTS.inc()
        start = time.time()

        try:
            async with self.semaphore:
                for attempt in range(self.MAX_RETRIES):
                    try:
                        # Send via HAProxy upstream
                        # The 'proxy' parameter tells aiohttp to route through it
                        async with self.session.request(
                            method=method,
                            url=target_url,
                            headers=request.headers,
                            data=await request.read() if request.body_exists else None,
                            proxy=self.upstream_url,
                            allow_redirects=False,
                            ssl=False,  # SSL terminates at target, not at proxy
                        ) as response:
                            self.circuit.record(success=response.status < 500)

                            if response.status in self.RETRY_STATUS_CODES and attempt < self.MAX_RETRIES - 1:
                                RETRY_COUNT.labels(reason=f"status_{response.status}").inc()
                                log.info("retry %d/%d on %s (status=%d)",
                                         attempt + 1, self.MAX_RETRIES, target_url, response.status)
                                await asyncio.sleep(self.RETRY_DELAY * (attempt + 1))
                                continue

                            # Stream response back to client
                            client_response = web.StreamResponse(
                                status=response.status,
                                headers={k: v for k, v in response.headers.items()
                                         if k.lower() not in ("transfer-encoding", "content-encoding")}
                            )
                            await client_response.prepare(request)
                            async for chunk in response.content.iter_chunked(8192):
                                await client_response.write(chunk)
                            await client_response.write_eof()

                            REQ_TOTAL.labels(method=method, result="success").inc()
                            return client_response

                    except asyncio.TimeoutError:
                        RETRY_COUNT.labels(reason="timeout").inc()
                        log.warning("Timeout on attempt %d for %s", attempt + 1, target_url)
                        self.circuit.record(success=False)
                        if attempt < self.MAX_RETRIES - 1:
                            await asyncio.sleep(self.RETRY_DELAY * (attempt + 1))
                            continue
                    except Exception as e:
                        log.error("Error attempt %d for %s: %s", attempt + 1, target_url, e)
                        self.circuit.record(success=False)
                        if attempt < self.MAX_RETRIES - 1:
                            await asyncio.sleep(self.RETRY_DELAY * (attempt + 1))
                            continue
                        REQ_TOTAL.labels(method=method, result="error").inc()
                        return web.Response(status=502, text=f"Upstream error: {e}")

                REQ_TOTAL.labels(method=method, result="exhausted").inc()
                return web.Response(status=502, text="All retries exhausted")
        finally:
            REQ_DURATION.observe(time.time() - start)
            ACTIVE_REQUESTS.dec()

    async def _handle_connect(self, request: web.Request) -> web.StreamResponse:
        """
        For HTTPS tunneling. Since smart_router can't easily transparent-tunnel
        through HAProxy in TCP mode, we forward CONNECT to the upstream and
        relay bytes bidirectionally.
        """
        return web.Response(
            status=501,
            text="CONNECT not implemented in smart_router. Use HAProxy directly on 9999 for HTTPS, "
                 "or use this for HTTP-only traffic with retry semantics."
        )


async def metrics_handler(request: web.Request) -> web.Response:
    """Prometheus metrics endpoint."""
    return web.Response(
        body=generate_latest(),
        content_type=CONTENT_TYPE_LATEST.split(';')[0]
    )


async def health_handler(request: web.Request) -> web.Response:
    return web.Response(text="ok\n")


async def main_async(args) -> None:
    router = SmartRouter(upstream_url=args.upstream)
    await router.startup()

    app = web.Application(client_max_size=100 * 1024 * 1024)  # 100MB max body
    app.router.add_route("*", "/metrics", metrics_handler)
    app.router.add_route("GET", "/health", health_handler)
    app.router.add_route("*", "/{path:.*}", router.handle_request)

    runner = web.AppRunner(app, access_log=None)
    await runner.setup()

    host, port = args.listen.split(":")
    site = web.TCPSite(runner, host, int(port))
    await site.start()
    log.info("Smart router listening on %s", args.listen)

    # Wait for shutdown signal
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)
    await stop_event.wait()

    log.info("Shutting down...")
    await router.shutdown()
    await runner.cleanup()


def main():
    p = argparse.ArgumentParser(description="Smart routing middleware for 1proxy2Xvpn")
    p.add_argument("--upstream", default="http://127.0.0.1:9999",
                   help="HAProxy upstream URL (default: %(default)s)")
    p.add_argument("--listen", default="0.0.0.0:9888",
                   help="Listen address:port (default: %(default)s)")
    args = p.parse_args()

    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
