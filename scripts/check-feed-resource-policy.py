#!/usr/bin/env python3
"""Reject app/worker feed-policy drift without compiling either platform."""
import ast
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
swift = (root / "Packages/OpenCastCore/Sources/OpenCastCore/FeedResourcePolicy.swift").read_text()
rust = (root / "Server/NotificationsWorker/src/feed_resource.rs").read_text()


def number(source, name):
    expression = re.search(rf"\b{re.escape(name)}\b[^=\n]*=\s*([0-9_* +]+)", source).group(1).strip()
    tree = ast.parse(expression, mode="eval")

    def compute(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
            return compute(node.left) * compute(node.right)
        raise ValueError(f"Unsupported policy expression: {expression}")

    return compute(tree.body)


for app, worker, expected in [
    ("maximumDecodedBytes", "MAX_DECODED_BYTES", 128 * 1024 * 1024),
    ("maximumItems", "MAX_ITEMS", 100_000),
    ("maximumDepth", "MAX_DEPTH", 50),
    ("maximumFieldBytes", "MAX_FIELD_BYTES", 12 * 1024 * 1024),
    ("maximumItemTextBytes", "MAX_ITEM_TEXT_BYTES", 16 * 1024 * 1024),
    ("maximumProcessingBytes", "MAX_PROCESSING_BYTES", 512 * 1024 * 1024),
]:
    assert number(swift, app) == number(rust, worker) == expected, f"Feed policy drift: {app}/{worker}"
print("Feed resource policy matches: 128 MiB / 100,000 items; all processing guards agree.")
