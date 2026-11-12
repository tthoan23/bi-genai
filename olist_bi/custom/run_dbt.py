"""
Block Mage (Custom, Python), chạy SAU block ingest_csv.

1. Gọi `dbt build`: tạo seed, view staging, bảng intermediate, bảng khoá, dimension, fact và chạy kiểm thử.
   Batch INCREMENTAL thì truyền batch_id để fact chỉ tính lại các đơn bị ảnh hưởng.
2. Đọc target/run_results.json, ghi từng model và kiểm thử vào audit.etl_step_log (step = 'dbt').
3. Chốt trạng thái: mọi bước thành công (kiểm thử mức cảnh báo vẫn được) thì batch SUCCESS, ngược lại FAILED.

Lưu ý: khi dbt đang chạy, block này KHÔNG giữ kết nối DuckDB (DuckDB chỉ cho một chương trình ghi cùng lúc).
"""
import json
import os
import subprocess

import duckdb
import pandas as pd

if 'custom' not in globals():
    from mage_ai.data_preparation.decorators import custom

DUCKDB_PATH = os.environ.get('DUCKDB_PATH', '/home/src/warehouse/olist.duckdb')
DBT_DIR = os.environ.get('DBT_PROJECT_DIR', '/home/src/olist_dbt')


@custom
def run_dbt(*args, **kwargs):
    batch_id = kwargs.get('batch_id', 'FULL_001')
    batch_type = kwargs.get('batch_type', 'FULL')

    # 1) Lấy lần chạy hiện tại của batch (do block ingest_csv vừa tạo), rồi đóng kết nối ngay
    con = duckdb.connect(DUCKDB_PATH)
    try:
        run_id = con.execute('select max(run_id) from audit.etl_run where batch_id = ?', [batch_id]).fetchone()[0]
    finally:
        con.close()

    # 2) Chạy dbt
    cmd = ['dbt', 'build', '--project-dir', DBT_DIR, '--profiles-dir', DBT_DIR]
    if batch_type == 'INCREMENTAL':
        cmd += ['--vars', json.dumps({'batch_id': batch_id})]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    print(proc.stdout[-3000:])

    results_path = os.path.join(DBT_DIR, 'target', 'run_results.json')
    rows, failed = [], []
    if os.path.exists(results_path):
        with open(results_path, encoding='utf-8') as f:
            for r in json.load(f)['results']:
                status = r['status']                       # success, pass, warn, error, fail, skipped
                rows.append({
                    'node': r['unique_id'],
                    'status': status.upper(),
                    'rows_affected': (r.get('adapter_response') or {}).get('rows_affected'),
                    'failures': r.get('failures'),
                    'message': (r.get('message') or '')[:2000] or None,
                })
                if status in ('error', 'fail', 'skipped'):
                    failed.append(r['unique_id'])
    if proc.returncode != 0 and not failed:
        failed.append(f'dbt build thoát với mã {proc.returncode}: {proc.stderr[-500:]}')

    # 3) Ghi kết quả vào audit và chốt trạng thái
    final = 'FAILED' if failed else 'SUCCESS'
    con = duckdb.connect(DUCKDB_PATH)
    try:
        for r in rows:
            con.execute("""
                insert into audit.etl_step_log
                    (run_id, step, table_name, rows_loaded, rows_rejected, status, error_message)
                values (?, 'dbt', ?, ?, ?, ?, ?)
            """, [run_id, r['node'], r['rows_affected'], r['failures'], r['status'], r['message']])
        con.execute("""update audit.etl_run set status = ?, ended_at = now(), error_message = ?
                       where run_id = ?""", [final, '; '.join(failed)[:2000] or None, run_id])
        con.execute('update audit.etl_batch set status = ?, ended_at = now() where batch_id = ?',
                    [final, batch_id])
    finally:
        con.close()

    if failed:
        raise RuntimeError(f'dbt có bước lỗi: {failed[:5]}')
    return pd.DataFrame(rows)
