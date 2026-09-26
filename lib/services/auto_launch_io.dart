import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

bool _setupDone = false;

void setupAutoLaunch() {
  if (_setupDone) return;
  _setupDone = true;
  launchAtStartup.setup(
    appName: 'OMPlayer',
    appPath: Platform.resolvedExecutable,
  );
}

Future<void> setAutoLaunchEnabled(bool enabled) async {
  setupAutoLaunch();
  if (enabled) {
    await launchAtStartup.enable();
  } else {
    await launchAtStartup.disable();
  }
}

Future<bool> isAutoLaunchEnabled() async {
  setupAutoLaunch();
  try {
    return await launchAtStartup.isEnabled();
  } catch (_) {
    return false;
  }
}
