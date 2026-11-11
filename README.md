# BI-GenAI: hệ thống BI cho dữ liệu thương mại điện tử Olist

Đồ án môn Hệ thống thông tin phục vụ trí tuệ kinh doanh (CSC12107, FIT HCMUS). Hệ thống trả lời ba câu hỏi: **đơn hàng có được giao đúng hạn không, khách phải chờ bao lâu, và đơn giao trễ có bị đánh giá thấp hơn không**.

```
9 file CSV ──► Mage (nạp dữ liệu) ──► DuckDB ◄── dbt (làm sạch, dựng kho) ──► Power BI ──► AI tóm tắt, giải thích
 data/                                 warehouse/olist.duckdb
```

| Công cụ | Dùng để | Chạy ở đâu |
|---|---|---|
| Mage | Nạp dữ liệu, điều phối các bước | Trong Docker |
| dbt | Làm sạch dữ liệu, dựng kho (fact, dimension), kiểm thử | Trong Docker (cùng container với Mage) |
| DuckDB | Kho dữ liệu, là một file duy nhất | `warehouse/olist.duckdb` |
| Power BI Desktop | Dashboard | Windows |

Hướng dẫn này đi từng bước. Làm xong bước nào thì kiểm tra kết quả của bước đó rồi mới sang bước sau.

## Mục lục

