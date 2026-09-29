"""Shared writer for every tabular download (CSV now, XLSX planned)."""
import csv
import io
from decimal import Decimal
from typing import Iterable, Iterator, Sequence


def _cell(value):
    if isinstance(value, Decimal):
        return f"{value:.2f}"
    return "" if value is None else str(value)


def stream_csv(columns: Sequence[str], rows: Iterable[Sequence]) -> Iterator[str]:
    """Yield a UTF-8 (with BOM) CSV document line by line, RFC 4180 quoting."""
    buffer = io.StringIO()
    writer = csv.writer(buffer, quoting=csv.QUOTE_MINIMAL)

    def flush() -> str:
        text = buffer.getvalue()
        buffer.seek(0)
        buffer.truncate(0)
        return text

    writer.writerow(columns)
    yield "﻿" + flush()
    for row in rows:
        writer.writerow([_cell(v) for v in row])
        yield flush()
