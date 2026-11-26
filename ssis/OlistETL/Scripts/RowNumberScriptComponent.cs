// Script Component (Transformation) "SCR Row No" - dùng trong 9 Data Flow.
// Trong editor: Input = "Flat File Source Output"; chọn synchronous output và thêm
// cột output source_row_number kiểu DT_I4 (DT_I4 = Standard Integer, 4 byte).
// Dán code này vào tab Script (Language = C#).
using System;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using Microsoft.SqlServer.Dts.Runtime.Wrapper;

[Microsoft.SqlServer.Dts.Pipeline.SSISScriptComponentEntryPointAttribute]
public class ScriptMain : UserComponent
{
    private int _rowNumber = 0;

    public override void Input0_ProcessInputRow(Input0Buffer Row)
    {
        // Bắt đầu từ 1, giống range(1, file_rows + 1) trong ingest_csv.py.
        Row.source_row_number = ++_rowNumber;
    }
}
