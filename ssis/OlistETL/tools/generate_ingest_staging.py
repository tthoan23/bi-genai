import base64
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "OlistETL" / "Ingest_Staging.dtsx"
ASSEMBLIES = ROOT / "Scripts" / "assemblies"
TEMPLATE = Path(__file__).resolve().parent / "script_component_template"
TASK_TEMPLATE = Path(__file__).resolve().parent / "script_task_template.xml"
SOURCES = ROOT / "Scripts"

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
PROJECT_NS = "SC_9f6a4c21e7b748d3a1c2e5f8b0d47a63"
VSTA_BY_TABLE = {
    "category_translation": "SC_9f6a4c21e7b748d3a1c2e5f8b0001",
    "customers": "SC_9f6a4c21e7b748d3a1c2e5f8b0002",
    "geolocation": "SC_9f6a4c21e7b748d3a1c2e5f8b0003",
    "order_items": "SC_9f6a4c21e7b748d3a1c2e5f8b0004",
    "order_payments": "SC_9f6a4c21e7b748d3a1c2e5f8b0005",
    "order_reviews": "SC_9f6a4c21e7b748d3a1c2e5f8b0006",
    "orders": "SC_9f6a4c21e7b748d3a1c2e5f8b0007",
    "products": "SC_9f6a4c21e7b748d3a1c2e5f8b0008",
    "sellers": "SC_9f6a4c21e7b748d3a1c2e5f8b0009",
}

