// 值这一层的白盒测试：`Row` 的字段是私有的（只有查询结果会构造它），
// 所以构造 `Row` 只能从包内做。

///|
fn decode_int(v : @value.Value) -> Int raise ValueError {
  FromValue::from_value(v)
}

///|
test "往返：内建类型 ToValue -> FromValue" {
  assert_true(ToValue::to_value(true) == @value.Value::Integer(1L))
  assert_true(ToValue::to_value(42) == @value.Value::Integer(42L))
  assert_true(ToValue::to_value(7L) == @value.Value::Integer(7L))
  assert_true(ToValue::to_value(1.5) == @value.Value::Real(1.5))
  assert_true(ToValue::to_value("hi") == @value.Value::Text("hi"))
  assert_true(ToValue::to_value(b"\x01\x02") == @value.Value::Blob(b"\x01\x02"))
  // Option：None -> Null
  assert_true(ToValue::to_value((None : Int?)) == @value.Value::Null)
  assert_true(ToValue::to_value(Some(3)) == @value.Value::Integer(3L))
  assert_true(
    ToValue::to_value(Timestamp(1000000L)) == @value.Value::Integer(1000000L),
  )

  let b : Bool = FromValue::from_value(@value.Value::Integer(1L))
  assert_true(b)
  let i : Int = FromValue::from_value(@value.Value::Integer(42L))
  assert_true(i == 42)
  let i64 : Int64 = FromValue::from_value(@value.Value::Integer(7L))
  assert_true(i64 == 7L)
  let d : Double = FromValue::from_value(@value.Value::Real(1.5))
  assert_true(d == 1.5)
  let s : String = FromValue::from_value(@value.Value::Text("hi"))
  assert_true(s == "hi")
  let by : Bytes = FromValue::from_value(@value.Value::Blob(b"\x01\x02"))
  assert_true(by == b"\x01\x02")
  let n : Int? = FromValue::from_value(@value.Value::Null)
  assert_true(n is None)
  let ts : Timestamp = FromValue::from_value(@value.Value::Integer(1000000L))
  assert_true(ts == Timestamp(1000000L))
}

///|
test "类型不符时抛 ValueError（不是 panic、不是静默错值）" {
  let mut got = false
  try ignore(decode_int(@value.Value::Text("nope"))) catch {
    ValueError::ValueError(_) => got = true
  } noraise {
    _ => ()
  }
  assert_true(got)
}

///|
test "Timestamp 约定：整数微秒；Integer / Real 都能解" {
  let ts : Timestamp = FromValue::from_value(@value.Value::Real(2.0))
  assert_true(ts == Timestamp(2L))
}

///|
test "Json 约定：存成 Text(JSON 文本)，读回可再解析" {
  let j : Json = @json.parse("{\"a\":1}")
  let v = ToValue::to_value(j)
  assert_true(v is @value.Value::Text(_))
  let back : Json = FromValue::from_value(v)
  assert_true(back.stringify() == j.stringify())
}

///|
test "FromRow：元组按列顺序映射，列元信息可读" {
  let row : Row = {
    values: [
      @value.Value::Integer(1L),
      @value.Value::Text("alice"),
      @value.Value::Null,
    ],
    columns: [
      @value.Column::{ name: "id", decltype: "INTEGER", },
      @value.Column::{ name: "name", decltype: "TEXT", },
    ],
  }
  assert_true(row.len() == 3)
  assert_true(row.columns().length() == 2)
  assert_true(row.columns()[0].name == "id")
  assert_true(row.value(0) == @value.Value::Integer(1L))

  let (id, name) : (Int, String) = FromRow::from_row(row)
  assert_true(id == 1)
  assert_true(name == "alice")

  // 3 元组 + Option 列
  let (a, b, c) : (Int, String, Int?) = FromRow::from_row(row)
  assert_true(a == 1)
  assert_true(b == "alice")
  assert_true(c is None)
}

///|
test "往返：更宽的整数族 / 浮点 / 字符 / Unit / Ref" {
  assert_true(ToValue::to_value((1 : Byte)) == @value.Value::Integer(1L))
  assert_true(ToValue::to_value((2 : Int16)) == @value.Value::Integer(2L))
  assert_true(ToValue::to_value((3 : UInt)) == @value.Value::Integer(3L))
  assert_true(ToValue::to_value((4 : UInt16)) == @value.Value::Integer(4L))
  assert_true(ToValue::to_value((5 : UInt64)) == @value.Value::Integer(5L))
  assert_true(ToValue::to_value((1.5 : Float)) == @value.Value::Real(1.5))
  assert_true(ToValue::to_value('a') == @value.Value::Text("a"))
  assert_true(ToValue::to_value(()) == @value.Value::Null)
  let r : Ref[Int] = Ref(9)
  assert_true(ToValue::to_value(r) == @value.Value::Integer(9L))

  let b : Byte = FromValue::from_value(@value.Value::Integer(1L))
  assert_true(b == (1 : Byte))
  let i16 : Int16 = FromValue::from_value(@value.Value::Integer(2L))
  assert_true(i16 == (2 : Int16))
  let u : UInt = FromValue::from_value(@value.Value::Integer(3L))
  assert_true(u == (3 : UInt))
  let u16 : UInt16 = FromValue::from_value(@value.Value::Integer(4L))
  assert_true(u16 == (4 : UInt16))
  let u64 : UInt64 = FromValue::from_value(@value.Value::Integer(5L))
  assert_true(u64 == (5 : UInt64))
  let c : Char = FromValue::from_value(@value.Value::Text("a"))
  assert_true(c == 'a')
  let rr : Ref[Int] = FromValue::from_value(@value.Value::Integer(9L))
  assert_true(rr.val == 9)
}

///|
test "JSON 族：Array / Map 落成 JSON 文本（Value::Text）" {
  let v = ToValue::to_value([1, 2, 3])
  assert_true(v is @value.Value::Text(_))
  let back : Array[Int] = FromValue::from_value(v)
  assert_true(back == [1, 2, 3])

  let m : Map[String, Int] = { "a": 1 }
  let mv = ToValue::to_value(m)
  assert_true(mv is @value.Value::Text(_))
  let mback : Map[String, Int] = FromValue::from_value(mv)
  assert_true(mback["a"] == 1)
}
