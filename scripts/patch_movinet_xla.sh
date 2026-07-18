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

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d)

if [ "$(docker exec "$CONTAINER" grep -c _XlaMustCompilZ "$MODEL_PB")" != "0" ]; then
    echo "XLA patch already present in saved_model.pb."
else
    docker cp "$CONTAINER:$(dirname "$MODEL_PB")" "$BACKUP_DIR/movinet-a3.bak-$STAMP"
    echo "Backup: $BACKUP_DIR/movinet-a3.bak-$STAMP"

    docker exec "$CONTAINER" perl -pi -e 's/_XlaMustCompile/_XlaMustCompilZ/g' "$MODEL_PB"
    docker exec "$CONTAINER" chown 33:33 "$MODEL_PB"

    PATCHED=$(docker exec "$CONTAINER" grep -c _XlaMustCompilZ "$MODEL_PB")
    echo "Patched $PATCHED occurrences. Video tagging now runs on GPU."
fi

# Second patch: NVDEC hardware video decoding in MovinetModel.js.
# The stock app transcodes with a bundled software ffmpeg (~3x slower than
# NVDEC on 4K HEVC). A patched copy lives in backups/; it adds a
# GPU-decode path with automatic software fallback. App updates replace
# MovinetModel.js, so re-deploy the patched copy if the marker is gone.
MOVINET_JS=/var/www/html/custom_apps/recognize/src/movinet/MovinetModel.js
PATCHED_JS="$(dirname "$0")/backups/MovinetModel.js.nvdec"
if [ "$(docker exec "$CONTAINER" grep -c hwaccel "$MOVINET_JS")" = "0" ]; then
    if [ -f "$PATCHED_JS" ]; then
        docker cp "$CONTAINER:$MOVINET_JS" "$(dirname "$0")/backups/MovinetModel.js.stock-$STAMP"
        docker cp "$PATCHED_JS" "$CONTAINER:$MOVINET_JS"
        docker exec "$CONTAINER" chown 33:33 "$MOVINET_JS"
        echo "NVDEC patch re-applied to MovinetModel.js (stock copy backed up)."
        echo "If the app update changed this file upstream, diff backups/MovinetModel.js.stock-$STAMP against the patched copy."
    else
        echo "WARNING: MovinetModel.js lacks NVDEC patch and no patched copy found at $PATCHED_JS" >&2
    fi
else
    echo "NVDEC patch present in MovinetModel.js."
fi
