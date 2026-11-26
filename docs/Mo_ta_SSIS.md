# Mô tả project SSIS `OlistETL`: tích hợp dữ liệu Olist vào kho dữ liệu

Nhóm 9, môn CSC12107, mini project BI trên dữ liệu Olist. Nhánh `ssis/t3-ssis-etl`.
Tài liệu này mô tả thiết kế; cách cài và chạy demo xem [huong_dan_SSIS.md](huong_dan_SSIS.md).

## Tóm tắt

Project SSIS `OlistETL` đưa 9 file CSV Olist vào kho dữ liệu SQL Server `OlistDW` theo quy trình
**Extract → Validate → Load Staging → Transform → Load Dimensions → Load Facts → Test**.

- **Nạp lần đầu là Full Load, các lần sau là Incremental Load.** Hệ thống tự chọn chế độ; lấy dữ liệu tăng dần
  bằng LSET/CET kết hợp so mã băm dòng; bỏ qua file đã nạp.
- **Dòng lỗi được tách riêng** vào `audit.reject_row`, không làm dừng cả bảng.
- **Mỗi lần chạy đều ghi lại** trạng thái, số dòng và lỗi. Chạy lại không sinh dữ liệu trùng.
- **Đã chạy thật** trên Visual Studio qua 4 batch:
  - Nạp tăng dần `FULL_001` → `INC_001` → `INC_002` cho kho **giống từng dòng** với nạp toàn bộ một lần.
  - Chạy lại không đổi một dòng nào trong kho.
  - Lỗi giữa chừng được ghi nhận, và chạy lại thì phục hồi đúng.

```
 data/batches/<BatchId>/*.csv
        │  Extract, Validate
        ▼
 ┌──────────────┐   Transform    ┌──────────────────────┐  Load    ┌──────────────────────┐
 │ staging.*    │ ─────────────► │ intermediate.cln_*   │ ───────► │ dwh.dim_* (7)        │ ──► Power BI
 │ (thô, theo   │                │ intermediate.int_*   │          │ dwh.fact_* (2)       │
 │  từng batch) │                │ affected_orders      │          │ galaxy schema        │
 └──────────────┘                └──────────────────────┘          └──────────────────────┘
        ▲                                   audit.* : batch, lần chạy, từng bước, LSET/CET, dòng lỗi, kiểm thử
```

---

## 1. Các package và vai trò trong ETL

Project có **7 package làm việc** và 1 package rỗng (`Package.dtsx`, do Task 1 tạo sẵn, không dùng).

| # | Package | Công đoạn | Đọc từ → Ghi vào | Việc chính |
|---|---|---|---|---|
| 0 | `Master` | Điều phối | — | Mở batch (tự chọn FULL hay INCREMENTAL), gọi 6 package dưới theo thứ tự, chốt SUCCESS hoặc FAILED, đẩy LSET |
| 1 | `Ingest_Staging` | **Extract, Validate, Load Staging** | CSV → `staging.*` | Đọc 9 file, kiểm tra tiêu đề và SHA-256, bỏ qua file đã nạp, lọc LSET/CET và so mã băm, tách dòng lỗi |
| 2 | `Transform_Clean` | **Transform** (làm sạch) | `staging.*` → `intermediate.cln_*` | Lấy bản mới nhất mỗi khoá, chuẩn hoá chuỗi, đổi kiểu dữ liệu, gắn cờ lỗi đọc, bỏ dòng trùng toạ độ |
| 3 | `Transform_Business` | **Transform** (nghiệp vụ) | `cln_*` → `intermediate.int_*` | Vòng đời đơn, đúng hạn hay trễ, đánh giá đại diện, gộp dòng hàng, đối chiếu thanh toán, mã bưu chính chuẩn; xác định đơn bị ảnh hưởng |
| 4 | `Load_Dimensions` | **Load** (dimension) | `cln_*`, `int_*`, CSV seed → `dwh.dim_*` | Chèn khoá nghiệp vụ mới (khoá thay thế không đổi), cập nhật thuộc tính (SCD 1), dựng lịch ngày |
| 5 | `Load_Facts` | **Load** (fact) | `int_*`, `cln_*` → stage → `dwh.fact_*` | Tra khoá dimension, tính khoá ngày và measure, MERGE các đơn bị ảnh hưởng vào fact |
| 6 | `Test_DW` | **Test** | kho, audit | 19 kiểm tra: không mất hay nhân dòng, khoá không mồ côi, khoá không đổi, đối chiếu trích xuất… |

