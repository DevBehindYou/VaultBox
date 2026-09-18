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
  /// file descriptor separately (see [openFileDescriptor]) to write content.
  /// Splitting create-then-write (rather than one call that also takes bytes)
  /// is what makes streaming large files possible at all through this
  /// bridge.
  @async
  String createFile(String treeUri, String parentDocumentId, String name, String mimeType);

  @async
  void deleteDocument(String treeUri, String documentId);

  /// Returns the (possibly changed — SAF may rename-on-conflict) new name.
  @async
  String renameDocument(String treeUri, String documentId, String newName);

  /// Opens a raw file descriptor via
  /// `ContentResolver.openFileDescriptor(uri, mode)`, then `detachFd()`s
  /// it — ownership transfers to the caller from this point, so Dart is
  /// responsible for closing whatever it opens from this fd. [mode] is
  /// `"r"`, `"w"`, or `"rw"` — the same vocabulary
  /// `ContentResolver.openFileDescriptor` itself takes.
  ///
  /// Dart-side usage: `File('/proc/self/fd/$fd')` — Android's `/proc`
  /// exposes a process's own open descriptors as regular file paths, which
  /// is what lets `dart:io` stream through a SAF-backed file at normal
  /// throughput instead of round-tripping every chunk over a platform
  /// channel. This is the highest-risk, least-verified part of this whole
  /// contract — it needs on-device validation (large file, both directions,
  /// cancellation mid-transfer, and behaviour across the Android versions
  /// VaultBox targets) before anything depends on it for real user data. See
  /// docs/IMPLEMENTATION_PLAN.md's risk register.
  @async
  int openFileDescriptor(String treeUri, String documentId, String mode);

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
}

/// UI engine -> native. Synchronous on purpose: these only start/stop the
/// service and read a snapshot.
@HostApi()
abstract class ServerControlApi {
  void start();
  void stop();
  ServerStateMessage getState();
}

/// Service (headless) engine -> native.
@HostApi()
abstract class ServerRuntimeApi {
  void reportState(ServerStateMessage state);
}

/// Native -> UI engine push whenever the server state changes.
@FlutterApi()
abstract class ServerStateListener {
  void onStateChanged(ServerStateMessage state);
}
