/// v7.7.7
int compareVersion(String a, String b) {
  List<String> numberA = a.replaceFirst('v', '').split('.');
  List<String> numberB = b.replaceFirst('v', '').split('.');

  if (numberA.length != numberB.length) {
    return 0;
  }

  for (int i = 0; i < numberA.length; i++) {
    int a = int.parse(numberA[i]);
    int b = int.parse(numberB[i]);
    if (a > b) {
      return 1;
    } else if (a < b) {
      return -1;
    }
  }

  return 0;
}

int compareBuildVersions(String a, String b) {
  final first = a.split('+');
  final second = b.split('+');
  final version = compareVersion(first.first, second.first);
  if (version != 0) {
    return version;
  }
  final firstBuild = first.length == 2 ? int.tryParse(first[1]) ?? 0 : 0;
  final secondBuild = second.length == 2 ? int.tryParse(second[1]) ?? 0 : 0;
  return firstBuild.compareTo(secondBuild);
}
