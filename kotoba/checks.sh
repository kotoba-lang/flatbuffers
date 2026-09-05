#!/usr/bin/env bash
# Compile flatbuffers.kotoba with Kotoba 0.7.2 (wasm32, i64-v1) and assert
# the vendored fixture's file identifier bytes and size-prefix u32.
# Fail closed. A local run of this script is not CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${ROOT}/flatbuffers.kotoba"
FIXTURE="${ROOT}/fixtures/tiny-size-prefixed.bin"
KOTOBA="${KOTOBA:-kotoba}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-flatbuffers-v1.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Published kotoba-lang/kotoba v0.7.2 linux-amd64 executable digest
# (release asset kotoba-linux-amd64.tar.gz extracted binary).
KOTOBA_072_LINUX_AMD64_SHA256="51f696d7d08b92d3d0f34ac5a32dc846ce63aeab3295b1baf74f8fc78a85601c"

fail() {
  printf 'kotoba/checks.sh: %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required to instantiate the wasm32 module"

if [[ -f "${KOTOBA}" && -x "${KOTOBA}" ]]; then
  KOTOBA_BIN="${KOTOBA}"
elif command -v "${KOTOBA}" >/dev/null 2>&1; then
  KOTOBA_BIN="$(command -v "${KOTOBA}")"
else
  fail "kotoba 0.7.2 is required and was not found (${KOTOBA})"
fi
if [[ ! -f "${KOTOBA_BIN}" || -d "${KOTOBA_BIN}" ]]; then
  fail "kotoba resolved to a directory, not the 0.7.2 CLI (${KOTOBA_BIN})"
fi

# install.sh puts a POSIX wrapper on PATH. Hash the ELF, not the wrapper.
if [[ -L "${KOTOBA_BIN}" ]]; then
  KOTOBA_BIN="$(readlink -f "${KOTOBA_BIN}")"
fi
if ! python3 -c 'import sys; sys.exit(0 if open(sys.argv[1],"rb").read(4)==b"\x7fELF" else 1)' "${KOTOBA_BIN}"; then
  installed_elf="${KOTOBA_HOME:-$HOME/.local/share/kotoba}/v0.7.2/kotoba"
  if [[ -f "${installed_elf}" ]]; then
    KOTOBA_BIN="${installed_elf}"
  fi
fi
if [[ ! -f "${KOTOBA_BIN}" || -d "${KOTOBA_BIN}" ]]; then
  fail "kotoba resolved to a directory, not the 0.7.2 CLI (${KOTOBA_BIN})"
fi

CURRENT_LINK="${KOTOBA_HOME:-$HOME/.local/share/kotoba}/current"
if [[ -L "${CURRENT_LINK}" ]]; then
  INSTALLED="$(readlink "${CURRENT_LINK}")"
  printf 'kotoba install current: %s\n' "${INSTALLED}"
  if [[ "${INSTALLED}" != "v0.7.2" ]]; then
    fail "refusing kotoba ${INSTALLED} (need v0.7.2)"
  fi
fi

if [[ ! -f "${SRC}" ]]; then
  fail "missing module ${SRC}"
fi
if [[ ! -f "${FIXTURE}" ]]; then
  fail "missing fixture ${FIXTURE}"
fi

if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
  actual_sha="$(sha256sum "${KOTOBA_BIN}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${KOTOBA_072_LINUX_AMD64_SHA256}" ]]; then
    echo "fail: kotoba binary is not v0.7.2 linux-amd64" >&2
    echo "  path:   ${KOTOBA_BIN}" >&2
    echo "  actual: ${actual_sha}" >&2
    echo "  want:   ${KOTOBA_072_LINUX_AMD64_SHA256}" >&2
    exit 1
  fi
  echo "kotoba binary matches v0.7.2 linux-amd64"
else
  echo "note: binary SHA-256 pin is linux-amd64 only; host is $(uname -s)/$(uname -m)"
  echo "note: functional compile/run still decide pass/fail"
fi

eval "$(python3 - "${SRC}" "${FIXTURE}" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text()
blob = Path(sys.argv[2]).read_bytes()
if len(blob) != 12:
    sys.exit(f"fixture length {len(blob)} != 12")
size_prefix = int.from_bytes(blob[0:4], "little")
ident = blob[8:12]
if ident != b"MYFI":
    sys.exit(f"fixture identifier is {ident!r}, want b'MYFI'")
if size_prefix != 8:
    sys.exit(f"fixture size-prefix u32 is {size_prefix}, want 8")
required = [
    f"(= i {i}) {b}"
    for i, b in enumerate(blob)
]
missing = [frag for frag in required if frag not in src]
if missing:
    sys.exit(f"flatbuffers.kotoba is missing fixture byte literals: {missing}")
print(f"FIXTURE_LEN={len(blob)}")
print(f"FIELD_SIZE_PREFIX={size_prefix}")
print(f"FIELD_ID0={ident[0]}")
print(f"FIELD_ID1={ident[1]}")
print(f"FIELD_ID2={ident[2]}")
print(f"FIELD_ID3={ident[3]}")
print(f"FIELD_ID_ASCII={ident.decode('ascii')}")
PY
)"

printf 'fixture: %s (%s bytes)\n' "${FIXTURE}" "${FIXTURE_LEN}"
printf 'fixture fields: size-prefix-u32=%s identifier=%s (%s %s %s %s)\n' \
  "${FIELD_SIZE_PREFIX}" "${FIELD_ID_ASCII}" \
  "${FIELD_ID0}" "${FIELD_ID1}" "${FIELD_ID2}" "${FIELD_ID3}"

