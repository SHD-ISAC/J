import 'package:jhentai/src/exception/internal_exception.dart';

class GalleryImagePageUrl {
  final bool isEH;

  final String imageToken;

  final int gid;

  final int pageNo;

  const GalleryImagePageUrl({
    required this.isEH,
    required this.gid,
    required this.imageToken,
    required this.pageNo,
  }) : assert(imageToken.length == 10);

  static GalleryImagePageUrl? tryParse(String url) {
    RegExp regExp = RegExp(r'https://e([-x])hentai\.org/s/([a-z0-9]{10})/(\d+)-(\d+)');
    Match? match = regExp.firstMatch(url);
    if (match == null) {
      return null;
    }

    final gid = int.tryParse(match.group(3)!);
    final pageNo = int.tryParse(match.group(4)!);
    if (gid == null || pageNo == null) {
      return null;
    }

    return GalleryImagePageUrl(
      isEH: match.group(1) == '-',
      imageToken: match.group(2)!,
      gid: gid,
      pageNo: pageNo,
    );
  }

  static GalleryImagePageUrl parse(String url) {
    GalleryImagePageUrl? galleryImagePageUrl = tryParse(url);

    if (galleryImagePageUrl == null) {
      throw InternalException(message: 'Parse gallery image page url failed');
    }
    return galleryImagePageUrl;
  }

  String get url => isEH ? 'https://e-hentai.org/s/$imageToken/$gid-$pageNo' : 'https://exhentai.org/s/$imageToken/$gid-$pageNo';
}
