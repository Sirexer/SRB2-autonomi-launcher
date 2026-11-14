import 'dart:convert';
import 'dart:typed_data';

/// UBJSON (Universal Binary JSON) — так Ring Racers хранит ringdata.dat и
/// ringprofiles.prf (srb2::JsonValue::to_ubjson). Результат — как у
/// jsonDecode: `Map<String, Object?>`, `List<Object?>`, num, bool, String, null.
class Ubjson {
  Ubjson._(this._b) : _bd = ByteData.sublistView(_b);

  final Uint8List _b;
  final ByteData _bd;
  int _p = 0;

  /// Значение с позиции [offset]; FormatException — не UBJSON или обрезан.
  static Object? decode(Uint8List bytes, [int offset = 0]) {
    final u = Ubjson._(bytes).._p = offset;
    try {
      return u._value(u._type());
    } on RangeError {
      throw const FormatException('UBJSON is cut short');
    }
  }

  String _type() {
    var t = String.fromCharCode(_b[_p++]);
    while (t == 'N') {
      t = String.fromCharCode(_b[_p++]); // no-op
    }
    return t;
  }

  int _count() {
    final n = _value(_type());
    if (n is! int || n < 0) throw const FormatException('UBJSON: bad length');
    return n;
  }

  Object? _value(String t) {
    switch (t) {
      case 'Z':
        return null;
      case 'T':
        return true;
      case 'F':
        return false;
      case 'i':
        return _bd.getInt8(_p++);
      case 'U':
        return _b[_p++];
      case 'I':
        _p += 2;
        return _bd.getInt16(_p - 2);
      case 'l':
        _p += 4;
        return _bd.getInt32(_p - 4);
      case 'L':
        _p += 8;
        return _bd.getInt64(_p - 8);
      case 'd':
        _p += 4;
        return _bd.getFloat32(_p - 4);
      case 'D':
        _p += 8;
        return _bd.getFloat64(_p - 8);
      case 'C':
        return String.fromCharCode(_b[_p++]);
      case 'S' || 'H':
        return _string();
      case '[':
        return _array();
      case '{':
        return _object();
    }
    throw FormatException('UBJSON: unknown type "$t" at ${_p - 1}');
  }

  String _string() {
    final n = _count();
    final s = utf8.decode(_b.sublist(_p, _p + n), allowMalformed: true);
    _p += n;
    return s;
  }

  /// Оптимизированный контейнер: `$тип` и/или `#число`.
  (String?, int?) _header() {
    String? type;
    int? count;
    if (_b[_p] == 0x24) {
      // $
      type = String.fromCharCode(_b[_p + 1]);
      _p += 2;
    }
    if (_b[_p] == 0x23) {
      // #
      _p++;
      count = _count();
    }
    return (type, count);
  }

  List<Object?> _array() {
    final (type, count) = _header();
    final out = <Object?>[];
    if (count != null) {
      for (var i = 0; i < count; i++) {
        out.add(_value(type ?? _type()));
      }
      return out;
    }
    while (_b[_p] != 0x5D) {
      out.add(_value(_type()));
    }
    _p++; // ]
    return out;
  }

  Map<String, Object?> _object() {
    final (type, count) = _header();
    final out = <String, Object?>{};
    if (count != null) {
      for (var i = 0; i < count; i++) {
        final k = _string();
        out[k] = _value(type ?? _type());
      }
      return out;
    }
    while (_b[_p] != 0x7D) {
      final k = _string();
      out[k] = _value(_type());
    }
    _p++; // }
    return out;
  }
}
