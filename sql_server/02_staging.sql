USE OlistDW;
GO
IF OBJECT_ID(N'staging.orders', N'U') IS NULL
CREATE TABLE staging.orders (
    order_id NVARCHAR(255), customer_id NVARCHAR(255), order_status NVARCHAR(255),
    order_purchase_timestamp NVARCHAR(255), order_approved_at NVARCHAR(255),
    order_delivered_carrier_date NVARCHAR(255), order_delivered_customer_date NVARCHAR(255),
    order_estimated_delivery_date NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.customers', N'U') IS NULL
CREATE TABLE staging.customers (
    customer_id NVARCHAR(255), customer_unique_id NVARCHAR(255), customer_zip_code_prefix NVARCHAR(255),
    customer_city NVARCHAR(255), customer_state NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.order_items', N'U') IS NULL
CREATE TABLE staging.order_items (
    order_id NVARCHAR(255), order_item_id NVARCHAR(255), product_id NVARCHAR(255), seller_id NVARCHAR(255),
    shipping_limit_date NVARCHAR(255), price NVARCHAR(255), freight_value NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.order_reviews', N'U') IS NULL
CREATE TABLE staging.order_reviews (
    review_id NVARCHAR(255), order_id NVARCHAR(255), review_score NVARCHAR(255),
    review_comment_title NVARCHAR(1000), review_comment_message NVARCHAR(1000),
    review_creation_date NVARCHAR(255), review_answer_timestamp NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.order_payments', N'U') IS NULL
CREATE TABLE staging.order_payments (
    order_id NVARCHAR(255), payment_sequential NVARCHAR(255), payment_type NVARCHAR(255),
    payment_installments NVARCHAR(255), payment_value NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.products', N'U') IS NULL
CREATE TABLE staging.products (
    product_id NVARCHAR(255), product_category_name NVARCHAR(255),
    product_name_lenght NVARCHAR(255), product_description_lenght NVARCHAR(255),
    product_photos_qty NVARCHAR(255), product_weight_g NVARCHAR(255),
    product_length_cm NVARCHAR(255), product_height_cm NVARCHAR(255), product_width_cm NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.sellers', N'U') IS NULL
CREATE TABLE staging.sellers (
    seller_id NVARCHAR(255), seller_zip_code_prefix NVARCHAR(255),
    seller_city NVARCHAR(255), seller_state NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.geolocation', N'U') IS NULL
CREATE TABLE staging.geolocation (
    geolocation_zip_code_prefix NVARCHAR(255), geolocation_lat NVARCHAR(255), geolocation_lng NVARCHAR(255),
    geolocation_city NVARCHAR(255), geolocation_state NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));

IF OBJECT_ID(N'staging.category_translation', N'U') IS NULL
CREATE TABLE staging.category_translation (
    product_category_name NVARCHAR(255), product_category_name_english NVARCHAR(255),
    source_file NVARCHAR(260), source_checksum VARCHAR(64), source_row_number INT,
    source_batch_id VARCHAR(100), ingested_at DATETIME2(0));
GO