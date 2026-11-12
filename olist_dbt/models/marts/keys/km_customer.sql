-- Khoá thay thế bền vững cho khách thật (customer_unique_id). full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('customer_key', ['customer_unique_id'], ref('stg_customers')) }}
