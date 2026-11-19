-- Holes in trade_id per symbol over the last N minutes (default 10). Expect missing = 0.
-- Binance trade_id is sequential per symbol, so max - min + 1 is how many rows there should be.
\set minutes 10
SELECT symbol, count(*) AS rows, max(trade_id) - min(trade_id) + 1 - count(*) AS missing
FROM trades WHERE trade_time > now() - make_interval(mins => :minutes)
GROUP BY symbol ORDER BY missing DESC, symbol;
