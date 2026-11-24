#!/usr/bin/env bash
# ios/dev-iphone.sh in a Terminal window of the developer's session, where signing reaches the login keychain; its
# output also goes to ios/build/dev-iphone.log, for a reader over SSH. The window stays open afterwards.
cd "$(dirname "$0")" && mkdir -p build && zsh -lc "./dev-iphone.sh $*" 2>&1 | tee build/dev-iphone.log
echo "exit ${PIPESTATUS[0]}" | tee -a build/dev-iphone.log
