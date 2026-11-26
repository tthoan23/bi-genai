"""Sinh các file SQL nguồn (OLE DB Source) cho project SSIS OlistETL vào ssis/OlistETL/queries/.
Chạy một lần khi đổi logic: python ssis/tools/make_queries.py  (từ thư mục gốc repo).
BuildOlistEtl.cs đọc các file này và nhúng vào package."""
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[1] / "OlistETL" / "queries"
OUT.mkdir(parents=True, exist_ok=True)
Q = {}

LATEST = """-- Transform_Clean, nguồn {t}: lấy bản mới nhất của mỗi khoá theo batch_seq (đợt nạp sau thắng đợt trước),
-- hoà thì lấy dòng nằm sau trong file. Việc làm sạch (TRIM, đổi kiểu...) làm bằng Derived Column, Data Conversion.
SELECT {cols},
       source_file, source_row_number, source_batch_id
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY {pk}
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.{t} s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.{k}), '') IS NOT NULL
) x
WHERE rn = 1
"""
for t, cols, pk, k in [
    ("orders", "order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,\n"
               "       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date",
     "TRIM(s.order_id)", "order_id"),
    ("customers", "customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state",
     "TRIM(s.customer_id)", "customer_id"),
    ("order_items", "order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value",
     "TRIM(s.order_id), TRIM(s.order_item_id)", "order_id"),
    ("order_payments", "order_id, payment_sequential, payment_type, payment_installments, payment_value",
     "TRIM(s.order_id), TRIM(s.payment_sequential)", "order_id"),
    ("products", "product_id, product_category_name, product_weight_g, product_length_cm, product_height_cm, product_width_cm",
     "TRIM(s.product_id)", "product_id"),
    ("sellers", "seller_id, seller_zip_code_prefix, seller_city, seller_state", "TRIM(s.seller_id)", "seller_id"),
]:
    Q[f"src_{t}"] = LATEST.format(t=t, cols=cols, pk=pk, k=k)

Q["src_category_translation"] = """-- Transform_Clean, nguồn category_translation: một dòng cho mỗi danh mục (so không phân biệt hoa thường).
SELECT product_category_name, product_category_name_english
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY LOWER(TRIM(s.product_category_name))
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.category_translation s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.product_category_name), '') IS NOT NULL
) x
WHERE rn = 1
"""

Q["src_order_reviews"] = """-- Transform_Clean, nguồn order_reviews: giữ mọi đánh giá, chỉ bỏ dòng trùng hoàn toàn mọi cột nội dung.
-- BIN2: so từng ký tự, để hai bình luận chỉ khác hoa/thường không bị coi là trùng.
SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
       review_creation_date, review_answer_timestamp,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY review_id, order_id, review_score,
                            review_comment_title COLLATE Latin1_General_100_BIN2,
                            review_comment_message COLLATE Latin1_General_100_BIN2,
                            review_creation_date, review_answer_timestamp
               ORDER BY source_batch_id, source_row_number) AS dup_rn
    FROM staging.order_reviews
) x
WHERE dup_rn = 1
"""

Q["src_geolocation"] = """-- Transform_Clean, nguồn geolocation: đọc nguyên bảng thô. Bỏ dòng trùng làm bằng Sort (Remove duplicates)
-- SAU khi chuẩn hoá, vì hai dòng chỉ khác dấu hoặc hoa/thường sẽ trùng sau khi làm sạch.
SELECT geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state
FROM staging.geolocation
"""

Q["src_order_review_representative"] = """-- Transform_Business: mỗi đơn chọn một đánh giá đại diện: điểm hợp lệ (1-5), trả lời gần nhất;
-- hoà thì xét ngày tạo, mã đánh giá, rồi vị trí dòng để kết quả luôn cố định. SSIS không có thành phần
-- ROW_NUMBER nên bước xếp hạng viết bằng SQL; ghép mã nguồn làm bằng Derived Column.
SELECT order_id, review_id AS representative_review_id, review_score AS representative_review_score,
       review_creation_ts, review_answer_ts, review_record_count,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_ts DESC, review_creation_ts DESC,
                                       review_id, source_batch_id, source_row_number) AS rk,
           COUNT(*) OVER (PARTITION BY order_id) AS review_record_count
    FROM intermediate.cln_order_reviews r
    WHERE review_score IS NOT NULL AND NULLIF(order_id, '') IS NOT NULL
) x
WHERE rk = 1
"""