**Vì sao tách thành nhiều package mà không gộp một như bài HW4:**
- **Mỗi package ứng với một tầng dữ liệu và một công đoạn.** Lỗi ở đâu biết ngay ở đâu, và chạy lại được từ package đó.
- **Bước sau dùng kết quả đã lưu của bước trước.** Ví dụ `Load_Facts` cần các bảng `dim_*` đã có khoá.
- HW4 chỉ có một nguồn database đã sạch, một lần nạp, không audit, không fact. Olist thì có:
  - Nguồn là file CSV.
  - Dữ liệu trùng và thiếu (theo kết quả profiling).
  - Hai fact khác grain.
  - Yêu cầu Full/Incremental Load, ghi log và chạy lại của đề.

**Ánh xạ sang quy trình ETL:**

| Bước | Package | Thành phần SSIS |
|---|---|---|
| Extract | `Ingest_Staging` | Flat File Connection Manager, Flat File Source |
| Validate | `Ingest_Staging`, `Transform_Clean` | Execute SQL Task (tiêu đề, SHA-256), Row Count, Error Output; Data Conversion và cờ lỗi |
| Load Staging | `Ingest_Staging` | OLE DB Destination vào bảng `_load`, Execute SQL Task (chọn dòng, chuyển trong một transaction) |
| Transform | `Transform_Clean`, `Transform_Business` | OLE DB Source, Derived Column, Data Conversion, Sort, Lookup, Aggregate |
| Load Dimensions | `Load_Dimensions` | Lookup (No Match Output), Conditional Split, OLE DB Command, OLE DB Destination |
| Load Facts | `Load_Facts` | Chuỗi Lookup, Derived Column, OLE DB Destination (stage), Execute SQL Task (MERGE) |
| Test | `Test_DW` | Execute SQL Task |
| Điều phối | `Master` | Execute Package Task (tham chiếu trong project), Event Handler `OnError` |

**Thành phần dùng chung:**
- **Connection manager `OlistDW`** (OLE DB, cấp project): mọi package dùng chung.
- **Tham số project:** `SqlServerName`, `DatabaseName`, `RawDir`, `BatchId`. Đổi `BatchId` để chọn batch cần nạp.
- **Locale English (US)** cho package và Data Flow, để `58.90` được đọc là số thập phân trên máy cài tiếng Việt.

---

## 2. Thiết kế chi tiết từng package

Quy ước đặt tên: `SQL …` Execute SQL Task, `SEQ …` Sequence Container, `DFT …` Data Flow Task,
`EPT …` Execute Package Task, `SRC`/`DST` nguồn/đích, `DER` Derived Column, `CNV` Data Conversion,
`LKP` Lookup, `AGG` Aggregate, `SRT` Sort, `CSPL` Conditional Split, `CMD` OLE DB Command.

### 2.0. `Master`: điều phối

```
SQL Bat dau batch ─► EPT Ingest_Staging ─► EPT Transform_Clean ─► EPT Transform_Business
                  ─► EPT Load_Dimensions ─► EPT Load_Facts ─► EPT Test_DW ─► SQL Ket thuc SUCCESS
Event Handler OnError: SQL Danh dau FAILED (ghi nội dung lỗi)
```

| Task | Làm gì | Vì sao |
|---|---|---|
| `SQL Bat dau batch` | `audit.usp_start_run`: mở batch và lần chạy; **FULL nếu chưa có batch nào thành công, ngược lại INCREMENTAL**; đọc CET từ `_cutoff.txt` của batch | Người chạy không phải tự chọn chế độ; lần đầu luôn là Full Load |
| `EPT …` (6 task) | Gọi package con trong cùng project, nối tiếp: package trước thành công mới chạy package sau | Bảo đảm thứ tự phụ thuộc giữa các tầng |
| `SQL Ket thuc SUCCESS` | `usp_finish_run`: batch SUCCESS, **đẩy LSET = CET** (chỉ tiến, không lùi), lưu ảnh chụp khoá thay thế | LSET chỉ được đẩy khi **cả pipeline** thành công, nên lỗi ở bước nào cũng không làm mất dữ liệu |
| `OnError` | Batch và lần chạy chuyển FAILED, lưu thông báo lỗi; LSET giữ nguyên | Chạy lại cùng batch sẽ lấy lại đúng cửa sổ dữ liệu |

