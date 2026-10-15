#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../../build/goal-amend-20261014/portable-runtime .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D DEBUG -D TASK_PLAN_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Features/ConversationLocalDraftDrains.swift Sources/Features/ConversationTaskPlanService.swift Sources/Features/ConversationTaskPlanModel.swift Sources/App/ConversationTaskPlanFixture.swift Tests/ConversationTaskPlanTests.swift -o ../../build/goal-amend-20261014/portable-runtime/task-plan-tests
TASK_PLAN_TEST_ROOT="${PWD}/../../build/goal-amend-20261014/portable-runtime" ../../build/goal-amend-20261014/portable-runtime/task-plan-tests
