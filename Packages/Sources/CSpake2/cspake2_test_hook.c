// DroidDrive glue for the vendored BoringSSL SPAKE2 (not BoringSSL code).
#include "boringssl_shim.h"

_Thread_local const uint8_t *cspake2_test_random = NULL;

void cspake2_set_test_random(const uint8_t random[64]) {
  cspake2_test_random = random;
}
