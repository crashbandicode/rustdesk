/// Returns a server-reported API error, or `null` when the payload represents
/// success.
///
/// Some RustDesk-compatible API servers include `"error": false` in a
/// successful response. Treating key presence (or merely non-null) as failure
/// turns that boolean success sentinel into a literal `false` UI error and can
/// poison the shared network-error gate used by dependent models.
Object? apiResponseError(Object? payload) {
  if (payload is! Map || !payload.containsKey('error')) {
    return null;
  }
  final error = payload['error'];
  if (error == null || error == false) {
    return null;
  }
  if (error is String && error.trim().isEmpty) {
    return null;
  }
  return error;
}
