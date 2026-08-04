#!/usr/bin/env python3
"""Fail when Rust test code sits inside a wasm-only module.

Backing implementation for scripts/check-wasm-only-test-gating.sh — see the
wrapper's header for the contract and the Phase 10.5 G hardening rationale.
Conservative by design: shapes the scanner cannot resolve (#[path], modules
with no file on disk, unbalanced braces, an attribute still open at EOF)
fail loud instead of passing silent.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

MOD_DECL = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z0-9_]+)\s*(;|\{)"
)
# A positive, standalone `test` predicate (word-boundary so `latest`,
# `test_util`, or feature strings never match).
TEST_WORD = re.compile(r'(?<![A-Za-z0-9_"])test(?![A-Za-z0-9_"])')

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def normalize(attr: str) -> str:
    return re.sub(r"\s+", "", attr)


def is_wasm_only(attr_norm: str) -> bool:
    """A cfg that compiles for wasm32 with NO positive test arm.

    `not(test)` is stripped before looking for `test`: the old substring
    match read `#[cfg(all(target_arch = "wasm32", not(test)))]` as
    test-reachable, which is exactly backwards.
    """
    if not attr_norm.startswith("#[cfg("):
        return False
    if 'target_arch="wasm32"' not in attr_norm:
        return False
    without_not_test = attr_norm.replace("not(test)", "")
    return not TEST_WORD.search(without_not_test)


def has_positive_test_cfg(attr_norm: str) -> bool:
    """A cfg predicate that requires (or offers) `test` positively.

    Inside a wasm-only module even `any(test, …)` arms are dead on host —
    the module itself never compiles there — so any positive mention flags.
    """
    if not (attr_norm.startswith("#[cfg(") or attr_norm.startswith("#[cfg_attr(")):
        return False
    without_not_test = attr_norm.replace("not(test)", "")
    return bool(TEST_WORD.search(without_not_test))


def strip_noise(line: str) -> str:
    """Remove string literals and line comments before counting braces."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return line.split("//", 1)[0]


class FileScan:
    """One pass over a .rs file: attributes, module declarations, inline
    wasm-only blocks (brace-tracked), and fail-loud unparseable shapes."""

    def __init__(self, path: Path):
        self.path = path
        self.rel = path.relative_to(REPO)
        # (module_name, declared_wasm_only) for `mod x;` declarations.
        self.declared: list[tuple[str, bool]] = []
        # Line numbers of positive-test cfg attributes anywhere in the file.
        self.test_cfg_lines: list[int] = []
        self.scan()

    def scan(self) -> None:
        lines = self.path.read_text(encoding="utf-8").splitlines()
        pending_attrs: list[str] = []
        attr_buffer: str | None = None
        attr_depth = 0
        # Stack of (mod_name, brace_depth_at_entry) for inline wasm-only
        # blocks currently open.
        wasm_blocks: list[tuple[str, int]] = []
        depth = 0

        for number, raw in enumerate(lines, start=1):
            stripped = raw.strip()

            # Multi-line attribute accumulation.
            if attr_buffer is not None:
                attr_buffer += stripped
                attr_depth += stripped.count("[") - stripped.count("]")
                if attr_depth <= 0:
                    pending_attrs.append(normalize(attr_buffer))
                    attr_buffer = None
                continue
            if stripped.startswith("#["):
                depth_delta = stripped.count("[") - stripped.count("]")
                if depth_delta > 0:
                    attr_buffer = stripped
                    attr_depth = depth_delta
                    continue
                pending_attrs.append(normalize(stripped))
                self.note_attr(pending_attrs[-1], number, wasm_blocks)
                continue

            # Blank lines and doc comments keep pending attributes alive.
            if not stripped or stripped.startswith("//"):
                continue

            declaration = MOD_DECL.match(raw)
            wasm_only_attr = any(is_wasm_only(attr) for attr in pending_attrs)
            if declaration:
                name, terminator = declaration.group(1), declaration.group(2)
                if terminator == ";":
                    self.declared.append((name, wasm_only_attr))
                elif wasm_only_attr:
                    wasm_blocks.append((name, depth))
            pending_attrs = []

            counted = strip_noise(raw)
            depth += counted.count("{") - counted.count("}")
            if depth < 0:
                fail(
                    f"{self.rel}:{number}: brace tracking went negative — "
                    "the tripwire cannot parse this file; simplify the shape "
                    "or extend the script"
                )
                return
            while wasm_blocks and depth <= wasm_blocks[-1][1]:
                wasm_blocks.pop()

        if attr_buffer is not None:
            fail(f"{self.rel}: attribute still open at EOF (unparseable shape)")
        if wasm_blocks:
            fail(
                f"{self.rel}: inline wasm-only mod "
                f"'{wasm_blocks[-1][0]}' never closed by brace tracking — "
                "the tripwire cannot parse this file; simplify the shape or "
                "extend the script"
            )

    def note_attr(
        self, attr_norm: str, number: int, wasm_blocks: list[tuple[str, int]]
    ) -> None:
        if attr_norm.startswith("#[path"):
            fail(
                f"{self.rel}:{number}: #[path] module declaration — the "
                "tripwire cannot resolve it; restructure or extend the script"
            )
        if has_positive_test_cfg(attr_norm):
            self.test_cfg_lines.append(number)
            if wasm_blocks:
                fail(
                    f"{self.rel}:{number}: test-gated code inside inline "
                    f"wasm-only mod '{wasm_blocks[-1][0]}' — host cargo test "
                    "never compiles it. Move the tests to a host-gated "
                    "module (see subscription_payloads.rs)."
                )


def module_files(declaring_file: Path, module: str) -> list[Path]:
    """Resolve `mod x;` in `declaring_file` to candidate files on disk."""
    directory = declaring_file.parent
    if declaring_file.name not in ("lib.rs", "main.rs", "mod.rs"):
        directory = directory / declaring_file.stem
    candidates: list[Path] = []
    file_form = directory / f"{module}.rs"
    if file_form.is_file():
        candidates.append(file_form)
    dir_form = directory / module
    if dir_form.is_dir():
        candidates.extend(sorted(dir_form.rglob("*.rs")))
    return candidates


def main() -> int:
    crates = sorted(REPO.glob("Server/*/src/lib.rs"))
    if not crates:
        fail("no Server crates found — repository layout drifted?")

    for lib in crates:
        src = lib.parent
        scans = {path: FileScan(path) for path in sorted(src.rglob("*.rs"))}
        for path, scan in scans.items():
            for module, wasm_only in scan.declared:
                if not wasm_only:
                    continue
                children = module_files(path, module)
                if not children:
                    fail(
                        f"{path.relative_to(REPO)}: wasm-only mod "
                        f"'{module}' has no resolvable file — the tripwire "
                        "cannot verify it; restructure or extend the script"
                    )
                for child in children:
                    child_scan = scans.get(child) or FileScan(child)
                    for line in child_scan.test_cfg_lines:
                        fail(
                            f"{child.relative_to(REPO)}:{line}: test-gated "
                            f"code in wasm-only module '{module}' — host "
                            "cargo test never compiles it. Gate the module "
                            '#[cfg(any(target_arch = "wasm32", test))] or '
                            "move the tests to a host-gated module."
                        )

    if failures:
        for message in failures:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1
    print(
        "PASS: no wasm-only module (declared or inline) contains test-gated code"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
