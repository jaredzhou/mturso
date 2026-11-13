// Bearer authentication shared by the native HTTP server and its lifecycle API.

///|
/// Authentication policy for sync-server HTTP endpoints.
///
/// `BearerVerifier` is the extension point for JWT/OIDC validation. It receives
/// the token without the `Bearer` scheme.
pub(all) enum SyncServerAuth {
  Disabled
  BearerToken(String)
  BearerVerifier((String) -> Bool)
}

///|
pub fn SyncServerAuth::is_enabled(self : SyncServerAuth) -> Bool {
  match self {
    Disabled => false
    BearerToken(_) | BearerVerifier(_) => true
  }
}

///|
fn parse_bearer_token(authorization : String) -> String? {
  let value = authorization.trim()
  let (scheme, credentials) = match value.split_once(" ") {
    Some(parts) => parts
    None => return None
  }
  if scheme.to_lower() != "bearer" {
    return None
  }
  let token = credentials.trim()
  if token == "" || token.contains(" ") || token.contains("\t") {
    return None
  }
  Some(token.to_owned())
}

///|
fn constant_time_equal(left : String, right : String) -> Bool {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  let limit = if left_bytes.length() > right_bytes.length() {
    left_bytes.length()
  } else {
    right_bytes.length()
  }
  let mut difference = left_bytes.length() ^ right_bytes.length()
  for i in 0..<limit {
    let left_byte = if i < left_bytes.length() {
      left_bytes[i].to_int()
    } else {
      0
    }
    let right_byte = if i < right_bytes.length() {
      right_bytes[i].to_int()
    } else {
      0
    }
    difference = difference | (left_byte ^ right_byte)
  }
  difference == 0
}

///|
/// Validate an incoming `Authorization` header value.
///
/// Missing, malformed, and incorrect credentials all return `false`.
pub fn SyncServerAuth::verify_header(
  self : SyncServerAuth,
  authorization : String?,
) -> Bool {
  let token = match authorization {
    Some(value) => parse_bearer_token(value)
    None => None
  }
  match self {
    Disabled => true
    BearerToken(expected) =>
      match token {
        Some(actual) => constant_time_equal(expected, actual)
        None => false
      }
    BearerVerifier(verify) =>
      match token {
        Some(actual) => verify(actual)
        None => false
      }
  }
}