1. [Cài công cụ (làm một lần)](#1-cài-công-cụ-làm-một-lần)
2. [Lấy mã nguồn](#2-lấy-mã-nguồn)
3. [Giải nén dữ liệu](#3-giải-nén-dữ-liệu)
4. [Khởi động Mage và DuckDB](#4-khởi-động-mage-và-duckdb)
5. [Dừng và chạy lại](#5-dừng-và-chạy-lại)
6. [Các bước tiếp theo](#6-các-bước-tiếp-theo)
7. [Xử lý sự cố](#7-xử-lý-sự-cố)
8. [Nguồn dữ liệu](#8-nguồn-dữ-liệu)

## 1. Cài công cụ (làm một lần)

| Công cụ | Windows | macOS | Linux |
|---|---|---|---|
| Git | [git-scm.com/downloads](https://git-scm.com/downloads) | Có sẵn khi gõ `git` lần đầu, hoặc cài từ link bên trái | `sudo apt install git` (Ubuntu) hoặc trình quản lý gói của bản phân phối |
| Docker | [Docker Desktop cho Windows](https://docs.docker.com/desktop/setup/install/windows-install/) | [Docker Desktop cho Mac](https://docs.docker.com/desktop/setup/install/mac-install/) | [Docker Engine](https://docs.docker.com/engine/install/) kèm plugin Docker Compose |

Lưu ý:
- **Windows:** Docker Desktop cần WSL 2. Nếu trình cài báo thiếu, mở PowerShell bằng quyền Administrator, chạy `wsl --install` rồi khởi động lại máy.
- **Máy cần:** RAM từ 8 GB, ổ đĩa trống khoảng 8 GB (image Mage tải về khoảng 1,3 GB, giải nén ra khoảng 5,5 GB).
- **Kiểm tra cài xong:** mở terminal (Windows: PowerShell; macOS: Terminal; Linux: terminal bất kỳ) và chạy:

```bash
git --version
docker --version
docker compose version
```

Cả ba lệnh đều in ra số phiên bản là được. Trên Windows và macOS, nhớ **mở Docker Desktop** và chờ biểu tượng cá voi báo đang chạy trước khi làm các bước sau.

## 2. Lấy mã nguồn

```bash
git clone https://github.com/tthoan23/bi-genai.git
cd bi-genai
```

Mọi lệnh từ đây trở đi đều chạy **trong thư mục `bi-genai`**.

## 3. Giải nén dữ liệu

Dữ liệu gốc nằm sẵn trong repo ở `data/olist-brazilian-ecommerce.zip`. Giải nén vào `data/raw`:

**Windows (PowerShell):**
```powershell
Expand-Archive -Path data\olist-brazilian-ecommerce.zip -DestinationPath data\raw -Force
```

**macOS và Linux:**
```bash
unzip -o data/olist-brazilian-ecommerce.zip -d data/raw
```

**Kiểm tra:** thư mục `data/raw` có đúng 9 file `.csv`, từ `olist_customers_dataset.csv` đến `product_category_name_translation.csv`.

## 4. Khởi động Mage và DuckDB

**Chỉ dành cho Linux:** nếu lệnh `id -u` không in ra `1000`, tạo file `.env` trong thư mục `bi-genai` với nội dung sau (thay số cho đúng máy bạn, lấy từ `id -u` và `id -g`), để file do Mage tạo ra thuộc về tài khoản của bạn:

```
UID=1001
GID=1001
```

Khởi động (lần đầu sẽ tải image Mage, mất vài phút tùy mạng):

```bash
docker compose up -d
```

Chờ khoảng 30 giây rồi mở trình duyệt vào **http://localhost:6789**. Thấy giao diện Mage là được.

**Kiểm tra DuckDB:**

```bash
docker compose exec mage python -c "import duckdb, os; con = duckdb.connect(os.environ['DUCKDB_PATH']); print(con.sql('select 42 as ket_qua'))"
```

Kết quả đúng là một bảng nhỏ có cột `ket_qua` bằng `42`, đồng thời xuất hiện file `warehouse/olist.duckdb`. Đây chính là kho dữ liệu: toàn bộ bảng sẽ nằm trong file này.

## 5. Dừng và chạy lại

| Việc | Lệnh |
|---|---|
| Xem container có đang chạy không | `docker compose ps` |
| Dừng (giữ nguyên dữ liệu) | `docker compose stop` |
| Chạy lại | `docker compose start` |
| Xem log khi có lỗi | `docker compose logs --tail 50 mage` |
| Gỡ container (file trong repo vẫn còn) | `docker compose down` |

## 6. Các bước tiếp theo

Nhóm đang dựng hệ thống theo từng bước. Mỗi bước xong sẽ được thêm hướng dẫn vào đây.

- [x] Bước 0: khung repo, dữ liệu, Docker Compose
- [x] Bước 1: Mage và DuckDB chạy được
- [ ] Bước 2: pipeline Mage nạp 9 file CSV vào DuckDB, có bảng audit
- [ ] Bước 3: dbt làm sạch dữ liệu (staging)
- [ ] Bước 4: dbt dựng kho dữ liệu (dimension, fact)
- [ ] Bước 5: kiểm thử và tài liệu dbt
- [ ] Bước 6: nạp tăng thêm (incremental) và kiểm tra chạy lại
- [ ] Bước 7: kết nối Power BI
- [ ] Bước 8: AI tóm tắt và giải thích

## 7. Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| `docker: command not found` hoặc `Cannot connect to the Docker daemon` | Docker chưa cài hoặc Docker Desktop chưa mở. Mở Docker Desktop, chờ chạy xong rồi thử lại. |
| `port is already allocated` khi `docker compose up` | Cổng 6789 đang bị chương trình khác dùng. Tắt chương trình đó, hoặc đổi dòng `"6789:6789"` trong `docker-compose.yml` thành `"6790:6789"` rồi mở http://localhost:6790. |
| Trang http://localhost:6789 không mở được | Chờ thêm 30 giây; xem log bằng `docker compose logs --tail 50 mage`. |
| Báo lỗi file DuckDB bị khóa (`Could not set lock on file`) | DuckDB chỉ cho một chương trình ghi cùng lúc. Đóng DBeaver hoặc chương trình khác đang mở `olist.duckdb` rồi chạy lại. |
| Linux: không sửa được file do Mage tạo | Xem phần `.env` với `UID`, `GID` ở mục 4, rồi chạy `docker compose up -d` lại. |

## 8. Nguồn dữ liệu

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), giấy phép CC BY-NC-SA 4.0. Repo giữ nguyên file gốc trong `data/` để mọi người chạy lại được, chỉ dùng cho mục đích học tập. Xem thêm `data/README.md`.
