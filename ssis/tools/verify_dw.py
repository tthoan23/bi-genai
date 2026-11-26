"""Đối chiếu từng dòng kết quả SSIS trên SQL Server với bản tham chiếu DuckDB (warehouse/olist.duckdb).
Chỉ là công cụ kiểm chứng, không thuộc luồng ETL. Chạy từ thư mục gốc repo sau khi chạy package:
    .venv\\Scripts\\python.exe ssis\\tools\\verify_dw.py              (mọi tầng)
    .venv\\Scripts\\python.exe ssis\\tools\\verify_dw.py staging      (staging | cln | int | dim | fact)
So theo khoá nghiệp vụ và measure, KHÔNG so khoá thay thế. Toạ độ so với trung vị tính lại (bảng DuckDB lưu sẵn bị sai)."""
import decimal
import pathlib
import re
import subprocess
import sys
from collections import Counter

import duckdb
import pyodbc

repo = pathlib.Path(__file__).resolve().parents[2]
ms = pyodbc.connect(r"DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost\SQLEXPRESS;DATABASE=OlistDW;"
                    "Trusted_Connection=yes;TrustServerCertificate=yes", autocommit=True).cursor()
dk = duckdb.connect(str(repo / "warehouse" / "olist.duckdb"), read_only=True)
problems = 0


def norm(row):
    return tuple(int(v) if isinstance(v, bool) else v for v in row)


def compare(label, duck_sql, ms_sql):
    global problems
    a = Counter(norm(r) for r in dk.execute(duck_sql).fetchall())
    rows = ms.execute(ms_sql)
    names = [d[0] for d in rows.description]
    b = Counter(norm(r) for r in rows.fetchall())
    only_a, only_b = a - b, b - a
    ok = not only_a and not only_b
    problems += not ok
    print(f"{'OK  ' if ok else 'LỆCH'} {label:38} tham chiếu {sum(a.values()):>10,}  SSIS {sum(b.values()):>10,}"
          + ("" if ok else f"  khác {sum(only_a.values()):,}/{sum(only_b.values()):,}"))
    if ok or not only_a or not only_b:
        return
    for i, col in enumerate(names):   # chỉ ra cột gây lệch và vài ví dụ
        x, y = Counter(), Counter()
        for r, k in only_a.items():
            x[(r[0], r[i])] += k
        for r, k in only_b.items():
            y[(r[0], r[i])] += k
        if x != y:
            print(f"       cột {col}: tham chiếu {ascii(sorted(x - y, key=str)[:3])}")
            print(f"       {'':{len(col) + 5}}SSIS       {ascii(sorted(y - x, key=str)[:3])}")


def columns(schema, table, exclude=()):
    return [r[0] for r in ms.execute(
        "select column_name from information_schema.columns where table_schema=? and table_name=? order by ordinal_position",
        schema, table).fetchall() if r[0] not in exclude]


def same(label, duck_table, schema, table, exclude=(), where_ms=""):
    cols = ", ".join(columns(schema, table, exclude))
    compare(label, f"select {cols} from {duck_table}", f"select {cols} from {schema}.{table} {where_ms}")


TABLES = ["orders", "customers", "order_items", "order_reviews", "order_payments", "products", "sellers",
          "geolocation", "category_translation"]


def staging():
    for t in TABLES:
        same(f"staging.{t}", f"staging.{t}", "staging", t, ("ingested_at",), "where source_batch_id = 'FULL_001'")


def cln():
    for t in TABLES:
        same(f"cln_{t}", f"staging.stg_{t}", "intermediate", f"cln_{t}")


def fresh_geography():
    """Chạy lại câu SQL trung vị của bản DuckDB để có toạ độ tham chiếu đúng."""
    sql = subprocess.check_output(["git", "show", "main:olist_dbt/models/intermediate/int_geography_canonical.sql"],
                                  cwd=repo).decode("utf-8")
    sql = re.sub(r"\{\{ ref\('(\w+)'\) \}\}", r"staging.\1", sql)
    return {r[0]: (r[5], r[6]) for r in dk.execute(sql).fetchall()}


