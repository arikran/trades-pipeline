"""Kafka topic `trades` -> PostgreSQL table `trades`, exactly one row per (symbol, trade_id)."""
import json
import logging
import os
import pathlib
import signal
import socket
import time
from datetime import datetime, timezone
from decimal import Decimal

import psycopg
from confluent_kafka import Consumer, KafkaException

TOPIC = os.environ.get("KAFKA_TOPIC", "trades")
HEARTBEAT = pathlib.Path(os.environ.get("HEARTBEAT_FILE", "/tmp/heartbeat"))
CLOUDWATCH = os.environ.get("CLOUDWATCH_ENABLED", "false") == "true"
KAFKA_GRACE_S = 120  # Kafka errors tolerated before the heartbeat stops (rolling broker restarts are shorter)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("consumer")

# The table, its indexes and this role's grants come from db_init.py (Helm hook Job, master user).
# The consumer connects as trades_app: SELECT and INSERT on trades, nothing else.
INSERT = """INSERT INTO trades (symbol, trade_id, price, quantity, notional, trade_time)
    VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (symbol, trade_id) DO NOTHING"""


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


def db_connect():
    user, password = os.environ.get("DB_USER"), os.environ.get("DB_PASSWORD")
    if os.environ.get("DB_SECRET_ARN"):
        import boto3
        # botocore reads only AWS_DEFAULT_REGION from the environment, so pass the region explicitly
        secret = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"]).get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
        creds = json.loads(secret["SecretString"])
        user, password = creds["username"], creds["password"]
    return psycopg.connect(host=os.environ["DB_HOST"], port=os.environ.get("DB_PORT", "5432"),
                           dbname=os.environ.get("DB_NAME", "trades"), user=user, password=password,
                           sslmode=os.environ.get("DB_SSLMODE", "prefer"),
                           connect_timeout=10)  # an unreachable RDS fails fast instead of hanging the loop


def retry(what, fn):
    """Startup: keep trying with backoff so a pod started before RDS/MSK is ready recovers."""
    for attempt in range(10):
        HEARTBEAT.touch()  # waiting for MSK/RDS is not a hung pod: keep startup/liveness probes green
        try:
            return fn()
        except Exception as e:
            delay = min(20, 2 ** attempt)
            log.warning("%s not ready (%s); retry in %ds", what, e, delay)
            time.sleep(delay)
    HEARTBEAT.touch()
    return fn()  # last try: let the error crash the pod


def to_row(trade):
    price, qty = Decimal(trade["p"]), Decimal(trade["q"])  # strings -> exact decimals, never float
    when = datetime.fromtimestamp(trade["T"] / 1000, tz=timezone.utc)
    return trade["s"], trade["t"], price, qty, price * qty, when


class Freshness:
    """Seconds between commit time and the oldest trade; the WORST value of each 10 s window is published."""

    def __init__(self):
        self.last = time.time()
        self.worst = None
        self.cw = None
        if CLOUDWATCH:
            import boto3
            self.cw = boto3.client("cloudwatch", region_name=os.environ["AWS_REGION"])

    def report(self, rows):
        if rows:
            lag = (datetime.now(timezone.utc) - min(r[5] for r in rows)).total_seconds()  # oldest trade in batch
            self.worst = lag if self.worst is None else max(self.worst, lag)
        if self.worst is None or time.time() - self.last < 10:
            return
        lag, self.worst, self.last = self.worst, None, time.time()
        if self.cw:
            try:
                self.cw.put_metric_data(Namespace="TradesPipeline", MetricData=[
                    {"MetricName": "FreshnessSeconds", "Value": lag, "Unit": "Seconds"}])
            except Exception as e:  # a metric failure must not stop the writes; the alarm sees missing data
                log.warning("freshness metric not sent: %s", e)
        log.info("freshness worst %.2fs in the last 10s window", lag)


def main():
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))

    HEARTBEAT.touch()  # alive before the first connect attempt
    db = retry("postgres", db_connect)

    kafka_failing_since = []  # set by error_cb, cleared by the first message that arrives

    def on_kafka_error(err):  # auth / all-brokers-down errors are reported here, not as messages
        log.error("kafka error: %s", err)
        if not kafka_failing_since:
            kafka_failing_since.append(time.time())

    consumer = Consumer({**kafka_config(), "group.id": "trades-writer", "enable.auto.commit": False,
                         "auto.offset.reset": "earliest", "error_cb": on_kafka_error,
                         "partition.assignment.strategy": "cooperative-sticky"})  # rebalance moves only changed partitions
    def on_assign(_c, parts):  # evidence for scale-out/rebalance in the logs
        log.info("assigned partitions %s", sorted(p.partition for p in parts))

    def on_revoke(_c, parts):
        log.info("revoked partitions %s", sorted(p.partition for p in parts))

    consumer.subscribe([TOPIC], on_assign=on_assign, on_revoke=on_revoke)
    freshness = Freshness()
    log.info("consuming %s", TOPIC)

    while not stop:
        # Every loop, also on empty polls: a quiet market is not a dead pod. But after 120 s of Kafka
        # errors with no message, stop touching it, so liveness restarts the pod and the failure is visible.
        if kafka_failing_since and time.time() - kafka_failing_since[0] >= KAFKA_GRACE_S:
            # A consumer can own only an empty partition (9 symbols hash onto 5 of 6), so "no message"
            # alone is not proof of failure: ask the brokers. Auth/network failures make this raise too.
            try:
                consumer.list_topics(TOPIC, timeout=5)
                kafka_failing_since.clear()
            except KafkaException as e:
                log.error("kafka still failing after %ds: %s", KAFKA_GRACE_S, e)
        if not kafka_failing_since or time.time() - kafka_failing_since[0] < KAFKA_GRACE_S:
            HEARTBEAT.touch()
        msgs = consumer.consume(num_messages=500, timeout=1)
        rows = []
        for m in msgs:
            if m.error():
                log.error("kafka error: %s", m.error())
                continue
            kafka_failing_since.clear()
            rows.append(to_row(json.loads(m.value())))
        if not rows:
            continue
        while True:
            try:
                with db.cursor() as cur:
                    cur.executemany(INSERT, rows)
                    inserted = cur.rowcount  # rows actually written; ON CONFLICT skips are not counted
                db.commit()
                break
            except psycopg.OperationalError as e:  # DB dropped (e.g. RDS failover): reconnect, retry same batch
                log.warning("db error (%s); reconnecting", e)
                try:
                    db.close()  # do not leak the broken connection
                except Exception:
                    pass
                time.sleep(1)  # an error that survives a reconnect (e.g. disk full) must not spin
                db = retry("postgres", db_connect)
        try:
            consumer.commit(asynchronous=False)  # only after the DB commit: a crash in between = replay, not loss
        except KafkaException as e:  # e.g. rebalance in progress; safe, a replay is dropped by the PK
            log.warning("commit skipped: %s", e)
        log.info("batch %d, inserted %d, duplicates_skipped %d", len(rows), inserted, len(rows) - inserted)
        freshness.report(rows)

    log.info("SIGTERM: last batch committed, closing")
    consumer.close()
    db.close()
    log.info("clean exit")


if __name__ == "__main__":
    main()
