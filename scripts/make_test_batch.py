"""Tạo batch kiểm thử INC_003 (sau INC_002) để chứng minh xử lý dòng lỗi.

Chép nguyên 9 file của INC_002 (cùng SHA-256 nên 8 file sẽ bị bỏ qua), riêng orders thêm 2 dòng hỏng:
  1. Một đơn có customer_id dài 300 ký tự (vượt độ rộng 255 của cột): Flat File Source không đọc được
     -> Error Output -> audit.reject_row (stage 'extract'). Các dòng khác vẫn nạp.
  2. Một đơn thiếu order_id: đọc được, vào staging, nhưng Transform_Clean không đưa vào tầng làm sạch
     -> audit.reject_row (stage 'transform').
Không dòng hợp lệ nào đổi, nên kho sau INC_003 vẫn phải giống hệt sau INC_002.

Chạy từ thư mục gốc repo:  python scripts/make_test_batch.py   (cần đã chạy make_batches.py)
"""
import csv
import pathlib
import shutil

SRC = pathlib.Path("data/batches/INC_002")
DST = pathlib.Path("data/batches/INC_003")
CUTOFF = "2018-10-31 00:00:00"


def main():
    if not SRC.exists():
        raise SystemExit("Chưa có data/batches/INC_002: chạy scripts/make_batches.py trước.")
    DST.mkdir(parents=True, exist_ok=True)
    for f in SRC.glob("*.csv"):
        shutil.copyfile(f, DST / f.name)
    (DST / "_cutoff.txt").write_text(CUTOFF, encoding="ascii")

    bad = [
        ["test0000000000000000000000000001", "x" * 300, "delivered", "2018-10-30 10:00:00",
         "2018-10-30 10:10:00", "", "", "2018-11-20 00:00:00"],
        ["", "test0000000000000000000000000002", "processing", "2018-10-30 11:00:00",
         "", "", "", "2018-11-21 00:00:00"],
    ]
    with open(DST / "olist_orders_dataset.csv", "a", encoding="utf-8", newline="") as f:
        csv.writer(f, lineterminator="\n").writerows(bad)
    print(f"Đã tạo {DST} (CET {CUTOFF}); orders thêm 2 dòng hỏng.")


if __name__ == "__main__":
    main()
