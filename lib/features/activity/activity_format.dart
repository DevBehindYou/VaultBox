import "../../core/utils/byte_format.dart";
import "../../domain/entities/activity.dart";

/// A transfer that says "running" but hasn't moved for this long is treated as
/// stalled: the other side is almost certainly gone.
const Duration transferStallAfter = Duration(minutes: 5);

/// A client seen this recently counts as connected.
const Duration clientActiveWithin = Duration(minutes: 5);

/// "just now", "5 minutes ago", "2 hours ago", "3 days ago".
String describeAgo(DateTime at, DateTime now) {
  final Duration gone = now.difference(at);
  if (gone.inSeconds < 45) return "just now";
  if (gone.inMinutes < 2) return "a minute ago";
  if (gone.inMinutes < 60) return "${gone.inMinutes} minutes ago";
  if (gone.inHours < 2) return "an hour ago";
  if (gone.inHours < 48) return "${gone.inHours} hours ago";
  return "${gone.inDays} days ago";
}

String describeVia(AccessVia via) => switch (via) {
  AccessVia.web => "Browser",
  AccessVia.webdav => "WebDAV",
  AccessVia.link => "Link",
  AccessVia.ftp => "FTP",
};

bool isStalled(TransferRecord transfer, DateTime now) =>
    transfer.isRunning && now.difference(transfer.updatedAt) >= transferStallAfter;

/// The short state shown on a transfer's chip.
String describeTransferState(TransferRecord transfer, DateTime now) {
  if (isStalled(transfer, now)) return "Stalled";
  return switch (transfer.state) {
    TransferState.running => transfer.direction == TransferDirection.download ? "Sending" : "Receiving",
    TransferState.completed => "Done",
    TransferState.failed => "Failed",
    TransferState.interrupted => "Stopped",
  };
}

/// "1.2 MB of 4.0 MB" while the size is known, otherwise just what moved.
String describeTransferSize(TransferRecord transfer) {
  final int? total = transfer.totalBytes;
  if (transfer.state == TransferState.completed || total == null || total <= 0) {
    return ByteFormat.format(transfer.bytes);
  }
  return "${ByteFormat.format(transfer.bytes)} of ${ByteFormat.format(total)}";
}
