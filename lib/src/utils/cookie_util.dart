import 'dart:io';

import 'package:collection/collection.dart';

class CookieUtil {
  static List<Cookie> parse2Cookies(String? cookiesString) {
    if (cookiesString == null || cookiesString.trim().isEmpty) {
      return [];
    }

    final cookies = <Cookie>[];
    try {
      for (final entry in cookiesString.split(';')) {
        final pair = entry.trim();
        if (pair.isEmpty) {
          continue;
        }
        final separator = pair.indexOf('=');
        if (separator <= 0) {
          return [];
        }
        cookies.add(Cookie(pair.substring(0, separator).trim(), pair.substring(separator + 1).trim()));
      }
    } on FormatException {
      return [];
    }
    return cookies;
  }

  static List<Cookie> parseSetCookieHeaders(Iterable<String> headers) {
    final cookies = <Cookie>[];
    for (final header in headers) {
      try {
        cookies.add(Cookie.fromSetCookieValue(header));
      } on FormatException {
        continue;
      } on HttpException {
        continue;
      }
    }
    return cookies;
  }

  static String parse2String(List<Cookie> cookies) {
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  static bool validateCookiesString(String? cookiesString) {
    if (cookiesString?.isEmpty ?? false) {
      return false;
    }
    RegExpMatch? match = RegExp(r'ipb_member_id=(\w+).*ipb_pass_hash=(\w+)').firstMatch(cookiesString!);
    String? ipbMemberId = match?.group(1);
    String? ipbPassHash = match?.group(2);
    return (ipbMemberId != null && ipbPassHash != null && ipbMemberId != '0' && ipbPassHash != '0');
  }

  static bool validateCookies(List<Cookie> cookies) {
    String? ipbMemberId = cookies.firstWhereOrNull((cookie) => cookie.name == 'ipb_member_id')?.value;
    String? ipbPassHash = cookies.firstWhereOrNull((cookie) => cookie.name == 'ipb_pass_hash')?.value;
    return (ipbMemberId != null && ipbPassHash != null && ipbMemberId != '0' && ipbPassHash != '0');
  }
}
