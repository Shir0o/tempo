import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sync/peer_pairing.dart';
import '../core/sync/sync_client.dart';
import '../ui/theme/tempo_theme.dart';

/// Pairing runs one way: the Mac shows a code, the phone scans it.
///
/// [MacPairingView] is the Mac's side, a QR of `tempo://pair?s=&id=` with the
/// same values written out for a phone whose camera is not the easy path. It
/// carries no address, because the Mac has no listener: the phone keeps the
/// secret and the Mac finds the phone through [SyncClient].
///
/// [PhonePairingView] is the phone's side: it scans that code and hands the
/// decoded invite to [PeerPairing], which stores the secret so the Mac's first
/// signed request is accepted.
class MacPairingView extends StatefulWidget {
  final PeerPairing pairing;

  /// Drives the first exchange while the code is on screen, so the phone is
  /// adopted the moment it scans instead of at the next retry.
  final SyncClient client;

  const MacPairingView({
    super.key,
    required this.pairing,
    required this.client,
  });

  @override
  State<MacPairingView> createState() => _MacPairingViewState();
}

class _MacPairingViewState extends State<MacPairingView> {
  /// How often the page nudges the client and asks whether a phone answered.
  static const Duration _pollInterval = Duration(seconds: 2);

  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  Timer? _poll;
  PairingInvite? _invite;
  String? _error;
  bool _paired = false;
  bool _showManualEntry = false;
  String? _manualAddress;

  /// The phones already paired when this page opened. A phone from that set is
  /// not the one being paired now.
  Set<String> _knownPeers = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _knownPeers = await widget.client.pairedPeerStores();
      final invite = await widget.pairing.createInvite();
      // Replication gates the client, so turning it on is what lets the Mac
      // look for the phone while the code is on screen.
      await widget.client.enableReplication();
      if (!mounted) return;
      setState(() => _invite = invite);
      _poll = Timer.periodic(_pollInterval, (_) => unawaited(_tick()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not create a pairing code: $e');
    }
  }

  Future<void> _tick() async {
    if (_paired) return;
    // Do not stack attempts behind one that is still waiting on discovery.
    if (widget.client.status.value != SyncClientStatus.syncing) {
      widget.client.retryNow();
    }
    final peers = await widget.client.pairedPeerStores();
    if (peers.difference(_knownPeers).isEmpty || !mounted) return;
    _poll?.cancel();
    setState(() => _paired = true);
  }

