# AdbKit test fixtures

These files let the auth tests check our key encoding against the real `adb` tool. The key is a throwaway generated for tests only; no device trusts it.

- `test-adbkey-pkcs1.pem`: `openssl genrsa -traditional 2048`
- `test-adbkey-pkcs8.pem`: the same key as PKCS#8, the format adb writes to `~/.android/adbkey`
- `test-adbkey.pub`: output of `adb pubkey test-adbkey-pkcs8.pem` (the trailing user@host replaced with `test@droiddrive`), the expected AUTH RSAPUBLICKEY text
- `malicious-names.bin`: NUL-separated file names that would run as commands if a path were not quoted (spec §5.4); also copied to `Tests/fixtures/` at the repo root
