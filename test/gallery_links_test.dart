import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/gallery_image_page_url.dart';
import 'package:jhentai/src/model/gallery_url.dart';

void main() {
  test('gallery links with out-of-range identifiers are rejected', () {
    const oversized = '100000000000000000000';
    expect(GalleryUrl.tryParse('https://exhentai.org/g/$oversized/abcdef1234/'), isNull);
    expect(GalleryImagePageUrl.tryParse('https://exhentai.org/s/abcdef1234/$oversized-2'), isNull);
    expect(GalleryImagePageUrl.tryParse('https://exhentai.org/s/abcdef1234/12-$oversized'), isNull);
  });

  test('gallery links in shared text retain their existing behavior', () {
    expect(
      GalleryUrl.tryParse('Link: https://exhentai.org/g/12/abcdef1234/')?.url,
      'https://exhentai.org/g/12/abcdef1234/',
    );
    expect(
      GalleryImagePageUrl.tryParse('Link: https://exhentai.org/s/abcdef1234/12-2')?.url,
      'https://exhentai.org/s/abcdef1234/12-2',
    );
  });
}
