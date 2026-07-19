import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/diagnostics.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse_widgets.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/connection_policy.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../utils/image.dart';
import '../ime_input_diff.dart';
import '../keyboard_image_paste.dart';
import '../native_android_ime.dart';
import '../outgoing_session_keepalive.dart';
import '../remote_tab_lifecycle.dart';
import '../widgets/dialog.dart';
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

class RemotePage extends StatefulWidget {
  RemotePage(
      {Key? key,
      required this.id,
      required this.sessionId,
      this.password,
      this.isSharedPassword,
      this.forceRelay,
      this.active = true,
      required this.lifecycleTarget,
      this.closeNativeSessionOnDispose = true,
      this.restoreGlobalUiOnDispose = true,
      this.onCloseRequested})
      : super(key: key);

  final String id;
  final SessionID sessionId;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final bool active;
  final MobileSessionLifecycleTarget lifecycleTarget;
  final bool closeNativeSessionOnDispose;
  final bool restoreGlobalUiOnDispose;
  final VoidCallback? onCloseRequested;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage> {
  late final FFI _ffi;
  Timer? _timer;
  bool _showBar = !isWebDesktop;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;
  Timer? _resumeOverlayTimer;
  bool _awaitingResumeFrame = false;
  late final MobileInputLifecycleGuard _inputLifecycleGuard;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  final NativeAndroidImeController _nativeAndroidImeController =
      NativeAndroidImeController();
  var _showEdit = false; // use soft keyboard

  Worker? _waylandKeyboardGateWorker;
  bool _waylandKeyboardGateInitialized = false;

  InputModel get inputModel => _ffi.inputModel;
  SessionID get sessionId => _ffi.sessionId;

  Future<void> _applySavedMouseStartPosition() async {
    final position = mouseStartPositionFromOption(
        bind.mainGetLocalOption(key: kOptionMouseStartPosition));
    if (position == MouseStartPosition.none) return;

    // The first image normally arrives after the remote display rectangle is
    // known. Retry briefly for slower peers, rather than guessing from local
    // canvas dimensions before the screen geometry is available.
    for (var attempt = 0; attempt < 3 && mounted; attempt++) {
      if (await inputModel.moveMouseToStartPosition(position)) return;
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  final TextEditingController _textController =
      TextEditingController(text: initText);

  _RemotePageState(String id) {
    initSharedStates(id);
  }

  @override
  void initState() {
    super.initState();
    unawaited(DiagnosticSupport.event('mobile_session_started', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'force_relay': widget.forceRelay ?? false,
      'active': widget.active,
    }));
    _ffi = FFI(widget.sessionId);
    _inputLifecycleGuard = MobileInputLifecycleGuard(
      active: widget.active,
      releaseModifiers: _releaseMobileModifiers,
    );
    widget.lifecycleTarget.attach(
      onPaused: _handleAppPaused,
      onResumed: _handleAppResumed,
    );
    _ffi.imageModel.setPresentationActive(widget.active);
    _ffi.imageModel.addCallbackOnFrame(_handleIncomingFrame);
    _ffi.onCloseRequested = widget.onCloseRequested;
    _ffi.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    _ffi.dialogManager.loadMobileActionsOverlayVisible();
    _ffi.ffiModel.updateEventListener(sessionId, widget.id);
    _ffi.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: _ffi.requestClose);
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    _ffi.inputModel.listenToMouse(true);
    _ffi.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    keyboardSubscription =
        keyboardVisibilityController.onChange.listen(onSoftKeyboardChanged);
    _ffi.chatModel
        .changeCurrentKey(MessageKey(widget.id, ChatModel.clientModeID));
    _blockableOverlayState.applyFfi(_ffi);
    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      unawaited(DiagnosticSupport.event('mobile_first_image', {
        'session_id': widget.sessionId.toString(),
        'peer_id': peerId,
        'active': widget.active,
      }));
      _ffi.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: _ffi.sessionId));
      if (_ffi.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
          isKeyboardVisible: keyboardVisibilityController.isVisible);
      unawaited(_applySavedMouseStartPosition());
    });
    inputModel.keyboardInputAllowed = true;

    // Wayland sessions may use clipboard-based text input on the controlled side.
    // Require explicit user confirmation before allowing soft-keyboard and
    // clipboard-assisted text input. Physical keyboard events are not gated here.
    _waylandKeyboardGateWorker = ever(_ffi.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) {
        _initWaylandKeyboardGateIfNeeded();
      }
    });
    if (_ffi.ffiModel.pi.isSet.value) {
      _initWaylandKeyboardGateIfNeeded();
    }
  }

  @override
  void didUpdateWidget(covariant RemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    unawaited(DiagnosticSupport.event('mobile_tab_active_changed', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'active': widget.active,
    }));
    _inputLifecycleGuard.setActive(widget.active);
    _ffi.imageModel.setPresentationActive(widget.active);
    if (widget.active) {
      _physicalFocusNode.requestFocus();
      if (_ffi.ffiModel.pi.isSet.value) {
        unawaited(sessionRefreshVideo(_ffi.sessionId, _ffi.ffiModel.pi));
        unawaited(DiagnosticSupport.event('mobile_tab_video_refreshed', {
          'session_id': widget.sessionId.toString(),
          'peer_id': widget.id,
        }));
      }
      return;
    }
    _showEdit = false;
    _unfocusSoftKeyboardEditor();
  }

  @override
  Future<void> dispose() async {
    unawaited(DiagnosticSupport.event('mobile_session_disposed', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'active': widget.active,
    }));
    widget.lifecycleTarget.detach();
    _resumeOverlayTimer?.cancel();
    _ffi.imageModel.removeCallbackOnFrame(_handleIncomingFrame);
    _inputLifecycleGuard.dispose();
    // A standalone page owns its native close and dispatches it before any async
    // UI cleanup. The multi-tab host owns native session teardown explicitly, so
    // keyed child reconciliation can never close a sibling session by mistake.
    if (widget.closeNativeSessionOnDispose) {
      unawaited(bind.sessionClose(sessionId: sessionId));
    }
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    _ffi.dialogManager.hideMobileActionsOverlay(store: false);
    _ffi.inputModel.listenToMouse(false);
    _ffi.imageModel.disposeImage();
    _ffi.cursorModel.disposeImages();
    if (widget.restoreGlobalUiOnDispose) {
      await _ffi.invokeMethod("enable_soft_keyboard", true);
    }
    _nativeAndroidImeController.hide();
    _nativeAndroidImeController.reset();
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());
    _waylandKeyboardGateWorker?.dispose();
    inputModel.keyboardInputAllowed = true;
    await _ffi.close(closeSession: widget.closeNativeSessionOnDispose);
    _timer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    _ffi.dialogManager.dismissAll();
    if (widget.restoreGlobalUiOnDispose) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    }
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    _ffi.chatModel.onVoiceCallClosed("End connetion");
  }

  void _handleAppPaused() {
    _resumeOverlayTimer?.cancel();
    _awaitingResumeFrame = false;
    _inputLifecycleGuard.pause();
    _ffi.ffiModel.onMobileAppPaused(
        allowBackgroundRecovery: mobileOutgoingSessionKeepaliveEnabled());
    unawaited(DiagnosticSupport.event('mobile_session_lifecycle_applied', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'state': AppLifecycleState.paused.name,
      'active': widget.active,
    }));
  }

  void _releaseMobileModifiers(String reason) {
    final hadCtrl = inputModel.ctrl;
    final hadAlt = inputModel.alt;
    final hadShift = inputModel.shift;
    final hadCommand = inputModel.command;
    inputModel.releaseAllModifiers();
    unawaited(DiagnosticSupport.event('mobile_modifiers_released', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'reason': reason,
      'had_ctrl': hadCtrl,
      'had_alt': hadAlt,
      'had_shift': hadShift,
      'had_command': hadCommand,
    }));
  }

  void _handleAppResumed() {
    _resumeOverlayTimer?.cancel();
    if (mounted) {
      setState(() => _awaitingResumeFrame = true);
    } else {
      _awaitingResumeFrame = true;
    }
    if (widget.active) trySyncClipboard();
    final reconnectDispatched = _ffi.ffiModel.onMobileAppResumed();
    unawaited(DiagnosticSupport.event('mobile_session_lifecycle_applied', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'state': AppLifecycleState.resumed.name,
      'active': widget.active,
      'reconnect_dispatched': reconnectDispatched,
    }));
    if (!reconnectDispatched) {
      if (_ffi.ffiModel.pi.isSet.value) {
        // Ask the controlled peer for a key frame. A live transport responds
        // even when the desktop is otherwise static, so this distinguishes a
        // healthy retained socket from Android's common half-open resume case.
        unawaited(sessionRefreshVideo(_ffi.sessionId, _ffi.ffiModel.pi));
        unawaited(DiagnosticSupport.event('mobile_resume_probe_sent', {
          'session_id': widget.sessionId.toString(),
          'peer_id': widget.id,
          'active': widget.active,
        }));
        _resumeOverlayTimer = Timer(kMobileResumeFrameProbeTimeout, () {
          _resumeOverlayTimer = null;
          if (!mounted || !_awaitingResumeFrame) return;
          final started = _ffi.ffiModel.beginMobileResumeRecovery();
          unawaited(DiagnosticSupport.event('mobile_resume_probe_timed_out', {
            'session_id': widget.sessionId.toString(),
            'peer_id': widget.id,
            'active': widget.active,
            'reconnect_dispatched': started,
          }));
          if (!started) {
            _clearResumeOverlay(source: 'reconnect_unavailable');
          }
        });
      } else {
        // The session was still making its first connection when Android
        // backgrounded it. Let that initial native handshake continue.
        _resumeOverlayTimer = Timer(const Duration(milliseconds: 750), () {
          _clearResumeOverlay(source: 'initial_connection');
        });
      }
    }
  }

  void _handleIncomingFrame() {
    _ffi.ffiModel.onMobileFrameHealthy();
    if (!_awaitingResumeFrame) return;
    _clearResumeOverlay(source: 'fresh_frame');
  }

  void _clearResumeOverlay({required String source}) {
    if (!_awaitingResumeFrame) return;
    _resumeOverlayTimer?.cancel();
    _resumeOverlayTimer = null;
    _awaitingResumeFrame = false;
    if (mounted) setState(() {});
    unawaited(DiagnosticSupport.event('mobile_resume_guard_cleared', {
      'session_id': widget.sessionId.toString(),
      'peer_id': widget.id,
      'active': widget.active,
      'source': source,
    }));
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
  void trySyncClipboard() {
    _ffi.invokeMethod("try_sync_clipboard");
  }

  bool _shouldGateKeyboardForWayland() {
    if (!(isAndroid || isIOS)) return false;
    final pi = _ffi.ffiModel.pi;
    return pi.platform == kPeerPlatformLinux && pi.isWayland;
  }

  void _initWaylandKeyboardGateIfNeeded() {
    if (!mounted) return;
    if (_waylandKeyboardGateInitialized) return;
    if (!_shouldGateKeyboardForWayland()) return;

    _waylandKeyboardGateInitialized = true;

    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (!shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = true;
      return;
    }

    inputModel.keyboardInputAllowed = false;

    // Ensure soft keyboard is not active before user confirms.
    _showEdit = false;
    _ffi.invokeMethod("enable_soft_keyboard", false);
    _unfocusSoftKeyboardEditor();
    _physicalFocusNode.requestFocus();
    setState(() {});
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
        /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
        /// see override build() in [BlockableOverlay]
        state: _blockableOverlayState,
        underlying: Container(
          color: bgColor,
        ),
      );

  void onSoftKeyboardChanged(bool visible) {
    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (_ffi.chatModel.chatWindowOverlayEntry == null &&
          _ffi.ffiModel.pi.version.isNotEmpty) {
        _ffi.invokeMethod("enable_soft_keyboard", false);
      }

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted) return;
            _physicalFocusNode.requestFocus();
          });
        });
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _focusSoftKeyboardEditor();
      });
    }
    // update for Scaffold
    setState(() {});
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (;
        common < subOldValue.length &&
            common < subNewValue.length &&
            subNewValue[common] == subOldValue[common];
        ++common) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength = _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
    if (newStr.length > 1) {
      bind.sessionInputString(sessionId: sessionId, value: newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String _) {
    _applyAndroidImeEditingValue(_textController.value);
  }

  void _applyAndroidImeEditingValue(TextEditingValue editingValue) {
    final plan = planAndroidImeEdit(
      sentValue: _value,
      editingValue: editingValue,
    );
    if (plan.deferred) {
      return;
    }
    _value = plan.nextSentValue;

    final content = plan.insertText;
    if (!plan.hasRemoteEdit) {
      return;
    }

    bind.sessionApplyInputEdit(
      sessionId: sessionId,
      deleteCount: plan.deleteCount,
      value: content,
      alt: inputModel.alt,
      ctrl: inputModel.ctrl,
      shift: inputModel.shift,
      command: inputModel.command,
    );

    if (plan.deleteCount == 0 &&
        content.length == 2 &&
        (content == '""' ||
            content == '()' ||
            content == '[]' ||
            content == '<>' ||
            content == "{}" ||
            content == '”“' ||
            content == '《》' ||
            content == '（）' ||
            content == '【】')) {
      // Restart the hidden input after auto-paired punctuation so the closing
      // character is not consumed by the local editor on the next keystroke.
      _openKeyboardUnlocked();
    }
  }

  Future<void> _pasteAndroidClipboardImage() async {
    try {
      final payload = await platformFFI.invokeMethod('read_clipboard_image');
      final parsed = parseAndroidImagePayload(payload);
      if (parsed == null) {
        showToast(translate('No image found in the Android clipboard'));
        return;
      }
      await _pasteImageBytes(parsed.bytes, parsed.mimeType);
    } catch (e) {
      debugPrint('Failed to read Android clipboard image: $e');
      if (mounted) {
        showToast(translate('Unable to read the Android clipboard image'));
      }
    }
  }

  Future<void> _pasteImageBytes(Uint8List bytes, String mimeType) async {
    if (!inputModel.keyboardInputAllowed || !inputModel.keyboardPerm) {
      showToast(translate('Keyboard input is not permitted'));
      return;
    }
    if (_ffi.ffiModel.permissions['clipboard'] == false) {
      showToast(translate('Clipboard permission is required'));
      return;
    }

    if (bytes.length > kMaxKeyboardImageBytes) {
      showToast(translate('The image is too large to paste'));
      return;
    }

    try {
      final png = await compute(
        normalizeKeyboardImageToPng,
        (bytes: bytes, mimeType: mimeType),
      );
      if (!mounted || png == null) {
        if (mounted) {
          showToast(translate('Unable to paste this image'));
        }
        return;
      }

      final pasted = bind.sessionPasteKeyboardImage(
        sessionId: sessionId,
        png: png,
        useCommand: _ffi.ffiModel.pi.platform == kPeerPlatformMacOS,
      );
      showToast(translate(
          pasted ? 'Image sent to remote clipboard' : 'Unable to paste image'));
    } catch (e) {
      debugPrint('Failed to paste keyboard image: $e');
      if (mounted) {
        showToast(translate('Unable to paste this image'));
      }
    }
  }

  // handle mobile virtual keyboard
  void handleSoftKeyboardInput(String newValue) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void openKeyboard() {
    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = false;
      showWaylandKeyboardInputWarningDialog(
        id: widget.id,
        connectionId: sessionId.toString(),
        ffi: _ffi,
        onEnable: () async {
          _openKeyboardUnlocked();
        },
      );
      return;
    }
    _openKeyboardUnlocked();
  }

  void _openKeyboardUnlocked() {
    inputModel.keyboardInputAllowed = true;
    _ffi.invokeMethod("enable_soft_keyboard", true);
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _focusSoftKeyboardEditor();
      });
    });
  }

  void _focusSoftKeyboardEditor() {
    if (isAndroid) {
      _nativeAndroidImeController.show();
    } else {
      _mobileFocusNode.requestFocus();
    }
  }

  void _unfocusSoftKeyboardEditor() {
    if (isAndroid) {
      _nativeAndroidImeController.hide();
    }
    _mobileFocusNode.unfocus();
  }

  Widget _bottomWidget() => _showGestureHelp
      ? getGestureHelp()
      : (_showBar && _ffi.ffiModel.pi.displays.isNotEmpty
          ? getBottomAppBar()
          : Offstage());

  @override
  Widget build(BuildContext context) {
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showActionButton = !_showBar || keyboardIsVisible || _showGestureHelp;

    return WillPopScope(
      onWillPop: () async {
        clientClose(sessionId, _ffi);
        return false;
      },
      child: MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: _ffi.ffiModel),
            ChangeNotifierProvider.value(value: _ffi.imageModel),
            ChangeNotifierProvider.value(value: _ffi.cursorModel),
            ChangeNotifierProvider.value(value: _ffi.canvasModel),
            ChangeNotifierProvider.value(value: _ffi.recordingModel),
          ],
          child: Scaffold(
              // workaround for https://github.com/rustdesk/rustdesk/issues/3131
              floatingActionButtonLocation: keyboardIsVisible
                  ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
                  : null,
              floatingActionButton: !showActionButton
                  ? null
                  : FloatingActionButton(
                      mini: !keyboardIsVisible,
                      child: Icon(
                        (keyboardIsVisible || _showGestureHelp)
                            ? Icons.expand_more
                            : Icons.expand_less,
                        color: Colors.white,
                      ),
                      backgroundColor: MyTheme.accent,
                      onPressed: () {
                        setState(() {
                          if (keyboardIsVisible) {
                            _showEdit = false;
                            _ffi.invokeMethod("enable_soft_keyboard", false);
                            _unfocusSoftKeyboardEditor();
                            _physicalFocusNode.requestFocus();
                          } else if (_showGestureHelp) {
                            _showGestureHelp = false;
                          } else {
                            _showBar = !_showBar;
                          }
                        });
                      }),
              bottomNavigationBar: Obx(() => Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      _ffi.ffiModel.pi.isSet.isTrue &&
                              _ffi.ffiModel.waitForFirstImage.isTrue
                          ? emptyOverlay(MyTheme.canvasColor)
                          : () {
                              _ffi.ffiModel.tryShowAndroidActionsOverlay();
                              return Offstage();
                            }(),
                      _bottomWidget(),
                      _ffi.ffiModel.pi.isSet.isFalse
                          ? emptyOverlay(MyTheme.canvasColor)
                          : Offstage(),
                    ],
                  )),
              body: Obx(
                () => getRawPointerAndKeyBody(Overlay(
                  initialEntries: [
                    OverlayEntry(builder: (context) {
                      return Container(
                        color: kColorCanvas,
                        child: isWebDesktop
                            ? getBodyForDesktopWithListener()
                            : SafeArea(
                                child: OrientationBuilder(
                                    builder: (ctx, orientation) {
                                  if (_currentOrientation != orientation) {
                                    Timer(const Duration(milliseconds: 200),
                                        () {
                                      _ffi.dialogManager
                                          .resetMobileActionsOverlay(ffi: _ffi);
                                      _currentOrientation = orientation;
                                      _ffi.canvasModel.updateViewStyle();
                                    });
                                  }
                                  return Container(
                                    color: MyTheme.canvasColor,
                                    child: inputModel.isPhysicalMouse.value
                                        ? getBodyForMobile()
                                        : RawTouchGestureDetectorRegion(
                                            child: getBodyForMobile(),
                                            ffi: _ffi,
                                          ),
                                  );
                                }),
                              ),
                      );
                    }),
                    OverlayEntry(builder: (context) {
                      if (!_awaitingResumeFrame) return const Offstage();
                      return IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: MyTheme.canvasColor.withAlpha(235),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 14,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(translate('Connecting...')),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    })
                  ],
                )),
              ))),
    );
  }

  Widget getRawPointerAndKeyBody(Widget child) {
    final ffiModel = _ffi.ffiModel;
    return RawPointerMouseRegion(
      cursor: ffiModel.keyboard ? SystemMouseCursors.none : MouseCursor.defer,
      inputModel: inputModel,
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: _ffi.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child)
          : child,
    );
  }

  Widget getBottomAppBar() {
    final ffiModel = _ffi.ffiModel;
    return BottomAppBar(
      elevation: 10,
      color: MyTheme.accent,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
              children: <Widget>[
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.clear),
                      onPressed: () {
                        clientClose(sessionId, _ffi);
                      },
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.tv),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showOptions(
                            context, widget.id, _ffi.dialogManager, _ffi);
                      },
                    )
                  ] +
                  (isWebDesktop || ffiModel.viewOnly || !ffiModel.keyboard
                      ? []
                      : _ffi.ffiModel.isPeerAndroid
                          ? [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              IconButton(
                                color: Colors.white,
                                icon: const Icon(Icons.build),
                                onPressed: () => _ffi.dialogManager
                                    .toggleMobileActionsOverlay(ffi: _ffi),
                              )
                            ]
                          : [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              if (isAndroid)
                                IconButton(
                                  color: Colors.white,
                                  tooltip: translate(
                                      'Paste image from Android clipboard'),
                                  icon: const Icon(Icons.add_photo_alternate),
                                  onPressed: _pasteAndroidClipboardImage,
                                ),
                              IconButton(
                                color: Colors.white,
                                icon: Icon(_ffi.ffiModel.touchMode
                                    ? Icons.touch_app
                                    : Icons.mouse),
                                onPressed: () => setState(
                                    () => _showGestureHelp = !_showGestureHelp),
                              ),
                            ]) +
                  (isWeb
                      ? []
                      : <Widget>[
                          futureBuilder(
                              future: _ffi.invokeMethod(
                                  "get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
                              hasData: (isSupportVoiceCall) => IconButton(
                                    color: Colors.white,
                                    icon: isAndroid && isSupportVoiceCall
                                        ? SvgPicture.asset('assets/chat.svg',
                                            colorFilter: ColorFilter.mode(
                                                Colors.white, BlendMode.srcIn))
                                        : Icon(Icons.message),
                                    onPressed: () =>
                                        isAndroid && isSupportVoiceCall
                                            ? showChatOptions(widget.id)
                                            : onPressedTextChat(widget.id),
                                  ))
                        ]) +
                  [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.more_vert),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showActions(widget.id);
                      },
                    ),
                  ]),
          Obx(() => IconButton(
                color: Colors.white,
                icon: Icon(Icons.expand_more),
                onPressed: _ffi.ffiModel.waitForFirstImage.isTrue
                    ? null
                    : () {
                        setState(() => _showBar = !_showBar);
                      },
              )),
        ],
      ),
    );
  }

  bool get showCursorPaint =>
      !_ffi.ffiModel.isPeerAndroid &&
      !_ffi.canvasModel.cursorEmbedded &&
      !_ffi.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    final keyboardIsVisible = keyboardVisibilityController.isVisible;
    return Container(
        color: MyTheme.canvasColor,
        child: Stack(children: () {
          final paints = [
            ImagePaint(ffiModel: _ffi.ffiModel),
            Positioned(
              top: 10,
              right: 10,
              child: QualityMonitor(_ffi.qualityMonitorModel),
            ),
            KeyHelpTools(
                ffi: _ffi,
                keyboardIsVisible: keyboardIsVisible,
                showGestureHelp: _showGestureHelp),
            SizedBox(
              width: isAndroid ? 1 : 0,
              height: isAndroid ? 1 : 0,
              child: !_showEdit
                  ? Container()
                  : isAndroid
                      ? NativeAndroidIme(
                          controller: _nativeAndroidImeController,
                          initialText: initText,
                          onEditingValueChanged: _applyAndroidImeEditingValue,
                          onImageContent: (payload) => unawaited(
                            _pasteImageBytes(payload.bytes, payload.mimeType),
                          ),
                          onImageError: (message) => showToast(message),
                        )
                      : TextFormField(
                          textInputAction: TextInputAction.newline,
                          autocorrect: true,
                          enableSuggestions: true,
                          autofocus: true,
                          focusNode: _mobileFocusNode,
                          maxLines: null,
                          controller: _textController,
                          // trick way to make backspace work always
                          keyboardType: TextInputType.multiline,
                          // `onChanged` may be called depending on the input method if this widget is wrapped in
                          // `Focus(onKeyEvent: ..., child: ...)`
                          // For `Backspace` button in the soft keyboard:
                          // en/fr input method:
                          //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                          //      2. The button will trigger `onKeyEvent` if the text field is empty.
                          // ko/zh/ja input method: the button will trigger `onKeyEvent`
                          //                     and the event will not popup if `KeyEventResult.handled` is returned.
                          onChanged: handleSoftKeyboardInput,
                        ).workaroundFreezeLinuxMint(),
            ),
          ];
          if (showCursorPaint) {
            paints.add(CursorPaint(widget.id));
          }
          if (_ffi.ffiModel.touchMode) {
            paints.add(FloatingMouse(
              ffi: _ffi,
            ));
          } else {
            paints.add(FloatingMouseWidgets(
              ffi: _ffi,
            ));
          }
          return paints;
        }()));
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = _ffi.ffiModel;
    var paints = <Widget>[ImagePaint(ffiModel: ffiModel)];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
        color: MyTheme.canvasColor, child: Stack(children: paints));
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (_ffi.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !_ffi.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(_ffi.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => _ffi.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => _ffi.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => _ffi.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => _ffi.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => _ffi.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => _ffi.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final size = MediaQuery.of(context).size;
    final x = 120.0;
    final y = size.height;
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, _ffi);

    final List<PopupMenuEntry<int>> more = [
      ...mobileActionMenus
          .asMap()
          .entries
          .map((e) =>
              PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
          .toList(),
      if (mobileActionMenus.isNotEmpty) PopupMenuDivider(),
      ...menus
          .asMap()
          .entries
          .map((e) => PopupMenuItem<int>(
              child: e.value.getChild(),
              value: e.key + mobileActionMenus.length))
          .toList(),
    ];
    () async {
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: more,
        elevation: 8,
      );
      if (index != null) {
        if (index < mobileActionMenus.length) {
          mobileActionMenus[index].onPressed?.call();
        } else if (index < mobileActionMenus.length + more.length) {
          menus[index - mobileActionMenus.length].onPressed?.call();
        }
      }
    }();
  }

  onPressedTextChat(String id) {
    _ffi.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    _ffi.chatModel.toggleChatOverlay();
  }

  showChatOptions(String id) async {
    onPressVoiceCall() => bind.sessionRequestVoiceCall(sessionId: sessionId);
    onPressEndVoiceCall() => bind.sessionCloseVoiceCall(sessionId: sessionId);

    makeTextMenu(String label, Widget icon, VoidCallback onPressed,
            {TextStyle? labelStyle}) =>
        TTextMenu(
          child: Text(translate(label), style: labelStyle),
          trailingIcon: Transform.scale(
            scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
            child: IgnorePointer(
              child: IconButton(
                onPressed: null,
                icon: icon,
              ),
            ),
          ),
          onPressed: onPressed,
        );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected
    ].contains(_ffi.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu('Text chat', Icon(Icons.message, color: MyTheme.accent),
          () => onPressedTextChat(widget.id)),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter:
                    ColorFilter.mode(Colors.redAccent, BlendMode.srcIn),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent))
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall),
    ];

    final menuItems = menus
        .asMap()
        .entries
        .map((e) => PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
        .toList();
    Future.delayed(Duration.zero, () async {
      final size = MediaQuery.of(context).size;
      final x = 120.0;
      final y = size.height;
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: menuItems,
        elevation: 8,
      );
      if (index != null && index < menus.length) {
        menus[index].onPressed?.call();
      }
    });
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
        child: SingleChildScrollView(
            controller: ScrollController(),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: GestureHelp(
              touchMode: _ffi.ffiModel.touchMode,
              onTouchModeChange: (t) {
                _ffi.ffiModel.toggleTouchMode();
                final v = _ffi.ffiModel.touchMode ? 'Y' : 'N';
                bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
              },
              virtualMouseMode: _ffi.ffiModel.virtualMouseMode,
              inputModel: _ffi.inputModel,
            )));
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   _ffi.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class KeyHelpTools extends StatefulWidget {
  final FFI ffi;
  final bool keyboardIsVisible;
  final bool showGestureHelp;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  KeyHelpTools(
      {required this.ffi,
      required this.keyboardIsVisible,
      required this.showGestureHelp});

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _more = true;
  var _fn = false;
  var _pin = false;
  final _keyboardVisibilityController = KeyboardVisibilityController();
  final _key = GlobalKey();

  FFI get _ffi => widget.ffi;
  InputModel get inputModel => _ffi.inputModel;

  Widget wrap(String text, void Function() onPressed,
      {bool? active, IconData? icon}) {
    return TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size(0, 0),
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 9.75),
          //adds padding inside the button
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          //limits the touch area to the button area
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5.0),
          ),
          backgroundColor: active == true ? MyTheme.accent80 : null,
        ),
        child: icon != null
            ? Icon(icon, size: 14, color: Colors.white)
            : Text(translate(text),
                style: TextStyle(color: Colors.white, fontSize: 11)),
        onPressed: onPressed);
  }

  _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      Offset pos = renderObject.localToGlobal(Offset.zero);
      _ffi.cursorModel.keyHelpToolsVisibilityChanged(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
          widget.keyboardIsVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasModifierOn = inputModel.ctrl ||
        inputModel.alt ||
        inputModel.shift ||
        inputModel.command;

    if (!_pin && !hasModifierOn && !widget.requestShow) {
      _ffi.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return Offstage();
    }
    final size = MediaQuery.of(context).size;

    final pi = _ffi.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = <Widget>[
      wrap('Ctrl ', () {
        setState(() => inputModel.ctrl = !inputModel.ctrl);
      }, active: inputModel.ctrl),
      wrap(' Alt ', () {
        setState(() => inputModel.alt = !inputModel.alt);
      }, active: inputModel.alt),
      wrap('Shift', () {
        setState(() => inputModel.shift = !inputModel.shift);
      }, active: inputModel.shift),
      wrap(isMac ? ' Cmd ' : ' Win ', () {
        setState(() => inputModel.command = !inputModel.command);
      }, active: inputModel.command),
    ];
    final keys = <Widget>[
      wrap(
          ' Fn ',
          () => setState(
                () {
                  _fn = !_fn;
                  if (_fn) {
                    _more = false;
                  }
                },
              ),
          active: _fn),
      wrap(
          '',
          () => setState(
                () => _pin = !_pin,
              ),
          active: _pin,
          icon: Icons.push_pin),
      wrap(
          ' ... ',
          () => setState(
                () {
                  _more = !_more;
                  if (_more) {
                    _fn = false;
                  }
                },
              ),
          active: _more),
    ];
    final fn = <Widget>[
      SizedBox(width: 9999),
    ];
    for (var i = 1; i <= 12; ++i) {
      final name = 'F$i';
      fn.add(wrap(name, () {
        inputModel.inputKey('VK_$name');
      }));
    }
    final more = <Widget>[
      SizedBox(width: 9999),
      wrap('Esc', () {
        inputModel.inputKey('VK_ESCAPE');
      }),
      wrap('Tab', () {
        inputModel.inputKey('VK_TAB');
      }),
      wrap('Home', () {
        inputModel.inputKey('VK_HOME');
      }),
      wrap('End', () {
        inputModel.inputKey('VK_END');
      }),
      wrap('Ins', () {
        inputModel.inputKey('VK_INSERT');
      }),
      wrap('Del', () {
        inputModel.inputKey('VK_DELETE');
      }),
      wrap('PgUp', () {
        inputModel.inputKey('VK_PRIOR');
      }),
      wrap('PgDn', () {
        inputModel.inputKey('VK_NEXT');
      }),
      // to-do: support PrtScr on Mac
      if (isWin || isLinux)
        wrap('PrtScr', () {
          inputModel.inputKey('VK_SNAPSHOT');
        }),
      if (isWin || isLinux)
        wrap('ScrollLock', () {
          inputModel.inputKey('VK_SCROLL');
        }),
      if (isWin || isLinux)
        wrap('Pause', () {
          inputModel.inputKey('VK_PAUSE');
        }),
      if (isWin || isLinux)
        // Maybe it's better to call it "Menu"
        // https://en.wikipedia.org/wiki/Menu_key
        wrap('Menu', () {
          inputModel.inputKey('Apps');
        }),
      wrap('Enter', () {
        inputModel.inputKey('VK_ENTER');
      }),
      SizedBox(width: 9999),
      wrap('', () {
        inputModel.inputKey('VK_LEFT');
      }, icon: Icons.keyboard_arrow_left),
      wrap('', () {
        inputModel.inputKey('VK_UP');
      }, icon: Icons.keyboard_arrow_up),
      wrap('', () {
        inputModel.inputKey('VK_DOWN');
      }, icon: Icons.keyboard_arrow_down),
      wrap('', () {
        inputModel.inputKey('VK_RIGHT');
      }, icon: Icons.keyboard_arrow_right),
      wrap(isMac ? 'Cmd+C' : 'Ctrl+C', () {
        sendPrompt(_ffi, isMac, 'VK_C');
      }),
      wrap(isMac ? 'Cmd+V' : 'Ctrl+V', () {
        sendPrompt(_ffi, isMac, 'VK_V');
      }),
      wrap(isMac ? 'Cmd+S' : 'Ctrl+S', () {
        sendPrompt(_ffi, isMac, 'VK_S');
      }),
    ];
    final space = size.width > 320 ? 4.0 : 2.0;
    // 500 ms is long enough for this widget to be built!
    Future.delayed(Duration(milliseconds: 500), () {
      _updateRect();
    });
    return Container(
        key: _key,
        color: Color(0xAA000000),
        padding: EdgeInsets.only(
            top: _keyboardVisibilityController.isVisible ? 24 : 4, bottom: 8),
        child: Wrap(
          spacing: space,
          runSpacing: space,
          children: <Widget>[SizedBox(width: 9999)] +
              modifiers +
              keys +
              (_fn ? fn : []) +
              (_more ? more : []),
        ));
  }
}

