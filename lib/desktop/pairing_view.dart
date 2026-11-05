import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sync/peer_pairing.dart';
import '../ui/theme/tempo_theme.dart';

/// Pairing runs one way: the phone shows a code, the Mac scans it.
///
/// [PairingInviteView] is the phone's side, a QR of `tempo://pair?h=&p=&s=&id=`
/// with the same values written out for networks where the camera is not the
/// easy path. [PairingView] is the Mac's side: it scans that code and, when the
/// camera or the user prefers typing, accepts the host, port, secret, and store
/// id the phone displays.
///
/// Neither view stores anything itself. Both hand the decoded invite to
/// [PeerPairing], which writes the secret to secure storage and the address to
/// `sync_peers`.
class PairingView extends StatefulWidget {
  final PeerPairing pairing;

  /// Called with the invite once the Mac has adopted it. When null the route
  /// is simply popped with `true`.
  final void Function(PairingInvite invite)? onPaired;

  const PairingView({super.key, required this.pairing, this.onPaired});

  @override
  State<PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<PairingView> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  final TextEditingController _storeController = TextEditingController();

  bool _working = false;
  bool _showManualEntry = false;
  String? _error;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _secretController.dispose();
    _storeController.dispose();
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
      await _save(invite);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _messageFor(e);
      });
    }
  }

  Future<void> _pairManually() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final secret = _secretController.text.trim();
    final storeId = _storeController.text.trim();

    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(() => _error = 'Enter the phone\u2019s host and port.');
      return;
    }
    if (storeId.isEmpty) {
      setState(() => _error = 'Enter the store id the phone shows.');
      return;
    }
    if (!PairingInvite.isValidSecret(secret)) {
      setState(() => _error = 'That secret is not a complete pairing secret.');
      return;
    }

    await _adopt(
      PairingInvite(
        host: host,
        port: port,
        secret: secret,
        storeId: storeId,
      ).encode(),
    );
  }

  Future<void> _save(PairingInvite invite) async {
    await widget.pairing.pairFromInvite(invite);
    if (!mounted) return;
    final onPaired = widget.onPaired;
    if (onPaired != null) {
      onPaired(invite);
    }
    Navigator.of(context).pop(true);
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
          'Pair a phone',
          style: TempoText.title.copyWith(color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Open Tempo on your phone, choose Settings \u2192 Pair this Mac, '
            'then point the camera at the code it shows.',
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

  Widget _buildScanner() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(TempoRadii.card),
      child: SizedBox(
        height: 260,
        child: MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (context, error) => ColoredBox(
            color: TempoColors.surface,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'The camera is not available. Type the details the phone '
                  'shows instead.',
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
    );
  }

  Widget _buildManualEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Type the details the phone shows',
          style: TempoText.label.copyWith(
            color: TempoColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _buildField(_hostController, 'Host, e.g. 192.168.1.24'),
        const SizedBox(height: 8),
        _buildField(
          _portController,
          'Port, e.g. 8756',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 8),
        _buildField(_secretController, 'Secret'),
        const SizedBox(height: 8),
        _buildField(_storeController, 'Store id'),
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

/// The phone's side of pairing: the code to scan, and the same values as text
/// for networks where mDNS is blocked and the camera is inconvenient.
class PairingInviteView extends StatefulWidget {
  final PeerPairing pairing;

  /// The phone's LAN address and listener port, which the invite carries so the
  /// Mac can dial without mDNS.
  final String host;
  final int port;

  /// Overrides the phone's own `store_id`, for a preview or a test.
  final String? storeId;

  /// Drops every pairing secret, including the one on screen. When null the
  /// invite is read-only and only the back arrow leaves it.
  final Future<void> Function()? onRevokeAll;

  const PairingInviteView({
    super.key,
    required this.pairing,
    required this.host,
    required this.port,
    this.storeId,
    this.onRevokeAll,
  });

  @override
  State<PairingInviteView> createState() => _PairingInviteViewState();
}

class _PairingInviteViewState extends State<PairingInviteView> {
  PairingInvite? _invite;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _createInvite();
  }

  Future<void> _createInvite() async {
    try {
      final invite = await widget.pairing.createInvite(
        host: widget.host,
        port: widget.port,
        storeId: widget.storeId,
      );
      if (!mounted) return;
      setState(() => _invite = invite);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not create a pairing code: $e');
    }
  }

  /// Revokes every paired device, which also invalidates the secret shown
  /// here, so the view closes rather than leaving a dead code on screen.
  Future<void> _revokeAll() async {
    final onRevokeAll = widget.onRevokeAll;
    if (onRevokeAll == null || _working) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Revoke every paired device?'),
        content: const Text('Each paired device must pair again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: TempoColors.inkMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text(
              'Revoke all',
              style: TextStyle(
                color: TempoColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _working = true);
    try {
      await onRevokeAll();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'Could not revoke the paired devices: $e';
      });
    }
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
          'Pair this Mac',
          style: TempoText.title.copyWith(color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Show this code to the Mac. It carries one pairing secret, and '
            'the Mac stores it in its Keychain.',
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
                  semanticsLabel: 'Pairing code for this phone',
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'If the Mac cannot use the camera',
              style: TempoText.label.copyWith(
                color: TempoColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _buildValue('Host', invite.host),
            _buildValue('Port', '${invite.port}'),
            _buildValue('Store id', invite.storeId),
          ],
          if (widget.onRevokeAll != null) ...[
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _working
                  ? null
                  : () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: TempoColors.ink,
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
                textStyle: TempoText.body.copyWith(fontWeight: FontWeight.w700),
              ),
              child: const Text('Done'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _working ? null : _revokeAll,
              style: TextButton.styleFrom(
                foregroundColor: TempoColors.textMuted,
                minimumSize: const Size.fromHeight(48),
                textStyle: TempoText.label.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text('Revoke all'),
            ),
          ],
        ],
      ),
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
}
