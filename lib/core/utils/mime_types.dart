/// A small extension -> MIME table for downloads. Anything unknown is served as
/// `application/octet-stream`, which browsers save rather than run.
abstract final class MimeTypes {
  static const String fallback = "application/octet-stream";

  static const Map<String, String> _byExtension = <String, String>{
    "txt": "text/plain",
    "md": "text/plain",
    "csv": "text/csv",
    "log": "text/plain",
    "json": "application/json",
    "xml": "application/xml",
    "html": "text/html",
    "htm": "text/html",
    "css": "text/css",
    "js": "text/javascript",
    "pdf": "application/pdf",
    "zip": "application/zip",
    "gz": "application/gzip",
    "7z": "application/x-7z-compressed",
    "rar": "application/vnd.rar",
    "apk": "application/vnd.android.package-archive",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "bmp": "image/bmp",
    "svg": "image/svg+xml",
    "heic": "image/heic",
    "mp3": "audio/mpeg",
    "m4a": "audio/mp4",
    "aac": "audio/aac",
    "wav": "audio/wav",
    "ogg": "audio/ogg",
    "flac": "audio/flac",
    "mp4": "video/mp4",
    "m4v": "video/mp4",
    "mkv": "video/x-matroska",
    "webm": "video/webm",
    "mov": "video/quicktime",
    "avi": "video/x-msvideo",
    "3gp": "video/3gpp",
  };

  /// The MIME type for [fileName] from its extension.
  static String forName(String fileName) {
    final int dot = fileName.lastIndexOf(".");
    if (dot <= 0 || dot == fileName.length - 1) return fallback;
    return _byExtension[fileName.substring(dot + 1).toLowerCase()] ?? fallback;
  }

  /// Types a browser can show inline without being able to run script from
  /// them. HTML, SVG and XML are deliberately NOT here: an uploaded page
  /// rendered inline would run in the server's origin.
  static bool isSafeToDisplayInline(String mimeType) {
    final String type = mimeType.split(";").first.trim().toLowerCase();
    if (type == "image/svg+xml") return false;
    return type.startsWith("image/") ||
        type.startsWith("audio/") ||
        type.startsWith("video/") ||
        type == "text/plain";
  }
}
