-- Khoá thay thế bền vững cho đơn hàng. full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('order_key', ['order_id'], ref('stg_orders')) }}
