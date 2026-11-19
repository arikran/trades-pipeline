-- How far behind the newest stored trade is, and ingest delay over the last minute.
SELECT now() - max(trade_time) AS newest_trade_age,
       (SELECT avg(ingested_at - trade_time) FROM trades WHERE ingested_at > now() - interval '1 minute') AS avg_ingest_delay
FROM trades;