### 2.1. `Ingest_Staging`: Extract, Validate, Load Staging

**Control Flow:**

```
SQL Bat dau batch ─► SEQ orders ─► SEQ customers ─► … (9 Sequence) … ─► SQL Danh dau INGESTED
                      ┌───────────────────────────────────────────────────────────────┐
                      │ SQL Validate orders     (VALIDATE)                             │
                      │      │  ràng buộc: thành công VÀ @[User::skip_orders] == 0      │
                      │      ▼                                                         │
                      │ DFT orders              (EXTRACT)                              │
                      │      ▼                                                         │
                      │ SQL Swap va audit orders (LOAD STAGING)                        │
                      └───────────────────────────────────────────────────────────────┘
```

**Sequence Container (`SEQ`)** gom 3 bước của cùng một file:
- Nhìn là biết file nào đang chạy và file nào lỗi.
- 9 file có cấu trúc giống nhau.
- Các SEQ chạy nối tiếp nhau.

| Task | Thành phần | Làm gì |
|---|---|---|
| `SQL Validate <bảng>` | Execute SQL Task, ResultSet = Single row | `usp_validate_source`: file đọc được; **dòng tiêu đề đúng tên và thứ tự cột**; tính **SHA-256**; dọn bảng `_load`. Trả về 3 giá trị gán vào biến: `skip` (1 nếu file cùng tên, cùng SHA-256 đã nạp ở batch từng thành công), `lset`, `cet` |
| Ràng buộc → DFT | Precedence Constraint *Expression and Constraint* | `skip = 1` thì **không chạy Data Flow** (không nạp lại file cũ) |
| `DFT <bảng>` | Data Flow | Xem sơ đồ dưới |
| `SQL Swap va audit <bảng>` | Execute SQL Task | `usp_finish_ingest`: (1) **đối chiếu Row Count với số dòng trong `_load` trước khi ghi**; (2) chọn dòng cần lấy; (3) chuyển sang `staging.<bảng>` trong một transaction; (4) ghi `source_manifest`, `etl_step_log`, `extract_stat`, chốt dòng lỗi |

**Data Flow `DFT orders`:**

```
FF Source orders ──(dòng đọc được)──► Row Count ──► DER Cot truy vet ──► DST orders_load
      │                                              source_file, source_batch_id,
      │                                              in_window = có mốc thời gian trong (LSET, CET]
      └──(Error Output: Redirect row)──► DER Dong loi ──► CNV Noi dung dong ──► DST reject_row
                                          batch, bảng, stage   DT_TEXT → DT_NTEXT
```

| Thành phần (SSIS Toolbox) | Cấu hình | Mục đích |
|---|---|---|
| **Flat File Source** + Flat File Connection Manager | UTF-8 (65001), dấu phân cách `,`, text qualifier `"`, mọi cột `DT_WSTR`, `RetainNulls` | Đọc CSV nguyên dạng chữ, đổi kiểu để bước Transform làm |
| Error Output của Flat File Source | *Redirect row* cho lỗi chuyển đổi và lỗi cắt chuỗi | Dòng hỏng (sai cấu trúc, dài quá cột) đi sang nhánh riêng, **không làm dừng cả bảng** |
| **Row Count** | Gán vào biến `User::rows_<bảng>` | Số dòng đọc được, để đối chiếu trước khi ghi |
| **Derived Column** | Thêm `source_file`, `source_batch_id`; `in_window` cho `orders`, `order_reviews` | Cột truy vết; cờ đánh dấu dòng có mốc thời gian trong cửa sổ **LSET/CET** |
| **Data Conversion** (nhánh lỗi) | Nội dung dòng lỗi `DT_TEXT` → `DT_NTEXT` | Lưu nguyên văn dòng lỗi vào `nvarchar(max)` |
| **OLE DB Destination** | Fast load vào `staging.<bảng>_load` và `audit.reject_row` | `_load` có `source_row_number` tự tăng theo thứ tự dòng trong file |

