import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:uuid/uuid.dart';

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
  }) : sessionId = Uuid().v4obj();

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final SessionID sessionId;
}

class _MobileConnectionRequest {
  const _MobileConnectionRequest({required this.id, this.peer});

  final String id;
  final Peer? peer;
}

class _AddressBookPeerLabel extends StatelessWidget {
  const _AddressBookPeerLabel({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final name = _MobileConnectionTabPageState._addressBookPeerName(peer);
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

class _MobileConnectionTabPageState extends State<MobileConnectionTabPage> {
  final List<_MobileRemoteSession> _sessions = [];
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
  }

  Future<void> _showNewConnectionDialog() async {
    if (_sessions.length >= _maxConcurrentMobileConnections) {
      showToast(translate(
          'A maximum of 3 connections can stay open on mobile at once.'));
      return;
    }

    final controller = TextEditingController();
    final peers = _addressBookPeers();
    final request = await showDialog<_MobileConnectionRequest>(
      context: context,
      builder: (dialogContext) {
        String? selectedId;
        var enteringIdManually = peers.isEmpty;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final canConnect = enteringIdManually
                ? controller.text.trim().isNotEmpty
                : selectedId != null;
            final selectedPeer = selectedId == null
                ? null
                : peers.firstWhere((peer) => peer.id == selectedId);

            void connect() {
              final id = enteringIdManually ? controller.text : selectedId;
              if (id == null || id.trim().isEmpty) return;
              Navigator.of(dialogContext).pop(_MobileConnectionRequest(
                id: id,
                peer: enteringIdManually ? null : selectedPeer,
              ));
            }

            return AlertDialog(
              title: Text(translate('New connection')),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (peers.isNotEmpty && !enteringIdManually)
                      DropdownButtonFormField<String>(
                        value: selectedId,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: translate('Address book'),
                          hintText: translate('Select a saved device'),
                        ),
                        items: [
                          for (final peer in peers)
                            DropdownMenuItem(
                              value: peer.id,
                              child: _AddressBookPeerLabel(peer: peer),
                            ),
                        ],
                        onChanged: (id) {
                          setDialogState(() => selectedId = id);
                        },
                      )
                    else
                      TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        decoration: InputDecoration(
                          hintText: translate('ID Server'),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                        onSubmitted: (_) => connect(),
                      ),
                    if (peers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          translate('No saved devices in your address book.'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (peers.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setDialogState(() {
                              enteringIdManually = !enteringIdManually;
                            });
                          },
                          icon: Icon(enteringIdManually
                              ? Icons.contacts_outlined
                              : Icons.keyboard_outlined),
                          label: Text(translate(enteringIdManually
                              ? 'Choose from address book'
                              : 'Enter ID manually')),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(translate('Cancel')),
                ),
                TextButton(
                  onPressed: canConnect ? connect : null,
                  child: Text(translate('Connect')),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();

    final candidateId = request?.id.replaceAll(' ', '');
    if (candidateId == null || candidateId.isEmpty || !mounted) return;
    final forceRelay = candidateId.endsWith('/r');
    final normalizedId = forceRelay
        ? candidateId.substring(0, candidateId.length - 2)
        : candidateId;
    if (normalizedId.isEmpty) return;

    final existing = _sessions.indexWhere((e) => e.id == normalizedId);
    if (existing >= 0) {
      setState(() => _selectedIndex = existing);
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

  List<Peer> _addressBookPeers() {
    final peersById = <String, Peer>{};
    for (final peer in gFFI.abModel.allPeers()) {
      if (peer.id.isEmpty) continue;
      final existing = peersById[peer.id];
      if (existing == null ||
          (existing.alias.isEmpty && peer.alias.isNotEmpty)) {
        peersById[peer.id] = peer;
      }
    }
    final peers = peersById.values.toList();
    peers.sort((left, right) =>
        _addressBookPeerName(left).compareTo(_addressBookPeerName(right)));
    return peers;
  }

  static String _addressBookPeerName(Peer peer) {
    if (peer.alias.isNotEmpty) return peer.alias;
    if (peer.hostname.isNotEmpty) return peer.hostname;
    if (peer.username.isNotEmpty) return peer.username;
    return peer.id;
  }

  void _closeSession(SessionID sessionId) {
    final index = _sessions.indexWhere((e) => e.sessionId == sessionId);
    if (index < 0) return;

    final closesLastSession = _sessions.length == 1;
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
          _buildTabStrip(),
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
                    onTap: () => setState(() => _selectedIndex = index),
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
