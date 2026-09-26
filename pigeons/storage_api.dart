// Pigeon source spec for the native Android storage bridge (doc §47: "typed
// platform bridge... AndroidStorageApi... over dozens of untyped string
// MethodChannel calls").
//
// This is a SOURCE file for the Pigeon generator, not application code — it
// is never imported by lib/. Its only consumers are the `pigeon` CLI (which
// reads this file's declarations, not its runtime behaviour) and, indirectly,
// the two files it generates once run:
//   lib/platform/pigeon/storage_api.g.dart
//   android/app/src/main/kotlin/com/vaultbox/app/pigeon/StorageApi.g.kt
//
// Generate with (after `flutter create .` has produced a real android/ tree):
//   dart run pigeon --input pigeons/storage_api.dart
//
// SAF (Storage Access Framework) is the only backend that needs a native
// bridge at all — direct-path and in-memory storage are pure Dart. Every
// method below maps onto one `DocumentFile` / `DocumentsContract` /
// `ContentResolver` operation from the standard Android SDK; none of it is
// invented, but none of it has been run on a device from this delivery
// either — see docs/IMPLEMENTATION_PLAN.md's risk register before treating
// this contract as final.
//
// VERIFIED by CI (Pigeon 29.0.2, run #4+): every method is `@async`, and the
// generated Kotlin interface therefore declares `suspend fun` for all of them.
// The generated `setUp` launches each call on `Dispatchers.Main`, so the Kotlin
// implementation must hop to `Dispatchers.IO` for ContentResolver work.
// `openDocumentTree` in particular could not have worked as a synchronous
// method — it has to wait for an Activity result.

import "dart:typed_data";

import "package:pigeon/pigeon.dart";

@ConfigurePigeon(
  PigeonOptions(
    dartOut: "lib/platform/pigeon/storage_api.g.dart",
    kotlinOut: "android/app/src/main/kotlin/com/vaultbox/app/pigeon/StorageApi.g.kt",
    kotlinOptions: KotlinOptions(package: "com.vaultbox.app.pigeon"),
    dartPackageName: "vaultbox",
  ),
)
// One granted SAF root — the Dart-side mirror of what a user picked via
// ACTION_OPEN_DOCUMENT_TREE. treeUri is the opaque, persistable content://
// string; VaultBox never parses or constructs one itself, only stores and
// replays it (doc §21/§23: SAF URIs are not paths).
//
// Pigeon message classes follow the library's own convention here: plain
// nullable fields, no constructor — Pigeon reads the field list itself and
// generates the real constructor in its output, so writing one here doesn't
// do what it looks like it does and may not even be valid input.
class SafTreeMessage {
  String? treeUri;
  String? displayName;

  // `DocumentsContract.getTreeDocumentId(treeUri)` — the document id of the
  // tree's top level. SafStorageBackend needs it to start walking paths; it
  // was missing from the first draft of this contract.
  String? rootDocumentId;
}

enum SafEntryTypeMessage {
  file,
  directory,
}

// One row in a SAF directory listing — the native-side equivalent of
// StorageEntry, before it's mapped into the domain type in
// SafStorageBackend.
class SafEntryMessage {
  // The DocumentsContract document id for this exact entry — not a path.
  // Every operation on this entry (read, write, delete, rename) addresses it
  // by this id plus its parent tree's treeUri, never by reconstructing a
  // path string.
  String? documentId;
  String? name;
  SafEntryTypeMessage? type;
  int? sizeBytes;
  int? lastModifiedMillis;
  String? mimeType;
}

// A document the user picked with the system file picker, ALREADY COPIED into
// the app's cache directory by the native side. Handing Dart a plain cache
// path (instead of a content:// URI) means importing needs no SAF fd tricks:
// Dart just streams a normal file. The caller owns the copy and must delete it.
class PickedFileMessage {
  // Absolute path of the cached copy. The file name is an index, never the
  // provider-supplied name (a hostile provider could otherwise inject path
  // segments); the real name travels separately in [name].
  String? cachePath;
  String? name;
  int? sizeBytes;
  String? mimeType;
}

/// Native-side storage bridge. Implemented in Kotlin
/// (`SafStorageHostApi.kt`), called from Dart via `SafStorageBackend`
/// (`lib/data/services/saf_storage_backend.dart`) through the
/// `AndroidStorageHost` interface it's adapted to.
@HostApi()
abstract class AndroidStorageApi {
  /// Launches `ACTION_OPEN_DOCUMENT_TREE`, takes a persistable read/write URI
  /// permission grant on the result (`Intent.FLAG_GRANT_*_URI_PERMISSION` +
  /// `ContentResolver.takePersistableUriPermission`), and returns the chosen
  /// tree. Returns null if the user cancelled the picker.
  @async
  SafTreeMessage? openDocumentTree();

  /// Every tree this app currently holds a persisted grant for — survives
  /// app restarts and reboots by design (that's what "persistable" means), so
  /// this is how the storage-root repository reconciles its own rows against
  /// what Android will actually still let the app touch.
  @async
  List<SafTreeMessage> persistedTrees();

  /// Releases a grant. Does not delete any files — purely revokes VaultBox's
  /// own access, mirroring what "Remove storage location" should do in
  /// Settings.
  @async
  void releasePersistedUri(String treeUri);

  /// Direct children of [parentDocumentId] within [treeUri]. Pass the tree's
  /// own root document id (obtainable via
  /// `DocumentFile.fromTreeUri(...).documentId` on the Kotlin side) to list
  /// the tree's top level.
  @async
  List<SafEntryMessage> listChildren(String treeUri, String parentDocumentId);