COMPILE_JSON="${WORKDIR}/compile.json"
WASM_OUT="${WORKDIR}/flatbuffers.wasm"
set +e
"${KOTOBA_BIN}" compile "${SRC}" --target wasm -o "${WASM_OUT}" --json >"${COMPILE_JSON}" 2>"${WORKDIR}/compile.err"
compile_rc=$?
set -e
if [[ "${compile_rc}" -ne 0 ]]; then
  cat "${COMPILE_JSON}" "${WORKDIR}/compile.err" >&2 || true
  fail "kotoba compile failed (exit ${compile_rc})"
fi

python3 - "${COMPILE_JSON}" "${WASM_OUT}" <<'PY'
import json
import pathlib
import sys

WASM_IMPORT_SECTION = 2


def read_uleb128(buf, i):
    shift = 0
    value = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated uleb128")
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, i
        shift += 7
        if shift > 35:
            raise ValueError("uleb128 too long")


def wasm_import_section(buf):
    if buf[:4] != b"\x00asm":
        raise ValueError(f"artifact magic {buf[:4]!r} is not wasm")
    if len(buf) < 8:
        raise ValueError("truncated wasm header")
    i = 8
    found = False
    import_count = None
    while i < len(buf):
        section_id = buf[i]
        i += 1
        size, i = read_uleb128(buf, i)
        end = i + size
        if end > len(buf):
            raise ValueError("truncated wasm section")
        payload = buf[i:end]
        i = end
        if section_id == WASM_IMPORT_SECTION:
            found = True
            import_count, _ = read_uleb128(payload, 0) if payload else (0, 0)
    return found, import_count


if wasm_import_section(b"\x00asm\x01\x00\x00\x00") != (False, None):
    raise SystemExit("fail: import-section checker failed on a no-section wasm")
if wasm_import_section(b"\x00asm\x01\x00\x00\x00\x02\x01\x00") != (True, 0):
    raise SystemExit("fail: import-section checker failed to see an import section")

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
if report.get("kotoba.cli/ok?") is not True:
    raise SystemExit(f"fail: compile did not succeed: {report}")
if report.get("kotoba.cli/code") != "emitted":
    raise SystemExit(
        f"fail: compile JSON code is {report.get('kotoba.cli/code')!r}, want 'emitted'"
    )
data = report.get("kotoba.cli/data") or {}
profile = data.get("value-profile")
target = (data.get("compatibility") or {}).get("target")
if profile != "i64-v1":
    raise SystemExit(f"fail: value-profile {profile!r} != 'i64-v1'")
if target != "wasm32-kotoba-v1":
    raise SystemExit(f"fail: target {target!r} != 'wasm32-kotoba-v1'")
wasm_path = pathlib.Path(sys.argv[2])
if not wasm_path.is_file():
    raise SystemExit("fail: compile did not write a wasm artifact")
wasm = wasm_path.read_bytes()
if wasm[:4] != b"\0asm":
    raise SystemExit("fail: compile output is not a wasm32 module (missing \\0asm)")
has_imports, import_count = wasm_import_section(wasm)
if has_imports:
    raise SystemExit(
        f"fail: wasm has import section (id 2, count={import_count}); FFI is out of v1"
    )
print(f"compile: code=emitted target={target} value-profile={profile} import-section=absent")
PY

GOT="$(node --input-type=module - "${WASM_OUT}" <<'JS'
import fs from "node:fs";
const wasm = fs.readFileSync(process.argv[2]);
const { instance } = await WebAssembly.instantiate(wasm);
const e = instance.exports;
for (const name of ["identifier-b0", "identifier-b1", "identifier-b2", "identifier-b3", "size-prefix-u32"]) {
  if (typeof e[name] !== "function") {
    throw new Error(`wasm module has no exported ${name}`);
  }
}
const b0 = Number(e["identifier-b0"]());
const b1 = Number(e["identifier-b1"]());
const b2 = Number(e["identifier-b2"]());
const b3 = Number(e["identifier-b3"]());
const sizePrefix = Number(e["size-prefix-u32"]());
process.stdout.write(`${b0} ${b1} ${b2} ${b3} ${sizePrefix}`);
JS
)"

read -r GOT_ID0 GOT_ID1 GOT_ID2 GOT_ID3 GOT_SIZE <<<"${GOT}"
printf 'wasm identifier bytes: %s %s %s %s size-prefix-u32=%s\n' \
  "${GOT_ID0}" "${GOT_ID1}" "${GOT_ID2}" "${GOT_ID3}" "${GOT_SIZE}"

if [[ "${GOT_ID0}" != "${FIELD_ID0}" || "${GOT_ID1}" != "${FIELD_ID1}" \
   || "${GOT_ID2}" != "${FIELD_ID2}" || "${GOT_ID3}" != "${FIELD_ID3}" ]]; then
  fail "identifier bytes ${GOT_ID0} ${GOT_ID1} ${GOT_ID2} ${GOT_ID3} != fixture ${FIELD_ID0} ${FIELD_ID1} ${FIELD_ID2} ${FIELD_ID3}"
fi
if [[ "${GOT_SIZE}" != "${FIELD_SIZE_PREFIX}" ]]; then
  fail "size-prefix u32 ${GOT_SIZE} != fixture ${FIELD_SIZE_PREFIX}"
fi

echo "kotoba v1 file-identification checks passed"
