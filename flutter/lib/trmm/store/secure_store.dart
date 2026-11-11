// Protects session tokens at rest.
// Windows: DPAPI (CryptProtectData, bound to the Windows user account).
// Linux: plain bytes in a file readable only by the user (chmod 600).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptProtectDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _CryptUnprotectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptUnprotectDart = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

const _cryptprotectUiForbidden = 0x1;
const _entropy = 'trmm-desktop-token';

class SecureStore {
  static Uint8List protect(String value) {
    final data = Uint8List.fromList(utf8.encode(value));
    if (!Platform.isWindows) return data;
    return _dpapi(data, encrypt: true);
  }

  static String? unprotect(Uint8List data) {
    try {
      if (!Platform.isWindows) return utf8.decode(data);
      return utf8.decode(_dpapi(data, encrypt: false));
    } catch (_) {
      return null; // other windows user / corrupted: login again
    }
  }

  static Uint8List _dpapi(Uint8List data, {required bool encrypt}) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final localFree = kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final inBuf = calloc<Uint8>(data.length);
    final entBytes = utf8.encode(_entropy);
    final entBuf = calloc<Uint8>(entBytes.length);
    try {
      inBuf.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = inBuf;
      entBuf.asTypedList(entBytes.length).setAll(0, entBytes);
      entropy.ref
        ..cbData = entBytes.length
        ..pbData = entBuf;

      final int ok;
      if (encrypt) {
        final f = crypt32.lookupFunction<_CryptProtectNative, _CryptProtectDart>('CryptProtectData');
        ok = f(input, nullptr, entropy, nullptr, nullptr, _cryptprotectUiForbidden, output);
      } else {
        final f = crypt32
            .lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>('CryptUnprotectData');
        ok = f(input, nullptr, entropy, nullptr, nullptr, _cryptprotectUiForbidden, output);
      }
      if (ok == 0) throw StateError('DPAPI failed');
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      localFree(output.ref.pbData.cast());
      return result;
    } finally {
      calloc.free(inBuf);
      calloc.free(entBuf);
      calloc.free(input);
      calloc.free(entropy);
      calloc.free(output);
    }
  }
}
