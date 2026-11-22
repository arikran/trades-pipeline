"""Run one SQL query from stdin with the consumer's own DB access, in a read-only transaction.

Used by `make query SQL=scripts/<file>.sql`: nobody handles the DB password, the pod already
has it through IRSA and Secrets Manager, and a read-only session cannot change any data.
"""
import sys

from consumer import db_connect


def main():
    sql = sys.stdin.read()
    with db_connect() as conn:
        conn.read_only = True
        with conn.cursor() as cur:
            cur.execute(sql, prepare=True)  # prepared = one statement only, so no 'COMMIT; ...' escape
            if cur.description is None:
                print(cur.statusmessage)
                return
            cols = [d.name for d in cur.description]
            rows = [[str(v) for v in r] for r in cur.fetchall()]
            widths = [max([len(c)] + [len(r[i]) for r in rows]) for i, c in enumerate(cols)]
            print(" | ".join(c.ljust(w) for c, w in zip(cols, widths)))
            print("-+-".join("-" * w for w in widths))
            for r in rows:
                print(" | ".join(v.ljust(w) for v, w in zip(r, widths)))
            print(f"({len(rows)} rows)")


if __name__ == "__main__":
    main()
