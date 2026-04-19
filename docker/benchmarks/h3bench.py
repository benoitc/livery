#!/usr/bin/env python3
"""
HTTP/3 Benchmark Tool using aioquic.

Uses a single QUIC connection with multiplexed streams for reliable benchmarking.
Note: Limited to ~100 streams per connection due to server limits.

Usage: python h3bench.py -n 100 -c 10 https://server:9443/
"""

import argparse
import asyncio
import socket
import ssl
import time
from dataclasses import dataclass, field
from typing import Dict, Optional
from urllib.parse import urlparse

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent


@dataclass
class BenchmarkStats:
    total_requests: int = 0
    successful: int = 0
    failed: int = 0
    total_duration: float = 0
    request_times: list = field(default_factory=list)
    bytes_received: int = 0

    @property
    def requests_per_second(self) -> float:
        return self.successful / self.total_duration if self.total_duration > 0 else 0

    @property
    def min_time(self) -> float:
        return min(self.request_times) if self.request_times else 0

    @property
    def max_time(self) -> float:
        return max(self.request_times) if self.request_times else 0

    @property
    def mean_time(self) -> float:
        return sum(self.request_times) / len(self.request_times) if self.request_times else 0


class H3BenchClient(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http: Optional[H3Connection] = None
        self._responses: Dict[int, dict] = {}
        self._events: Dict[int, asyncio.Event] = {}
        self._lock = asyncio.Lock()

    def quic_event_received(self, event: QuicEvent) -> None:
        if self._http is None:
            self._http = H3Connection(self._quic)

        for h3_event in self._http.handle_event(event):
            if isinstance(h3_event, (HeadersReceived, DataReceived)):
                stream_id = h3_event.stream_id
                if stream_id not in self._responses:
                    self._responses[stream_id] = {
                        'status': 0, 'data': bytearray(), 'start': time.perf_counter()
                    }

                resp = self._responses[stream_id]
                if isinstance(h3_event, HeadersReceived):
                    for header, value in h3_event.headers:
                        if header == b':status':
                            resp['status'] = int(value)
                    if h3_event.stream_ended:
                        resp['end'] = time.perf_counter()
                        if stream_id in self._events:
                            self._events[stream_id].set()
                elif isinstance(h3_event, DataReceived):
                    resp['data'].extend(h3_event.data)
                    if h3_event.stream_ended:
                        resp['end'] = time.perf_counter()
                        if stream_id in self._events:
                            self._events[stream_id].set()

    async def request(self, authority: str, path: str) -> dict:
        async with self._lock:
            if self._http is None:
                self._http = H3Connection(self._quic)

            stream_id = self._quic.get_next_available_stream_id()
            self._responses[stream_id] = {
                'status': 0, 'data': bytearray(), 'start': time.perf_counter()
            }
            self._events[stream_id] = asyncio.Event()

            self._http.send_headers(
                stream_id=stream_id,
                headers=[
                    (b':method', b'GET'),
                    (b':scheme', b'https'),
                    (b':authority', authority.encode()),
                    (b':path', path.encode()),
                ],
                end_stream=True,
            )
            self.transmit()

        await asyncio.wait_for(self._events[stream_id].wait(), timeout=10)
        return self._responses.get(stream_id, {})


async def run_benchmark(url: str, num_requests: int, concurrency: int, insecure: bool) -> BenchmarkStats:
    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or 443
    path = parsed.path or '/'
    authority = f"{host}:{port}" if parsed.port else host

    # Resolve hostname (aioquic has issues with hostnames in some environments)
    try:
        resolved_host = socket.gethostbyname(host)
    except socket.gaierror:
        resolved_host = host

    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    if insecure:
        config.verify_mode = ssl.CERT_NONE

    stats = BenchmarkStats(total_requests=num_requests)

    print(f"Starting benchmark: {num_requests} requests, {concurrency} concurrent")
    print(f"Target: {url}")
    print(f"Using: aioquic (single connection, multiplexed streams)")
    print()

    try:
        async with connect(resolved_host, port, configuration=config, create_protocol=H3BenchClient) as client:
            semaphore = asyncio.Semaphore(concurrency)

            async def send_request():
                async with semaphore:
                    start = time.perf_counter()
                    try:
                        resp = await client.request(authority, path)
                        end = resp.get('end', time.perf_counter())
                        return {
                            'success': 200 <= resp.get('status', 0) < 400,
                            'duration': end - resp.get('start', start),
                            'bytes': len(resp.get('data', b'')),
                        }
                    except asyncio.TimeoutError:
                        return {'success': False, 'duration': 10, 'bytes': 0}
                    except Exception:
                        return {'success': False, 'duration': 0, 'bytes': 0}

            start_time = time.perf_counter()
            results = await asyncio.gather(*[send_request() for _ in range(num_requests)])
            stats.total_duration = time.perf_counter() - start_time

            for r in results:
                if r['success']:
                    stats.successful += 1
                    stats.request_times.append(r['duration'])
                    stats.bytes_received += r['bytes']
                else:
                    stats.failed += 1

            return stats

    except Exception as e:
        print(f"Connection failed: {e}")
        print("Falling back to curl...")
        return await run_curl_fallback(url, num_requests, concurrency, insecure)


async def run_curl_fallback(url: str, num_requests: int, concurrency: int, insecure: bool) -> BenchmarkStats:
    print(f"Using: curl --http3-only (new connection per request)")
    print()

    semaphore = asyncio.Semaphore(concurrency)

    async def single_request():
        async with semaphore:
            cmd = ["curl", "--http3-only", "-s", "-o", "/dev/null", "-w", "%{time_total}"]
            if insecure:
                cmd.append("-k")
            cmd.append(url)
            try:
                proc = await asyncio.create_subprocess_exec(
                    *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
                if proc.returncode == 0:
                    return True, float(stdout.decode().strip())
                return False, 0
            except Exception:
                return False, 0

    stats = BenchmarkStats(total_requests=num_requests)
    start_time = time.perf_counter()
    results = await asyncio.gather(*[single_request() for _ in range(num_requests)])
    stats.total_duration = time.perf_counter() - start_time

    for success, duration in results:
        if success:
            stats.successful += 1
            stats.request_times.append(duration)
        else:
            stats.failed += 1

    return stats


def print_stats(stats: BenchmarkStats):
    print(f"finished in {stats.total_duration:.2f}s, {stats.requests_per_second:.2f} req/s")
    print(f"requests: {stats.total_requests} total, {stats.successful} succeeded, {stats.failed} failed")
    if stats.bytes_received > 0:
        print(f"traffic: {stats.bytes_received} bytes received")
    print()
    if stats.request_times:
        print(f"time for request: min {stats.min_time*1000:.2f}ms, max {stats.max_time*1000:.2f}ms, mean {stats.mean_time*1000:.2f}ms")
    print(f"req/s           : {stats.requests_per_second:.2f}")


def main():
    parser = argparse.ArgumentParser(description="HTTP/3 Benchmark (aioquic)")
    parser.add_argument("url", help="Target URL")
    parser.add_argument("-n", "--requests", type=int, default=100, help="Number of requests (default: 100)")
    parser.add_argument("-c", "--concurrency", type=int, default=10, help="Concurrent streams (default: 10)")
    parser.add_argument("-k", "--insecure", action="store_true", help="Skip cert verification")

    args = parser.parse_args()

    if not args.url.startswith("https://"):
        print("Error: URL must use https://")
        return 1

    stats = asyncio.run(run_benchmark(args.url, args.requests, args.concurrency, args.insecure))
    print_stats(stats)
    return 0


if __name__ == "__main__":
    exit(main())
