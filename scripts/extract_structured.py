#!/usr/bin/env python3
"""
Convert unstructured text to structured form using LangExtract (Google).
Reads from stdin, prints a single structured text to stdout for indexing.

Usage:
  echo "raw page text..." | python extract_structured.py
  python extract_structured.py < input.txt

Requires: pip install -r requirements-langextract.txt
Env: LANGEXTRACT_API_KEY (Gemini) or use model_id="gemma2:2b" with Ollama for local.
"""

import json
import sys
import textwrap

def main() -> None:
    raw = sys.stdin.read()
    raw = raw.strip()
    if not raw:
        sys.stderr.write("extract_structured: no input\n")
        sys.exit(1)

    try:
        import langextract as lx
    except ImportError:
        sys.stderr.write("extract_structured: langextract not installed (pip install -r requirements-langextract.txt)\n")
        sys.exit(1)

    prompt = textwrap.dedent("""\
    Extract structured information from the following web page or document text.
    Use exact wording from the text where possible. Do not paraphrase heavily.
    Provide: a short summary, key points (bullets), and important facts or entities.
    Order extractions by appearance. Do not overlap or duplicate.""")

    examples = [
        lx.data.ExampleData(
            text="John is a Data Engineer at Acme. He works on Python and SQL. He has 3 years of experience.",
            extractions=[
                lx.data.Extraction(
                    extraction_class="summary",
                    extraction_text="John is a Data Engineer at Acme with 3 years of experience.",
                    attributes={"role": "Data Engineer", "company": "Acme"},
                ),
                lx.data.Extraction(
                    extraction_class="key_point",
                    extraction_text="Works on Python and SQL",
                    attributes={"skills": "Python, SQL"},
                ),
                lx.data.Extraction(
                    extraction_class="fact",
                    extraction_text="3 years of experience",
                    attributes={"metric": "experience"},
                ),
            ],
        ),
    ]

    model_id = "gemini-2.5-flash"
    extract_kwargs = {
        "text_or_documents": raw[:200_000],
        "prompt_description": prompt,
        "examples": examples,
        "model_id": model_id,
    }
    if not __get_env_key():
        extract_kwargs["model_id"] = "gemma2:2b"
        extract_kwargs["model_url"] = "http://localhost:11434"
        extract_kwargs["fence_output"] = False
        extract_kwargs["use_schema_constraints"] = False

    try:
        result = lx.extract(**extract_kwargs)
    except Exception as e:
        sys.stderr.write(f"extract_structured: extraction failed: {e}\n")
        sys.exit(1)

    # result can be one AnnotatedDocument or a list for multi-doc
    if isinstance(result, list) and result:
        result = result[0]
    out = flatten_extractions(result)
    if not out.strip():
        sys.stdout.write(raw[:50_000])
        return
    sys.stdout.write(out)


def __get_env_key() -> str:
    import os
    return (os.environ.get("LANGEXTRACT_API_KEY") or os.environ.get("GOOGLE_API_KEY") or "").strip()


def flatten_extractions(result) -> str:
    """Turn AnnotatedDocument extractions into one structured text for chunking."""
    if not hasattr(result, "extractions") or not result.extractions:
        return ""
    by_class = {}
    for e in result.extractions:
        cls = getattr(e, "extraction_class", "fact")
        text = getattr(e, "extraction_text", str(e)).strip()
        if not text:
            continue
        by_class.setdefault(cls, []).append(text)
    parts = []
    if by_class.get("summary"):
        parts.append("Summary:\n" + "\n".join(by_class["summary"]))
    if by_class.get("key_point"):
        parts.append("Key points:\n" + "\n".join("- " + t for t in by_class["key_point"]))
    if by_class.get("fact"):
        parts.append("Facts:\n" + "\n".join("- " + t for t in by_class["fact"]))
    for cls, texts in sorted(by_class.items()):
        if cls in ("summary", "key_point", "fact"):
            continue
        parts.append(f"{cls.replace('_', ' ').title()}:\n" + "\n".join("- " + t for t in texts))
    return "\n\n".join(parts) if parts else ""

if __name__ == "__main__":
    main()
