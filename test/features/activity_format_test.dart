import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/features/activity/activity_format.dart";

void main() {
  final DateTime now = DateTime.utc(2026, 9, 20, 12);

  group("describeAgo", () {
    test("speaks in the largest sensible unit", () {
      String ago(Duration d) => describeAgo(now.subtract(d), now);

      expect(ago(Duration.zero), "just now");
      expect(ago(const Duration(seconds: 44)), "just now");
      expect(ago(const Duration(seconds: 50)), "a minute ago");
      expect(ago(const Duration(minutes: 5)), "5 minutes ago");
      expect(ago(const Duration(minutes: 59)), "59 minutes ago");
      expect(ago(const Duration(minutes: 61)), "an hour ago");
      expect(ago(const Duration(hours: 5)), "5 hours ago");
      expect(ago(const Duration(hours: 47)), "47 hours ago");
      expect(ago(const Duration(days: 3)), "3 days ago");
    });

    test("a moment in the future (clock skew) still reads as now", () {
      expect(describeAgo(now.add(const Duration(seconds: 5)), now), "just now");
    });
  });

  test("describeVia names each door", () {
    expect(describeVia(AccessVia.web), "Browser");
    expect(describeVia(AccessVia.webdav), "WebDAV");
    expect(describeVia(AccessVia.link), "Link");
  });

  group("transfers", () {
    TransferRecord transfer({
      TransferState state = TransferState.running,
      TransferDirection direction = TransferDirection.download,
      int bytes = 0,
      int? total,
      Duration idle = Duration.zero,
    }) => TransferRecord(
      id: "t",
      direction: direction,
      via: AccessVia.web,
      actor: "admin",
      name: "a.bin",
      startedAt: now.subtract(const Duration(hours: 1)),
      updatedAt: now.subtract(idle),
      bytes: bytes,
      totalBytes: total,
      state: state,
    );

    test("the state words follow the direction while running", () {
      expect(describeTransferState(transfer(), now), "Sending");
      expect(describeTransferState(transfer(direction: TransferDirection.upload), now), "Receiving");
      expect(describeTransferState(transfer(state: TransferState.completed), now), "Done");
      expect(describeTransferState(transfer(state: TransferState.failed), now), "Failed");
      expect(describeTransferState(transfer(state: TransferState.interrupted), now), "Stopped");
    });

    test("a running transfer that hasn't moved for five minutes is stalled", () {
      expect(isStalled(transfer(idle: const Duration(minutes: 4)), now), isFalse);
      expect(isStalled(transfer(idle: const Duration(minutes: 5)), now), isTrue);
      expect(describeTransferState(transfer(idle: const Duration(minutes: 10)), now), "Stalled");
    });

    test("only a running transfer can be stalled", () {
      expect(isStalled(transfer(state: TransferState.completed, idle: const Duration(days: 1)), now), isFalse);
    });

    test("size reads as 'x of y' while moving, and plain once done or unknown", () {
      expect(describeTransferSize(transfer(bytes: 1536, total: 4096)), "1.5 KB of 4.0 KB");
      expect(describeTransferSize(transfer(bytes: 1536)), "1.5 KB");
      expect(describeTransferSize(transfer(bytes: 4096, total: 4096, state: TransferState.completed)), "4.0 KB");
      expect(describeTransferSize(transfer(bytes: 5, total: 0)), "5 B");
    });
  });
}