def coordinates(label, table, where=""):
    global problems
    truth = fresh_geography()
    got = {r[0]: (r[1], r[2]) for r in ms.execute(f"select zip_prefix, latitude, longitude from {table} {where}").fetchall()}
    tol = decimal.Decimal("0.0000001")
    bad = [z for z, t in truth.items() if z not in got or any(
        (t[i] is None) != (got[z][i] is None) or (t[i] is not None and abs(t[i] - got[z][i]) > tol) for i in (0, 1))]
    ok = not bad and len(got) == len(truth)
    problems += not ok
    print(f"{'OK  ' if ok else 'LỆCH'} {label:38} {len(got):,} mã, sai quá 1e-7 độ: {len(bad):,}")


def intermediate():
    for t in ["int_order_timeline", "int_order_customer_map", "int_order_item_summary",
              "int_order_review_representative", "int_order_payment_reconciliation"]:
        same(t, f"intermediate.{t}", "intermediate", t)
    same("int_geography_canonical (trừ toạ độ)", "intermediate.int_geography_canonical", "intermediate",
         "int_geography_canonical", ("latitude", "longitude"))
    coordinates("int_geography_canonical (toạ độ)", "intermediate.int_geography_canonical")


def dim():
    audit = ("dw_created_at", "dw_updated_at")
    same("dim_date", "dwh.dim_date", "dwh", "dim_date")
    same("dim_order_status", "dwh.dim_order_status", "dwh", "dim_order_status")
    same("dim_delivery_outcome", "dwh.dim_delivery_outcome", "dwh", "dim_delivery_outcome")
    same("dim_customer", "dwh.dim_customer", "dwh", "dim_customer", audit + ("customer_key",))
    same("dim_seller", "dwh.dim_seller", "dwh", "dim_seller", audit + ("seller_key",))
    same("dim_product", "dwh.dim_product", "dwh", "dim_product", audit + ("product_key",))
    same("dim_geography (trừ toạ độ)", "dwh.dim_geography", "dwh", "dim_geography",
         audit + ("geography_key", "latitude", "longitude"))
    coordinates("dim_geography (toạ độ)", "dwh.dim_geography", "where geography_key <> 0")


def fact():
    skip = ("dw_created_at", "dw_updated_at", "source_batch_id")
    keys = {"customer_key": ("dc.customer_unique_id", "dwh.dim_customer dc on dc.customer_key = f.customer_key"),
            "customer_geography_key": ("cg.zip_prefix", "dwh.dim_geography cg on cg.geography_key = f.customer_geography_key"),
            "seller_geography_key": ("sg.zip_prefix", "dwh.dim_geography sg on sg.geography_key = f.seller_geography_key"),
            "product_key": ("dp.product_id", "dwh.dim_product dp on dp.product_key = f.product_key"),
            "seller_key": ("ds.seller_id", "dwh.dim_seller ds on ds.seller_key = f.seller_key")}
    for t in ["fact_order_experience", "fact_order_item"]:
        select, joins = [], []
        for c in columns("dwh", t, skip):
            if c in keys:
                select.append(keys[c][0])
                joins.append("left join " + keys[c][1])
            else:
                select.append("f." + c)
        sql = f"select {', '.join(select)} from dwh.{t} f {' '.join(joins)}"
        compare(t, sql, sql)
    r = ms.execute("select count(*), sum(late_count), sum(delivery_eligible_count), "
                   "avg(cast(representative_review_score as decimal(10,4))) from dwh.fact_order_experience").fetchone()
    v = ms.execute("select sum(price_amount) from dwh.fact_order_item").fetchone()[0]
    if r[0]:
        print(f"     KPI: {r[0]:,} đơn (99,441); trễ {100 * r[1] / r[2]:.2f}% (6.77); điểm TB {r[3]:.2f} (4.09); "
              f"tiền hàng {v:,.2f} (13,591,643.70)")


layers = {"staging": staging, "cln": cln, "int": intermediate, "dim": dim, "fact": fact}
for name in (sys.argv[1:] or layers):
    print(f"== {name}")
    layers[name]()
print("TẤT CẢ KHỚP" if not problems else f"CÓ {problems} MỤC LỆCH")
sys.exit(1 if problems else 0)