**Vì sao ghi qua `_load` rồi mới chuyển sang bảng chính:**
- Lỗi giữa chừng thì bảng chính không bị dở dang.
- Việc chọn dòng (incremental) làm được bằng SQL trên toàn bộ file đã nạp.
- Chạy lại cùng batch thì xoá phần cũ của batch rồi chèn, **không sinh dòng trùng**.

**Incremental Extract: dòng nào được lấy vào staging**

| Chế độ | Quy tắc |
|---|---|
| FULL | Lấy mọi dòng |
| INCREMENTAL | Lấy dòng có `in_window = 1` (mốc thời gian trong `(LSET, CET]`) **hoặc** dòng **mới hoặc đổi nội dung** so với bản mới nhất của các batch trước (so mã băm SHA-256 của dòng) |

- LSET/CET chỉ áp cho `orders` (4 mốc: mua, duyệt, giao vận chuyển, khách nhận) và `order_reviews` (thời điểm trả lời).
- So mã băm áp cho mọi bảng, và **bắt được thay đổi không kèm mốc thời gian**, ví dụ đơn chuyển sang huỷ.
  Bảng không có cột thời gian (`customers`, `products`, `sellers`…) chỉ dùng cách này.
- File **không đổi** (cùng SHA-256) bị bỏ qua từ bước Validate.

Mọi con số đều ghi vào `audit.extract_stat`, mỗi dòng ứng với một lần chạy và một file:
số dòng đọc, trong cửa sổ, đổi ngoài cửa sổ, lấy, không đổi, bị loại.

### 2.2. `Transform_Clean`: làm sạch

**Control Flow:**
```
SQL Ghi dong thieu khoa ─► SQL Don bang cln ─► DFT cln_orders ─► … (9 Data Flow) … ─► SQL Ghi audit
```

| Task | Làm gì |
|---|---|
| `SQL Ghi dong thieu khoa` | `usp_log_missing_keys`: dòng staging của batch thiếu khoá nghiệp vụ được ghi vào `reject_row` (stage `transform`) thay vì bị lọc âm thầm |
| `SQL Don bang cln` | TRUNCATE 9 bảng `cln_*`: tầng này tính lại toàn bộ mỗi lần, luôn phản ánh bản mới nhất của staging |
| `SQL Ghi audit` | Ghi số dòng từng bảng vào `etl_step_log` |

**Data Flow mẫu `DFT cln_orders`:**

```
SRC orders ─► DER Chuan hoa ─► CNV Doi kieu ngay gio ─► DER Co loi ─► DST cln_orders
(bản mới nhất   TRIM, chữ thường,   chuỗi → datetime2(0)     *_parse_error = 1
 theo batch)    ô trống → NULL       (Ignore failure)         nếu đọc không được
```

| Thành phần | Dùng ở | Mục đích |
|---|---|---|
| **OLE DB Source** (SQL command) | 9 bảng | Giữ **bản mới nhất của mỗi khoá** qua các batch (`ROW_NUMBER` theo `batch_seq`); đánh giá: bỏ dòng trùng hoàn toàn. SSIS không có thành phần tương đương `ROW_NUMBER` nên phần này viết bằng SQL |
| **Derived Column** | 9 bảng | `TRIM`, chữ thường/hoa, ô trống thành NULL; mã bưu chính đủ 5 chữ số; tên thành phố bỏ dấu tiếng Bồ Đào Nha và gộp khoảng trắng; điểm đánh giá chỉ nhận 1–5; giữ bình luận chỉ có emoji |
| **Data Conversion** | orders, items, reviews, payments, products, geolocation | Chuỗi → ngày giờ, số. *Ignore failure*: giá trị sai thành NULL, dòng vẫn giữ |
| **Derived Column** (cờ lỗi) | orders, items | `*_parse_error = 1` khi có giá trị nhưng đọc không được (phục vụ câu hỏi BQ10 về chất lượng dữ liệu) |
| **Sort** (*Remove duplicates*) | geolocation | Bỏ dòng trùng **sau** khi chuẩn hoá: 1.000.163 → 720.460 dòng |
| **OLE DB Destination** | 9 bảng | Ghi `intermediate.cln_*` |

