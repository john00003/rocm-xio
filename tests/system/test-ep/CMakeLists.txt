# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# System-level tests for test-ep (require the full library).  Emulate mode
# does not need a GPU, so omit the "system" label (reserved for HIP tests
# that require a ROCm device).

xio_add_test(
  NAME test-ep-emulate
  SOURCE test-ep-emulate.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)
