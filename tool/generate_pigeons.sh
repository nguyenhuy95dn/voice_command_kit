#!/usr/bin/env bash
# Regenerates the Pigeon-derived channel code for every platform.
#
# iOS and macOS run as separate invocations because they need distinct
# copies of the Swift output under each platform's own Classes/ directory;
# everything else is written once from the @ConfigurePigeon defaults in
# pigeons/messages.dart.
set -euo pipefail
cd "$(dirname "$0")/.."

dart run pigeon \
  --input pigeons/messages.dart \
  --swift_out ios/Classes/messages.g.swift

dart run pigeon \
  --input pigeons/messages.dart \
  --swift_out macos/Classes/messages.g.swift
