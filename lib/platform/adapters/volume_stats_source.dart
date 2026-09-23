import "package:flutter/services.dart";

import "../../domain/entities/storage_root.dart";

/// How full a storage volume is.
final class VolumeStats {
  const VolumeStats({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  int get usedBytes => totalBytes > freeBytes ? totalBytes - freeBytes : 0;
}

/// Answers "how much space is left where this root lives?".
abstract interface class VolumeStatsSource {
  /// `null` when it can't be measured (a folder on an unplugged card, a
  /// memory-backed test root, a phone without the native side).
  Future<VolumeStats?> statsFor(StorageRoot root);
}

/// Asks the Android side over a plain method channel.
final class ChannelVolumeStatsSource implements VolumeStatsSource {
  const ChannelVolumeStatsSource();

  static const MethodChannel _channel = MethodChannel("vaultbox/storage_stats");

  @override
  Future<VolumeStats?> statsFor(StorageRoot root) async {
    if (root.backendType == StorageBackendType.memory) return null;
    try {
      final Map<Object?, Object?>? answer = await _channel.invokeMapMethod<Object?, Object?>(
        "volumeStats",
        <String, Object?>{"uriOrPath": root.uriOrPath},
      );
      final Object? free = answer?["free"];
      final Object? total = answer?["total"];
      if (free is int && total is int && total > 0) return VolumeStats(freeBytes: free, totalBytes: total);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
