"""One-shot schema and least-privilege setup. Runs as a Helm pre-install/pre-upgrade hook Job.

This is the only code that uses the RDS master user. It creates the table and its indexes, and
the app role trades_app, which may only SELECT and INSERT on trades. The consumer then connects
as trades_app, so a compromised consumer cannot delete data, create roles or touch other tables.
Safe to run again: every statement is idempotent.
"""
import json
import os

import psycopg
from psycopg import sql

# Run in one transaction behind an advisory lock: two runs started together would race on CREATE TABLE.
DDL = [
    "SELECT pg_advisory_xact_lock(7001)",
    """CREATE TABLE IF NOT EXISTS trades (
    symbol TEXT, trade_id BIGINT, price NUMERIC, quantity NUMERIC, notional NUMERIC,
    trade_time TIMESTAMPTZ, ingested_at TIMESTAMPTZ DEFAULT now(), PRIMARY KEY (symbol, trade_id))""",
    # BRIN: tiny time-ordered indexes, so "last 60 s" proof/health queries don't scan millions of rows
    "CREATE INDEX IF NOT EXISTS trades_ingested_at_brin ON trades USING brin (ingested_at)",
    "CREATE INDEX IF NOT EXISTS trades_trade_time_brin ON trades USING brin (trade_time)",
]


def credentials(arn_var, user_var, password_var):
    """From Secrets Manager on AWS; from plain env vars in the local docker compose harness."""
    if os.environ.get(arn_var):
        import boto3
        secret = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"]).get_secret_value(
            SecretId=os.environ[arn_var])
        creds = json.loads(secret["SecretString"])
        return creds["username"], creds["password"]
    return os.environ[user_var], os.environ.get(password_var, "")


def main():
    admin_user, admin_password = credentials("DB_ADMIN_SECRET_ARN", "DB_ADMIN_USER", "DB_ADMIN_PASSWORD")
    app_user, app_password = credentials("DB_APP_SECRET_ARN", "APP_DB_USER", "APP_DB_PASSWORD")
    role = sql.Identifier(app_user)

    with psycopg.connect(host=os.environ["DB_HOST"], dbname=os.environ.get("DB_NAME", "trades"),
                         user=admin_user, password=admin_password,
                         sslmode=os.environ.get("DB_SSLMODE", "prefer"), connect_timeout=10) as conn:
        with conn.transaction():
            for stmt in DDL:
                conn.execute(stmt)
            exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,)).fetchone()
            verb = sql.SQL("ALTER" if exists else "CREATE")
            # ROLE statements take no bind parameters: Literal quotes the password safely. Never logged.
            conn.execute(sql.SQL("{} ROLE {} LOGIN PASSWORD {}").format(verb, role, sql.Literal(app_password)))
            conn.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(role))
            conn.execute(sql.SQL("GRANT SELECT, INSERT ON trades TO {}").format(role))
    print(f"db-init: schema ready, role {app_user} has SELECT, INSERT on trades")


if __name__ == "__main__":
    main()
