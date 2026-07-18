import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/diagnostics.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:uuid/uuid.dart';

import '../remote_tab_lifecycle.dart';
import 'remote_page.dart';

const _maxConcurrentMobileConnections = 3;

class MobileConnectionTabPage extends StatefulWidget {
  const MobileConnectionTabPage({
    super.key,
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  });

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  @override
  State<MobileConnectionTabPage> createState() =>
      _MobileConnectionTabPageState();
}

class _MobileRemoteSession {
  _MobileRemoteSession({
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  }) {
    sessionId = Uuid().v4obj();
    lifecycleTarget = MobileSessionLifecycleTarget(
      sessionId: sessionId.toString(),
      peerId: id,
    );
  }

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  late final SessionID sessionId;
  late final MobileSessionLifecycleTarget lifecycleTarget;
}

class _MobileConnectionRequest {
  const _MobileConnectionRequest({required this.id, this.peer});

  final String id;
  final Peer? peer;
}

enum _MobileConnectionPickerSource { addressBook, recent, manual }

String _peerDisplayName(Peer peer) {
  if (peer.alias.isNotEmpty) return peer.alias;
  if (peer.hostname.isNotEmpty) return peer.hostname;
  if (peer.username.isNotEmpty) return peer.username;
  return peer.id;
}

List<Peer> _deduplicatePeers(Iterable<Peer> source, {bool sort = false}) {
  final peersById = <String, Peer>{};
  for (final peer in source) {
    if (peer.id.isEmpty) continue;
    final existing = peersById[peer.id];
    if (existing == null || (existing.alias.isEmpty && peer.alias.isNotEmpty)) {
      peersById[peer.id] = peer;
    }
  }
  final peers = peersById.values.toList();
  if (sort) {
    peers.sort((left, right) =>
        _peerDisplayName(left).compareTo(_peerDisplayName(right)));
  }
  return peers;
}

class _ConnectionSourceDialog extends StatelessWidget {
  const _ConnectionSourceDialog();

  @override
  Widget build(BuildContext context) {
    void choose(_MobileConnectionPickerSource source) {
      Navigator.of(context).pop(source);
    }

    return AlertDialog(
      title: Text(translate('New connection')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: () =>
                  choose(_MobileConnectionPickerSource.addressBook),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(translate('Address book')),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => choose(_MobileConnectionPickerSource.recent),
              icon: const Icon(Icons.history),
              label: Text(translate('Recent')),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => choose(_MobileConnectionPickerSource.manual),
              icon: const Icon(Icons.keyboard_outlined),
              label: Text(translate('Enter ID manually')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('Cancel')),
        ),
      ],
    );
  }
}

class _MobileConnectionPickerDialog extends StatefulWidget {
  const _MobileConnectionPickerDialog({required this.source});

  final _MobileConnectionPickerSource source;

  @override
  State<_MobileConnectionPickerDialog> createState() =>
      _MobileConnectionPickerDialogState();
}

