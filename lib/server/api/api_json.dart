import "dart:convert";
import "dart:io";

import "api_types.dart";

/// Small JSON request bodies (a login, a "delete these" list) are capped hard;
/// file contents never go through here — uploads stream straight to storage.
const int maxJsonBodyBytes = 16 * 1024;

/// Reads the request body as a JSON object, or throws an [ApiReject]:
/// 413 if it's too big, 400 if it isn't a JSON object.
Future<Map<String, Object?>> readJsonObject(ApiRequest request) async {
  final List<int>? bytes = await request.readBounded(maxJsonBodyBytes);
  if (bytes == null) {
    throw ApiReject(
      ApiResponse.error(HttpStatus.requestEntityTooLarge, "payload_too_large", closeConnection: true),
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "bad_request"));
  }
  if (decoded is! Map<String, Object?>) {
    throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "bad_request"));
  }
  return decoded;
}