Q["src_geography_canonical"] = """-- Transform_Business: một dòng cho mỗi mã bưu chính.
-- Thành phố, bang: cặp xuất hiện nhiều nhất (gộp khách, người bán, bảng toạ độ); hoà thì ưu tiên khách, rồi người bán.
-- Toạ độ: trung vị các toạ độ nằm trong khung gần đúng của Brazil. SSIS không có hàm trung vị nên phần này viết bằng SQL;
-- nhãn, cờ xung đột và mã chất lượng toạ độ làm bằng Derived Column.
WITH decl AS (
    SELECT zip_prefix, state, city, 1 AS src_rank FROM intermediate.cln_customers
    UNION ALL SELECT zip_prefix, state, city, 2 FROM intermediate.cln_sellers
    UNION ALL SELECT zip_prefix, state, city, 3 FROM intermediate.cln_geolocation
), zips AS (
    SELECT DISTINCT zip_prefix FROM decl WHERE zip_prefix IS NOT NULL
), pairs AS (
    SELECT zip_prefix, state, city, COUNT(*) AS n, MIN(src_rank) AS best_src
    FROM decl
    WHERE zip_prefix IS NOT NULL AND state IS NOT NULL AND city IS NOT NULL
    GROUP BY zip_prefix, state, city
), ranked AS (
    SELECT p.*,
           ROW_NUMBER() OVER (PARTITION BY zip_prefix
                              ORDER BY n DESC, best_src, state, city COLLATE Latin1_General_100_BIN2) AS rk,
           COUNT(*) OVER (PARTITION BY zip_prefix) AS variant_count
    FROM pairs p
), state_variants AS (
    SELECT zip_prefix, COUNT(DISTINCT state) AS state_count FROM pairs GROUP BY zip_prefix
), coords AS (
    SELECT DISTINCT zip_prefix,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lat) OVER (PARTITION BY zip_prefix) AS lat,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lng) OVER (PARTITION BY zip_prefix) AS lng
    FROM intermediate.cln_geolocation
    WHERE zip_prefix IS NOT NULL AND lat BETWEEN -34 AND 6 AND lng BETWEEN -74 AND -34
)
SELECT z.zip_prefix,
       r.state AS state_code,
       r.city  AS city_normalized,
       CAST(ROUND(c.lat, 7) AS decimal(10, 7)) AS latitude,
       CAST(ROUND(c.lng, 7) AS decimal(10, 7)) AS longitude,
       ISNULL(r.variant_count, 0) AS variant_count,
       ISNULL(sv.state_count, 0)  AS state_count,
       CAST(CASE WHEN c.zip_prefix IS NULL THEN 0 ELSE 1 END AS smallint) AS has_valid_coord
FROM zips z
LEFT JOIN ranked r          ON r.zip_prefix = z.zip_prefix AND r.rk = 1
LEFT JOIN state_variants sv ON sv.zip_prefix = z.zip_prefix
LEFT JOIN coords c          ON c.zip_prefix = z.zip_prefix
"""

Q["src_payment_reconciliation"] = """-- Transform_Business: ghép tổng thanh toán với tổng tiền hàng + phí vận chuyển theo đơn (hai bảng do Aggregate tạo).
-- FULL OUTER JOIN: giữ cả đơn chỉ có thanh toán hoặc chỉ có dòng hàng. Chênh lệch và cờ tính bằng Derived Column.
SELECT COALESCE(p.order_id, i.order_id) AS order_id,
       p.payment_total, p.payment_complete,
       i.goods_value, i.freight_value, i.amounts_complete
FROM intermediate.int_order_payment_summary p
FULL OUTER JOIN intermediate.int_order_item_summary i ON i.order_id = p.order_id
"""

Q["src_fact_order_experience"] = """-- Load_Facts, nguồn fact_order_experience: grain một dòng cho mỗi đơn.
-- Chỉ các đơn bị ảnh hưởng trong batch (intermediate.affected_orders; FULL = mọi đơn), sau đó MERGE vào fact.
-- Ghép các bảng intermediate cùng grain (đơn). Khoá dimension lấy bằng Lookup, khoá ngày tính bằng Derived Column.
SELECT t.order_id, t.order_status, t.outcome_code,
       t.purchase_ts, t.approved_ts, t.carrier_ts, t.delivered_ts, t.estimated_ts,
       t.purchase_ts_parse_error, t.approved_ts_parse_error, t.carrier_ts_parse_error,
       t.delivered_ts_parse_error, t.estimated_ts_parse_error,
       t.delivered_count, t.delivery_eligible_count, t.late_count, t.on_time_count,
       t.approval_seconds, t.handling_seconds, t.transit_seconds, t.delivery_seconds, t.late_days,
       t.invalid_approval_sequence, t.invalid_handling_sequence, t.invalid_transit_sequence,
       t.invalid_delivery_sequence, t.invalid_estimated_date, t.quality_issue_count, t.source_batch_id,
       cm.customer_unique_id, cm.customer_zip_prefix,
       rv.representative_review_score, rv.review_record_count, rv.representative_review_id,
       rv.representative_review_source_id, rv.review_creation_ts, rv.review_answer_ts,
       it.item_line_count, it.seller_count
FROM intermediate.int_order_timeline t
LEFT JOIN intermediate.int_order_customer_map cm          ON cm.order_id = t.order_id
LEFT JOIN intermediate.int_order_review_representative rv ON rv.order_id = t.order_id
LEFT JOIN intermediate.int_order_item_summary it          ON it.order_id = t.order_id
WHERE t.order_id IN (SELECT order_id FROM intermediate.affected_orders)
"""

Q["src_fact_order_item"] = """-- Load_Facts, nguồn fact_order_item: grain một dòng cho mỗi dòng hàng (order_id, order_item_id).
-- Chỉ dòng hàng của các đơn bị ảnh hưởng trong batch. Lấy thêm ngày mua, khách thật và mã bưu chính của đơn,
-- mã bưu chính người bán.
SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id,
       i.shipping_limit_ts, i.shipping_limit_parse_error, i.price_amount, i.freight_amount, i.source_batch_id,
       o.purchase_ts, o.purchase_ts_parse_error,
       cm.customer_unique_id, cm.customer_zip_prefix,
       s.zip_prefix AS seller_zip_prefix
FROM intermediate.cln_order_items i
LEFT JOIN intermediate.cln_orders o              ON o.order_id = i.order_id
LEFT JOIN intermediate.int_order_customer_map cm ON cm.order_id = i.order_id
LEFT JOIN intermediate.cln_sellers s             ON s.seller_id = i.seller_id
WHERE i.order_id IN (SELECT order_id FROM intermediate.affected_orders)
"""

for name, sql in Q.items():
    (OUT / f"{name}.sql").write_text(sql, encoding="utf-8", newline="\r\n")
print(f"{len(Q)} file -> {OUT}")
