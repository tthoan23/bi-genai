"""CHỈ DÙNG KHI PHÁT TRIỂN (Task 3): chép 9 bảng staging từ warehouse/olist.duckdb sang SQL Server
để làm dbt trong lúc chờ package SSIS Ingest_Staging.dtsx (Task 2). Không thuộc luồng chính.

Chạy từ thư mục gốc repo, sau khi đã chạy sql_server/00, 01, 02:
    python scripts/dev_load_staging_sqlserver.py
Biến môi trường: MSSQL_HOST (mặc định localhost). Có MSSQL_USER thì đăng nhập SQL, không thì Windows.
Script XOÁ nội dung 9 bảng staging trước khi nạp.
"""
import os

import duckdb
import pyodbc

TABLES = ["orders", "customers", "order_items", "order_reviews", "order_payments",
          "products", "sellers", "geolocation", "category_translation"]
CHUNK = 50_000

host = os.environ.get("MSSQL_HOST", "localhost")
auth = (f"UID={os.environ['MSSQL_USER']};PWD={os.environ['MSSQL_PASSWORD']}"
        if os.environ.get("MSSQL_USER") else "Trusted_Connection=yes")
ms = pyodbc.connect(f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={host};DATABASE=OlistDW;"
                    f"{auth};TrustServerCertificate=yes")
cur = ms.cursor()
cur.fast_executemany = True
dk = duckdb.connect("warehouse/olist.duckdb", read_only=True)

total, ok = 0, True
for table in TABLES:
    # Lấy danh sách cột từ SQL Server: SQL Server là đích, quyết định cần cột nào
    cols = [r[0] for r in cur.execute(
        "select column_name from information_schema.columns "
        "where table_schema = 'staging' and table_name = ? order by ordinal_position", table).fetchall()]
    if not cols:
        raise SystemExit(f"Chưa có bảng staging.{table}: chạy sql_server/02_staging.sql trước.")
    src = dk.execute(f"select {', '.join(cols)} from staging.{table}")
    insert = f"insert into staging.{table} ({', '.join(cols)}) values ({', '.join('?' * len(cols))})"
    cur.execute(f"truncate table staging.{table}")
    read = 0
    while rows := src.fetchmany(CHUNK):
        cur.executemany(insert, rows)
        read += len(rows)
    loaded = cur.execute(f"select count_big(*) from staging.{table}").fetchone()[0]
    ms.commit()  # mỗi bảng một transaction: lỗi giữa chừng thì bảng đó giữ nguyên dữ liệu cũ
    ok &= read == loaded
    total += loaded
    print(f"{table:22} doc {read:>10,}  nap {loaded:>10,}  {'OK' if read == loaded else 'LECH'}")

# Các view stg_* join audit.etl_batch để lấy batch_seq: cần có dòng batch này
cur.execute("if not exists (select 1 from audit.etl_batch where batch_id = 'FULL_001') "
            "insert into audit.etl_batch (batch_id, batch_type, status, started_at) "
            "values ('FULL_001', 'FULL', 'INGESTED', sysdatetime())")
ms.commit()
print(f"Tong {total:,} (mong doi 1,550,922)")
raise SystemExit(0 if ok and total == 1_550_922 else 1)
