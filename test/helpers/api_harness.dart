import "dart:convert";

import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/system_clock.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/download_tickets.dart";
import "package:vaultbox/domain/security/login_service.dart";
import "package:vaultbox/domain/security/login_throttle.dart";
import "package:vaultbox/domain/security/session_manager.dart";
import "package:vaultbox/domain/usecases/copy_items.dart";
import "package:vaultbox/domain/usecases/create_share.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/usecases/move_items.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/api/api_types.dart";
import "package:vaultbox/server/api/file_endpoints.dart";
import "package:vaultbox/server/api/public_endpoints.dart";
import "package:vaultbox/server/api/vault_api.dart";
import "package:vaultbox/server/files/storage_gate.dart";

import "fake_clock.dart";
import "fake_password_hasher.dart";

/// A whole [VaultApi] on in-memory parts: one admin account (plus any extra
/// ones), a clock that only moves when told to, and a memory-backed storage
/// root `r1`.
final class ApiHarness {
  ApiHarness._({
    required this.clock,
    required this.hasher,
    required this.sessions,
    required this.accounts,
    required this.backend,
    required this.rootRepository,
    required this.shareRepository,
    required this.unlocks,
    required this.tickets,
    required this.createShare,
    required this.api,
  });

  factory ApiHarness({
    List<StorageRoot>? roots,
    MemoryStorageBackend? backend,
    Authorizer authorizer = const SingleAdminAuthorizer(),
    List<Account> extraAccounts = const <Account>[],
  }) {
    final FakeClock clock = FakeClock();
    final FakePasswordHasher hasher = FakePasswordHasher();
    final InMemoryAccountRepository accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "fake:$password", createdAt: clock.now()),
      ...extraAccounts,
    ]);
    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final MemoryStorageBackend memory = backend ?? MemoryStorageBackend(id: "r1");
    final BackendRegistry registry = BackendRegistry()..register(memory);
    final InMemoryStorageRootRepository rootRepository = InMemoryStorageRootRepository(
      initial: roots ?? <StorageRoot>[root()],
    );
    final FileRepositoryImpl files = FileRepositoryImpl(resolveBackend: registry.forRoot);
    final StorageGate gate = StorageGate(roots: rootRepository, authorizer: authorizer);
    final InMemoryShareRepository shareRepository = InMemoryShareRepository();
    final ShareUnlocks unlocks = ShareUnlocks(clock: clock);
    final DownloadTicketService tickets = DownloadTicketService(clock: clock);

    final VaultApi api = VaultApi(
      login: LoginService(
        accounts: accounts,
        hasher: hasher,
        sessions: sessions,
        perAccountThrottle: LoginThrottle(clock: clock),
        perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
      ),
      sessions: sessions,
      accounts: accounts,
      gate: gate,
      public: PublicEndpoints(
        shares: shareRepository,
        accounts: accounts,
        gate: gate,
        files: files,
        hasher: hasher,
        clock: clock,
        unlocks: unlocks,
      ),
      files: FileEndpoints(
        gate: gate,
        files: files,
        accounts: accounts,
        tickets: tickets,
        copy: CopyItems(files),
        move: MoveItems(files),
        delete: DeleteItemsToRecycleBin(files, InMemoryRecycleBinRepository(), clock, UuidIdGenerator()),
      ),
    );
    return ApiHarness._(
      clock: clock,
      hasher: hasher,
      sessions: sessions,
      accounts: accounts,
      backend: memory,
      rootRepository: rootRepository,
      shareRepository: shareRepository,
      unlocks: unlocks,
      tickets: tickets,
      createShare: CreateShare(
        roots: rootRepository,
        files: files,
        shares: shareRepository,
        hasher: hasher,
        ids: UuidIdGenerator(),
        clock: clock,
        authorizer: authorizer,
      ),
      api: api,
    );
  }

  static const String password = "correct horse battery";
  static const String secretUri = "content://com.android.externalstorage.documents/tree/primary%3ASecret";

  final FakeClock clock;
  final FakePasswordHasher hasher;
  final SessionManager sessions;
  final InMemoryAccountRepository accounts;
  final MemoryStorageBackend backend;
  final InMemoryStorageRootRepository rootRepository;
  final InMemoryShareRepository shareRepository;
  final ShareUnlocks unlocks;
  final DownloadTicketService tickets;
  final CreateShare createShare;
  final VaultApi api;

  static StorageRoot root({
    String id = "r1",
    String name = "Phone",
    bool enabled = true,
    bool available = true,
    StorageCapabilities capabilities = const StorageCapabilities.fullLocal(),
  }) => StorageRoot(
    id: id,
    displayName: name,
    backendType: StorageBackendType.memory,
    uriOrPath: secretUri,
    capabilities: capabilities,
    isEnabled: enabled,
    isAvailable: available,
    freeBytes: 1000,
    totalBytes: 5000,
  );

  ApiRequest request(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
    String? token,
    Object? json,
    List<int>? bytes,
    Stream<List<int>>? stream,
    String address = "192.168.1.10",
  }) => ApiRequest(
    method: method,
    segments: path.split("/").where((String s) => s.isNotEmpty).toList(),
    query: query,
    headers: headers,
    remoteAddress: address,
    bearerToken: token,
    body: stream != null ? null : (bytes ?? (json == null ? const <int>[] : utf8.encode(jsonEncode(json)))),
    bodyStream: stream,
  );

  Future<ApiResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
    String? token,
    Object? json,
    List<int>? bytes,
    Stream<List<int>>? stream,
    String address = "192.168.1.10",
  }) => api.handle(
    request(method, path, query: query, headers: headers, token: token, json: json, bytes: bytes, stream: stream, address: address),
  );

  Future<String> login({String username = "admin", String pass = password}) async {
    final ApiResponse response = await api.handle(
      request("POST", "/api/v1/auth/login", json: <String, Object?>{"username": username, "password": pass}),
    );
    if (response.status != 200) throw StateError("test login failed: ${response.status}");
    return (response.json! as Map<String, Object?>)["token"]! as String;
  }

  /// The admin account (the harness always has one, id `a1`).
  Future<Account> admin() async => (await accounts.findById("a1"))!;

  /// Makes a link as [creator] (default: the admin) and returns its token.
  Future<CreatedShare> makeShare({
    Account? creator,
    ShareKind kind = ShareKind.download,
    String rootId = "r1",
    required String path,
    Duration? lifetime,
    String? password,
    int? maxUses,
    int? maxFileBytes,
  }) async => createShare(
    creator: creator ?? await admin(),
    kind: kind,
    rootId: rootId,
    path: path,
    lifetime: lifetime,
    password: password,
    maxUses: maxUses,
    maxFileBytes: maxFileBytes,
  );

  /// A response body as JSON.
  static Map<String, Object?> json(ApiResponse response) => response.json! as Map<String, Object?>;

  /// A streamed or buffered response body as bytes.
  static Future<List<int>> bodyBytes(ApiResponse response) async {
    if (response.bytes != null) return response.bytes!;
    final Stream<List<int>>? stream = response.stream;
    if (stream == null) return const <int>[];
    return <int>[for (final List<int> chunk in await stream.toList()) ...chunk];
  }
}