class _MobileConnectionPickerDialogState
    extends State<_MobileConnectionPickerDialog> {
  final _controller = TextEditingController();
  String? _selectedId;
  late bool _enteringIdManually;

  @override
  void initState() {
    super.initState();
    _enteringIdManually = widget.source == _MobileConnectionPickerSource.manual;
    if (widget.source == _MobileConnectionPickerSource.recent) {
      gFFI.recentPeersModel.addListener(_refreshRecentPeers);
      bind.mainLoadRecentPeers();
    }
  }

  @override
  void dispose() {
    if (widget.source == _MobileConnectionPickerSource.recent) {
      gFFI.recentPeersModel.removeListener(_refreshRecentPeers);
    }
    _controller.dispose();
    super.dispose();
  }

  void _refreshRecentPeers() {
    if (mounted) setState(() {});
  }

  List<Peer> get _peers {
    switch (widget.source) {
      case _MobileConnectionPickerSource.addressBook:
        return _deduplicatePeers(gFFI.abModel.allPeers(), sort: true);
      case _MobileConnectionPickerSource.recent:
        final model = gFFI.recentPeersModel;
        return _deduplicatePeers([
          ...model.peers,
          for (final id in model.restPeerIds) Peer.fromJson({'id': id}),
        ]);
      case _MobileConnectionPickerSource.manual:
        return const [];
    }
  }

  String get _sourceLabel {
    switch (widget.source) {
      case _MobileConnectionPickerSource.addressBook:
        return translate('Address book');
      case _MobileConnectionPickerSource.recent:
        return translate('Recent');
      case _MobileConnectionPickerSource.manual:
        return translate('New connection');
    }
  }

  String get _emptyMessage =>
      widget.source == _MobileConnectionPickerSource.recent
          ? translate('No recent connections.')
          : translate('No saved devices in your address book.');

  Peer? _selectedPeer(List<Peer> peers) {
    for (final peer in peers) {
      if (peer.id == _selectedId) return peer;
    }
    return null;
  }

  void _connect(List<Peer> peers) {
    final peer = _selectedPeer(peers);
    final id = _enteringIdManually ? _controller.text : peer?.id;
    if (id == null || id.trim().isEmpty) return;
    Navigator.of(context).pop(_MobileConnectionRequest(
      id: id,
      peer: _enteringIdManually ? null : peer,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final peers = _peers;
    final selectedPeer = _selectedPeer(peers);
    final showManualField = _enteringIdManually || peers.isEmpty;
    final canConnect = showManualField
        ? _controller.text.trim().isNotEmpty
        : selectedPeer != null;

    return AlertDialog(
      title: Text(_sourceLabel),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showManualField)
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(hintText: translate('ID Server')),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _connect(peers),
              )
            else
              DropdownButtonFormField<String>(
                value: selectedPeer?.id,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _sourceLabel,
                  hintText: translate('Select a saved device'),
                ),
                items: [
                  for (final peer in peers)
                    DropdownMenuItem(
                      value: peer.id,
                      child: _ConnectionPeerLabel(peer: peer),
                    ),
                ],
                onChanged: (id) => setState(() => _selectedId = id),
              ),
            if (peers.isEmpty &&
                widget.source != _MobileConnectionPickerSource.manual)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _emptyMessage,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (peers.isNotEmpty &&
                widget.source != _MobileConnectionPickerSource.manual)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _enteringIdManually = !_enteringIdManually;
                    });
                  },
                  icon: Icon(_enteringIdManually
                      ? Icons.arrow_back_outlined
                      : Icons.keyboard_outlined),
                  label: Text(_enteringIdManually
                      ? _sourceLabel
                      : translate('Enter ID manually')),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('Cancel')),
        ),
        TextButton(
          onPressed: canConnect ? () => _connect(peers) : null,
          child: Text(translate('Connect')),
        ),
      ],
    );
  }
}

