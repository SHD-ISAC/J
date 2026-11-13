import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/utils/cookie_util.dart';

void main() {
  test('retains the complete cookie value', () {
    final cookies = CookieUtil.parse2Cookies('ipb_member_id=123; sample=YQ==;');

    expect(CookieUtil.parse2String(cookies), 'ipb_member_id=123; sample=YQ==');
  });

  test('rejects a malformed cookie string as a whole', () {
    expect(CookieUtil.parse2Cookies('sample=value; invalid'), isEmpty);
    expect(CookieUtil.parse2Cookies('sample=value; =invalid'), isEmpty);
    expect(CookieUtil.parse2Cookies(null), isEmpty);
  });

  test('reads separate Set-Cookie headers and ignores invalid entries', () {
    final cookies = CookieUtil.parseSetCookieHeaders(['igneous=YQ==; Path=/; Secure', 'invalid', 'sample=value; Path=/']);

    expect(CookieUtil.parse2String(cookies), 'igneous=YQ==; sample=value');
  });
}
