import "package:flutter/material.dart";

import "../../../../core/design/aurora_colors.dart";
import "../../../../core/design/aurora_spacing.dart";
import "../../../../core/design/aurora_typography.dart";
import "../../../../core/utils/byte_format.dart";
import "../../../../domain/value_objects/storage_entry.dart";

/// One row in the file browser.
///
/// **Fixed height on purpose.** [rowHeight] is exported so the list can set
/// `itemExtent`, which lets Flutter skip measuring every child and makes
/// scroll-position maths O(1) — the difference between smooth and janky at
/// 10,000 rows (kickoff §12, KB §9 "Lists"). Nothing in this row may grow
/// with content: names ellipsize, metadata is one line.
///
/// It is also `const`-constructible and takes only plain values, so rows that
/// didn't change are cheap to rebuild if the list above them does.
class FileRow extends StatelessWidget {
  const FileRow({
    required this.entry,
    required this.onTap,
    super.key,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  static const double rowHeight = 68;

  final StorageEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color subtle =
        isDark ? AuroraColorsDark.inkSecondary : AuroraColors.inkSecondary;
    final Color selectionFill =
        isDark ? AuroraColorsDark.selectionSoft : AuroraColors.selectionSoft;
    final Color selectionAccent =
        isDark ? AuroraColorsDark.selectionBlue : AuroraColors.selectionBlue;

    return SizedBox(
      height: rowHeight,
      child: Material(
        color: selected ? selectionFill : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AuroraSpacing.md,
              vertical: AuroraSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                if (selectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: AuroraSpacing.sm),
                    child: Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 22,
                      color: selected ? selectionAccent : subtle,
                    ),
                  ),
                _EntryGlyph(entry: entry),
                const SizedBox(width: AuroraSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AuroraTypography.bodyLg.copyWith(
                          fontWeight: entry.isDirectory ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AuroraTypography.bodySm.copyWith(color: subtle),
                      ),
                    ],
                  ),
                ),
                if (entry.isDirectory && !selectionMode)
                  Icon(Icons.chevron_right, size: 20, color: subtle),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final List<String> parts = <String>[];
    // A null size means "backend couldn't report it cheaply", which is not
    // the same as zero — say nothing rather than claim "0 B" (doc §11).
    if (entry.sizeBytes != null) parts.add(ByteFormat.format(entry.sizeBytes!));
    if (entry.modifiedAt != null) parts.add(_relativeDate(entry.modifiedAt!));
    if (parts.isEmpty) return entry.isDirectory ? "Folder" : "File";
    return parts.join(" · ");
  }

  static String _relativeDate(DateTime moment) {
    final Duration age = DateTime.now().difference(moment);
    if (age.inMinutes < 1) return "Just now";
    if (age.inHours < 1) return "${age.inMinutes} min ago";
    if (age.inHours < 24) return "${age.inHours} hr ago";
    if (age.inDays < 7) return "${age.inDays} d ago";
    return "${moment.year}-${_two(moment.month)}-${_two(moment.day)}";
  }

  static String _two(int value) => value.toString().padLeft(2, "0");
}

class _EntryGlyph extends StatelessWidget {
  const _EntryGlyph({required this.entry});

  final StorageEntry entry;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color tint) = entry.isDirectory
        ? (Icons.folder_outlined, AuroraColors.auroraLavender)
        : _fileGlyph(entry.name);

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: AuroraRadiiLocal.glyph,
      ),
      child: Icon(icon, size: 20, color: tint),
    );
  }

  static (IconData, Color) _fileGlyph(String name) {
    final int dot = name.lastIndexOf(".");
    final String extension = dot <= 0 ? "" : name.substring(dot + 1).toLowerCase();
    return switch (extension) {
      "jpg" || "jpeg" || "png" || "gif" || "webp" || "heic" || "dng" =>
        (Icons.image_outlined, AuroraColors.auroraPink),
      "mp4" || "mov" || "mkv" || "avi" || "webm" =>
        (Icons.movie_outlined, AuroraColors.auroraPink),
      "mp3" || "wav" || "flac" || "m4a" =>
        (Icons.audiotrack_outlined, AuroraColors.auroraMid),
      "pdf" => (Icons.picture_as_pdf_outlined, AuroraColors.statusDanger),
      "zip" || "tar" || "gz" || "7z" || "rar" =>
        (Icons.folder_zip_outlined, AuroraColors.auroraMid),
      _ => (Icons.insert_drive_file_outlined, AuroraColors.inkTertiary),
    };
  }
}

abstract final class AuroraRadiiLocal {
  static const BorderRadius glyph = BorderRadius.all(Radius.circular(10));
}
