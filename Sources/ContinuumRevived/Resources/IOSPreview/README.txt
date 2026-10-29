Array iOS Preview helper

bridge.cjs is Array's narrow, process-owned adapter for local simulator capture
and input. Connect installs these exact packages in the current Array channel's
Application Support/DeveloperTools/iOSPreview directory:

expo-device-hub 0.19.0-canary-20261023-1357114 (MIT)
https://github.com/expo/expo-device-hub
The vendored serve-sim native addon retains its LICENSE and NOTICE files.

ws 8.21.0 (MIT)
https://github.com/websockets/ws

Package tarballs are SHA-512 verified before extraction. Installation preserves
all upstream license/notice files, runs no npm lifecycle scripts, and does not
install global packages. Node.js and an Xcode iOS Simulator runtime are required.
The native addon uses private simulator APIs; compatibility is pinned to the
tested artifact rather than claimed as an Apple-supported embedding API.