class ImagePaint extends StatelessWidget {
  final FfiModel ffiModel;
  ImagePaint({Key? key, required this.ffiModel}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: m.image, x: c.x / s, y: (c.y + adjust) / s, scale: s),
    );
  }
}

class CursorPaint extends StatelessWidget {
  late final String id;
  CursorPaint(this.id);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return Offstage();
    }

    final minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: image,
          x: (m.x - hotx) * factor + c.x / s2,
          y: (m.y - hoty) * factor + (c.y + adjust) / s2,
          scale: s2),
    );
  }
}

void showOptions(BuildContext context, String id,
    OverlayDialogManager dialogManager, FFI ffi) async {
  var displays = <Widget>[];
  final pi = ffi.ffiModel.pi;
  final image = ffi.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  final privacyModeState = PrivacyModeState.find(id);
  if (pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacyModeState.isEmpty ||
          allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value))) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorSelected = Colors.white;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(InkWell(
          onTap: () {
            if (i == cur) return;
            openMonitorInTheSameTab(i, ffi, pi);
            ffi.dialogManager.dismissAll();
          },
          child: Ink(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).hintColor),
                  borderRadius: BorderRadius.circular(2),
                  color: i == cur ? numBgSelected : null),
              child: Center(
                  child: Text((i + 1).toString(),
                      style: TextStyle(
                          color:
                              i == cur ? numColorSelected : numColorUnselected,
                          fontWeight: FontWeight.bold))))));
    }
    displays.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        )));
  }
  if (displays.isNotEmpty) {
    displays.add(const Divider(color: MyTheme.border));
  }

  List<TRadioMenu<String>> viewStyleRadios =
      await toolbarViewStyle(context, id, ffi);
  List<TRadioMenu<String>> imageQualityRadios =
      await toolbarImageQuality(context, id, ffi);
  List<TRadioMenu<String>> codecRadios = await toolbarCodec(context, id, ffi);
  List<TToggleMenu> cursorToggles = await toolbarCursor(context, id, ffi);
  List<TToggleMenu> displayToggles =
      await toolbarDisplayToggle(context, id, ffi);

  List<TToggleMenu> privacyModeList = [];
  if ((ffi.ffiModel.pi.features.privacyMode && ffi.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, ffi);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  dialogManager.show((setState, close, context) {
    var viewStyle =
        (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
    var imageQuality =
        (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
            .obs;
    var codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
    final radios = [
      for (var e in viewStyleRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            viewStyle.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) viewStyle.value = v;
                  }
                : null)),
      // Show custom scale controls when custom view style is selected
      Obx(() => viewStyle.value == kRemoteViewStyleCustom
          ? MobileCustomScaleControls(ffi: ffi)
          : const SizedBox.shrink()),
      const Divider(color: MyTheme.border),
      for (var e in imageQualityRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            imageQuality.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) imageQuality.value = v;
                  }
                : null)),
      const Divider(color: MyTheme.border),
      for (var e in codecRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            codec.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) codec.value = v;
                  }
                : null)),
      if (codecRadios.isNotEmpty) const Divider(color: MyTheme.border),
    ];
    final rxCursorToggleValues = cursorToggles.map((e) => e.value.obs).toList();
    final cursorTogglesList = cursorToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxCursorToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxCursorToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();

    final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();
    final displayTogglesList = displayToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();
    final toggles = [
      ...cursorTogglesList,
      if (cursorToggles.isNotEmpty) const Divider(color: MyTheme.border),
      ...displayTogglesList,
    ];

    Widget privacyModeWidget = Offstage();
    if (privacyModeList.length > 1) {
      privacyModeWidget = ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: Text(translate('Privacy mode')),
        onTap: () => setPrivacyModeDialog(
            dialogManager, privacyModeList, privacyModeState),
      );
    }

    var popupDialogMenus = List<Widget>.empty(growable: true);
    final resolution = getResolutionMenu(ffi, id);
    if (resolution != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: resolution.child,
        onTap: () {
          close();
          resolution.onPressed?.call();
        },
      ));
    }
    final virtualDisplayMenu = getVirtualDisplayMenu(ffi, id);
    if (virtualDisplayMenu != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: virtualDisplayMenu.child,
        onTap: () {
          close();
          virtualDisplayMenu.onPressed?.call();
        },
      ));
    }
    if (popupDialogMenus.isNotEmpty) {
      popupDialogMenus.add(const Divider(color: MyTheme.border));
    }

    return CustomAlertDialog(
      content: Column(
          mainAxisSize: MainAxisSize.min,
          children: displays +
              radios +
              popupDialogMenus +
              toggles +
              [privacyModeWidget]),
    );
  }, clickMaskDismiss: true, backDismiss: true).then((value) {
    _disableAndroidSoftKeyboard();
  });
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = getVirtualDisplayMenuChildren(ffi, id, close);
        return CustomAlertDialog(
          title: Text(translate('Virtual display')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

TTextMenu? getResolutionMenu(FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = resolutions
            .map((e) => getRadio<String>(
                  Text('${e.width}x${e.height}'),
                  '${e.width}x${e.height}',
                  '${display.width}x${display.height}',
                  (value) {
                    close();
                    bind.sessionChangeResolution(
                      sessionId: ffi.sessionId,
                      display: pi.currentDisplay,
                      width: e.width,
                      height: e.height,
                    );
                  },
                ))
            .toList();
        return CustomAlertDialog(
          title: Text(translate('Resolution')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

void sendPrompt(FFI ffi, bool isMac, String key) {
  final old = isMac ? ffi.inputModel.command : ffi.inputModel.ctrl;
  if (isMac) {
    ffi.inputModel.command = true;
  } else {
    ffi.inputModel.ctrl = true;
  }
  ffi.inputModel.inputKey(key);
  if (isMac) {
    ffi.inputModel.command = old;
  } else {
    ffi.inputModel.ctrl = old;
  }
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
