#!/usr/bin/env python3
"""
Export sentence-transformers/all-MiniLM-L6-v2 to Core ML for KnowledgeCache.

Output:
  - EmbeddingModel.mlmodel (input_ids, attention_mask -> embedding Float32[384])
  - minilm_vocab.txt (one token per line, index = line number for Swift tokenizer)

Usage (from repo root, with venv activated):
  python scripts/export_embedding_model.py

Requires: pip install -r scripts/requirements-export.txt
Python 3.9–3.11 strongly recommended (Python 3.14 + coremltools 9 may fail conversion).
"""

import os
import shutil
import sys

import numpy as np
import torch
import coremltools as ct
from transformers import AutoTokenizer, AutoModel

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MAX_LENGTH = 256
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_MLPACKAGE = os.path.join(REPO_ROOT, "KnowledgeCache", "EmbeddingModel.mlpackage")
OUTPUT_MLMODEL = os.path.join(REPO_ROOT, "KnowledgeCache", "EmbeddingModel.mlmodel")
OUTPUT_VOCAB = os.path.join(REPO_ROOT, "KnowledgeCache", "Resources", "minilm_vocab.txt")


class MiniLMEmbeddingModel(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.model = AutoModel.from_pretrained(MODEL_NAME)

    def forward(self, input_ids, attention_mask):
        outputs = self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
        )
        token_embeddings = outputs.last_hidden_state
        mask = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
        summed = torch.sum(token_embeddings * mask, dim=1)
        counts = torch.clamp(mask.sum(dim=1), min=1e-9)
        mean_pooled = summed / counts
        return mean_pooled


def export_vocab(tokenizer):
    """Export vocabulary: one token per line, index = line number (for Swift MiniLMTokenizer)."""
    vocab = tokenizer.get_vocab()
    sorted_items = sorted(vocab.items(), key=lambda x: x[1])
    os.makedirs(os.path.dirname(OUTPUT_VOCAB), exist_ok=True)
    with open(OUTPUT_VOCAB, "w", encoding="utf-8") as f:
        for token, _ in sorted_items:
            f.write(token + "\n")
    print(f"✅ Saved vocabulary ({len(sorted_items)} tokens) to {OUTPUT_VOCAB}")


def main():
    print("Loading tokenizer and model...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = MiniLMEmbeddingModel().eval()

    tokens = tokenizer(
        "This is a test sentence.",
        padding="max_length",
        truncation=True,
        max_length=MAX_LENGTH,
        return_tensors="pt",
    )
    input_ids = tokens["input_ids"].to(torch.int32)
    attention_mask = tokens["attention_mask"].to(torch.int32)

    # Always export vocab first (needed for Swift MiniLMTokenizer)
    export_vocab(tokenizer)

    # Export Core ML model (trace -> convert)
    print("Tracing model...")
    try:
        traced = torch.jit.trace(model, (input_ids, attention_mask))
    except Exception as e:
        print(f"❌ JIT trace failed: {e}")
        print("Try with Python 3.9–3.11 and torch 2.0–2.2.")
        sys.exit(1)

    print("Converting to Core ML (neuralnetwork = single file with embedded weights)...")
    try:
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="input_ids", shape=(1, MAX_LENGTH), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(1, MAX_LENGTH), dtype=np.int32),
            ],
            convert_to="neuralnetwork",
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=ct.target.macOS11,
        )
    except Exception as e:
        print(f"❌ Core ML conversion failed: {e}")
        print("Use Python 3.9–3.11 and: pip install torch transformers coremltools numpy")
        print("Alternatively, use a pre-converted EmbeddingModel.mlmodel from Hugging Face.")
        sys.exit(1)

    # neuralnetwork format saves as .mlmodel (single file, weights embedded). Do not rename output (breaks NN backend).
    os.makedirs(os.path.dirname(OUTPUT_MLMODEL), exist_ok=True)
    mlmodel.save(OUTPUT_MLMODEL)
    out_name = mlmodel.get_spec().description.output[0].name if mlmodel.get_spec().description.output else "?"
    print(f"✅ Saved Core ML model to {OUTPUT_MLMODEL} (output name: {out_name})")
    print("Add EmbeddingModel.mlmodel to your Xcode target (or use the post-build copy script).")


if __name__ == "__main__":
    main()
