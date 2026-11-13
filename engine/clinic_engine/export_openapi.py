"""Write the OpenAPI document to docs/api/openapi.json.

    python -m clinic_engine.export_openapi [output-path]
"""

import json
import sys
from pathlib import Path

from .app import create_app
from .config import Settings
from .store import MemoryStore

DEFAULT_OUT = Path(__file__).resolve().parents[2] / "docs" / "api" / "openapi.json"


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    app = create_app(settings=Settings(store="memory"), store=MemoryStore(), start_ticker=False)
    doc = app.openapi()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n", "utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
