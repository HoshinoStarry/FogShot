import 'package:flutter/services.dart';

int? windowsVirtualKey(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 0x07) return null;
  final code = usage & 0xffff;
  if (code >= 4 && code <= 29) return 0x41 + code - 4;
  if (code >= 30 && code <= 38) return 0x31 + code - 30;
  if (code >= 58 && code <= 69) return 0x70 + code - 58;
  if (code >= 104 && code <= 115) return 0x7c + code - 104;
  if (code >= 89 && code <= 97) return 0x61 + code - 89;
  return const {
    39: 0x30,
    40: 0x0d,
    41: 0x1b,
    42: 0x08,
    43: 0x09,
    44: 0x20,
    45: 0xbd,
    46: 0xbb,
    47: 0xdb,
    48: 0xdd,
    49: 0xdc,
    51: 0xba,
    52: 0xde,
    53: 0xc0,
    54: 0xbc,
    55: 0xbe,
    56: 0xbf,
    57: 0x14,
    70: 0x2c,
    71: 0x91,
    72: 0x13,
    73: 0x2d,
    74: 0x24,
    75: 0x21,
    76: 0x2e,
    77: 0x23,
    78: 0x22,
    79: 0x27,
    80: 0x25,
    81: 0x28,
    82: 0x26,
    83: 0x90,
    84: 0x6f,
    85: 0x6a,
    86: 0x6d,
    87: 0x6b,
    88: 0x0d,
    98: 0x60,
    99: 0x6e,
    100: 0xe2,
    101: 0x5d,
    224: 0xa2,
    225: 0xa0,
    226: 0xa4,
    227: 0x5b,
    228: 0xa3,
    229: 0xa1,
    230: 0xa5,
    231: 0x5c,
  }[code];
}
