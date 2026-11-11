"""
Chạy một file SQL trên kho DuckDB và in kết quả từng câu lệnh (chỉ đọc, không sửa dữ liệu).

Cách dùng (trong thư mục bi-genai):
    docker compose exec mage python scripts/query.py sql/check_ingest.sql
"""
import os
import sys

import duckdb

DUCKDB_PATH = os.environ.get('DUCKDB_PATH', '/home/src/warehouse/olist.duckdb')


def main():
    if len(sys.argv) != 2:
        sys.exit('Cách dùng: python scripts/query.py <file.sql>')
    sql_path = sys.argv[1]
    if not os.path.isabs(sql_path):
        sql_path = os.path.join('/home/src', sql_path)
    with open(sql_path, encoding='utf-8') as f:
        text = f.read()
    # Tách câu lệnh theo dấu ';' (bỏ dòng chú thích bắt đầu bằng --)
    lines = [l for l in text.splitlines() if not l.strip().startswith('--')]
    statements = [s.strip() for s in '\n'.join(lines).split(';') if s.strip()]
    con = duckdb.connect(DUCKDB_PATH, read_only=True)
    try:
        for stmt in statements:
            print(con.sql(stmt))
    finally:
        con.close()


if __name__ == '__main__':
    main()
