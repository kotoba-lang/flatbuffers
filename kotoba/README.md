# Kotoba v1 — FlatBuffers file identification

This directory is a first-class language tree on the `kotoba-lang/flatbuffers` fork, next to `src/` (C++), `java/`, `python/`, and the other runtimes. It is **not** part of [google/flatbuffers](https://github.com/google/flatbuffers) and is not a replacement for those implementations.

## Honest scope

v1 reads **file identification only**:

- the 4-byte file identifier
- the leading size-prefix `u32` when the buffer is size-prefixed

from one vendored fixture, `fixtures/tiny-size-prefixed.bin`.

It does **not** implement the schema compiler, table/vtable walk, vectors, or JSON. There is no FFI to C++/Java or any other runtime. It is **not robotics-ready**.

The fixture is a 12-byte size-prefixed identification prefix (size field + root `uoffset` + identifier `MYFI` from the FlatBuffers schema documentation). The root `uoffset` is present in the file and is not walked.

## Language constraints

- Kotoba CLI **0.7.2**
- `kotoba compile --target wasm` → `wasm32-kotoba-v1`
- value profile **i64-v1** (no IEEE floats, no vector/map ABI)
- no FFI / no host imports

`flatbuffers.kotoba` embeds the fixture as integer bytes. Exported functions return each identifier byte and the size-prefix `u32`. They do not pack those fields into one number.

## Checks

`checks.sh` compiles with Kotoba 0.7.2, rejects a wasm import section, instantiates the module, and compares the identifier bytes (and the size-prefix `u32`) to the fixture file. A local run of that script is not CI.

```sh
# requires kotoba 0.7.2 on PATH (the workflow installs it)
./checks.sh
```

Google CLA is not filed from this tree. It may apply later if this work is offered upstream; do not treat this fork as that offer.
