#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/task-actions-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "${1:-}" == "--transport" ]]; then
    swiftc -D TASK_ACTION_TRANSPORT_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/ConversationOutbox.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift Tests/NativeTaskActionTransportTests.swift -o .build/task-actions-tests/transport-runner
    .build/task-actions-tests/transport-runner
    exit
fi
swiftc -D DEBUG -D TASK_ACTIONS_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationTaskActionService.swift Sources/App/ConversationTaskActionFixture.swift Tests/ConversationTaskActionTests.swift -o .build/task-actions-tests/runner
.build/task-actions-tests/runner
