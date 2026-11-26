-- Task 3 (SSIS): bảng đích của tầng Transform, schema intermediate.
-- Chạy sau 00, 01, 02. Bảng ở đây là dữ liệu dẫn xuất, nạp lại toàn bộ mỗi lần chạy,
-- nên file này XOÁ và TẠO LẠI mọi bảng trong schema intermediate (an toàn khi chạy lại).
--   cln_*  : kết quả Transform_Clean.dtsx (làm sạch từng bảng nguồn, giữ bản mới nhất theo batch)
--   int_*  : kết quả Transform_Business.dtsx (tính toán theo nghiệp vụ)
USE OlistDW;
GO
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'DROP TABLE IF EXISTS intermediate.' + QUOTENAME(name) + N';'
FROM sys.tables WHERE schema_id = SCHEMA_ID(N'intermediate');
EXEC sys.sp_executesql @sql;   -- gồm cả bảng int_* do bản dbt tạo trước đây
GO

-- ---------- Transform_Clean ----------
CREATE TABLE intermediate.cln_orders (
    order_id                 nvarchar(255) NOT NULL CONSTRAINT PK_cln_orders PRIMARY KEY,
    customer_id              nvarchar(255) NULL,
    order_status             nvarchar(255) NULL,
    purchase_ts              datetime2(0)  NULL,
    approved_ts              datetime2(0)  NULL,
    carrier_ts               datetime2(0)  NULL,
    delivered_ts             datetime2(0)  NULL,
    estimated_ts             datetime2(0)  NULL,
    purchase_ts_parse_error  smallint      NOT NULL,
    approved_ts_parse_error  smallint      NOT NULL,
    carrier_ts_parse_error   smallint      NOT NULL,
    delivered_ts_parse_error smallint      NOT NULL,
    estimated_ts_parse_error smallint      NOT NULL,
    source_file              nvarchar(260) NULL,
    source_row_number        int           NULL,
    source_batch_id          varchar(100)  NULL
);

CREATE TABLE intermediate.cln_customers (
    customer_id        nvarchar(255) NOT NULL CONSTRAINT PK_cln_customers PRIMARY KEY,
    customer_unique_id nvarchar(255) NULL,
    zip_prefix         nvarchar(5)   NULL,
    city               nvarchar(255) NULL,
    state              nvarchar(255) NULL,
    source_file        nvarchar(260) NULL,
    source_row_number  int           NULL,
    source_batch_id    varchar(100)  NULL
);

CREATE TABLE intermediate.cln_order_items (
    order_id                   nvarchar(255) NOT NULL,
    order_item_id              int           NULL,
    product_id                 nvarchar(255) NULL,
    seller_id                  nvarchar(255) NULL,
    shipping_limit_ts          datetime2(0)  NULL,
    shipping_limit_parse_error smallint      NOT NULL,
    price_amount               decimal(18,2) NULL,
    freight_amount             decimal(18,2) NULL,
    price_parse_error          smallint      NOT NULL,
    freight_parse_error        smallint      NOT NULL,
    source_file                nvarchar(260) NULL,
    source_row_number          int           NULL,
    source_batch_id            varchar(100)  NULL
);
CREATE INDEX IX_cln_order_items_order ON intermediate.cln_order_items (order_id);

CREATE TABLE intermediate.cln_order_reviews (
    review_id              nvarchar(255)  NULL,
    order_id               nvarchar(255)  NULL,
    review_score           smallint       NULL,
    invalid_score_flag     smallint       NOT NULL,
    review_comment_title   nvarchar(1000) NULL,
    review_comment_message nvarchar(1000) NULL,
    review_creation_ts     datetime2(0)   NULL,
    review_answer_ts       datetime2(0)   NULL,
    source_file            nvarchar(260)  NULL,
    source_row_number      int            NULL,
    source_batch_id        varchar(100)   NULL
);

CREATE TABLE intermediate.cln_order_payments (
    order_id             nvarchar(255) NOT NULL,
    payment_sequential   int           NULL,
    payment_type         nvarchar(255) NULL,
    payment_installments int           NULL,
    payment_value        decimal(18,2) NULL,
    source_file          nvarchar(260) NULL,
    source_row_number    int           NULL,
    source_batch_id      varchar(100)  NULL
);

CREATE TABLE intermediate.cln_products (
    product_id        nvarchar(255) NOT NULL CONSTRAINT PK_cln_products PRIMARY KEY,
    category_name     nvarchar(255) NULL,
    product_weight_g  decimal(18,3) NULL,
    product_length_cm decimal(18,3) NULL,
    product_height_cm decimal(18,3) NULL,
    product_width_cm  decimal(18,3) NULL,
    source_file       nvarchar(260) NULL,
    source_row_number int           NULL,
    source_batch_id   varchar(100)  NULL
);

CREATE TABLE intermediate.cln_sellers (
    seller_id         nvarchar(255) NOT NULL CONSTRAINT PK_cln_sellers PRIMARY KEY,
    zip_prefix        nvarchar(5)   NULL,
    city              nvarchar(255) NULL,
    state             nvarchar(255) NULL,
    source_file       nvarchar(260) NULL,
    source_row_number int           NULL,
    source_batch_id   varchar(100)  NULL
);