  /// Dials the typed address once, with the secret in the code on screen. The
  /// peer row is only written when the phone answers, so a typo pairs nothing.
  void _connectManually() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(() => _error = 'Enter the phone\u2019s host and port.');
      return;
    }
    widget.client.setManualPeer(host: host, port: port);
    widget.client.retryNow();
    setState(() {
      _error = null;
      _manualAddress = '$host:$port';
    });
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    final error = _error;

    return Scaffold(
      backgroundColor: TempoColors.background,
      appBar: AppBar(
        backgroundColor: TempoColors.background,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Pair your phone',
          style: TempoText.title.copyWith(color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Open Tempo on your phone, choose Settings \u2192 Mac & devices '
            '\u2192 Pair this Mac, then scan this code.',
            style: TempoText.body.copyWith(
              color: TempoColors.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          if (error != null)
            Text(
              error,
              style: TempoText.body.copyWith(color: const Color(0xFFE5534B)),
            )
          else if (invite == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(color: TempoColors.accent),
              ),
            )
          else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(TempoRadii.card),
                ),
                child: QrImageView(
                  data: invite.encode(),
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  semanticsLabel: 'Pairing code for this Mac',
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildStatus(),
            const SizedBox(height: 20),
            Text(
              'If the phone cannot use the camera',
              style: TempoText.label.copyWith(
                color: TempoColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _buildValue('Store id', invite.storeId),
            _buildValue('Secret', invite.secret),
            const SizedBox(height: 20),
            if (!_showManualEntry)
              Center(
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: TempoColors.accent,
                    minimumSize: const Size(0, 48),
                    textStyle: TempoText.label.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () => setState(() => _showManualEntry = true),
                  child: const Text('Type the phone\u2019s address instead'),
                ),
              )
            else
              _buildManualEntry(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus() {
    if (_paired) {
      return Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            color: TempoColors.accent,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Paired. Tempo is syncing now.',
              style: TempoText.body.copyWith(color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: TempoColors.accent,
              minimumSize: const Size(0, 44),
            ),
            child: const Text('Done'),
          ),
        ],
      );
    }

    final address = _manualAddress;
    return Row(
      children: [
        // Deliberately still: an animated spinner keeps a test's frames from
        // ever settling, and the wait is only as long as the scan.
        const Icon(
          Icons.sensors_rounded,
          color: TempoColors.textMuted,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            address == null
                ? 'Waiting for your phone\u2026'
                : 'Looking for the phone at $address\u2026',
            style: TempoText.label.copyWith(color: TempoColors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildManualEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'mDNS is blocked on some networks. Type the phone\u2019s address '
          'and Tempo dials it with the code above.',
          style: TempoText.label.copyWith(
            color: TempoColors.textMuted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        _buildField(_hostController, 'Host, e.g. 192.168.1.24'),
        const SizedBox(height: 8),
        _buildField(
          _portController,
          'Port, e.g. 8727',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _connectManually,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: TempoColors.ink,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            textStyle: TempoText.body.copyWith(fontWeight: FontWeight.w700),
          ),
          child: const Text('Connect'),
        ),
      ],
    );
  }

  Widget _buildValue(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TempoText.label.copyWith(color: TempoColors.textMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TempoText.body.copyWith(
                color: Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    TextEditingController controller,
    String hint, {
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      style: TempoText.body.copyWith(color: Colors.white),
      cursorColor: TempoColors.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: TempoColors.surface,
        hintText: hint,
        hintStyle: TempoText.body.copyWith(color: TempoColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TempoRadii.row),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// The phone's side of pairing: the camera that reads the code on the Mac, and
/// the store id and secret as text for a phone whose camera is unavailable.
class PhonePairingView extends StatefulWidget {
  final PeerPairing pairing;

  const PhonePairingView({super.key, required this.pairing});

  @override
  State<PhonePairingView> createState() => _PhonePairingViewState();
}

class _PhonePairingViewState extends State<PhonePairingView> {
  /// The part of the preview a code must be inside to be read: a centred
  /// square, so a code held at the edge of the frame does not pair by accident.
  static const Rect _scanWindow = Rect.fromLTWH(0.14, 0.14, 0.72, 0.72);

  final TextEditingController _storeController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();

  bool _working = false;
  bool _showManualEntry = false;
  String? _error;

  @override
  void dispose() {
    _storeController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_working) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || !raw.startsWith('tempo://pair')) continue;
      await _adopt(raw);
      return;
    }
  }

  Future<void> _adopt(String raw) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final invite = PairingInvite.decode(raw);
      if (invite.hasEndpoint) {
        throw const FormatException(
          'That code belongs to a phone. Scan the code Tempo shows on the Mac.',
        );
      }
      await widget.pairing.pairFromInvite(invite);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _messageFor(e);
      });
    }
  }

  Future<void> _pairManually() async {
    final storeId = _storeController.text.trim();
    final secret = _secretController.text.trim();

    if (storeId.isEmpty) {
      setState(() => _error = 'Enter the store id the Mac shows.');
      return;
    }
    if (!PairingInvite.isValidSecret(secret)) {
      setState(() => _error = 'That secret is not a complete pairing secret.');
      return;
    }

    await _adopt(PairingInvite(secret: secret, storeId: storeId).encode());
  }

  String _messageFor(Object error) {
    if (error is FormatException) return error.message;
    return 'Could not pair: $error';
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return Scaffold(
      backgroundColor: TempoColors.background,
      appBar: AppBar(
        backgroundColor: TempoColors.background,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Pair this Mac',
          style: TempoText.title.copyWith(color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Open Tempo on your Mac, choose Settings \u2192 Phone & devices '
            '\u2192 Pair a phone, then point this camera at the code it shows.',
            style: TempoText.body.copyWith(
              color: TempoColors.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _buildScanner(),
          if (error != null) ...[
            const SizedBox(height: 12),
            _buildError(error),
          ],
          const SizedBox(height: 20),
          if (!_showManualEntry)
            Center(
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: TempoColors.accent,
                  minimumSize: const Size(0, 48),
                  textStyle: TempoText.label.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => setState(() => _showManualEntry = true),
                child: const Text('Type the details instead'),
              ),
            )
          else
            _buildManualEntry(),
        ],
      ),
    );
  }

  /// A code-reading window, not the camera at page width: a 320px square is
  /// the size a QR is actually held at, and the scan window inside it means a
  /// code at the edge of the frame does not pair by accident.
  Widget _buildScanner() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TempoRadii.card),
            child: ColoredBox(
              color: TempoColors.surface,
              child: MobileScanner(
                onDetect: _onDetect,
                fit: BoxFit.cover,
                scanWindow: _scanWindow,
                placeholderBuilder: (_) => const Center(
                  child: CircularProgressIndicator(color: TempoColors.accent),
                ),
                overlayBuilder: (context, constraints) => IgnorePointer(
                  child: CustomPaint(
                    painter: const _ScanFramePainter(_scanWindow),
                    child: const SizedBox.expand(),
                  ),
                ),
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Tempo needs the camera to read the code on your Mac. '
                      'Allow Camera for Tempo in your phone\u2019s settings, '
                      'or type the details below.',
                      textAlign: TextAlign.center,
                      style: TempoText.label.copyWith(
                        color: TempoColors.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildManualEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Type the details the Mac shows',
          style: TempoText.label.copyWith(
            color: TempoColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _buildField(_storeController, 'Store id'),
        const SizedBox(height: 8),
        _buildField(_secretController, 'Secret, shown under the code'),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _working ? null : _pairManually,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: TempoColors.ink,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            textStyle: TempoText.body.copyWith(fontWeight: FontWeight.w700),
          ),
          child: Text(_working ? 'Pairing\u2026' : 'Pair this Mac'),
        ),
      ],
    );
  }

  Widget _buildField(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      style: TempoText.body.copyWith(color: Colors.white),
      cursorColor: TempoColors.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: TempoColors.surface,
        hintText: hint,
        hintStyle: TempoText.body.copyWith(color: TempoColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TempoRadii.row),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TempoColors.surface,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        border: Border.all(color: const Color(0xFFE5534B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFE5534B),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TempoText.label.copyWith(color: Colors.white, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dims everything outside the scan window and draws the four corner brackets
/// a code scanner is read through.
class _ScanFramePainter extends CustomPainter {
  static const double _bracketLength = 24;
  static const double _bracketStroke = 3;

  final Rect scanWindow;

  const _ScanFramePainter(this.scanWindow);

  @override
  void paint(Canvas canvas, Size size) {
    final window = Rect.fromLTRB(
      scanWindow.left * size.width,
      scanWindow.top * size.height,
      scanWindow.right * size.width,
      scanWindow.bottom * size.height,
    );

    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(window)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    final bracket = Paint()
      ..color = Colors.white
      ..strokeWidth = _bracketStroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void corner(Offset at, double dx, double dy) {
      canvas.drawLine(at, at.translate(dx * _bracketLength, 0), bracket);
      canvas.drawLine(at, at.translate(0, dy * _bracketLength), bracket);
    }

    corner(window.topLeft, 1, 1);
    corner(window.topRight, -1, 1);
    corner(window.bottomLeft, 1, -1);
    corner(window.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _ScanFramePainter oldDelegate) =>
      oldDelegate.scanWindow != scanWindow;
}
