import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

/// The phone's address as the Mac found it: where to dial and which store the
/// answer belongs to.
class DiscoveredPeer {
  final String host;
  final int port;
  final String storeId;

  const DiscoveredPeer({
    required this.host,
    required this.port,
    required this.storeId,
  });

  @override
  String toString() =>
      'DiscoveredPeer(host: $host, port: $port, storeId: $storeId)';
}

/// Thrown when the platform's mDNS stack is unavailable. The pairing view falls
/// back to typing the host and port the phone shows.
class DiscoveryUnavailableException implements Exception {
  final String message;

  const DiscoveryUnavailableException(this.message);

  @override
  String toString() => message;
}

/// Finds the phone on the home network. Implemented with `bonsoir` on a device
/// and by a fake in tests; [ManualPeerDiscovery] is the fallback for networks
/// that block mDNS.
abstract class PeerDiscovery {
  /// Starts browsing, if the implementation needs it.
  Future<void> start();

  /// The first phone that answers within [timeout], or null.
  Future<DiscoveredPeer?> find({Duration? timeout});

  Future<void> stop();
}

/// How long a discovery pass waits before reporting that nothing answered.
const Duration defaultDiscoveryTimeout = Duration(seconds: 5);

/// Browses `_tempo._tcp` and resolves a service to a host and port.
class BonsoirPeerDiscovery implements PeerDiscovery {
  static const String defaultServiceType = '_tempo._tcp';

  final String serviceType;
  final Duration timeout;

  BonsoirDiscovery? _discovery;

  BonsoirPeerDiscovery({
    this.serviceType = defaultServiceType,
    this.timeout = defaultDiscoveryTimeout,
  });

  @override
  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(type: serviceType);
    try {
      await discovery.initialize();
      await discovery.start();
    } catch (e) {
      throw DiscoveryUnavailableException('mDNS is unavailable: $e');
    }
    _discovery = discovery;
  }

  @override
  Future<DiscoveredPeer?> find({Duration? timeout}) async {
    await start();
    final discovery = _discovery!;
    final stream = discovery.eventStream;
    if (stream == null) {
      throw const DiscoveryUnavailableException('mDNS is unavailable');
    }

    final found = Completer<DiscoveredPeer?>();
    final subscription = stream.listen((event) {
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        unawaited(
          Future<void>.sync(
            () => discovery.serviceResolver.resolveService(event.service),
          ),
        );
        return;
      }
      if (event is BonsoirDiscoveryServiceResolvedEvent) {
        final peer = _peerFrom(event.service);
        if (peer != null && !found.isCompleted) found.complete(peer);
      }
    });

    try {
      return await found.future.timeout(
        timeout ?? this.timeout,
        onTimeout: () => null,
      );
    } finally {
      await subscription.cancel();
    }
  }

  DiscoveredPeer? _peerFrom(BonsoirService service) {
    final storeId = service.attributes['store'];
    if (storeId == null || storeId.isEmpty) return null;
    final host = service.hostAddresses.isNotEmpty
        ? service.hostAddresses.first
        : service.hostname?.replaceAll(RegExp(r'\.$'), '');
    if (host == null || host.isEmpty) return null;
    return DiscoveredPeer(host: host, port: service.port, storeId: storeId);
  }

  @override
  Future<void> stop() async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery == null) return;
    try {
      await discovery.stop();
    } catch (_) {
      // Stopping a discovery that never started is not an error.
    }
  }
}

/// A discovery that always answers with the peer it was given, for the
/// manual-entry path once the user has typed the phone's host and port.
class ManualPeerDiscovery implements PeerDiscovery {
  DiscoveredPeer? peer;

  ManualPeerDiscovery({this.peer});

  void setPeer({
    required String host,
    required int port,
    required String storeId,
  }) {
    peer = DiscoveredPeer(host: host, port: port, storeId: storeId);
  }

  @override
  Future<void> start() async {}

  @override
  Future<DiscoveredPeer?> find({Duration? timeout}) async => peer;

  @override
  Future<void> stop() async {}
}

/// A discovery that always answers with the peer it was given, counting how
/// often it was asked. Used by the replication tests.
class FakePeerDiscovery implements PeerDiscovery {
  DiscoveredPeer? peer;
  int lookups = 0;

  FakePeerDiscovery({this.peer});

  @override
  Future<void> start() async {}

  @override
  Future<DiscoveredPeer?> find({Duration? timeout}) async {
    lookups++;
    return peer;
  }

  @override
  Future<void> stop() async {}
}

/// Advertises the phone's listener over mDNS.
abstract class PeerAdvertiser {
  Future<void> advertise({
    required String name,
    required int port,
    required String storeId,
  });

  Future<void> stop();
}

/// Publishes `_tempo._tcp` with the store id in its TXT record, so a Mac never
/// pairs with the wrong phone.
class BonsoirPeerAdvertiser implements PeerAdvertiser {
  static const String defaultServiceType = '_tempo._tcp';

  final String serviceType;
  BonsoirBroadcast? _broadcast;

  BonsoirPeerAdvertiser({this.serviceType = defaultServiceType});

  @override
  Future<void> advertise({
    required String name,
    required int port,
    required String storeId,
  }) async {
    await stop();
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: name,
        type: serviceType,
        port: port,
        attributes: {'store': storeId},
      ),
    );
    try {
      await broadcast.initialize();
      await broadcast.start();
    } catch (e) {
      throw DiscoveryUnavailableException('could not advertise over mDNS: $e');
    }
    _broadcast = broadcast;
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast == null) return;
    try {
      await broadcast.stop();
    } catch (_) {
      // The advertiser may already be gone with its engine.
    }
  }
}
