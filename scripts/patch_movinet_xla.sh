#!/usr/bin/env bash
# Patch Recognize's MoviNet SavedModel so video tagging runs on GPU.
#
# Why: tfjs-node-gpu uses the prebuilt libtensorflow C library, which never
# registers the XLA GPU platform (tensorflow/tensorflow#50458). The MoviNet
# model ships with `_XlaMustCompile=true` baked into its function defs, so any
# GPU run dies with:
#   NOT_FOUND: could not find registered platform with id: 0x...
#
# Fix: rename the attr key to a same-length unknown key ("_XlaMustCompilZ").
# TF ignores unknown underscore-prefixed attrs and runs the ops as normal CUDA
# kernels. Byte length is identical, so the protobuf stays valid.
#
# Re-run this after every Recognize app update or model re-download
# (the update replaces saved_model.pb with the stock XLA version).
set -euo pipefail

CONTAINER="${1:-nextcloud-app}"
MODEL_PB=/var/www/html/custom_apps/recognize/models/movinet-a3/saved_model.pb
BACKUP_DIR="$(dirname "$0")/backups"

if ! docker exec "$CONTAINER" test -f "$MODEL_PB"; then
    echo "Model not found in container: $MODEL_PB" >&2
    exit 1
fi

if [ "$(docker exec "$CONTAINER" grep -c _XlaMustCompilZ "$MODEL_PB")" != "0" ]; then
    echo "Already patched. Nothing to do."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d)
docker cp "$CONTAINER:$(dirname "$MODEL_PB")" "$BACKUP_DIR/movinet-a3.bak-$STAMP"
echo "Backup: $BACKUP_DIR/movinet-a3.bak-$STAMP"

docker exec "$CONTAINER" perl -pi -e 's/_XlaMustCompile/_XlaMustCompilZ/g' "$MODEL_PB"
docker exec "$CONTAINER" chown 33:33 "$MODEL_PB"

PATCHED=$(docker exec "$CONTAINER" grep -c _XlaMustCompilZ "$MODEL_PB")
echo "Patched $PATCHED occurrences. Video tagging now runs on GPU."
