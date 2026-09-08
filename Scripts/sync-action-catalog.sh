#!/usr/bin/env bash
# Copies the shared assistant catalog into the package's resources.
#
# Swift Package Manager resources must live inside the package directory, so the
# catalog cannot be referenced in place from the submodule. The copy is committed
# and ActionCatalogSyncTests fails when it drifts from the source of truth.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_catalog="${here}/../../../assistant/catalog/actions.json"
destination="${here}/../Sources/ARKAssistantKit/Resources/actions.json"

if [[ ! -f "${source_catalog}" ]]; then
  echo "Shared catalog not found at ${source_catalog}." >&2
  echo "Run: git submodule update --init assistant" >&2
  exit 1
fi

cp "${source_catalog}" "${destination}"
echo "Synced action catalog into ARKAssistantKit resources."
