# Toner serial signature — C reference and Windows tests

This is a development reference for signing a canonical ATSHA204A cartridge record with ECDSA P-256/SHA-256. It includes three command-line C programs (`keygen`, `sign`, `verify`), one shared record encoder, fixed golden vectors, and a native Windows test runner. It does **not** write to a chip or integrate with printer firmware.

## Run on Windows

Prerequisites: Visual Studio 2022 C++ Build Tools (MSVC and CMake), vcpkg, PowerShell 5.1 or newer, and network access for vcpkg's first OpenSSL installation. Visual Studio's bundled vcpkg is detected automatically; alternatively pass `-VcpkgRoot`.

```powershell
pwsh -File .\run_tests.ps1
# Or, from Windows PowerShell:
powershell.exe -NoProfile -File .\run_tests.ps1
# With an independent vcpkg installation:
pwsh -File .\run_tests.ps1 -VcpkgRoot C:\vcpkg
```

The script builds the C programs with MSVC and OpenSSL (via CMake/vcpkg), then runs 26 checks. It creates disposable encrypted test keys in the OS temp directory and removes them after testing. `RESULT: 26 passed, 0 failed` is the success criterion. GitHub Actions runs the same script on `windows-2022` for pushes and pull requests. A POSIX `run_tests.sh` is also included.

## Record and trust model

The signed record is exactly `"TONER-AUTH"` (10 ASCII bytes, no NUL) | version `0x02` | key ID (1 byte, nonzero) | chip model `0x01` (ATSHA204A) | SKU length + SKU | color (`K/C/M/Y`) | capacity-code length + capacity code | full 9-byte binary chip serial. `record.c` is the single encoder used by both `sign` and `verify`; `record_test.c` holds fixed record and SHA-256 golden vectors. The 64-byte signature is raw `r[32] || s[32]`, not DER.

The verifier's key ID selects exactly one locally trusted public key (`TRUSTED_KEY_DIR/key-XX.pem` in this CLI demonstration). A cartridge must never supply its own trusted public key. Production firmware must use a pinned key table, obtain the serial **live from the chip configuration zone**, and still perform its independent fresh ATSHA204A MAC check. Signature failure must not silently fall back to a weaker path.

`keygen.c` and `sign.c` use encrypted PEM only for tests. Production issuance needs a non-exportable private key in an HSM and a controlled signing process. The signature alone cannot prevent chip emulation, relay, or firmware modification. The examples do not claim NIST/FIPS validation, and passing Windows tests is not a substitute for target BSP, cartridge, and factory tests.
