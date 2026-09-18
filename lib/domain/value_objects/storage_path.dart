import "../../core/errors/app_failure.dart";

/// A normalized, traversal-safe path within one [StorageRoot].
///
/// Per `11_Storage_File_Manager_and_Transfer_Engine.md` ("Path model") and
/// `12_Security_...md` ("Path traversal"): untrusted string paths must never
/// reach a [StorageBackend] directly. Every path a remote client, the UI, or
/// a protocol handler supplies goes through [StoragePath.parse], which is the
/// single choke point that rejects:
///   - `..` segments (traversal)
///   - encoded / double-encoded traversal (`%2e%2e`, `%252e%252e`)
///   - absolute-looking segments and empty/whitespace-only segments
///   - backslash-as-separator tricks (mixed separator escape)
///
/// A [StoragePath] that exists was, by construction, already validated —
/// there is no "trusted" vs "untrusted" flavor of this type. This mirrors
/// architecture invariant #7 in `03_System_Architecture_MVVM.md`: "Client
/// paths are never trusted."
final class StoragePath {
  StoragePath._(this.rootId, this.segments);

  /// Root-only path (e.g. the root's listing view).
  factory StoragePath.root(String rootId) => StoragePath._(rootId, const []);

  /// Parses a path string (from the UI, a protocol request, or an API call)
  /// into a validated [StoragePath]. Throws [PathTraversalRejectedFailure] if
  /// the input attempts to escape its root by any of the documented tricks.
  ///
  /// [raw] is expected to already be percent-decoded exactly once by the
  /// caller (protocol handlers are responsible for their own decode step —
  /// this constructor decodes a second time defensively and rejects if doing
  /// so *changes* the string, which catches double-encoding attempts).
  factory StoragePath.parse(String rootId, String raw) {
    final String doubleDecodeCheck = _safeDecode(raw);
    if (doubleDecodeCheck != raw && _safeDecode(doubleDecodeCheck) != doubleDecodeCheck) {
      // Decoding twice kept changing the string — treat as double-encoded
      // traversal and reject outright rather than guessing intent.
      throw const PathTraversalRejectedFailure(
        debugDetail: "possible double-encoded path",
      );
    }

    final String normalizedSeparators = raw.replaceAll("\\", "/");
    final List<String> rawSegments = normalizedSeparators.split("/");

    final List<String> segments = <String>[];
    for (final String rawSegment in rawSegments) {
      if (rawSegment.isEmpty) continue; // collapse //, leading/trailing /
      final String segment = _safeDecode(rawSegment).trim();
      if (segment.isEmpty) continue;
      if (segment == ".") continue;
      if (segment == "..") {
        throw const PathTraversalRejectedFailure(debugDetail: "'..' segment");
      }
      if (_looksAbsolute(segment)) {
        throw const PathTraversalRejectedFailure(
          debugDetail: "absolute-looking segment",
        );
      }
      // Reject NUL and other control characters outright.
      if (segment.codeUnits.any((int c) => c < 0x20)) {
        throw const PathTraversalRejectedFailure(
          debugDetail: "control character in segment",
        );
      }
      segments.add(segment);
    }

    return StoragePath._(rootId, List<String>.unmodifiable(segments));
  }

  final String rootId;
  final List<String> segments;

  bool get isRoot => segments.isEmpty;

  String get name => segments.isEmpty ? "" : segments.last;

  /// Parent path, or the root itself if already at the root.
  StoragePath get parent {
    if (segments.isEmpty) return this;
    return StoragePath._(rootId, segments.sublist(0, segments.length - 1));
  }

  /// Appends one **literal** file or folder name.
  ///
  /// Unlike [parse], this never percent-decodes or trims: [name] is an actual
  /// name that came from a directory listing or a text field, not a wire
  /// path. Routing it through [parse] (as this used to) silently rewrote real
  /// names — `100%25.txt` became `100%.txt`, `%2F` became a `/` inside one
  /// segment, and leading/trailing spaces were dropped — so the entry pointed
  /// at a different file than the one listed. Protocol handlers must still
  /// call [parse] on client-supplied paths; this is only for names we
  /// already hold.
  StoragePath child(String name) {
    if (name.trim().isEmpty || name == "." || name == "..") {
      throw const PathTraversalRejectedFailure(debugDetail: "invalid child name");
    }
    if (name.contains("/") || name.contains("\\")) {
      throw const PathTraversalRejectedFailure(
        debugDetail: "child() must be a single segment",
      );
    }
    if (_looksAbsolute(name)) {
      throw const PathTraversalRejectedFailure(debugDetail: "absolute-looking name");
    }
    if (name.codeUnits.any((int c) => c < 0x20)) {
      throw const PathTraversalRejectedFailure(
        debugDetail: "control character in name",
      );
    }
    return StoragePath._(rootId, <String>[...segments, name]);
  }

  /// True if this path is [other] itself, or lives inside it. Used to block
  /// "copy this folder into itself/a folder it contains" before any I/O
  /// starts — cheap, and the alternative (letting the backend discover it
  /// mid-recursive-copy) risks an unbounded/self-referential copy.
  bool isDescendantOfOrEqualTo(StoragePath other) {
    if (rootId != other.rootId) return false;
    if (other.segments.length > segments.length) return false;
    for (int i = 0; i < other.segments.length; i++) {
      if (segments[i] != other.segments[i]) return false;
    }
    return true;
  }

  /// Normalized, forward-slash-joined representation — safe to persist
  /// (e.g. `file_index.relative_path`, doc §06) or log.
  String get normalized => "/${segments.join('/')}";

  static String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on FormatException {
      // Malformed percent-encoding — treat the raw string as-is rather than
      // throwing here; the caller-level checks above still apply to it.
      return value;
    }
  }

  static bool _looksAbsolute(String segment) {
    if (segment.startsWith("/") || segment.startsWith("\\")) return true;
    // Windows drive letter, e.g. "C:". Must be a letter: "1:1 notes.txt" is a
    // perfectly ordinary Android file name and used to be rejected here.
    if (segment.length >= 2 && segment[1] == ":") {
      final int first = segment.codeUnitAt(0);
      final bool isLetter =
          (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
      if (isLetter) return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StoragePath &&
        other.rootId == rootId &&
        _segmentsEqual(other.segments, segments);
  }

  @override
  int get hashCode => Object.hash(rootId, Object.hashAll(segments));

  static bool _segmentsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => "StoragePath($rootId:$normalized)";
}