Nhiều Derived Column nối tiếp nhau vì SSIS không cho dùng cột vừa tạo trong cùng một Derived Column.

### 2.3. `Transform_Business`: tính toán nghiệp vụ

**Control Flow:**
```
SQL Don bang int ─► DFT int_order_customer_map ─► DFT int_order_item_summary ─► DFT int_order_payment_summary
 ─► DFT int_order_payment_reconciliation ─► DFT int_order_timeline ─► DFT int_order_review_representative
 ─► DFT int_geography_canonical ─► SQL Don hang bi anh huong ─► SQL Ghi audit
```

| Data Flow | Thành phần | Kết quả và câu hỏi nghiệp vụ |
|---|---|---|
| `int_order_customer_map` | OLE DB Source → **Lookup** (khách theo `customer_id`) → Derived Column | Khách thật và mã bưu chính **theo từng đơn**; cờ thiếu khách |
| `int_order_item_summary` | Derived Column → **Aggregate** (group by đơn: đếm dòng, đếm người bán khác nhau, tổng giá, tổng phí, MIN cờ đủ tiền) → Derived Column | Gộp dòng hàng về cấp đơn **trước** khi nối vào fact cấp đơn (tránh nhân dòng) |
| `int_order_payment_summary` | Derived Column → **Aggregate** | Tổng thanh toán mỗi đơn |
| `int_order_payment_reconciliation` | OLE DB Source (full outer join hai bảng tổng) → 2 Derived Column | Chênh lệch thanh toán; cờ lệch > 0,01 BRL và > 1 BRL (cảnh báo T13, 303 đơn) |
| `int_order_timeline` | 3 **Derived Column** nối tiếp: cờ sai thứ tự mốc → đủ điều kiện xét giao → trễ/đúng hạn, số ngày trễ, số giây từng bước, nhóm kết quả giao | BQ02–BQ05, BQ10 |
| `int_order_review_representative` | OLE DB Source (xếp hạng) → Derived Column | Một đánh giá đại diện mỗi đơn (trả lời gần nhất) – BQ06, BQ07 |
| `int_geography_canonical` | OLE DB Source (cặp thành phố/bang phổ biến nhất, **trung vị toạ độ**) → Derived Column (nhãn, cờ xung đột) | Một dòng mỗi mã bưu chính, cho bản đồ và phân tích theo bang |

`SQL Don hang bi anh huong` gọi `usp_build_affected_orders`, tính danh sách đơn cần nạp lại vào fact:
- **FULL:** mọi đơn.
- **INCREMENTAL:** đơn có dòng mới hoặc đổi ở `orders`, `order_items`, `order_reviews`, `order_payments`, đơn của khách hoặc người bán đổi thông tin.

Đây là cơ sở cho Incremental Load ở `Load_Facts`.

Một số phép tính viết bằng SQL trong OLE DB Source (trung vị, xếp hạng, full outer join), vì SSIS không có
thành phần tương ứng. Phần còn lại dùng thành phần Data Flow.

### 2.4. `Load_Dimensions`: nạp dimension

**Control Flow:**
```
DFT dim_order_status ─► DFT dim_delivery_outcome ─► SQL Dung dim_date ─► DFT dim_customer ─► DFT dim_seller
 ─► DFT dim_product ─► DFT dim_geography ─► SQL Gan thoi diem nap ─► SQL Ghi audit
```

**Mẫu 1, dimension tra cứu (`dim_order_status`, `dim_delivery_outcome`):**
```
Flat File Source (CSV seed) ─► Data Conversion (khoá) ─► Lookup "đã có chưa" ─(No Match Output)─► OLE DB Destination
```

**Mẫu 2, chỉ có khoá (`dim_customer`, `dim_seller`):**
```
OLE DB Source (DISTINCT khoá nghiệp vụ) ─► Lookup ─(No Match Output)─► Derived Column ─► OLE DB Destination
```

