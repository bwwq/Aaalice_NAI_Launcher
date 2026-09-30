import 'package:flutter_test/flutter_test.dart';
import '../../../tool/check_external_agent.dart' as checks;

void main() {
  for (final entry in checks.externalAgentChecks.entries) {
    test(entry.key, entry.value);
  }
}
