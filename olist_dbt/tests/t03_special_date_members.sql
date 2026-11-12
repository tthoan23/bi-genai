-- T03: đủ 3 member đặc biệt của Dim_Date (0, -1, -2)
select missing_key
from (values (0), (-1), (-2)) v(missing_key)
where not exists (select 1 from {{ ref('dim_date') }} d where d.date_key = v.missing_key)
