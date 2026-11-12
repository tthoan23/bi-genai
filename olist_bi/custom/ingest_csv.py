"""
Block Mage (Custom, Python): nạp 9 file CSV Olist vào DuckDB.

- Mỗi file thành một bảng trong schema `staging`, mọi cột giữ nguyên dạng text.
- Mỗi dòng có thêm 5 cột truy vết: source_file, source_checksum, source_row_number,
  source_batch_id, ingested_at.
- Ghi nhật ký vào các bảng audit (xem sql/00_schemas_audit.sql).
- Chạy lại cùng một batch không sinh dòng trùng.
- Nạp tăng dần theo LSET/CET (bảng audit.etl_metadata, mỗi file CSV là một nguồn):
    LSET = mốc thời gian dữ liệu đã nạp tới ở lần thành công trước.
    CET  = thời điểm bắt đầu trích xuất của lần chạy hiện tại.
  Batch FULL: nạp toàn bộ file, rồi đặt lại LSET.
  Batch INCREMENTAL (use_lset = true): chỉ nạp dòng có thời điểm muộn hơn LSET, rồi đẩy LSET lên.
  Bảng không có cột thời gian (customers, products, ...) luôn nạp lại toàn bộ file của batch.

Biến của pipeline:
  batch_id      mã đợt nạp, mặc định FULL_001
  batch_type    FULL hoặc INCREMENTAL
  raw_dir       thư mục chứa file CSV, mặc định /home/src/data/raw
  is_simulated  true nếu là batch mô phỏng
  use_lset      true (mặc định): batch INCREMENTAL lọc theo LSET. false: nạp toàn bộ file
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

# Cột thời gian làm mốc nạp tăng dần (LSET). Mỗi dòng lấy thời điểm muộn nhất trong các cột này,
# nên đơn cũ có thêm sự kiện mới (duyệt, giao hàng) ở batch sau vẫn được nạp lại.
# Bảng không có trong danh sách này không có cột thời gian: luôn nạp toàn bộ file của batch.
WATERMARK_COLS = {
    'orders': ['order_purchase_timestamp', 'order_approved_at',
               'order_delivered_carrier_date', 'order_delivered_customer_date'],
    'order_items': ['shipping_limit_date'],
    'order_reviews': ['review_creation_date', 'review_answer_timestamp'],
}


def row_watermark(df, cols):
    """Thời điểm muộn nhất của mỗi dòng trong các cột `cols` (NaT nếu không đọc được cột nào)."""
    parts = [pd.to_datetime(df[c], errors='coerce') for c in cols]
    return pd.concat(parts, axis=1).max(axis=1)


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
    # Chỉ batch INCREMENTAL mới lọc theo LSET. Batch FULL luôn nạp toàn bộ file.
    use_lset = batch_type == 'INCREMENTAL' and str(kwargs.get('use_lset', 'true')).lower() == 'true'
    cet = datetime.now()   # CET: thời điểm bắt đầu trích xuất của lần chạy này

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

        # Mỗi nguồn có một dòng trong audit.etl_metadata (đã tạo sẵn bởi file SQL). Đồng bộ cột mốc.
        for t in FILES:
            con.execute("""
                insert into audit.etl_metadata (source_name, watermark_column, lset, cet)
                values (?, ?, timestamp '1990-01-01', timestamp '1990-01-01')
                on conflict (source_name) do update set watermark_column = excluded.watermark_column
            """, [t, ','.join(WATERMARK_COLS.get(t, [])) or None])

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

                checksum = sha256(path)
                source_cols = list(df.columns)
                file_rows = len(df)
                df['source_file'] = fname
                df['source_checksum'] = checksum
                df['source_row_number'] = range(1, file_rows + 1)
                df['source_batch_id'] = batch_id
                df['ingested_at'] = datetime.now()

                # 4) Trích xuất theo LSET: lấy LSET của nguồn này rồi lọc các dòng mới hơn LSET.
                #    Dòng không đọc được thời gian vẫn giữ lại để không mất dữ liệu.
                wm_cols = WATERMARK_COLS.get(table)
                lset = con.execute('select lset from audit.etl_metadata where source_name = ?',
                                   [table]).fetchone()[0]
                wm = row_watermark(df, wm_cols) if wm_cols else None
                extracted = df[wm.isna() | (wm > lset)] if (wm_cols and use_lset) else df
                rows_read = len(extracted)      # số dòng được trích xuất. Số dòng cả file nằm trong source_manifest

                # LSET mới: thời điểm muộn nhất đã nạp. Bảng không có cột thời gian thì LSET = CET.
                if wm_cols:
                    newest = wm[extracted.index].max() if rows_read else pd.NaT
                    if pd.isna(newest):
                        new_lset = lset
                    else:
                        newest = newest.to_pydatetime()
                        new_lset = newest if batch_type == 'FULL' else max(lset, newest)
                else:
                    new_lset = cet

                # 5) Nạp trong một transaction (kèm cập nhật LSET/CET, nên nạp và mốc luôn khớp nhau).
                #    Nạp tăng dần chỉ chèn thêm. Các trường hợp còn lại xóa phần cũ của batch rồi chèn lại.
                con.begin()
                con.register('df_full', df)
                con.execute(f'create table if not exists staging."{table}" as select * from df_full limit 0')
                con.unregister('df_full')
                if not (wm_cols and use_lset):
                    con.execute(f'delete from staging."{table}" where source_batch_id = ?', [batch_id])
                rows_loaded = 0
                if rows_read:
                    con.register('df_batch', extracted)
                    rows_loaded = con.execute(
                        f'insert into staging."{table}" by name select * from df_batch').fetchone()[0]
                    con.unregister('df_batch')
                con.execute("""
                    insert into audit.source_manifest values (?, ?, ?, ?, ?)
                    on conflict (batch_id, source_file) do update
                    set source_checksum = excluded.source_checksum,
                        row_count = excluded.row_count, column_list = excluded.column_list
                """, [batch_id, fname, checksum, file_rows, ','.join(source_cols)])
                status = 'SUCCESS' if rows_loaded == rows_read else 'MISMATCH'
                con.execute("""
                    insert into audit.etl_step_log
                        (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status)
                    values (?, 'ingest', ?, ?, ?, ?, ?)
                """, [run_id, table, rows_read, rows_loaded, rows_read - rows_loaded, status])
                if status == 'SUCCESS':
                    con.execute("""
                        update audit.etl_metadata set lset = ?, cet = ?, last_batch_id = ?
                        where source_name = ?
                    """, [new_lset, cet, batch_id, table])
                con.commit()
                if status != 'SUCCESS':
                    raise RuntimeError(f'{table}: đọc {rows_read} dòng nhưng nạp {rows_loaded}')
                results.append({'table': table, 'rows_read': rows_read,
                                'rows_loaded': rows_loaded, 'lset': new_lset, 'status': status})

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