**Mẫu 3, có thuộc tính thay đổi, SCD Type 1 (`dim_product`, `dim_geography`):**
```
OLE DB Source ─► [Lookup tên danh mục tiếng Anh ─► Derived Column]   (chỉ dim_product)
              ─► Lookup theo khoá nghiệp vụ ─┬─(No Match Output)─► OLE DB Destination   (khách/sản phẩm mới)
                                             └─(Match Output)─► Conditional Split "có thay đổi?" ─► OLE DB Command UPDATE
```

| Thiết kế | Lý do |
|---|---|
| Khoá thay thế là cột `IDENTITY`, **chỉ chèn khoá nghiệp vụ mới** | Khoá đã cấp không bao giờ đổi, kể cả khi chạy lại hay nạp tăng thêm (kiểm thử T08: 151.323 khoá không đổi). Thay cho 6 bảng map `km_*` của bản dbt |
| Lookup *No Match Output* | Mẫu chuẩn của SSIS để tách bản ghi mới và bản ghi đã có |
| Conditional Split rồi OLE DB Command | SCD Type 1: chỉ ghi đè khi thuộc tính thật sự đổi, và cập nhật `dw_updated_at` |
| Dòng Unknown khoá 0 (tạo sẵn bằng SQL) | Fact không tìm được dimension thì nhận khoá 0, không mất dòng |
| `SQL Dung dim_date` | Lịch liên tục từ ngày nhỏ nhất đến lớn nhất trong dữ liệu (SCD Type 0, chỉ chèn ngày thiếu) cùng 3 khoá đặc biệt 0 / −1 / −2 |
| `SQL Gan thoi diem nap` | Điền `dw_created_at`, `dw_updated_at` cho dòng mới (tính trong Data Flow bị SSIS coi là lỗi cắt dữ liệu) |

### 2.5. `Load_Facts`: nạp fact

**Control Flow:**
```
SQL Don stage ─► DFT fact_order_experience ─► DFT fact_order_item ─► SQL MERGE vao fact ─► SQL Ghi audit
```

**Data Flow `DFT fact_order_experience` (grain: một đơn):**
```
SRC Don hang (chỉ đơn trong affected_orders) ─► LKP dim_customer ─► LKP dim_geography ─► LKP dim_order_status
 ─► LKP dim_delivery_outcome ─► DER Khoa dimension ─► DER Khoa ngay ─► DER Measure ─► DST fact_order_experience_stage
```

**Data Flow `DFT fact_order_item` (grain: một dòng hàng):**

5 Lookup (khách, địa chỉ khách, sản phẩm, người bán, địa chỉ người bán) → Derived Column → `fact_order_item_stage`.

| Thành phần | Mục đích |
|---|---|
| **OLE DB Source** | Ghép các bảng `int_*` cùng grain; **chỉ lấy đơn bị ảnh hưởng** của batch |
| Chuỗi **Lookup** (*Ignore failure*) | Đổi khoá nghiệp vụ thành khoá thay thế của dimension; không tìm thấy thì NULL |
| **Derived Column** `DER Khoa dimension` | NULL thành khoá 0 (Unknown) |
| **Derived Column** `DER Khoa ngay` | 6 vai trò ngày dạng `YYYYMMDD`; **−2** ngày lỗi, **−1** mốc chưa xảy ra theo trạng thái đơn, **0** thiếu |
| **Derived Column** `DER Measure` | `order_count`, cờ có đánh giá, đánh giá thấp (1–2 sao), đánh giá trước khi giao… |
| **OLE DB Destination** | Ghi vào bảng stage, không ghi thẳng fact |
| `SQL MERGE vao fact` | `usp_merge_facts`, **một transaction**: đơn đã có thì cập nhật khi nội dung đổi (giữ `dw_created_at`, đổi `dw_updated_at`); đơn mới thì chèn; dòng hàng không còn thì xoá |

**Vì sao dùng stage cộng MERGE, không TRUNCATE rồi nạp lại:**
- Chỉ xử lý phần bị ảnh hưởng.
- Kho không có lúc trống hay dở dang.
- Chạy lại cho cùng kết quả.
- Giữ được ngày tạo của từng dòng.

Cách này đúng với `fact_order_experience` dạng **accumulating snapshot**: một đơn một dòng, được cập nhật khi đơn
có thêm mốc giao hoặc đánh giá.