class _ConnectionPeerLabel extends StatelessWidget {
  const _ConnectionPeerLabel({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final name = _peerDisplayName(peer);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, overflow: TextOverflow.ellipsis),
        if (name != peer.id)
          Text(
            peer.id,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _MobileConnectionTabPageState extends State<MobileConnectionTabPage>
    with WidgetsBindingObserver {
  final List<_MobileRemoteSession> _sessions = [];
  late final MobileTabLifecycleCoordinator _lifecycleCoordinator;
  late final MobileSessionCloseCoordinator<SessionID> _closeCoordinator;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _sessions.add(_MobileRemoteSession(
      id: widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    ));
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _lifecycleCoordinator = MobileTabLifecycleCoordinator(
      initiallyBackgrounded:
          lifecycleState != null && lifecycleState != AppLifecycleState.resumed,
    );
    _closeCoordinator = MobileSessionCloseCoordinator<SessionID>(
      onCloseRequested: (sessionId) {
        unawaited(bind.sessionClose(sessionId: sessionId));
      },
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleCoordinator.dispose();
    for (final session in _sessions) {
      _requestNativeClose(session, source: 'tab_host_disposed');
    }
    super.dispose();
  }

  void _requestNativeClose(_MobileRemoteSession session,
      {required String source}) {
    if (!_closeCoordinator.request(session.sessionId)) return;
    unawaited(DiagnosticSupport.event('mobile_native_session_close_requested', {
      'session_id': session.sessionId.toString(),
      'peer_id': session.id,
      'source': source,
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_sessions.isEmpty) return;
    final targets =
        _sessions.map((session) => session.lifecycleTarget).toList();
    final selected = _sessions[_selectedIndex].lifecycleTarget;
    final changed = state == AppLifecycleState.resumed
        ? _lifecycleCoordinator.resumeAll(targets, selected: selected)
        : state == AppLifecycleState.inactive ||
                state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused
            ? _lifecycleCoordinator.pauseAll(targets)
            : false;
    if (changed) {
      unawaited(DiagnosticSupport.event('mobile_tabs_lifecycle_coordinated', {
        'state': state.name,
        'session_count': targets.length,
        'selected_session_id': selected.sessionId,
        'selected_peer_id': selected.peerId,
      }));
    }
  }

  Future<void> _showNewConnectionDialog() async {
    if (_sessions.length >= _maxConcurrentMobileConnections) {
      showToast(translate(
          'A maximum of 3 connections can stay open on mobile at once.'));
      return;
    }

    final source = await showDialog<_MobileConnectionPickerSource>(
      context: context,
      builder: (_) => const _ConnectionSourceDialog(),
    );
    if (source == null || !mounted) return;

    final request = await showDialog<_MobileConnectionRequest>(
      context: context,
      builder: (_) => _MobileConnectionPickerDialog(source: source),
    );

    final candidateId = request?.id.replaceAll(' ', '');
    if (candidateId == null || candidateId.isEmpty || !mounted) return;
    final forceRelay = candidateId.endsWith('/r');
    final normalizedId = forceRelay
        ? candidateId.substring(0, candidateId.length - 2)
        : candidateId;
    if (normalizedId.isEmpty) return;

    final existing = _sessions.indexWhere((e) => e.id == normalizedId);
    if (existing >= 0) {
      _selectSession(existing);
      return;
    }

    setState(() {
      _sessions.add(_MobileRemoteSession(
        id: normalizedId,
        password: request?.peer?.password.isNotEmpty == true
            ? request?.peer?.password
            : null,
        isSharedPassword: request?.peer?.password.isNotEmpty == true,
        forceRelay: forceRelay || (request?.peer?.forceAlwaysRelay ?? false),
      ));
      _selectedIndex = _sessions.length - 1;
    });
  }

  void _closeSession(SessionID sessionId) {
    final index = _sessions.indexWhere((e) => e.sessionId == sessionId);
    if (index < 0) return;

    final closesLastSession = _sessions.length == 1;
    final closingSession = _sessions[index];
    _lifecycleCoordinator.remove(closingSession.lifecycleTarget);
    _requestNativeClose(closingSession, source: 'tab_removed');
    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isNotEmpty) {
        if (_selectedIndex > index) {
          _selectedIndex -= 1;
        } else if (_selectedIndex >= _sessions.length) {
          _selectedIndex = _sessions.length - 1;
        }
      }
    });

    if (closesLastSession) {
      stateGlobal.isInMainPage = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
              overlays: []);
        }
      });
    }
  }

  void _selectSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    setState(() => _selectedIndex = index);
    final target = _sessions[index].lifecycleTarget;
    if (_lifecycleCoordinator.prioritize(target)) {
      unawaited(DiagnosticSupport.event('mobile_tab_resume_prioritized', {
        'session_id': target.sessionId,
        'peer_id': target.peerId,
      }));
    }
  }

  Future<void> _confirmCloseSession(_MobileRemoteSession session) async {
    final shouldClose = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(translate('Close')),
            content: Text(translate('Are you sure to close the connection?')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(translate('Cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(translate('Close')),
              ),
            ],
          ),
        ) ??
        false;
    if (shouldClose) _closeSession(session.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MyTheme.canvasColor,
      child: Column(
        children: [
          ColoredBox(
            color: MyTheme.accent,
            child: SafeArea(
              bottom: false,
              child: _buildTabStrip(),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                for (var i = 0; i < _sessions.length; i++)
                  () {
                    final session = _sessions[i];
                    return RemotePage(
                      key: ValueKey(session.sessionId),
                      id: session.id,
                      sessionId: session.sessionId,
                      password: session.password,
                      isSharedPassword: session.isSharedPassword,
                      forceRelay: session.forceRelay,
                      active: i == _selectedIndex,
                      lifecycleTarget: session.lifecycleTarget,
                      closeNativeSessionOnDispose: false,
                      restoreGlobalUiOnDispose: _sessions.length == 1,
                      onCloseRequested: () => _closeSession(session.sessionId),
                    );
                  }(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabStrip() {
    return SizedBox(
      height: 44,
      child: ColoredBox(
        color: MyTheme.accent,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final selected = index == _selectedIndex;
                  return InkWell(
                    onTap: () => _selectSession(index),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 118),
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      decoration: BoxDecoration(
                        color: selected ? Colors.black26 : Colors.transparent,
                        border: const Border(
                          right: BorderSide(color: Colors.white24),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected
                                ? Icons.desktop_windows
                                : Icons.desktop_windows_outlined,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 94),
                            child: Text(
                              session.id,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          IconButton(
                            tooltip: translate('Close'),
                            icon: const Icon(Icons.close,
                                color: Colors.white, size: 18),
                            onPressed: () => _confirmCloseSession(session),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            IconButton(
              tooltip: translate('New connection'),
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: _showNewConnectionDialog,
            ),
          ],
        ),
      ),
    );
  }
}
