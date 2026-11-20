-- Holes in trade_id per symbol over the last 10 minutes. Expect missing = 0.
-- Binance trade_id is sequential per symbol, so max - min + 1 is how many rows there should be.
SELECT symbol, count(*) AS rows, max(trade_id) - min(trade_id) + 1 - count(*) AS missing
FROM trades WHERE trade_time > now() - interval '10 minutes'
GROUP BY symbol ORDER BY missing DESC, symbol;
