import 'dart:convert';

const kPeerFlutterOptionRememberedDisplay = 'remembered-display-v1';

class RemoteDisplayIdentity {
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;

  const RemoteDisplayIdentity({
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  bool sameGeometry(RemoteDisplayIdentity other) =>
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height;

  Map<String, dynamic> toJson() => {
        'name': name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  static RemoteDisplayIdentity? fromJson(dynamic value) {
    if (value is! Map) return null;
    final x = value['x'];
    final y = value['y'];
    final width = value['width'];
    final height = value['height'];
    if (x is! int || y is! int || width is! int || height is! int) {
      return null;
    }
    return RemoteDisplayIdentity(
      name: value['name'] is String ? value['name'] as String : '',
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }
}

class RememberedRemoteDisplay {
  final int index;
  final RemoteDisplayIdentity? identity;

  const RememberedRemoteDisplay({required this.index, this.identity});

  String encode() => jsonEncode({
        'version': 1,
        'index': index,
        if (identity != null) 'identity': identity!.toJson(),
      });

  static RememberedRemoteDisplay? decode(String value) {
    if (value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map || decoded['version'] != 1) return null;
      final index = decoded['index'];
      if (index is! int) return null;
      final rawIdentity = decoded['identity'];
      final identity = rawIdentity == null
          ? null
          : RemoteDisplayIdentity.fromJson(rawIdentity);
      if (rawIdentity != null && identity == null) return null;
      return RememberedRemoteDisplay(index: index, identity: identity);
    } catch (_) {
      return null;
    }
  }
}

/// Resolves a saved display against the peer's current topology.
///
/// A non-empty display name is the strongest identity. Geometry handles older
/// peers that do not publish names. The saved index is only a final fallback
/// when no durable name was available, so unplugging a named display cannot
/// silently redirect a future connection to a different physical monitor.
int? resolveRememberedRemoteDisplay(
  RememberedRemoteDisplay remembered,
  List<RemoteDisplayIdentity> displays, {
  required int allDisplaysValue,
}) {
  if (remembered.index == allDisplaysValue) {
    return displays.isEmpty ? null : allDisplaysValue;
  }

  final saved = remembered.identity;
  if (saved != null && saved.name.isNotEmpty) {
    final namedMatches = <int>[];
    for (var i = 0; i < displays.length; i++) {
      if (displays[i].name == saved.name) namedMatches.add(i);
    }
    if (namedMatches.length == 1) return namedMatches.single;
    for (final i in namedMatches) {
      if (displays[i].sameGeometry(saved)) return i;
    }
    return null;
  }

  if (saved != null) {
    for (var i = 0; i < displays.length; i++) {
      if (displays[i].sameGeometry(saved)) return i;
    }
  }

  return remembered.index >= 0 && remembered.index < displays.length
      ? remembered.index
      : null;
}
