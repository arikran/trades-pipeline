"""Binance trades WebSocket -> Kafka topic `trades` (key = symbol, value = trade JSON)."""
import asyncio
import json
import logging
import os
import pathlib
import random
import signal
import socket
import sys
import time
import urllib.request

import websockets
from confluent_kafka import Producer

STREAM_URL = os.environ.get("BINANCE_URL", (
    "wss://stream.binance.com:9443/stream?streams=btcusdt@trade/ethusdt@trade/solusdt@trade/"
    "bnbusdt@trade/xrpusdt@trade/adausdt@trade/dogeusdt@trade/avaxusdt@trade/linkusdt@trade"))
TOPIC = os.environ.get("KAFKA_TOPIC", "trades")
HEARTBEAT = pathlib.Path(os.environ.get("HEARTBEAT_FILE", "/tmp/heartbeat"))
# Binance REST "old trade lookup": public since 2023-07 (no API key), weight 25, max 1000 trades per call
HISTORY_URL = "https://api.binance.com/api/v3/historicalTrades?symbol={}&fromId={}&limit=1000"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("producer")


def kafka_config():
    conf = {"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],
            "client.id": socket.gethostname(),  # pod name shows up in broker logs
            "reconnect.backoff.ms": 1000}  # MSK t3 brokers accept only 4 new IAM connections/s
    if os.environ.get("KAFKA_AUTH", "none") == "iam":
        from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
        region = os.environ["AWS_REGION"]

        def oauth_cb(_config):
            token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(region)
            return token, expiry_ms / 1000  # librdkafka wants seconds since epoch

        conf.update({"security.protocol": "SASL_SSL", "sasl.mechanisms": "OAUTHBEARER", "oauth_cb": oauth_cb,
                     "ssl.ca.location": "/etc/ssl/certs/ca-certificates.crt"})
    return conf


def send(producer, trade):
    while True:
        try:
            producer.produce(TOPIC, key=trade["s"], value=json.dumps(trade))
            break
        except BufferError:  # local queue full: Kafka is slow, not Binance. Wait, keep the socket
            producer.poll(1)
    producer.poll(0)  # serve delivery callbacks, frees the local queue
    HEARTBEAT.touch()


gaps_unfilled = 0


def backfill(producer, symbol, first, last):
    """Trades first..last were missed (e.g. reconnect): fetch them over REST, send them like WebSocket trades."""
    global gaps_unfilled
    sent, from_id = 0, first
    try:
        while from_id <= last:
            with urllib.request.urlopen(HISTORY_URL.format(symbol, from_id), timeout=10) as resp:
                page = json.load(resp)
            if not page:
                break
            for r in page:
                if r["id"] > last:
                    break
                send(producer, {"e": "trade", "s": symbol, "t": r["id"], "p": r["price"], "q": r["qty"],
                                "T": r["time"], "m": r["isBuyerMaker"]})  # REST names -> WebSocket names
                sent += 1
            from_id = page[-1]["id"] + 1
            if from_id <= last:
                time.sleep(1)  # 25 weight/page, max 1500/min per producer; Binance IP limit is 6000/min
        log.info("backfilled %d trades for %s", sent, symbol)
    except Exception as e:  # HTTP error (429 included) or timeout: stop, the stream itself goes on
        gaps_unfilled += 1
        log.error("backfill failed for %s %d..%d after %d trades (%s); gaps_unfilled=%d",
                  symbol, first, last, sent, e, gaps_unfilled)


async def stream(producer, stop):
    attempt = 0
    last_t = {}  # symbol -> last trade id seen. Empty after a restart: the other producer covers that window
    while not stop.is_set():
        try:
            async with websockets.connect(STREAM_URL, ping_interval=20) as ws:
                log.info("connected to Binance")
                attempt = 0
                async for raw in ws:
                    trade = json.loads(raw)["data"]
                    s, t = trade["s"], trade["t"]
                    if s in last_t and t > last_t[s] + 1:  # trade ids are sequential per symbol: a jump = missed trades
                        await asyncio.to_thread(backfill, producer, s, last_t[s] + 1, t - 1)  # thread: socket stays served
                    send(producer, trade)
                    last_t[s] = max(last_t.get(s, t), t)
                    if stop.is_set():
                        break
        except Exception as e:
            delay = min(30, 2 ** attempt) * random.uniform(0.5, 1)  # exponential backoff + jitter, cap 30s
            attempt += 1
            log.warning("connection lost (%s); reconnecting in %.1fs", e, delay)
            HEARTBEAT.touch()  # a Binance outage is waited out, not answered with a pod restart
            try:
                await asyncio.wait_for(stop.wait(), delay)
            except asyncio.TimeoutError:
                pass
            HEARTBEAT.touch()


failures = 0


def on_delivery(err, msg):
    global failures
    if not err:
        failures = 0
        return
    failures += 1
    log.error("delivery failed: %s", err)
    if failures > 100:  # Kafka keeps rejecting: crash so k8s restarts the pod
        log.critical("100+ consecutive delivery failures, exiting")
        sys.exit(1)


async def main():
    HEARTBEAT.touch()  # alive before the first connect attempt
    # The topic exists already (Terraform on MSK, kafka-init in compose): this process only produces.
    producer = Producer({**kafka_config(), "acks": "all", "enable.idempotence": True, "linger.ms": 20,
                         "on_delivery": on_delivery})
    producer.poll(1)  # lets oauth_cb run before the first produce (IAM mode)
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, stop.set)
    task = asyncio.create_task(stream(producer, stop))
    await stop.wait()
    task.cancel()
    left = producer.flush(10)
    log.info("shutdown: flushed, %d messages not delivered", left)


if __name__ == "__main__":
    asyncio.run(main())