### 2.6. `Test_DW`: kiểm thử

Một Execute SQL Task gọi `audit.usp_check_dw`. Có kiểm tra mức ERROR không đạt thì package đỏ và Master ghi FAILED.
Mọi kết quả đều ghi vào `audit.etl_step_log` (`step = 'test'`).

| Mã | Mức | Kiểm tra |
|---|---|---|
| T02a, T02b | ERROR | Fact có đúng số đơn và số dòng hàng của tầng làm sạch (không mất, không nhân dòng) |
| T03a, T03b | ERROR | Đủ khoá ngày 0/−1/−2 và dòng Unknown ở mọi dimension |
| T04a, T04b | ERROR | Mọi khoá ngoại của fact đều có trong dimension |
| T05a, T05b | ERROR | Trễ + đúng hạn = đủ điều kiện; các cờ đếm nhất quán |
| T06 | ERROR | Thời gian không âm, tổng 3 bước bằng tổng thời gian giao |
| T07 | ERROR | Điểm đánh giá đại diện thuộc 1–5 |
| T08 | ERROR | **Khoá thay thế không đổi** qua các lần nạp |
| T09, T10 | ERROR | Đối chiếu trích xuất: đọc = lấy + không đổi; số dòng staging khớp |
| T11, T12, T14 | ERROR | Khoá không trùng, cột bắt buộc không trống, giá trị hợp lệ |
| T13 | WARN | Đơn lệch thanh toán (có chủ đích, chỉ gắn cờ) |
| T15 | WARN | Đơn không tìm thấy khách |
| T16 | WARN | Dòng bị loại vào `reject_row` trong lần chạy |

### 2.7. Bảng audit (truy vết và bằng chứng)

| Bảng | Nội dung |
|---|---|
| `audit.etl_batch` | Mỗi batch: chế độ FULL/INCREMENTAL, trạng thái RUNNING → INGESTED → SUCCESS / FAILED |
| `audit.etl_run` | Mỗi lần chạy (`attempt` tăng khi chạy lại), thời gian, nội dung lỗi |
| `audit.etl_step_log` | Mỗi bước: bảng, số dòng đọc, nạp, loại, trạng thái; kết quả từng kiểm thử |
| `audit.source_manifest` | Mỗi file của batch: SHA-256, số dòng, danh sách cột |
| `audit.etl_metadata` | **LSET, CET** của `orders`, `order_reviews` |
| `audit.extract_stat` | Kết quả Incremental Extract theo từng lần chạy và từng file |
| `audit.reject_row` | Dòng bị loại: nội dung gốc, mã lỗi, lý do, công đoạn |
| `audit.dim_key_snapshot` | Ảnh chụp khoá thay thế cho kiểm thử T08 |

---

## 3. Kết quả ở mốc Data Warehouse và hướng sang Dashboard

### 3.1. Mục tiêu đã đạt

| Yêu cầu (đề mục 3.1–3.3, báo cáo nhóm) | Kết quả |
|---|---|
| Nạp dữ liệu nguồn vào Staging, kiểm tra cấu trúc và chất lượng | Kiểm tra tiêu đề, SHA-256, đối chiếu số dòng trước khi ghi; dòng lỗi vào `reject_row` |
| **Full Load và Incremental Load** (mô phỏng batch vì dữ liệu tĩnh) | `FULL_001` (FULL, 45.430 đơn) → `INC_001`, `INC_002` (INCREMENTAL, chỉ lấy dòng mới hoặc đổi). LSET tiến `2017-12-31` → `2018-04-30` → `2018-10-29`. Mã băm bắt thêm 51 và 19 đơn huỷ không kèm mốc thời gian |
| Ghi trạng thái, số dòng, lỗi | Các bảng `audit.*` ở mục 2.7 |
| **Chạy lại không trùng** | Chạy lại `INC_002`: 9/9 file bỏ qua, so 363.414 dòng của kho trước và sau: **khác 0** |
| Phục hồi khi lỗi | Cố ý làm hỏng bảng stage: `INC_003` FAILED ở `Load_Facts`, LSET giữ nguyên; sửa rồi chạy lại: SUCCESS, kho không đổi |
| Làm sạch, chuẩn hoá, tích hợp; kiểm tra chất lượng | 9 bảng `cln_*`, 7 bảng `int_*`; 19 kiểm thử tự động |
| Kho dữ liệu đa chiều trên SQL Server | Galaxy schema: `fact_order_experience` (99.441 đơn, accumulating snapshot), `fact_order_item` (112.650 dòng hàng, transaction); 7 dimension; dòng Unknown khoá 0; khoá ngày đặc biệt; SCD 0/1 |
| **Đúng số liệu** | Sau `INC_002`, mọi bảng `cln`, `int`, `dim`, `fact` **khớp từng dòng** với bản tham chiếu đã kiểm chứng; KPI: tỷ lệ trễ **6,77%**, điểm đánh giá **4,09**, tiền hàng **13.591.643,70 BRL**, 303 đơn lệch thanh toán |

