import '../utils/version_util.dart';

class HardenedUpdate {
  static const workflowRuns = 'https://api.github.com/repos/SHD-ISAC/J/actions/workflows/hardened_linux.yml/runs';
  static const _api = 'https://api.github.com/repos/SHD-ISAC/J/actions/runs';
  static const _web = 'https://github.com/SHD-ISAC/J/actions/runs';
  static const branch = 'hardened-v8.0.18';

  final String version;
  final Uri page;

  const HardenedUpdate(this.version, this.page);

  static String artifactsUrl(int runId) => '$_api/$runId/artifacts';
  static String jobsUrl(int runId) => '$_api/$runId/jobs';

  static bool completedBuildsWithUnstartedSmoke(Object? data) {
    if (data is! Map || data['jobs'] is! List) {
      return false;
    }
    final jobs = (data['jobs'] as List).whereType<Map>();
    bool succeeded(String name) => jobs.any((job) => job['name'] == name && job['conclusion'] == 'success');
    return succeeded('macOS arm64') &&
        succeeded('Linux x64') &&
        jobs.any((job) {
          final steps = job['steps'];
          return job['name'] == 'Launch macOS on Apple silicon' && job['conclusion'] == 'cancelled' && steps is List && steps.isEmpty;
        });
  }

  static HardenedUpdate? findLatest(Object? data, {required int runId, required String platform}) {
    if (data is! Map || data['artifacts'] is! List) {
      return null;
    }
    final pattern = RegExp('^JHenTai-Hardened-${RegExp.escape(platform)}-(\\d+\\.\\d+\\.\\d+\\+\\d+)\$');
    HardenedUpdate? latest;
    for (final artifact in (data['artifacts'] as List).whereType<Map>()) {
      final name = artifact['name'];
      final id = artifact['id'];
      if (artifact['expired'] != false || name is! String || id is! int || id <= 0) {
        continue;
      }
      final version = pattern.firstMatch(name)?.group(1);
      if (version != null && (latest == null || compareBuildVersions(version, latest.version) > 0)) {
        latest = HardenedUpdate(version, Uri.parse('$_web/$runId/artifacts/$id'));
      }
    }
    return latest;
  }
}
