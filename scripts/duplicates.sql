-- Expect 0 rows: any (symbol, trade_id) stored more than once.
SELECT symbol, trade_id, count(*) FROM trades GROUP BY 1, 2 HAVING count(*) > 1;
