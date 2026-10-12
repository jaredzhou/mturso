// 黑盒：确认 `Value` / `Column` 从根包 re-export 之后，使用方只写 @mturso.* 就能用。

///|
test "Value / Column 从根包 re-export 可用" {
  let v : @mturso.Value = @mturso.Value::Text("hi")
  guard v is @mturso.Value::Text(s) else { fail("Value re-export 失败") }
  assert_true(s == "hi")
  let c : @mturso.Column = @mturso.Column::{ name: "n", decltype: "", }
  assert_true(c.name == "n")
}