**Hạn chế (ghi vào báo cáo):**
- Không có SCD Type 2.
- Tầng Transform tính lại toàn bộ mỗi lần; chỉ fact và dimension nạp tăng dần.
- `DFT cln_geolocation` chậm vì Sort hơn 1 triệu dòng.
- Package chỉ chạy được trong Visual Studio, vì máy chưa cài dịch vụ Integration Services.
- Median và P90 tính ở Power BI.
- Dữ liệu tăng thêm là mô phỏng; giả định ghi ở đầu `scripts/make_batches.py`.

### 3.2. Sang Dashboard (Power BI)

**1. Kết nối:**
- Power BI Desktop → SQL Server `localhost\SQLEXPRESS`, database `OlistDW`, chế độ **Import**.
- Chỉ lấy schema `dwh`: 2 fact và 7 dimension (không lấy staging, intermediate).

**2. Semantic model:**
- Quan hệ 1–nhiều từ dimension đến fact theo khoá thay thế.
- `dim_date` đóng **nhiều vai trò**: quan hệ chính theo `purchase_date_key` (mọi KPI tính theo tháng mua); các vai trò khác để quan hệ không hoạt động và dùng `USERELATIONSHIP` khi cần.
- `dim_geography` dùng cho cả địa chỉ khách và địa chỉ người bán.
- Hierarchy: **Năm → Quý → Tháng → Ngày**; **Bang → Thành phố → Mã bưu chính**; **Danh mục → Sản phẩm**.

**3. Measure DAX: tính từ tử số và mẫu số, không lấy trung bình của tỷ lệ**

| Measure | Công thức |
|---|---|
| Số đơn | `SUM(order_count)` |
| Tỷ lệ trễ | `DIVIDE(SUM(late_count), SUM(delivery_eligible_count))` |
| Điểm đánh giá trung bình | `AVERAGE(representative_review_score)` |
| Tỷ lệ đánh giá thấp | `DIVIDE(SUM(low_review_order_count), SUM(reviewed_order_count))` |
| Số ngày chờ: trung bình, median, P90 | `delivery_seconds / 86400` với `AVERAGEX`, `MEDIANX`, `PERCENTILEX.INC` |
| Phân tích theo người bán hoặc danh mục | Lấy danh sách đơn từ `fact_order_item` rồi áp lên `fact_order_experience` bằng `TREATAS` |

**4. Hai trang dashboard:**
- **Overview:** thẻ KPI; xu hướng theo tháng mua; tỷ lệ trễ theo bang (bản đồ dùng toạ độ trong `dim_geography`); bộ lọc thời gian, trạng thái, bang.
- **Diagnostic:** drill-down Bang → Thành phố; thời gian từng bước (duyệt, chuẩn bị, vận chuyển); so điểm đánh giá giữa nhóm đúng hạn và các nhóm trễ (`dim_delivery_outcome`); drill-through đến danh sách đơn; danh mục và người bán.

**5. AI tóm tắt:**
- Lấy các KPI đã tính (từ semantic model hoặc truy vấn `dwh`) làm đầu vào cho mô hình ngôn ngữ.
- Yêu cầu mô hình chỉ diễn giải trên các con số đó, để kết quả kiểm chứng được.

**6. Làm mới dữ liệu:** sau mỗi batch chạy SUCCESS, refresh Power BI. Kho chỉ đổi ở các đơn bị ảnh hưởng.
