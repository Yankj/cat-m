#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/widget-notification-tests .build/module-cache
xcrun swiftc -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/module-cache \
  Widgets/CatpawWidgets/CatpawHomeWidgets.swift Sources/App/CatpawPushNotifications.swift \
  Tests/WidgetNotificationSurfaceRunner.swift -o .build/widget-notification-tests/runner
.build/widget-notification-tests/runner