  @async
  SafEntryMessage? stat(String treeUri, String documentId);

  /// Returns the new directory's document id.
  @async
  String createDirectory(String treeUri, String parentDocumentId, String name);

  /// Creates an empty document and returns its id — the caller then opens a
  /// stream on it (see [openStream]) to write content.
  @async
  String createFile(String treeUri, String parentDocumentId, String name, String mimeType);

  @async
  void deleteDocument(String treeUri, String documentId);

  /// Returns the (possibly changed — SAF may rename-on-conflict) new name.
  @async
  String renameDocument(String treeUri, String documentId, String newName);

  /// Opens a document for streaming and returns a handle for [readChunk] /
  /// [writeChunk] / [closeStream]. [mode] is `"r"` (read from byte [start])
  /// or `"w"` (truncate, then write; [start] ignored).
  ///
  /// Bytes travel over the channel in chunks rather than through
  /// `File('/proc/self/fd/N')`: re-opening that path re-resolves it to the
  /// provider's lower-filesystem path (e.g. `/mnt/media_rw/...` for an SD
  /// card), which the app may not open — EACCES on Android 14 (found on a
  /// real device, 2026-09-26). The native side reads and writes through the
  /// descriptor it opened itself, which the grant covers.
  @async
  int openStream(String treeUri, String documentId, String mode, int start);

  /// Up to [maxBytes] bytes; an empty result means end of file.
  @async
  Uint8List readChunk(int handle, int maxBytes);

  @async
  void writeChunk(int handle, Uint8List bytes);

  /// Flushes (and syncs, for writes) and releases the handle. Safe to call on
  /// an already-closed or unknown handle.
  @async
  void closeStream(int handle);

  /// Launches `ACTION_OPEN_DOCUMENT` (multi-select), then copies every picked
  /// document into a fresh directory under the app's cache and returns the
  /// copies. An empty list means the person cancelled. Copying happens on a
  /// background thread with plain ContentResolver streams (works for every
  /// provider, needs no persistable grant).
  ///
  /// Costs temporary extra space (one full copy per picked file) — acceptable
  /// for an import, and the reason the caller must delete each copy afterwards.
  @async
  List<PickedFileMessage> pickFilesToCache();

  /// Whether the app currently holds "All files access"
  /// (`Environment.isExternalStorageManager()`). Below API 30 this is always
  /// true — scoped storage's MANAGE_EXTERNAL_STORAGE gate doesn't exist there.
  /// Needed so "This phone" can default into the public Downloads folder
  /// (visible in any file manager) instead of the app-private directory
  /// scoped storage otherwise confines raw `dart:io` File access to.
  @async
  bool hasManageExternalStoragePermission();

  /// Sends the user to the system "All files access" settings screen for this
  /// app (`Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`) — Android
  /// does not allow granting MANAGE_EXTERNAL_STORAGE through an in-app runtime
  /// dialog, only through this settings screen. Fire-and-forget: the caller
  /// re-checks [hasManageExternalStoragePermission] the next time it matters
  /// rather than waiting for a result here.
  @async
  void requestManageExternalStoragePermission();
}

// ---------------------------------------------------------------------------
// Server host (Phase 2). Two Flutter engines are involved and must not be
// confused:
//  - the UI engine (the Activity's) CONTROLS the service via ServerControlApi
//    and RECEIVES state pushes via ServerStateListener;
//  - the service's own headless engine RUNS the Dart server (`serverMain`) and
//    REPORTS its state to native via ServerRuntimeApi.
// The Android Foreground Service, not the Activity, owns the server lifecycle
// (ADR-006), so state lives in native and is pushed to whichever UI is attached.
// ---------------------------------------------------------------------------

enum ServerRunStateMessage {
  stopped,
  starting,
  running,
  failed,
}

class ServerStateMessage {
  ServerRunStateMessage? state;

  /// Where the server can be reached, when running (e.g. http://127.0.0.1:41234/health/).
  String? endpoint;

  /// Human-readable failure reason, when failed.
  String? detail;

  /// Every URL the server answers on (HTTPS and/or HTTP), when running.
  List<String?>? endpoints;
}

class ServerConfigMessage {
  /// false (default) = loopback only; true = reachable from the local network.
  bool? allowNetworkAccess;

  /// HTTPS port.
  int? port;

  /// HTTPS (encrypted). On by default.
  bool? httpsEnabled;

  /// Plain HTTP (NOT encrypted). Off by default; an explicit, warned opt-in.
  bool? httpEnabled;
  int? httpPort;
}

/// The server's TLS identity. The private key is decrypted by native code only
/// to hand it to the headless server engine at start; it is never persisted in
/// plaintext.
class TlsIdentityMessage {
  String? certificatePem;
  String? privateKeyPem;

  /// SHA-256 of the certificate, upper-case colon-separated hex — what a person
  /// compares against the browser's certificate warning.
  String? sha256Fingerprint;
}

/// UI engine -> native. Synchronous on purpose: these only start/stop the
/// service and read/write small settings.
@HostApi()
abstract class ServerControlApi {
  void start();
  void stop();
  ServerStateMessage getState();
  ServerConfigMessage getConfig();
  void setConfig(ServerConfigMessage config);

  /// Creates the TLS identity on first use.
  String getTlsFingerprint();
}

/// Service (headless) engine -> native.
@HostApi()
abstract class ServerRuntimeApi {
  void reportState(ServerStateMessage state);
  ServerConfigMessage getConfig();
  TlsIdentityMessage getTlsIdentity();
}

/// Native -> UI engine push whenever the server state changes.
@FlutterApi()
abstract class ServerStateListener {
  void onStateChanged(ServerStateMessage state);
}
