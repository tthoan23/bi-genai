"""Đăng ký các package .dtsx do build.ps1 sinh ra vào OlistETL.dtproj và đặt tham số project.
Chạy từ thư mục gốc repo (đóng Visual Studio trước, hoặc đóng solution KHÔNG lưu rồi mở lại):
    python ssis/tools/register_packages.py [--server localhost\\SQLEXPRESS]
Chạy lại nhiều lần vẫn an toàn. RawDir được đặt theo vị trí repo trên máy đang chạy."""
import argparse
import pathlib
import re

repo = pathlib.Path(__file__).resolve().parents[2]
project = repo / "ssis" / "OlistETL" / "OlistETL"
PACKAGES = ["Master", "Ingest_Staging", "Transform_Clean", "Transform_Business", "Load_Dimensions", "Load_Facts", "Test_DW"]

parser = argparse.ArgumentParser()
parser.add_argument("--server", default="localhost\\SQLEXPRESS")
server = parser.parse_args().server


def read(path):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    return raw.decode("utf-8-sig"), bom


def write(path, text, bom):
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))


dtproj = project / "OlistETL.dtproj"
text, bom = read(dtproj)
for name in PACKAGES:
    xml, _ = read(project / f"{name}.dtsx")
    root = xml[xml.index("<DTS:Executable"):]
    root = root[:root.index(">")]
    attr = lambda a, d="": (re.search(rf'DTS:{a}="([^"]*)"', root) or [None, d])[1]
    # xoá đăng ký cũ (nếu có) rồi thêm lại với ID mới của package
    text = re.sub(rf'\s*<SSIS:Package SSIS:Name="{name}\.dtsx" SSIS:EntryPoint="\d" />', "", text)
    text = re.sub(rf'\s*<SSIS:PackageMetaData SSIS:Name="{name}\.dtsx">.*?</SSIS:PackageMetaData>', "", text, flags=re.S)
    text = re.sub(r"(\r?\n\s*)</SSIS:Packages>",
                  lambda m: f'{m[1]}  <SSIS:Package SSIS:Name="{name}.dtsx" SSIS:EntryPoint="1" />{m[1]}</SSIS:Packages>', text)
    props = [("ID", attr("DTSID")), ("Name", name), ("VersionMajor", "1"), ("VersionMinor", "0"),
             ("VersionBuild", attr("VersionBuild", "0")), ("VersionComments", ""), ("VersionGUID", attr("VersionGUID")),
             ("PackageFormatVersion", "8"), ("Description", ""), ("ProtectionLevel", "0")]

    def block(m, name=name, props=props):
        pad = m[1] + "  "
        lines = [f'{pad}<SSIS:PackageMetaData SSIS:Name="{name}.dtsx">', f"{pad}  <SSIS:Properties>"]
        lines += [f'{pad}    <SSIS:Property SSIS:Name="{k}">{v}</SSIS:Property>' for k, v in props]
        lines += [f"{pad}  </SSIS:Properties>", f"{pad}  <SSIS:Parameters />", f"{pad}</SSIS:PackageMetaData>"]
        return "".join(lines) + f"{m[1]}</SSIS:PackageInfo>"

    text = re.sub(r"(\r?\n\s*)</SSIS:PackageInfo>", block, text)
write(dtproj, text, bom)

params = project / "Project.params"
text, bom = read(params)
for key, value in {"SqlServerName": server, "RawDir": str(repo / "data" / "raw")}.items():
    pattern = rf'(<SSIS:Parameter\s+SSIS:Name="{key}">.*?SSIS:Name="Value">)([^<]*)(<)'
    text, n = re.subn(pattern, lambda m: m[1] + value + m[3], text, count=1, flags=re.S)
    assert n == 1, f"Không tìm thấy tham số {key}"
write(params, text, bom)
print(f"Đã đăng ký {len(PACKAGES)} package; SqlServerName={server}; RawDir={repo / 'data' / 'raw'}")
