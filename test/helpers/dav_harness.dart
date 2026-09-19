import "dart:convert";

import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/system_clock.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/file_repository.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/login_service.dart";
import "package:vaultbox/domain/security/login_throttle.dart";
import "package:vaultbox/domain/security/session_manager.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/api/api_types.dart";
import "package:vaultbox/server/files/storage_gate.dart";
import "package:vaultbox/server/webdav/dav_auth.dart";
import "package:vaultbox/server/webdav/dav_locks.dart";
import "package:vaultbox/server/webdav/webdav_handler.dart";
import "package:xml/xml.dart";

import "fake_clock.dart";
import "fake_password_hasher.dart";

/// A [WebDavHandler] on in-memory parts: an admin account, a controllable
/// clock, a writable memory root "Phone" (`r1`) and a read-only one "Card" (`r2`).
final class DavHarness {
  DavHarness._({
    required this.clock,
    required this.hasher,
    required this.phone,
    required this.card,
    required this.files,
    required this.locks,
    required this.auth,
    required this.handler,
  });

  factory DavHarness({
    Authorizer authorizer = const SingleAdminAuthorizer(),
    bool withCard = true,
    List<String> extraRootNames = const <String>[],
  }) {
    final FakeClock clock = FakeClock();
    final FakePasswordHasher hasher = FakePasswordHasher();
    final InMemoryAccountRepository accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "fake:$password", createdAt: clock.now()),
    ]);
    final MemoryStorageBackend phone = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hello world"))
      ..seedDirectory("/docs")
      ..seedFile("/docs/a.txt", utf8.encode("A"))
      ..seedDirectory("/empty")
      ..seedFile("/.vaultbox/recycle/keep.txt", utf8.encode("bin"));
    final MemoryStorageBackend card = MemoryStorageBackend(id: "r2")..seedFile("/photo.jpg", utf8.encode("jpg"));

    final Map<String, MemoryStorageBackend> backends = <String, MemoryStorageBackend>{"r1": phone, "r2": card};
    for (int i = 0; i < extraRootNames.length; i++) {
      backends["x$i"] = MemoryStorageBackend(id: "x$i");
    }
    final _Registry registry = _Registry(backends);
    final InMemoryStorageRootRepository roots = InMemoryStorageRootRepository(
      initial: <StorageRoot>[
        _root("r1", "Phone"),
        if (withCard) _root("r2", "Card", capabilities: const StorageCapabilities.readOnly()),
        for (int i = 0; i < extraRootNames.length; i++) _root("x$i", extraRootNames[i]),
      ],
    );
    final FileRepositoryImpl files = FileRepositoryImpl(resolveBackend: (StorageRoot root) => registry.forRoot(root));
    final StorageGate gate = StorageGate(roots: roots, authorizer: authorizer);
    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final LoginService login = LoginService(
      accounts: accounts,
      hasher: hasher,
      sessions: sessions,
      perAccountThrottle: LoginThrottle(clock: clock),
      perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
    );
    final DavAuthenticator auth = DavAuthenticator(login: login, accounts: accounts, clock: clock);
    final DavLockManager locks = DavLockManager(clock: clock);
    final WebDavHandler handler = WebDavHandler(
      gate: gate,
      files: files,
      delete: DeleteItemsToRecycleBin(files, InMemoryRecycleBinRepository(), clock, UuidIdGenerator()),
      auth: auth,
      locks: locks,
    );
    return DavHarness._(
      clock: clock,
      hasher: hasher,
      phone: phone,
      card: card,
      files: files,
      locks: locks,
      auth: auth,
      handler: handler,
    );
  }

  static const String password = "correct horse battery";

  static StorageRoot _root(String id, String name, {StorageCapabilities capabilities = const StorageCapabilities.fullLocal()}) =>
      StorageRoot(
        id: id,
        displayName: name,
        backendType: StorageBackendType.memory,
        uriOrPath: "memory://$id",
        capabilities: capabilities,
        freeBytes: 1000,
        totalBytes: 5000,
      );

  final FakeClock clock;
  final FakePasswordHasher hasher;
  final MemoryStorageBackend phone;
  final MemoryStorageBackend card;
  final FileRepository files;
  final DavLockManager locks;
  final DavAuthenticator auth;
  final WebDavHandler handler;

  static String basic(String user, String pass) => "Basic ${base64.encode(utf8.encode("$user:$pass"))}";

  /// Sends a request as the admin unless [authorization] says otherwise.
  Future<ApiResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Stream<List<int>>? stream,
    String? authorization,
    bool anonymous = false,
    String address = "192.168.1.10",
  }) {
    final List<int>? bytes = body == null ? null : (body is String ? utf8.encode(body) : body as List<int>);
    final Uri uri = Uri.parse(path);
    return handler.handle(
      ApiRequest(
        method: method,
        segments: uri.pathSegments.where((String s) => s.isNotEmpty).toList(),
        query: uri.queryParameters,
        remoteAddress: address,
        headers: <String, String>{
          if (!anonymous) "authorization": authorization ?? basic("admin", password),
          for (final MapEntry<String, String> e in headers.entries) e.key.toLowerCase(): e.value,
        },
        body: stream == null ? (bytes ?? const <int>[]) : null,
        bodyStream: stream,
      ),
    );
  }

  /// The response body as text.
  static String text(ApiResponse response) => utf8.decode(response.bytes ?? const <int>[]);

  /// A streamed or buffered body as bytes.
  static Future<List<int>> bodyBytes(ApiResponse response) async {
    if (response.bytes != null) return response.bytes!;
    final Stream<List<int>>? stream = response.stream;
    if (stream == null) return const <int>[];
    return <int>[for (final List<int> chunk in await stream.toList()) ...chunk];
  }

  /// Every `<response>` of a 207: href -> (status code -> property local name -> text).
  static Map<String, Map<int, Map<String, String>>> multistatus(ApiResponse response) {
    expectStatus(response, 207);
    final XmlDocument document = XmlDocument.parse(text(response));
    final Map<String, Map<int, Map<String, String>>> out = <String, Map<int, Map<String, String>>>{};
    for (final XmlElement resp in document.rootElement.childElements.where((XmlElement e) => e.name.local == "response")) {
      final String href = resp.childElements.firstWhere((XmlElement e) => e.name.local == "href").innerText;
      final Map<int, Map<String, String>> groups = out.putIfAbsent(href, () => <int, Map<String, String>>{});
      for (final XmlElement stat in resp.childElements.where((XmlElement e) => e.name.local == "propstat")) {
        final String statusLine = stat.childElements.firstWhere((XmlElement e) => e.name.local == "status").innerText;
        final int code = int.parse(statusLine.split(" ")[1]);
        final XmlElement prop = stat.childElements.firstWhere((XmlElement e) => e.name.local == "prop");
        final Map<String, String> values = groups.putIfAbsent(code, () => <String, String>{});
        for (final XmlElement p in prop.childElements) {
          values[p.name.local] = p.childElements.isEmpty ? p.innerText : p.toXmlString();
        }
      }
    }
    return out;
  }

  static void expectStatus(ApiResponse response, int status) {
    if (response.status != status) {
      throw StateError("expected $status, got ${response.status}: ${text(response)}");
    }
  }
}

final class _Registry {
  _Registry(this._backends);

  final Map<String, MemoryStorageBackend> _backends;

  MemoryStorageBackend forRoot(StorageRoot root) => _backends[root.id]!;
}
