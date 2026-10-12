#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/auth/module-cache
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -module-cache-path .build/auth/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Providers/NativeAuth*.swift Tests/AuthTestSupport.swift Tests/AnonymousAuthRunner.swift -o .build/auth/anonymous-runner
.build/auth/anonymous-runner
