"""
Block Mage (Custom, Python): nạp 9 file CSV Olist vào DuckDB.

- Mỗi file thành một bảng trong schema `staging`, mọi cột giữ nguyên dạng text.
- Mỗi dòng có thêm 5 cột truy vết: source_file, source_checksum, source_row_number,
  source_batch_id, ingested_at.
- Ghi nhật ký vào 4 bảng audit (xem sql/00_schemas_audit.sql).
- Chạy lại cùng một batch không sinh dòng trùng: dữ liệu cũ của batch đó bị xóa trước khi nạp.

Biến của pipeline:
  batch_id      mã đợt nạp, mặc định FULL_001
  batch_type    FULL hoặc INCREMENTAL
  raw_dir       thư mục chứa file CSV, mặc định /home/src/data/raw
  is_simulated  true nếu là batch mô phỏng
"""
import hashlib
import os
from datetime import datetime

import duckdb
import pandas as pd

if 'custom' not in globals():
    from mage_ai.data_preparation.decorators import custom

DUCKDB_PATH = os.environ.get('DUCKDB_PATH', '/home/src/warehouse/olist.duckdb')
SCHEMA_SQL = '/home/src/sql/00_schemas_audit.sql'

# Tên bảng trong DuckDB -> tên file CSV
FILES = {
    'orders': 'olist_orders_dataset.csv',
    'customers': 'olist_customers_dataset.csv',
    'order_items': 'olist_order_items_dataset.csv',
    'order_reviews': 'olist_order_reviews_dataset.csv',
    'order_payments': 'olist_order_payments_dataset.csv',
    'products': 'olist_products_dataset.csv',
    'sellers': 'olist_sellers_dataset.csv',
    'geolocation': 'olist_geolocation_dataset.csv',
    'category_translation': 'product_category_name_translation.csv',
}

# Kiểm tra cấu trúc: các cột bắt buộc phải có, thiếu là dừng ngay
REQUIRED = {
    'orders': ['order_id', 'customer_id', 'order_status', 'order_purchase_timestamp',
               'order_approved_at', 'order_delivered_carrier_date',
               'order_delivered_customer_date', 'order_estimated_delivery_date'],
    'order_items': ['order_id', 'order_item_id', 'product_id', 'seller_id', 'price', 'freight_value'],
    'order_reviews': ['review_id', 'order_id', 'review_score',
                      'review_creation_date', 'review_answer_timestamp'],
    'customers': ['customer_id', 'customer_unique_id', 'customer_zip_code_prefix'],
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


@custom
def ingest_csv(*args, **kwargs):
    batch_id = kwargs.get('batch_id', 'FULL_001')
    batch_type = kwargs.get('batch_type', 'FULL')
    raw_dir = kwargs.get('raw_dir', '/home/src/data/raw')
    is_simulated = str(kwargs.get('is_simulated', 'false')).lower() == 'true'

    con = duckdb.connect(DUCKDB_PATH)
    try:
        # 1) Tạo schema và bảng audit nếu chưa có
        with open(SCHEMA_SQL, encoding='utf-8') as f:
            con.execute(f.read())

        # 2) Mở batch và tạo một lần chạy mới
        con.execute("""
            insert into audit.etl_batch (batch_id, batch_type, is_simulated, status, started_at)
            values (?, ?, ?, 'RUNNING', now())
            on conflict (batch_id) do update
            set status = 'RUNNING', started_at = now(), ended_at = null
        """, [batch_id, batch_type, is_simulated])
        attempt = con.execute(
            'select coalesce(max(attempt), 0) + 1 from audit.etl_run where batch_id = ?',
            [batch_id]).fetchone()[0]
        run_id = con.execute("""
            insert into audit.etl_run (batch_id, attempt, status, started_at)
            values (?, ?, 'RUNNING', now()) returning run_id
        """, [batch_id, attempt]).fetchone()[0]

        results, current = [], None
        try:
            for table, fname in FILES.items():
                current = table
                path = os.path.join(raw_dir, fname)
                if not os.path.exists(path):
                    if batch_type == 'INCREMENTAL':   # batch tăng thêm có thể không đủ 9 file
                        continue
                    raise FileNotFoundError(
                        f'Không tìm thấy {path}. Đã giải nén data/olist-brazilian-ecommerce.zip '
                        f'vào data/raw chưa?')

                # 3) Đọc CSV, giữ mọi cột dạng text. utf-8-sig bỏ ký tự BOM ở đầu file nếu có.
                df = pd.read_csv(path, dtype=str, keep_default_na=False, encoding='utf-8-sig')
                missing = set(REQUIRED.get(table, [])) - set(df.columns)
                if missing:
                    raise ValueError(f'{fname} thiếu cột {sorted(missing)}')

                rows_read = len(df)
                checksum = sha256(path)
                source_cols = list(df.columns)
                df['source_file'] = fname
                df['source_checksum'] = checksum
                df['source_row_number'] = range(1, rows_read + 1)
                df['source_batch_id'] = batch_id
                df['ingested_at'] = datetime.now()

                # 4) Nạp trong một transaction: xóa phần cũ của batch rồi chèn lại
                con.begin()
                con.register('df_batch', df)
                con.execute(f'create table if not exists staging."{table}" as select * from df_batch limit 0')
                con.execute(f'delete from staging."{table}" where source_batch_id = ?', [batch_id])
                con.execute(f'insert into staging."{table}" by name select * from df_batch')
                con.unregister('df_batch')
                rows_loaded = con.execute(
                    f'select count(*) from staging."{table}" where source_batch_id = ?',
                    [batch_id]).fetchone()[0]
                con.execute("""
                    insert into audit.source_manifest values (?, ?, ?, ?, ?)
                    on conflict (batch_id, source_file) do update
                    set source_checksum = excluded.source_checksum,
                        row_count = excluded.row_count, column_list = excluded.column_list
                """, [batch_id, fname, checksum, rows_read, ','.join(source_cols)])
                status = 'SUCCESS' if rows_loaded == rows_read else 'MISMATCH'
                con.execute("""
                    insert into audit.etl_step_log
                        (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status)
                    values (?, 'ingest', ?, ?, ?, ?, ?)
                """, [run_id, table, rows_read, rows_loaded, rows_read - rows_loaded, status])
                con.commit()
                if status != 'SUCCESS':
                    raise RuntimeError(f'{table}: đọc {rows_read} dòng nhưng nạp {rows_loaded}')
                results.append({'table': table, 'rows_read': rows_read,
                                'rows_loaded': rows_loaded, 'status': status})

            # 5) Nạp xong: INGESTED. SUCCESS chỉ ghi sau khi dbt build và test xong (bước sau).
            con.execute("update audit.etl_run set status = 'INGESTED' where run_id = ?", [run_id])
            con.execute("update audit.etl_batch set status = 'INGESTED' where batch_id = ?", [batch_id])
        except Exception as ex:
            try:
                con.rollback()
            except Exception:
                pass
            msg = str(ex)[:2000]
            con.execute("""
                insert into audit.etl_step_log (run_id, step, table_name, status, error_message)
                values (?, 'ingest', ?, 'FAILED', ?)
            """, [run_id, current, msg])
            con.execute("""update audit.etl_run set status = 'FAILED', ended_at = now(), error_message = ?
                           where run_id = ?""", [msg, run_id])
            con.execute("update audit.etl_batch set status = 'FAILED', ended_at = now() where batch_id = ?",
                        [batch_id])
            raise
    finally:
        con.close()   # đóng kết nối để chương trình khác (dbt, DBeaver) mở được file

    return pd.DataFrame(results).assign(run_id=run_id, batch_id=batch_id)