CREATE TABLE intermediate.cln_geolocation (
    zip_prefix nvarchar(5)   NULL,
    lat        decimal(18,7) NULL,
    lng        decimal(18,7) NULL,
    city       nvarchar(255) NULL,
    state      nvarchar(255) NULL
);

CREATE TABLE intermediate.cln_category_translation (
    category_name         nvarchar(255) NOT NULL,
    category_name_english nvarchar(255) NULL
);

-- ---------- Transform_Business ----------
CREATE TABLE intermediate.int_order_customer_map (
    order_id              nvarchar(255) NOT NULL CONSTRAINT PK_int_order_customer_map PRIMARY KEY,
    customer_id           nvarchar(255) NULL,
    customer_unique_id    nvarchar(255) NULL,
    customer_zip_prefix   nvarchar(5)   NULL,
    missing_customer_flag smallint      NOT NULL
);

CREATE TABLE intermediate.int_order_item_summary (
    order_id         nvarchar(255) NOT NULL CONSTRAINT PK_int_order_item_summary PRIMARY KEY,
    item_line_count  int           NOT NULL,
    seller_count     int           NOT NULL,
    goods_value      decimal(18,2) NULL,
    freight_value    decimal(18,2) NULL,
    amounts_complete smallint      NOT NULL   -- 1 khi mọi dòng hàng đủ giá và phí vận chuyển
);

CREATE TABLE intermediate.int_order_payment_summary (
    order_id         nvarchar(255) NOT NULL CONSTRAINT PK_int_order_payment_summary PRIMARY KEY,
    payment_total    decimal(18,2) NULL,
    payment_complete smallint      NOT NULL   -- 1 khi mọi lần thanh toán có số tiền
);

CREATE TABLE intermediate.int_order_payment_reconciliation (
    order_id              nvarchar(255) NOT NULL CONSTRAINT PK_int_order_payment_reconciliation PRIMARY KEY,
    payment_total         decimal(18,2) NULL,
    goods_plus_freight    decimal(18,2) NULL,
    diff_brl              decimal(18,2) NULL,
    mismatch_gt_threshold int           NULL,
    mismatch_gt_1brl      int           NULL
);

CREATE TABLE intermediate.int_order_timeline (
    order_id                  nvarchar(255) NOT NULL CONSTRAINT PK_int_order_timeline PRIMARY KEY,
    customer_id               nvarchar(255) NULL,
    order_status              nvarchar(255) NULL,
    purchase_ts               datetime2(0)  NULL,
    approved_ts               datetime2(0)  NULL,
    carrier_ts                datetime2(0)  NULL,
    delivered_ts              datetime2(0)  NULL,
    estimated_ts              datetime2(0)  NULL,
    purchase_ts_parse_error   smallint      NOT NULL,
    approved_ts_parse_error   smallint      NOT NULL,
    carrier_ts_parse_error    smallint      NOT NULL,
    delivered_ts_parse_error  smallint      NOT NULL,
    estimated_ts_parse_error  smallint      NOT NULL,
    delivered_count           smallint      NOT NULL,
    invalid_approval_sequence smallint      NOT NULL,
    invalid_handling_sequence smallint      NOT NULL,
    invalid_transit_sequence  smallint      NOT NULL,
    invalid_delivery_sequence smallint      NOT NULL,
    invalid_estimated_date    smallint      NOT NULL,
    delivery_eligible_count   smallint      NOT NULL,
    late_count                smallint      NOT NULL,
    on_time_count             smallint      NOT NULL,
    late_days                 int           NULL,
    approval_seconds          int           NULL,
    handling_seconds          int           NULL,
    transit_seconds           int           NULL,
    delivery_seconds          int           NULL,
    outcome_code              nvarchar(20)  NOT NULL,
    quality_issue_count       int           NOT NULL,
    source_batch_id           varchar(100)  NULL
);

CREATE TABLE intermediate.int_order_review_representative (
    order_id                        nvarchar(255) NOT NULL CONSTRAINT PK_int_order_review_representative PRIMARY KEY,
    representative_review_id        nvarchar(255) NULL,
    representative_review_source_id nvarchar(300) NULL,
    representative_review_score     smallint      NOT NULL,
    review_creation_ts              datetime2(0)  NULL,
    review_answer_ts                datetime2(0)  NULL,
    review_record_count             int           NOT NULL,
    source_batch_id                 varchar(100)  NULL
);

CREATE TABLE intermediate.int_geography_canonical (
    zip_prefix              nvarchar(5)   NOT NULL CONSTRAINT PK_int_geography_canonical PRIMARY KEY,
    country_code            nvarchar(2)   NOT NULL,
    state_code              nvarchar(255) NULL,
    city_normalized         nvarchar(255) NULL,
    city_state_label        nvarchar(520) NULL,
    latitude                decimal(10,7) NULL,
    longitude               decimal(10,7) NULL,
    variant_count           int           NOT NULL,
    location_conflict_flag  smallint      NOT NULL,
    state_conflict_flag     smallint      NOT NULL,
    coordinate_quality_code nvarchar(20)  NOT NULL
);
GO
PRINT N'Đã tạo 9 bảng cln_* và 7 bảng int_* trong schema intermediate.';
GO
