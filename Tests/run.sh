#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/Shared/Usage.swift" "$project_dir/Shared/OneShotContinuation.swift" "$project_dir/Shared/WatchSnapshot.swift" "$project_dir/Shared/Storage.swift" "$project_dir/Shared/OAuth.swift" "$project_dir/Tests/main.swift" -o "$test_dir/usage-tests"
"$test_dir/usage-tests"