TABLES = [
    ("orders", "olist_orders_dataset.csv", [
        "order_id", "customer_id", "order_status", "order_purchase_timestamp",
        "order_approved_at", "order_delivered_carrier_date",
        "order_delivered_customer_date", "order_estimated_delivery_date",
    ], ["order_id", "customer_id", "order_status", "order_purchase_timestamp"]),
    ("customers", "olist_customers_dataset.csv", [
        "customer_id", "customer_unique_id", "customer_zip_code_prefix",
        "customer_city", "customer_state",
    ], ["customer_id", "customer_unique_id", "customer_zip_code_prefix"]),
    ("order_items", "olist_order_items_dataset.csv", [
        "order_id", "order_item_id", "product_id", "seller_id",
        "shipping_limit_date", "price", "freight_value",
    ], ["order_id", "order_item_id", "product_id", "seller_id", "price", "freight_value"]),
    ("order_reviews", "olist_order_reviews_dataset.csv", [
        "review_id", "order_id", "review_score", "review_comment_title",
        "review_comment_message", "review_creation_date", "review_answer_timestamp",
    ], ["review_id", "order_id", "review_score", "review_creation_date", "review_answer_timestamp"]),
    ("order_payments", "olist_order_payments_dataset.csv", [
        "order_id", "payment_sequential", "payment_type",
        "payment_installments", "payment_value",
    ], ["order_id", "payment_sequential", "payment_type"]),
    ("products", "olist_products_dataset.csv", [
        "product_id", "product_category_name", "product_name_lenght",
        "product_description_lenght", "product_photos_qty", "product_weight_g",
        "product_length_cm", "product_height_cm", "product_width_cm",
    ], ["product_id"]),
    ("sellers", "olist_sellers_dataset.csv", [
        "seller_id", "seller_zip_code_prefix", "seller_city", "seller_state",
    ], ["seller_id", "seller_zip_code_prefix"]),
    ("geolocation", "olist_geolocation_dataset.csv", [
        "geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng",
        "geolocation_city", "geolocation_state",
    ], ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng"]),
    ("category_translation", "product_category_name_translation.csv", [
        "product_category_name", "product_category_name_english",
    ], ["product_category_name", "product_category_name_english"]),
]

NTEXT_COLUMNS = {"review_comment_title", "review_comment_message"}
ROW_DELIM = "_x000D__x000A_"
COMMA = "_x002C_"
QUOTE = "_x0022_"

SWAP_EXPR = (
    '"EXEC audit.usp_swap_staging @table_name = N\'" + @[User::current_table] '
    '+ "\', @batch_id = \'" + @[User::var_batch_id] + "\';"'
)
AUDIT_EXPR = (
    '"EXEC audit.usp_write_ingest_audit @run_id = " + (DT_WSTR,10)@[User::var_run_id] '
    '+ ", @batch_id = N\'" + @[User::var_batch_id] '
    '+ "\', @table_name = N\'" + @[User::current_table] '
    '+ "\', @source_file = N\'" + @[User::current_file] '
    '+ "\', @source_checksum = \'" + @[User::checksum] '
    '+ "\', @row_count = " + (DT_WSTR,20)@[User::file_rows] '
    '+ ", @column_list = N\'" + @[User::column_list] '
    '+ "\', @rows_read = " + (DT_WSTR,20)@[User::rows_read] '
    '+ ", @rows_loaded = " + (DT_WSTR,20)@[User::rows_loaded] + ";"'
)
FINISH_EXPR = (
    '"EXEC audit.usp_mark_ingested @run_id = " + (DT_WSTR,10)@[$Package::run_id] '
    '+ ", @batch_id = N\'" + @[$Package::batch_id] + "\';"'
)
ERROR_EXPR = (
    '"EXEC audit.usp_mark_failed @run_id = " + (DT_WSTR,10)@[$Package::run_id] '
    '+ ", @batch_id = N\'" + @[$Package::batch_id] '
    '+ "\', @table_name = N\'" + @[System::SourceName] '
    '+ "\', @error_message = N\'" + REPLACE(@[System::ErrorDescription], "\'", "\'\'") + "\';"'
)


def guid(seed):
    return "{" + str(uuid.uuid5(NS, seed)).upper() + "}"


def short(seed):
    return str(uuid.uuid5(NS, seed)).replace("-", "")


def xa(value):
    return (str(value).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def xt(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def elem(tag, attrs=None, children="", empty=False, raw=True):
    body = "".join(' %s="%s"' % (k, xa(v)) for k, v in (attrs or {}).items())
    if empty:
        return "<%s%s />" % (tag, body)
    return "<%s%s>%s</%s>" % (tag, body, children, tag)


def dts_prop(name, value, dtype=None, extra=""):
    attrs = {"DTS:Name": name}
    if dtype is not None:
        attrs["DTS:DataType"] = dtype
    for key, val in extra.items() if isinstance(extra, dict) else []:
        attrs[key] = val
    return elem("DTS:Property", attrs, xt(value))


def row_delimiter(file_name):
    sample = (ROOT.parents[1] / "data" / "raw" / file_name).read_bytes()[:65536]
    return "_x000D__x000A_" if b"\r\n" in sample else "_x000A_"


def flat_column(name, index, count, row_delim):
    attrs = {
        "DTS:ColumnType": "Delimited",
        "DTS:ColumnDelimiter": row_delim if index == count - 1 else COMMA,
        "DTS:DataType": "130",
        "DTS:TextQualified": "True",
        "DTS:ObjectName": name,
        "DTS:DTSID": guid("flatcol:%s" % name),
        "DTS:CreationName": "",
        "DTS:MaximumWidth": "4000" if name in NTEXT_COLUMNS else "255",
    }
    return elem("DTS:FlatFileColumn", attrs, empty=True)


def connection_managers(ole_guid):
    ole_cm = elem("DTS:ConnectionManager", {
        "DTS:refId": "Package.ConnectionManagers[OlistDW]",
        "DTS:CreationName": "OLEDB",
        "DTS:DTSID": ole_guid,
        "DTS:ObjectName": "OlistDW",
    },
        elem("DTS:ObjectData", {}, elem("DTS:ConnectionManager", {
            "DTS:ConnectionString": "Data Source=localhost;Initial Catalog=OlistDW;Provider=MSOLEDBSQL;Integrated Security=SSPI;TrustServerCertificate=True;",
        }, empty=True))
    )

    cms = [ole_cm]
    for table, file_name, cols, _ in TABLES:
        row_delim = row_delimiter(file_name)
        columns = "".join(flat_column(c, i, len(cols), row_delim) for i, c in enumerate(cols))
        inner = elem("DTS:ConnectionManager", {
            "DTS:Format": "Delimited",
            "DTS:LocaleID": "1033",
            "DTS:Unicode": "False",
            "DTS:CodePage": "65001",
            "DTS:ColumnNamesInFirstDataRow": "True",
            "DTS:HeaderRowDelimiter": row_delim,
            "DTS:RowDelimiter": row_delim,
            "DTS:TextQualifier": QUOTE,
            "DTS:ConnectionString": "C:\\bi-genai\\data\\raw\\" + file_name,
        }, elem("DTS:FlatFileColumns", {}, columns))
        cms.append(elem("DTS:ConnectionManager", {
            "DTS:refId": "Package.ConnectionManagers[FF_%s]" % table,
            "DTS:CreationName": "FLATFILE",
            "DTS:DTSID": guid("cm:ff:%s" % table),
            "DTS:ObjectName": "FF_%s" % table,
            "DTS:Description": "Flat file source for staging.%s" % table,
            "DTS:DelayValidation": "True",
        },
            elem("DTS:PropertyExpression", {"DTS:Name": "ConnectionString"},
                 '@[$Package::raw_dir] + "\\\\%s"' % file_name)
            + elem("DTS:ObjectData", {}, inner)
        ))
    return elem("DTS:ConnectionManagers", {}, "".join(cms))


def package_parameters():
    items = []
    for name, dtype, value in [
        ("run_id", "3", "0"),
        ("batch_id", "8", "FULL_001"),
        ("batch_type", "8", "FULL"),
        ("raw_dir", "8", "C:\\bi-genai\\data\\raw"),
    ]:
        pval = elem("DTS:Property", {"DTS:DataType": "0" if value == "" else dtype,
                                     "DTS:Name": "ParameterValue"},
                    "" if value == "" else xt(value))
        items.append(elem("DTS:PackageParameter", {
            "DTS:CreationName": "",
            "DTS:DataType": dtype,
            "DTS:DTSID": guid("param:%s" % name),
            "DTS:ObjectName": name,
        }, pval))
    return elem("DTS:PackageParameters", {}, "".join(items))


def variable(name, value, dtype="8", expression=None):
    attrs = {
        "DTS:CreationName": "",
        "DTS:DTSID": guid("var:%s:%s" % (CONTEXT[0], name)),
        "DTS:IncludeInDebugDump": "2345",
        "DTS:Namespace": "User",
        "DTS:ObjectName": name,
    }
    if expression:
        attrs["DTS:Expression"] = expression
        attrs["DTS:EvaluateAsExpression"] = "True"
    inner = elem("DTS:VariableValue", {"DTS:DataType": dtype}, xt(value))
    return elem("DTS:Variable", attrs, inner)


def package_variables():
    return elem("DTS:Variables", {},
                variable("var_raw_dir", "", "8", '@[$Package::raw_dir]')
                + variable("var_batch_id", "", "8", '@[$Package::batch_id]')
                + variable("var_batch_type", "", "8", '@[$Package::batch_type]')
                + variable("var_run_id", "0", "3", '@[$Package::run_id]')
                + variable("sql_finish", "", "8", FINISH_EXPR))


def script_project(kind, dll_name, source_name, ro, rw):
    project = "ST_" + short(kind + ":" + CONTEXT[0])
    dll = base64.b64encode((ASSEMBLIES / dll_name).read_bytes()).decode("ascii")
    dll_lines = "\n".join(dll[i:i + 76] for i in range(0, len(dll), 76))
    raw_source = (SOURCES / source_name).read_text(encoding="utf-8")
    using_lines = list(re.finditer(r"(?m)^using [^\r\n]+;\s*$", raw_source))
    insert_at = using_lines[-1].end() if using_lines else 0
    enum = (
        "enum ScriptResults\n"
        "{\n"
        "    Success = Microsoft.SqlServer.Dts.Runtime.DTSExecResult.Success,\n"
        "    Failure = Microsoft.SqlServer.Dts.Runtime.DTSExecResult.Failure\n"
        "}\n\n"
    )
    source = raw_source[:insert_at] + "\n" + enum + raw_source[insert_at:]
    template = TASK_TEMPLATE.read_text(encoding="utf-8")
    template = template.replace("ST_487d3475938c43b59f1ac5d58a00fbd2", project)
    template = template.replace('ReadOnlyVariables="User::TargetFile"', 'ReadOnlyVariables="%s"' % xa(ro))
    template = template.replace('ReadWriteVariables="User::ImportFilePath,User::ImportTable"', 'ReadWriteVariables="%s"' % xa(rw))
    template = template.replace("Version=13.0.0.0", "Version=16.0.0.0")
    template = template.replace("SSIS_ST130", "SSIS_ST160")
    template = template.replace("<TargetFrameworkVersion>v4.5</TargetFrameworkVersion>", "<TargetFrameworkVersion>v4.8</TargetFrameworkVersion>")
    template = re.sub(
        r'(<ProjectItem\s+Name="ScriptMain\.cs"[^>]*><!\[CDATA\[).*?(\]\]></ProjectItem>)',
        lambda m: m.group(1) + "\n" + source + "\n" + m.group(2),
        template,
        flags=re.S,
    )
    binary = '<BinaryItem Name="%s.dll">\n%s\n</BinaryItem>' % (project, dll_lines)
    template = re.sub(r'<BinaryItem\s+Name="[^"]+">.*?</BinaryItem>', binary, template, flags=re.S)
    return template


def script_task(kind, name, dll_name, source_name, ro="", rw=""):
    seed = "%s:%s" % (CONTEXT[0], name)
    return elem("DTS:Executable", {
        "DTS:refId": CONTEXT[1] + "\\" + name,
        "DTS:CreationName": "Microsoft.ScriptTask",
        "DTS:Description": "SSIS Script Task",
        "DTS:DTSID": guid("task:" + seed),
        "DTS:ExecutableType": "Microsoft.ScriptTask",
        "DTS:LocaleID": "-1",
        "DTS:MaxErrorCount": "0",
        "DTS:ObjectName": name,
        "DTS:ThreadHint": "0",
    },
        elem("DTS:Variables", {}, empty=True)
        + elem("DTS:ObjectData", {}, script_project(kind, dll_name, source_name, ro, rw))
    )


def sql_task(name, source_var, ole_guid, result_variable=None, ref_prefix=None):
    prefix = ref_prefix or CONTEXT[1]
    seed = prefix + ":" + name
    children = ""
    if result_variable:
        children = elem("SQLTask:ResultBinding", {
            "SQLTask:ResultName": "0",
            "SQLTask:DtsVariableName": result_variable,
        }, empty=True)
    data_attrs = {
        "xmlns:SQLTask": "www.microsoft.com/sqlserver/dts/tasks/sqltask",
        "SQLTask:Connection": ole_guid,
        "SQLTask:SqlStmtSourceType": "Variable",
        "SQLTask:SqlStatementSource": "User::" + source_var,
        "SQLTask:ResultType": "ResultSetType_SingleRow" if result_variable else "ResultSetType_None",
    }
    return elem("DTS:Executable", {
        "DTS:refId": prefix + "\\" + name,
        "DTS:CreationName": "Microsoft.ExecuteSQLTask",
        "DTS:Description": "Execute SQL Task",
        "DTS:DTSID": guid("task:" + seed),
        "DTS:ExecutableType": "Microsoft.ExecuteSQLTask",
        "DTS:LocaleID": "-1",
        "DTS:ObjectName": name,
    },
        elem("DTS:Variables", {}, empty=True)
        + elem("DTS:ObjectData", {}, elem("SQLTask:SqlTaskData", data_attrs,
                                          children, empty=not children))
    )


def pipeline_attrs(name):
    return {
        "DTS:refId": CONTEXT[1] + "\\" + name,
        "DTS:CreationName": "Microsoft.Pipeline",
        "DTS:DelayValidation": "True",
        "DTS:DTSID": guid("task:" + CONTEXT[0] + ":" + name),
        "DTS:ExecutableType": "Microsoft.Pipeline",
        "DTS:LocaleID": "-1",
        "DTS:ObjectName": name,
        "DTS:TaskContact": "Performs high-performance data extraction, transformation and loading;Microsoft Corporation; Microsoft SQL Server; (C) Microsoft Corporation; All Rights Reserved;http://www.microsoft.com/sql/support/default.asp;1",
    }


def lineage(prefix, component, port, name):
    return "%s\\%s.%s.Columns[%s]" % (prefix, component, port, name)


def data_type_of(col):
    if col in NTEXT_COLUMNS:
        return ("wstr", "4000", "130")
    return ("wstr", "255", "130")


def source_component(prefix, cols):
    out_name = "Flat File Source Output"
    out_port = "Outputs[%s]" % out_name
    out_cols = []
    ext_cols = []
    for col in cols:
        dt, length, _ = data_type_of(col)
        attrs = {
            "refId": lineage(prefix, "Flat File Source", out_port, col),
            "dataType": dt,
            "errorOrTruncationOperation": "Conversion",
            "errorRowDisposition": "FailComponent",
            "externalMetadataColumnId": prefix + "\\Flat File Source.Outputs[" + out_name + "].ExternalColumns[" + col + "]",
            "lineageId": lineage(prefix, "Flat File Source", out_port, col),
            "name": col,
            "truncationRowDisposition": "FailComponent",
        }
        if length:
            attrs["length"] = length
        props = (
            elem("property", {
                "dataType": "System.Boolean",
                "description": "Indicates whether the column uses the faster, locale-neutral parsing routines.",
                "name": "FastParse",
            }, "false")
            + elem("property", {
                "dataType": "System.Boolean",
                "description": "Indicates whether the data is in binary format.",
                "name": "UseBinaryFormat",
            }, "false")
        )
        out_cols.append(elem("outputColumn", attrs, elem("properties", {}, props)))
        ext_attrs = {
            "refId": prefix + "\\Flat File Source.Outputs[" + out_name + "].ExternalColumns[" + col + "]",
            "dataType": dt,
            "name": col,
        }
        if length:
            ext_attrs["length"] = length
        if dt == "text":
            ext_attrs["codePage"] = "65001"
        ext_cols.append(elem("externalMetadataColumn", ext_attrs, empty=True))
    return elem("component", {
        "refId": prefix + "\\Flat File Source",
        "componentClassID": "Microsoft.FlatFileSource",
        "contactInfo": "Flat File Source;Microsoft Corporation; Microsoft SQL Server; (C) Microsoft Corporation; All Rights Reserved; http://www.microsoft.com/sql/support;1",
        "description": "Flat File Source",
        "localeId": "1033",
        "name": "Flat File Source",
        "usesDispositions": "true",
        "version": "1",
    },
        elem("properties", {},
             elem("property", {"dataType": "System.Boolean", "name": "RetainNulls"}, "false")
             + elem("property", {"dataType": "System.String", "name": "FileNameColumnName"}, ""))
        + elem("connections", {}, elem("connection", {
            "refId": prefix + "\\Flat File Source.Connections[FlatFileConnection]",
            "connectionManagerID": "Package.ConnectionManagers[FF_%s]" % CONTEXT[0],
            "connectionManagerRefId": "Package.ConnectionManagers[FF_%s]" % CONTEXT[0],
            "name": "FlatFileConnection",
        }, empty=True))
        + elem("outputs", {},
               elem("output", {
                   "refId": prefix + "\\Flat File Source.Outputs[" + out_name + "]",
                   "name": out_name,
               }, elem("outputColumns", {}, "".join(out_cols))
                   + elem("externalMetadataColumns", {"isUsed": "True"}, "".join(ext_cols)))
               + elem("output", {
                   "refId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output]",
                   "isErrorOut": "true",
                   "name": "Flat File Source Error Output",
               }, elem("outputColumns", {},
                       elem("outputColumn", {
                           "refId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[Flat File Source Error Output Column]",
                           "codePage": "65001",
                           "dataType": "text",
                           "lineageId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[Flat File Source Error Output Column]",
                           "name": "Flat File Source Error Output Column",
                       }, empty=True)
                       + elem("outputColumn", {
                           "refId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[ErrorCode]",
                           "dataType": "i4",
                           "lineageId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[ErrorCode]",
                           "name": "ErrorCode",
                           "specialFlags": "1",
                       }, empty=True)
                       + elem("outputColumn", {
                           "refId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[ErrorColumn]",
                           "dataType": "i4",
                           "lineageId": prefix + "\\Flat File Source.Outputs[Flat File Source Error Output].Columns[ErrorColumn]",
                           "name": "ErrorColumn",
                           "specialFlags": "2",
                       }, empty=True))
                   + elem("externalMetadataColumns", {}, empty=True)))
    )


def script_component_source(index, vsta_project, checksum):
    values = []
    for i in range(30):
        text = (TEMPLATE / ("%02d.txt" % i)).read_text(encoding="utf-8")
        text = text.replace("SC_3135bfb0b3bf460c83f93b645813d067", vsta_project)
        text = text.replace("RowId", "source_row_number")
        text = text.replace("this[14] = value;", "this[%d] = value;" % index)
        text = text.replace("SetNull(14);", "SetNull(%d);" % index)
        values.append(text)
    elements = []
    for value in values:
        elements.append(elem("arrayElement", {"dataType": "System.String"}, "\n<![CDATA[" + value + "]]>\n", raw=True))
    source = elem("property", {
        "dataType": "System.String",
        "description": "Stores the source code of the component",
        "isArray": "true",
        "name": "SourceCode",
        "state": "cdata",
    }, elem("arrayElements", {"arrayElementCount": "30"}, "".join(elements)))

    dll_name = "RowNumberScriptComponent_%s.dll" % CONTEXT[0]
    dll = base64.b64encode((ASSEMBLIES / dll_name).read_bytes()).decode("ascii")
    dll_lines = "\n".join(dll[i:i + 76] for i in range(0, len(dll), 76))
    binary = elem("property", {
        "dataType": "System.String",
        "description": "Stores the binary representation of the component",
        "isArray": "true",
        "name": "BinaryCode",
        "state": "cdata",
    }, elem("arrayElements", {"arrayElementCount": "2"},
            elem("arrayElement", {"dataType": "System.String"}, "\n<![CDATA[" + dll_name + "]]>\n", raw=True)
            + elem("arrayElement", {"dataType": "System.String"}, "\n<![CDATA[" + dll_lines + "]]>\n", raw=True)))
    return (
        source
        + binary
        + elem("property", {
            "dataType": "System.String",
            "description": "Specifies the name of the Microsoft Visual Studio Tools for Applications project. Project names must be unique within a package.",
            "name": "VSTAProjectName",
            "typeConverter": "NOTBROWSABLE",
        }, vsta_project)
        + elem("property", {
            "dataType": "System.String",
            "description": "Specifies the programming language used by the script.",
            "name": "ScriptLanguage",
            "typeConverter": "Microsoft.SqlServer.VSTAHosting.ScriptingLanguages",
        }, "CSharp")
        + elem("property", {
            "dataType": "System.String",
            "description": "Specifies a comma-separated list of read-only variables.",
            "name": "ReadOnlyVariables",
            "UITypeEditor": "Microsoft.DataTransformationServices.Controls.ScriptUIVariablePickerDlg",
        }, "")
        + elem("property", {
            "dataType": "System.String",
            "description": "Specifies a comma-separated list of read/write variables.",
            "name": "ReadWriteVariables",
            "UITypeEditor": "Microsoft.DataTransformationServices.Controls.ScriptUIWriteableVariablePickerDlg",
        }, "")
        + elem("property", {
            "dataType": "System.String",
            "description": "List of breakpoints present on the script.",
            "isArray": "true",
            "name": "BreakpointCollection",
            "typeConverter": "NOTBROWSABLE",
        }, elem("arrayElements", {"arrayElementCount": "0"}, empty=True))
        + elem("property", {
            "dataType": "System.String",
            "description": "Checksum to match component metedata against compiled codes.",
            "name": "MetadataChecksum140",
            "typeConverter": "NOTBROWSABLE",
        }, checksum)
        + elem("property", {"dataType": "System.String", "name": "UserComponentTypeName"}, "Microsoft.ScriptComponentHost")
    )


def script_component(prefix, cols):
    vsta_project = VSTA_BY_TABLE[CONTEXT[0]]
    checksum = short("metadata_" + CONTEXT[0])[:4]
    in_cols = []
    out_cols = []
    for i, col in enumerate(cols):
        dt, length, _ = data_type_of(col)
        in_attrs = {
            "id": str(i),
            "refId": lineage(prefix, "Script Component", "Inputs[Input 0]", col),
            "cachedDataType": dt,
            "cachedName": col,
            "lineageId": lineage(prefix, "Flat File Source", "Outputs[Flat File Source Output]", col),
        }
        if length:
            in_attrs["cachedLength"] = length
        in_cols.append(elem("inputColumn", in_attrs, empty=True))
    out_cols.append(elem("outputColumn", {
        "id": str(len(cols)),
        "refId": lineage(prefix, "Script Component", "Outputs[Output 0]", "source_row_number"),
        "dataType": "i4",
        "lineageId": lineage(prefix, "Script Component", "Outputs[Output 0]", "source_row_number"),
        "name": "source_row_number",
    }, empty=True))
    return elem("component", {
        "refId": prefix + "\\Script Component",
        "componentClassID": "Microsoft.SqlServer.Dts.Pipeline.ScriptComponentHost, Microsoft.SqlServer.TxScript, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91",
        "contactInfo": "Script Component;Microsoft Corporation; Microsoft SQL Server; Microsoft Corporation; All Rights Reserved; http://www.microsoft.com/sql/support;10",
        "description": "Adds source_row_number",
        "name": "Script Component",
        "version": "10",
    },
        elem("properties", {}, script_component_source(len(cols), vsta_project, checksum))
        + elem("inputs", {}, elem("input", {
            "refId": prefix + "\\Script Component.Inputs[Input 0]",
            "hasSideEffects": "true",
            "name": "Input 0",
        }, elem("inputColumns", {}, "".join(in_cols)) + elem("externalMetadataColumns", {}, empty=True)))
        + elem("outputs", {}, elem("output", {
            "refId": prefix + "\\Script Component.Outputs[Output 0]",
            "name": "Output 0",
            "synchronousInputId": prefix + "\\Script Component.Inputs[Input 0]",
        }, elem("outputColumns", {}, "".join(out_cols)) + elem("externalMetadataColumns", {}, empty=True)))
    )


def row_count_component(prefix, cols):
    in_cols = []
    all_cols = cols + ["source_row_number"]
    for col in all_cols:
        attrs = {
            "refId": lineage(prefix, "Row Count", "Inputs[Row Count Input]", col),
            "cachedDataType": "i4" if col == "source_row_number" else data_type_of(col)[0],
            "cachedName": col,
            "lineageId": lineage(prefix, "Script Component", "Outputs[Output 0]", col) if col == "source_row_number" else lineage(prefix, "Flat File Source", "Outputs[Flat File Source Output]", col),
        }
        if col != "source_row_number" and data_type_of(col)[1]:
            attrs["cachedLength"] = data_type_of(col)[1]
        in_cols.append(elem("inputColumn", attrs, empty=True))
    return elem("component", {
        "refId": prefix + "\\Row Count",
        "componentClassID": "Microsoft.RowCount",
        "contactInfo": "Row Count;Microsoft Corporation; Microsoft SQL Server; (C) Microsoft Corporation; All Rights Reserved; http://www.microsoft.com/sql/support;1",
        "description": "Counts rows read",
        "name": "Row Count",
    },
        elem("properties", {}, elem("property", {
            "dataType": "System.String",
            "name": "VariableName",
        }, "User::rows_read"))
        + elem("inputs", {}, elem("input", {
            "refId": prefix + "\\Row Count.Inputs[Row Count Input]",
            "name": "Row Count Input",
        }, elem("inputColumns", {}, "".join(in_cols)) + elem("externalMetadataColumns", {}, empty=True)))
        + elem("outputs", {}, elem("output", {
            "refId": prefix + "\\Row Count.Outputs[Row Count Output]",
            "name": "Row Count Output",
            "synchronousInputId": prefix + "\\Row Count.Inputs[Row Count Input]",
        }, elem("outputColumns", {}, empty=True) + elem("externalMetadataColumns", {}, empty=True)))
    )


AUDIT_COLS = [
    ("source_file", "wstr", "260", '"FILE_NAME"'),
    ("source_checksum", "str", "64", "(DT_STR,64,1252)@[User::checksum]"),
    ("source_batch_id", "str", "100", "(DT_STR,100,1252)@[$Package::batch_id]"),
    ("ingested_at", "dbTimeStamp2", None, "(DT_DBTIMESTAMP2,0)GETDATE()"),
]


def derived_column(prefix, cols, file_name):
    in_cols = []
    for col in cols + ["source_row_number"]:
        attrs = {
            "refId": lineage(prefix, "Derived Column", "Inputs[Derived Column Input]", col),
            "cachedDataType": "i4" if col == "source_row_number" else data_type_of(col)[0],
            "cachedName": col,
            "lineageId": lineage(prefix, "Script Component", "Outputs[Output 0]", col) if col == "source_row_number" else lineage(prefix, "Flat File Source", "Outputs[Flat File Source Output]", col),
        }
        if col != "source_row_number" and data_type_of(col)[1]:
            attrs["cachedLength"] = data_type_of(col)[1]
        in_cols.append(elem("inputColumn", attrs, empty=True))
    out_cols = []
    for name, dt, length, expression in AUDIT_COLS:
        expr = expression.replace("FILE_NAME", file_name)
        attrs = {
            "refId": lineage(prefix, "Derived Column", "Outputs[Derived Column Output]", name),
            "dataType": dt,
            "errorOrTruncationOperation": "Computation",
            "errorRowDisposition": "IgnoreFailure",
            "lineageId": lineage(prefix, "Derived Column", "Outputs[Derived Column Output]", name),
            "name": name,
            "truncationRowDisposition": "IgnoreFailure",
        }
        if length:
            attrs["length"] = length
        if dt == "str":
            attrs["codePage"] = "1252"
        if dt == "dbTimeStamp2":
            attrs["scale"] = "0"
        props = elem("property", {
            "containsID": "true",
            "dataType": "System.String",
            "description": "Derived Column Expression",
            "name": "Expression",
        }, xt(expr))
        friendly = expr.replace("@[User::checksum]", "checksum").replace("@[$Package::batch_id]", "batch_id")
        props += elem("property", {
            "containsID": "true",
            "dataType": "System.String",
            "description": "Derived Column Friendly Expression",
            "expressionType": "Notify",
            "name": "FriendlyExpression",
        }, xt(friendly))
        out_cols.append(elem("outputColumn", attrs, elem("properties", {}, props)))
    return elem("component", {
        "refId": prefix + "\\Derived Column",
        "componentClassID": "Microsoft.DerivedColumn",
        "contactInfo": "Derived Column;Microsoft Corporation; Microsoft SQL Server; (C) Microsoft Corporation; All Rights Reserved; http://www.microsoft.com/sql/support;0",
        "description": "Adds audit columns",
        "name": "Derived Column",
        "usesDispositions": "true",
    },
        elem("inputs", {}, elem("input", {
            "refId": prefix + "\\Derived Column.Inputs[Derived Column Input]",
            "description": "Input to the Derived Column Transformation",
            "name": "Derived Column Input",
        }, elem("inputColumns", {}, "".join(in_cols)) + elem("externalMetadataColumns", {}, empty=True)))
        + elem("outputs", {},
               elem("output", {
                   "refId": prefix + "\\Derived Column.Outputs[Derived Column Output]",
                   "description": "Default Output of the Derived Column Transformation",
                   "exclusionGroup": "1",
                   "name": "Derived Column Output",
                   "synchronousInputId": prefix + "\\Derived Column.Inputs[Derived Column Input]",
               }, elem("outputColumns", {}, "".join(out_cols)) + elem("externalMetadataColumns", {}, empty=True))
               + elem("output", {
                   "refId": prefix + "\\Derived Column.Outputs[Derived Column Error Output]",
                   "description": "Error Output of the Derived Column Transformation",
                   "exclusionGroup": "1",
                   "isErrorOut": "true",
                   "name": "Derived Column Error Output",
                   "synchronousInputId": prefix + "\\Derived Column.Inputs[Derived Column Input]",
               }, elem("outputColumns", {},
                       elem("outputColumn", {
                           "refId": prefix + "\\Derived Column.Outputs[Derived Column Error Output].Columns[ErrorCode]",
                           "dataType": "i4",
                           "lineageId": prefix + "\\Derived Column.Outputs[Derived Column Error Output].Columns[ErrorCode]",
                           "name": "ErrorCode",
                           "specialFlags": "1",
                       }, empty=True)
                       + elem("outputColumn", {
                           "refId": prefix + "\\Derived Column.Outputs[Derived Column Error Output].Columns[ErrorColumn]",
                           "dataType": "i4",
                           "lineageId": prefix + "\\Derived Column.Outputs[Derived Column Error Output].Columns[ErrorColumn]",
                           "name": "ErrorColumn",
                           "specialFlags": "2",
                       }, empty=True))
                  + elem("externalMetadataColumns", {}, empty=True)))
    )


def ole_destination(prefix, table, cols, ole_guid):
    input_cols = []
    external_cols = []
    all_cols = [(c, data_type_of(c)[0], data_type_of(c)[1]) for c in cols]
    all_cols += [("source_file", "wstr", "260"), ("source_checksum", "str", "64"),
                  ("source_row_number", "i4", None), ("source_batch_id", "str", "100"),
                  ("ingested_at", "dbTimeStamp2", None)]
    for name, dt, length in all_cols:
        if name == "source_row_number":
            lineage_id = lineage(prefix, "Script Component", "Outputs[Output 0]", name)
        elif name in [a[0] for a in AUDIT_COLS]:
            lineage_id = lineage(prefix, "Derived Column", "Outputs[Derived Column Output]", name)
        else:
            lineage_id = lineage(prefix, "Flat File Source", "Outputs[Flat File Source Output]", name)
        attrs = {
            "refId": lineage(prefix, "OLE DB Destination", "Inputs[OLE DB Destination Input]", name),
            "cachedDataType": dt,
            "cachedName": name,
            "externalMetadataColumnId": prefix + "\\OLE DB Destination.Inputs[OLE DB Destination Input].ExternalColumns[" + name + "]",
            "lineageId": lineage_id,
        }
        if length:
            attrs["cachedLength"] = length
        if dt == "str":
            attrs["codePage"] = "1252"
        if dt == "dbTimeStamp2":
            attrs["scale"] = "0"
        input_cols.append(elem("inputColumn", attrs, empty=True))
        ext_attrs = {
            "refId": prefix + "\\OLE DB Destination.Inputs[OLE DB Destination Input].ExternalColumns[" + name + "]",
            "dataType": dt,
            "name": name,
        }
        if length:
            ext_attrs["length"] = length
        if dt == "str":
            ext_attrs["codePage"] = "1252"
        if dt == "dbTimeStamp2":
            ext_attrs["scale"] = "0"
        external_cols.append(elem("externalMetadataColumn", ext_attrs, empty=True))
    props = (
        elem("property", {"dataType": "System.Int32", "name": "CommandTimeout"}, "0")
        + elem("property", {"dataType": "System.String", "name": "OpenRowset"}, "[staging].[%s_load]" % table)
        + elem("property", {"dataType": "System.String", "name": "OpenRowsetVariable"}, "")
        + elem("property", {"dataType": "System.String", "name": "SqlCommand", "UITypeEditor": "Microsoft.DataTransformationServices.Controls.ModalMultilineStringEditor"}, "")
        + elem("property", {"dataType": "System.Int32", "name": "DefaultCodePage"}, "65001")
        + elem("property", {"dataType": "System.Boolean", "name": "AlwaysUseDefaultCodePage"}, "false")
        + elem("property", {"dataType": "System.Int32", "name": "AccessMode", "typeConverter": "AccessMode"}, "3")
        + elem("property", {"dataType": "System.Boolean", "name": "FastLoadKeepIdentity"}, "false")
        + elem("property", {"dataType": "System.Boolean", "name": "FastLoadKeepNulls"}, "true")
        + elem("property", {"dataType": "System.String", "name": "FastLoadOptions"}, "TABLOCK")
        + elem("property", {"dataType": "System.Int32", "name": "FastLoadMaxInsertCommitSize"}, "50000")
    )
    return elem("component", {
        "refId": prefix + "\\OLE DB Destination",
        "componentClassID": "Microsoft.OLEDBDestination",
        "contactInfo": "OLE DB Destination;Microsoft Corporation; Microsoft SQL Server; (C) Microsoft Corporation; All Rights Reserved; http://www.microsoft.com/sql/support;4",
        "description": "OLE DB Destination",
        "name": "OLE DB Destination",
        "usesDispositions": "true",
        "version": "4",
    },
        elem("properties", {}, props)
        + elem("connections", {}, elem("connection", {
            "refId": prefix + "\\OLE DB Destination.Connections[OleDbConnection]",
            "connectionManagerID": "Package.ConnectionManagers[OlistDW]",
            "connectionManagerRefId": "Package.ConnectionManagers[OlistDW]",
            "description": "The OLE DB runtime connection used to access the database.",
            "name": "OleDbConnection",
        }, empty=True))
        + elem("inputs", {}, elem("input", {
            "refId": prefix + "\\OLE DB Destination.Inputs[OLE DB Destination Input]",
            "errorOrTruncationOperation": "Insert",
            "errorRowDisposition": "FailComponent",
            "hasSideEffects": "true",
            "name": "OLE DB Destination Input",
        }, elem("inputColumns", {}, "".join(input_cols))
             + elem("externalMetadataColumns", {"isUsed": "True"}, "".join(external_cols))))
        + elem("outputs", {}, elem("output", {
            "refId": prefix + "\\OLE DB Destination.Outputs[OLE DB Destination Error Output]",
            "description": "Error Output of the OLE DB Destination",
            "exclusionGroup": "1",
            "isErrorOut": "true",
            "name": "OLE DB Destination Error Output",
            "synchronousInputId": prefix + "\\OLE DB Destination.Inputs[OLE DB Destination Input]",
        }, elem("outputColumns", {},
                elem("outputColumn", {
                    "refId": prefix + "\\OLE DB Destination.Outputs[OLE DB Destination Error Output].Columns[ErrorCode]",
                    "dataType": "i4",
                    "lineageId": prefix + "\\OLE DB Destination.Outputs[OLE DB Destination Error Output].Columns[ErrorCode]",
                    "name": "ErrorCode",
                    "specialFlags": "1",
                }, empty=True)
                + elem("outputColumn", {
                    "refId": prefix + "\\OLE DB Destination.Outputs[OLE DB Destination Error Output].Columns[ErrorColumn]",
                    "dataType": "i4",
                    "lineageId": prefix + "\\OLE DB Destination.Outputs[OLE DB Destination Error Output].Columns[ErrorColumn]",
                    "name": "ErrorColumn",
                    "specialFlags": "2",
                }, empty=True))
           + elem("externalMetadataColumns", {}, empty=True))))


def paths(prefix):
    items = [
        ("Flat File Source Output", prefix + "\\Flat File Source.Outputs[Flat File Source Output]", prefix + "\\Script Component.Inputs[Input 0]"),
        ("Output 0", prefix + "\\Script Component.Outputs[Output 0]", prefix + "\\Row Count.Inputs[Row Count Input]"),
        ("Row Count Output", prefix + "\\Row Count.Outputs[Row Count Output]", prefix + "\\Derived Column.Inputs[Derived Column Input]"),
        ("Derived Column Output", prefix + "\\Derived Column.Outputs[Derived Column Output]", prefix + "\\OLE DB Destination.Inputs[OLE DB Destination Input]"),
    ]
    return elem("paths", {}, "".join(
        elem("path", {
            "refId": prefix + ".Paths[%s%d]" % (name, i),
            "endId": end,
            "name": name,
            "startId": start,
        }, empty=True) for i, (name, start, end) in enumerate(items)
    ))


def data_flow_task(table, cols, file_name, ole_guid):
    prefix = CONTEXT[1] + "\\DFT_%s" % table
    components = (
        source_component(prefix, cols)
        + script_component(prefix, cols)
        + row_count_component(prefix, cols)
        + derived_column(prefix, cols, file_name)
        + ole_destination(prefix, table, cols, ole_guid)
    )
    return elem("DTS:Executable", pipeline_attrs("DFT_%s" % table),
                dts_prop("DefaultBufferMaxRows", "5000", "3")
                + dts_prop("DefaultBufferSize", "5242880", "3")
                + elem("DTS:Variables", {}, empty=True)
                + elem("DTS:ObjectData", {}, elem("pipeline", {"version": "1"},
                        elem("components", {}, components) + paths(prefix))))


def constraint(name, from_name, to_name):
    return elem("DTS:PrecedenceConstraint", {
        "DTS:refId": CONTEXT[1] + "\\PrecedenceConstraints[%s]" % name,
        "DTS:CreationName": "",
        "DTS:DTSID": guid("pc:%s:%s" % (CONTEXT[0], name)),
        "DTS:From": CONTEXT[1] + "\\" + from_name,
        "DTS:LogicalAnd": "True",
        "DTS:ObjectName": name,
        "DTS:To": CONTEXT[1] + "\\" + to_name,
    }, empty=True)


def error_handler(ole_guid):
    global CONTEXT
    CONTEXT = ("OnError", "Package.EventHandlers[OnError]")
    prefix = CONTEXT[1]
    propagate = elem("DTS:Variable", {
        "DTS:CreationName": "",
        "DTS:Description": "The propagate property of the event",
        "DTS:DTSID": guid("var:propagate"),
        "DTS:IncludeInDebugDump": "6789",
        "DTS:Namespace": "System",
        "DTS:ObjectName": "Propagate",
    }, elem("DTS:VariableValue", {"DTS:DataType": "11"}, "-1"))
    sql_error = variable("sql_error", "", "8", ERROR_EXPR)
    task = sql_task("SQL_OnError", "sql_error", ole_guid, ref_prefix=prefix)
    return elem("DTS:EventHandlers", {},
                elem("DTS:EventHandler", {
                    "DTS:refId": prefix,
                    "DTS:CreationName": "OnError",
                    "DTS:DTSID": guid("handler:OnError"),
                    "DTS:EventID": "0",
                    "DTS:EventName": "OnError",
                    "DTS:LocaleID": "-1",
                },
                    elem("DTS:Variables", {}, propagate + sql_error)
                    + elem("DTS:Executables", {}, task)))


def sequence(table, file_name, cols, required, ole_guid):
    global CONTEXT
    CONTEXT = (table, "Package\\SEQ_%s" % table)
    variables = (
        variable("current_file", file_name)
        + variable("current_table", table)
        + variable("required_columns", ",".join(required))
        + variable("checksum", "")
        + variable("file_rows", "0", "20")
        + variable("rows_read", "0", "20")
        + variable("rows_loaded", "0", "20")
        + variable("column_list", ",".join(cols))
        + variable("sql_swap", "", "8", SWAP_EXPR)
        + variable("sql_audit", "", "8", AUDIT_EXPR)
    )
    check = script_task("check", "ST_Check_%s" % table, "CheckCsvHeader.dll", "CheckCsvHeader.cs",
                        "User::var_raw_dir,User::current_file,User::current_table",
                        "User::column_list,User::rows_read,User::rows_loaded")
    sha = script_task("sha", "ST_Sha_%s" % table, "ComputeSha256.dll", "ComputeSha256.cs",
                      "User::var_raw_dir,User::current_file",
                      "User::checksum,User::file_rows")
    dft = data_flow_task(table, cols, file_name, ole_guid)
    swap = sql_task("SQL_Swap_%s" % table, "sql_swap", ole_guid,
                    result_variable="User::rows_loaded")
    audit = sql_task("SQL_Audit_%s" % table, "sql_audit", ole_guid)
    constraints = elem("DTS:PrecedenceConstraints", {},
        constraint("check_%s" % table, "ST_Check_%s" % table, "ST_Sha_%s" % table)
        + constraint("sha_%s" % table, "ST_Sha_%s" % table, "DFT_%s" % table)
        + constraint("dft_%s" % table, "DFT_%s" % table, "SQL_Swap_%s" % table)
        + constraint("swap_%s" % table, "SQL_Swap_%s" % table, "SQL_Audit_%s" % table)
    )
    return elem("DTS:Executable", {
        "DTS:refId": "Package\\SEQ_%s" % table,
        "DTS:CreationName": "STOCK:SEQUENCE",
        "DTS:DTSID": guid("container:%s" % table),
        "DTS:ExecutableType": "STOCK:SEQUENCE",
        "DTS:LocaleID": "-1",
        "DTS:ObjectName": "SEQ_%s" % table,
    },
        elem("DTS:Variables", {}, variables)
        + elem("DTS:Executables", {}, check + sha + dft + swap + audit)
        + constraints
    )


def build():
    global CONTEXT
    ole_guid = guid("cm:ole")
    root_attrs = {
        "xmlns:DTS": "www.microsoft.com/SqlServer/Dts",
        "DTS:refId": "Package",
        "DTS:CreationDate": "11/25/2026 12:00:00 PM",
        "DTS:CreationName": "Microsoft.Package",
        "DTS:CreatorComputerName": "BI-GENAI",
        "DTS:CreatorName": "BI-GENAI\\bi-genai",
        "DTS:DTSID": guid("package:Ingest_Staging"),
        "DTS:ExecutableType": "Microsoft.Package",
        "DTS:LastModifiedProductVersion": "17.0.1016.0",
        "DTS:LocaleID": "1033",
        "DTS:ObjectName": "Ingest_Staging",
        "DTS:VersionBuild": "1",
        "DTS:VersionGUID": guid("packageversion:Ingest_Staging"),
        "DTS:ProtectionLevel": "0",
    }
    properties = dts_prop("PackageFormatVersion", "8")
    sequences = "".join(sequence(t, f, c, r, ole_guid) for t, f, c, r in TABLES)
    CONTEXT = ("package", "Package")
    finish = sql_task("SQL_Finish", "sql_finish", ole_guid)
    executables = sequences + finish
    seq_order = [
        "category_translation", "sellers", "customers", "order_payments",
        "products", "order_items", "orders", "order_reviews", "geolocation",
    ]
    constraints = "".join(
        constraint("seq_%s_to_%s" % (a, b), "SEQ_%s" % a, "SEQ_%s" % b)
        for a, b in zip(seq_order, seq_order[1:])
    )
    constraints += constraint("seq_to_finish", "SEQ_%s" % seq_order[-1], "SQL_Finish")
    package_constraints = elem("DTS:PrecedenceConstraints", {}, constraints)
    handlers = error_handler(ole_guid)
    design = elem("DTS:DesignTimeProperties", {},
                  "\n<![CDATA[<?xml version=\"1.0\"?>\n<Objects Version=\"8\">\n</Objects>]]>\n", raw=True)
    body = (properties + connection_managers(ole_guid) + package_parameters()
            + package_variables()
            + elem("DTS:Executables", {}, executables)
            + package_constraints + handlers + design)
    xml = '<?xml version="1.0"?>\n' + elem("DTS:Executable", root_attrs, body)
    OUT.write_text(xml, encoding="utf-8")
    print("Wrote %s (%d bytes)" % (OUT, OUT.stat().st_size))


CONTEXT = ("init", "Package")
build()
