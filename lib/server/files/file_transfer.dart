import "dart:async";

import "package:logging/logging.dart";

import "../../core/logging/app_logger.dart";
import "../../core/utils/mime_types.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
import "storage_gate.dart";

/// One satisfiable `Range: bytes=…` (single range only), inclusive on both ends.
final class ByteRange {
  const ByteRange(this.start, this.end);

  /// Marker: syntactically valid but outside the file (answer 416).
  static const ByteRange unsatisfiable = ByteRange(-1, -1);

  final int start;
  final int end;

  /// `null` means "ignore the header and send everything" (unparseable, or a
  /// multi-range request we don't split).
  static ByteRange? parse(String header, int size) {
    final RegExpMatch? match = RegExp(r"^bytes=(\d*)-(\d*)$").firstMatch(header.trim());
    if (match == null) return null;
    final String from = match.group(1)!;
    final String to = match.group(2)!;
    if (from.isEmpty && to.isEmpty) return null;

    if (from.isEmpty) {
      // Suffix: the last N bytes.
      final int? count = int.tryParse(to);
      if (count == null) return null;
      if (count == 0 || size == 0) return unsatisfiable;
      return ByteRange(count >= size ? 0 : size - count, size - 1);
    }
    final int? start = int.tryParse(from);
    if (start == null) return null;
    if (to.isEmpty) {
      // Open-ended: from [start] to the end.
      return start >= size ? unsatisfiable : ByteRange(start, size - 1);
    }
    final int? last = int.tryParse(to);
    if (last == null || last < start) return null; // an invalid range is ignored (RFC 9110)
    if (start >= size) return unsatisfiable;
    return ByteRange(start, last >= size ? size - 1 : last);
  }
}

/// What to send for a download: which bytes, with which validators. Nothing is
/// opened until [open] is called (a HEAD request never reads the file).
final class DownloadPlan {
  const DownloadPlan({
    required this.entry,
    required this.mimeType,
    required this.status,
    required this.length,
    required this.canRange,
    required this.range,
    required this.totalSize,
    required this.open,
  });

  final StorageEntry entry;
  final String mimeType;

  /// 200, or 206 when [range] applies.
  final int status;

  /// Bytes that will be sent, when known.
  final int? length;

  /// Whether the storage can seek (advertised as `Accept-Ranges`).
  final bool canRange;

  /// The served range, for a 206.
  final ByteRange? range;

  /// The whole file's size, when known.
  final int? totalSize;

  final Stream<List<int>> Function() open;

  /// `Content-Range` value for a 206.
  String? get contentRange => range == null ? null : "bytes ${range!.start}-${range!.end}/$totalSize";
}

final class UploadResult {
  const UploadResult({required this.created, required this.size});

  /// false when an existing file was replaced.
  final bool created;
  final int size;
}

/// The byte-moving half of storage access, shared by every protocol: plan a
/// (ranged) download, receive an upload safely. Callers do the authorising
/// first ([StorageGate]); this only reports [StorageFault]s.
final Logger _log = AppLogger.of("FileTransfer");

final class FileTransfer {
  const FileTransfer(this._files);

  final FileRepository _files;

  /// A folder that must exist (the root always does).
  Future<void> requireDirectory(FileRef directory, FaultKind otherwise) async {
    if (directory.path.isRoot) return;
    final StorageEntry? entry = await _files.statEntry(directory);
    if (entry == null || !entry.isDirectory) throw StorageFault(otherwise);
  }

  Future<DownloadPlan> planDownload(StorageRoot root, StoragePath path, {String? rangeHeader}) async {
    final FileRef ref = FileRef(root: root, path: path);
    final StorageEntry? entry = await _files.statEntry(ref);
    if (entry == null) throw const StorageFault(FaultKind.notFound);
    if (entry.isDirectory) throw const StorageFault(FaultKind.notAFile);

    final int? size = entry.sizeBytes;
    final bool canRange = root.capabilities.supportsRandomAccess && size != null;

    ByteRange? range;
    if (rangeHeader != null && canRange) {
      final ByteRange? parsed = ByteRange.parse(rangeHeader, size);
      if (identical(parsed, ByteRange.unsatisfiable)) {
        throw StorageFault(FaultKind.rangeNotSatisfiable, size: size);
      }
      range = parsed;
    }

    return DownloadPlan(
      entry: entry,
      mimeType: MimeTypes.forName(entry.name),
      status: range == null ? 200 : 206,
      length: range == null ? size : range.end - range.start + 1,
      canRange: canRange,
      range: range,
      totalSize: size,
      open: () => _files.openRead(ref, start: range?.start, end: range?.end),
    );
  }

  /// Streams [body] into [path]. The old file (if any) survives a failure, and
  /// a half-received upload is never committed.
  Future<UploadResult> receive(
    StorageRoot root,
    StoragePath path,
    Stream<List<int>> body, {
    required bool overwrite,
  }) async {
    await requireDirectory(FileRef(root: root, path: path.parent), FaultKind.parentMissing);
    final FileRef ref = FileRef(root: root, path: path);
    final StorageEntry? existing = await _files.statEntry(ref);
    if (existing != null) {
      if (existing.isDirectory) throw const StorageFault(FaultKind.isADirectory);
      if (!overwrite) throw const StorageFault(FaultKind.exists);
    }

    final StorageWriteHandle handle = await _files.openWrite(
      ref,
      mode: existing == null ? WriteMode.create : WriteMode.replace,
    );

    // Capture a failure of the CLIENT's stream ourselves: sinks differ in how
    // they report a broken source, and a half-received file must never be
    // committed as if it were complete.
    // (An `async*` wrapper can't do this: `yield*` forwards a stream's errors
    // without throwing them inside the generator, so a try/catch never sees them.)
    Object? sourceError;
    final Stream<List<int>> watched = body.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleError: (Object error, StackTrace trace, EventSink<List<int>> sink) {
          sourceError ??= error;
          sink.addError(error, trace);
        },
      ),
    );

    try {
      try {
        await handle.sink.addStream(watched);
      } on Object {
        if (sourceError == null) rethrow;
      }
      if (sourceError != null) {
        // Type and message only (a socket/TLS error names no file): what
        // tells a client that simply went away from a TLS teardown quirk.
        _log.warning("Upload stream ended with ${sourceError.runtimeType}: $sourceError");
        await handle.abort();
        throw const StorageFault(FaultKind.interrupted);
      }
      final int written = await handle.commit();
      return UploadResult(created: existing == null, size: written);
    } catch (_) {
      await handle.abort(); // no-op if already committed
      rethrow;
    }
  }
}
