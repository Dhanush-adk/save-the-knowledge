#!/bin/sh
DST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ -f "${SRCROOT}/KnowledgeCache/EmbeddingModel.mlmodel" ]; then
  cp "${SRCROOT}/KnowledgeCache/EmbeddingModel.mlmodel" "${DST}/"
fi
if [ -d "${SRCROOT}/KnowledgeCache/EmbeddingModel.mlpackage" ]; then
  cp -R "${SRCROOT}/KnowledgeCache/EmbeddingModel.mlpackage" "${DST}/"
fi

