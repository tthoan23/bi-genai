-- Load_Facts, nguồn fact_order_experience: grain một dòng cho mỗi đơn.
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
