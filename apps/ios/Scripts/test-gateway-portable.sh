#!/bin/zsh
# Compile current main-project adapters; all data is synthetic and no Simulator is touched.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/gateway-check/evidence .build/module-cache
node Development/gateway/scripts/demo.mjs .build/gateway-check/evidence
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sources=(Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/*Service.swift Sources/Features/GatewayAssistantImporter.swift Sources/Providers/*.swift)
swiftc -D GATEWAY_INTEGRATION -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache $sources Tests/GatewayRunner.swift -o .build/gateway-check/runner
swiftc -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache $sources Tests/ProjectReplyOwnershipRegression.swift -o .build/gateway-check/project-owners
swiftc -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache $sources Tests/GatewaySafetyRegression.swift -o .build/gateway-check/safety
.build/gateway-check/project-owners
.build/gateway-check/safety
task_root="$PWD"
cd .build/gateway-check
if [[ "${1:-contract}" == http ]]; then
  node "$task_root/Development/gateway/scripts/native-http.mjs" "$task_root/.build/gateway-check/runner"
else
  ./runner
fi
