-- Khoá thay thế bền vững cho dòng hàng (order_id, order_item_id). full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('order_item_key', ['order_id', 'order_item_id'], ref('stg_order_items')) }}
