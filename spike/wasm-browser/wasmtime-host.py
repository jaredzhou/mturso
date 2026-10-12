"""spike: 同一份 MoonBit wasm 在 **wasmtime** 里跑，宿主用 Python 直接调 Turso 的 C ABI。

回答的问题：Node 能跑的东西，wasmtime 之类的 runtime 是不是一样的用法？
结论：**module 本身与 runtime 无关**（标准 wasm1 + 我们的宿主导入），换 runtime 只需要
换宿主实现；而且这里宿主是同步的（C ABI 直接调），所以连 Node 版那两个线程 + Atomics
都不需要。
"""

import ctypes

from wasmtime import Engine, Func, FuncType, Instance, Module, Store, ValType

LIB = "/home/jared/turso/libs/libturso_sync_sdk_kit.so"
WASM = (
    "/home/jared/turso/spike/wasm-browser/moonbit/_build/wasm/debug/build/mturso-wasm-spike.wasm"
)

lib = ctypes.CDLL(LIB)


class TursoConfig(ctypes.Structure):
    _fields_ = [("logger", ctypes.c_void_p), ("log_level", ctypes.c_char_p)]


class TursoDbConfig(ctypes.Structure):
    _fields_ = [
        ("async_io", ctypes.c_uint64),
        ("path", ctypes.c_char_p),
        ("experimental_features", ctypes.c_char_p),
        ("vfs", ctypes.c_char_p),
        ("encryption_cipher", ctypes.c_char_p),
        ("encryption_hexkey", ctypes.c_char_p),
        ("page_codec", ctypes.c_void_p),
        ("open_flags", ctypes.c_uint32),
    ]


def proto(name, res, args):
    fn = getattr(lib, name)
    fn.restype = res
    fn.argtypes = args
    return fn


P_CHAR_P = ctypes.POINTER(ctypes.c_char_p)
proto("turso_setup", ctypes.c_int32, [ctypes.POINTER(TursoConfig), P_CHAR_P])
proto(
    "turso_database_new",
    ctypes.c_int32,
    [ctypes.POINTER(TursoDbConfig), ctypes.POINTER(ctypes.c_void_p), P_CHAR_P],
)
proto("turso_database_open", ctypes.c_int32, [ctypes.c_void_p, P_CHAR_P])
proto(
    "turso_database_connect",
    ctypes.c_int32,
    [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), P_CHAR_P],
)
proto(
    "turso_connection_prepare_single",
    ctypes.c_int32,
    [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), P_CHAR_P],
)
proto("turso_statement_step", ctypes.c_int32, [ctypes.c_void_p, P_CHAR_P])
proto("turso_statement_run_io", ctypes.c_int32, [ctypes.c_void_p, P_CHAR_P])
proto("turso_statement_finalize", ctypes.c_int32, [ctypes.c_void_p, P_CHAR_P])
proto("turso_statement_column_count", ctypes.c_int64, [ctypes.c_void_p])
proto("turso_statement_row_value_kind", ctypes.c_int32, [ctypes.c_void_p, ctypes.c_size_t])
proto("turso_statement_row_value_int", ctypes.c_int64, [ctypes.c_void_p, ctypes.c_size_t])
proto("turso_statement_row_value_double", ctypes.c_double, [ctypes.c_void_p, ctypes.c_size_t])
proto("turso_statement_row_value_bytes_count", ctypes.c_int64, [ctypes.c_void_p, ctypes.c_size_t])
proto(
    "turso_statement_row_value_bytes_ptr", ctypes.c_char_p, [ctypes.c_void_p, ctypes.c_size_t]
)

TURSO_OK, TURSO_DONE, TURSO_ROW, TURSO_IO = 0, 1, 2, 3
INTEGER, REAL, TEXT, BLOB = 1, 2, 3, 4

err = ctypes.c_char_p()
if lib.turso_setup(ctypes.byref(TursoConfig(None, None)), ctypes.byref(err)) != TURSO_OK:
    raise RuntimeError(err.value)

db = ctypes.c_void_p()
db_cfg = TursoDbConfig(0, b":memory:", None, None, None, None, None, 0)
if lib.turso_database_new(ctypes.byref(db_cfg), ctypes.byref(db), ctypes.byref(err)) != TURSO_OK:
    raise RuntimeError(err.value)
if lib.turso_database_open(db, ctypes.byref(err)) != TURSO_OK:
    raise RuntimeError(err.value)
conn = ctypes.c_void_p()
if lib.turso_database_connect(db, ctypes.byref(conn), ctypes.byref(err)) != TURSO_OK:
    raise RuntimeError(err.value)


def query(sql):
    """照抄 ffi/stub.c 的 do_query：结果渲染成「行内制表符、行间换行」。"""
    stmt = ctypes.c_void_p()
    if lib.turso_connection_prepare_single(
        conn, sql.encode(), ctypes.byref(stmt), ctypes.byref(err)
    ) != TURSO_OK:
        raise RuntimeError(err.value)
    rows = []
    while True:
        st = lib.turso_statement_step(stmt, ctypes.byref(err))
        if st == TURSO_IO:
            if lib.turso_statement_run_io(stmt, ctypes.byref(err)) != TURSO_OK:
                raise RuntimeError(err.value)
            continue
        if st == TURSO_DONE:
            break
        if st != TURSO_ROW:
            raise RuntimeError(err.value)
        cells = []
        for i in range(lib.turso_statement_column_count(stmt)):
            kind = lib.turso_statement_row_value_kind(stmt, i)
            if kind == INTEGER:
                cells.append(str(lib.turso_statement_row_value_int(stmt, i)))
            elif kind == REAL:
                cells.append(f"{lib.turso_statement_row_value_double(stmt, i):g}")
            elif kind in (TEXT, BLOB):
                n = lib.turso_statement_row_value_bytes_count(stmt, i)
                p = lib.turso_statement_row_value_bytes_ptr(stmt, i)
                cells.append(p[:n].decode("utf-8", "replace") if (p and n > 0) else "")
            else:
                cells.append("NULL")
        rows.append("\t".join(cells))
    lib.turso_statement_finalize(stmt, ctypes.byref(err))
    return "\n".join(rows)


# ---- 宿主 shim：把 wasm 的四个导入接到上面这个真 Turso 上 -------------------
engine = Engine()
store = Store(engine)
module = Module.from_file(engine, WASM)
state = {"mem": None, "pending": b""}


def read(ptr, length):
    return state["mem"].read(store, ptr, ptr + length)


def exec_(ptr, length):
    sql = read(ptr, length).decode("utf-8", "replace")
    state["pending"] = query(sql).encode()
    return 0


def result_len():
    return len(state["pending"])


def result_copy(out_ptr, cap):
    n = min(len(state["pending"]), cap)
    state["mem"].write(store, state["pending"][:n], out_ptr)
    return n


def log(ptr, length):
    print(read(ptr, length).decode("utf-8", "replace"), flush=True)


i32 = ValType.i32()
# wasmtime-py 的 Instance 要按模块的导入顺序给一个列表（不是 dict）：
# 模块里依次是 mtuoso.result_copy / result_len / log / exec（WebAssembly.Module.imports 查过）
imports = [
    Func(store, FuncType([i32, i32], [i32]), result_copy),
    Func(store, FuncType([], [i32]), result_len),
    Func(store, FuncType([i32, i32], []), log),
    Func(store, FuncType([i32, i32], [i32]), exec_),
]
instance = Instance(store, module, imports)
state["mem"] = instance.exports(store)["memory"]
print("runtime: wasmtime (python), host: Python + Turso C ABI via ctypes")
instance.exports(store)["_start"](store)
