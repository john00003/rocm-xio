/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Vendor abstraction layer for rdma-ep. Common host orchestration helpers live
 * in rdma-common.h; this layer keeps shared device descriptors, wave helpers,
 * locking, provider IDs, and provider string conversion close to the
 * vendor-specific QueuePair code that consumes them.
 */

#ifndef RDMA_EP_VENDOR_OPS_HPP
#define RDMA_EP_VENDOR_OPS_HPP

#include <cstdint>

#include <hip/hip_runtime.h>

namespace xio {
namespace rdma_ep {

/** @brief Wavefront size assumed by shared RDMA device helpers. */
constexpr uint32_t WF_SIZE = 64;
/** @brief Unlocked value for SpinLock::lock. */
constexpr uint32_t SPIN_LOCK_UNLOCKED = 0;

/** @brief Agent-scope GPU spin lock shared by provider device code. */
struct SpinLock {
  uint32_t lock{SPIN_LOCK_UNLOCKED}; /**< Atomic lock word. */

  /** @brief Acquire the lock using an agent-scope atomic exchange. */
  __device__ void acquire() {
    while (__hip_atomic_exchange(&lock, 1u, __ATOMIC_ACQUIRE,
                                 __HIP_MEMORY_SCOPE_AGENT) != 0u) {
#ifdef __HIP_DEVICE_COMPILE__
      __builtin_amdgcn_s_sleep(1);
#endif
    }
  }

  /** @brief Release the lock with agent-scope release ordering. */
  __device__ void release() {
    __hip_atomic_store(&lock, 0u, __ATOMIC_RELEASE, __HIP_MEMORY_SCOPE_AGENT);
  }
};

/** @brief Provider-neutral RDMA read/write work request descriptor. */
struct RmaDescriptor {
  uintptr_t local_addr;  /**< Local buffer virtual address. */
  uintptr_t remote_addr; /**< Remote buffer virtual address. */
  uint32_t length;       /**< Transfer length in bytes. */
  uint32_t lkey;         /**< Local memory-region key. */
  uint32_t rkey;         /**< Remote memory-region key. */
  uint8_t opcode;        /**< Provider opcode for the RMA operation. */
  bool send_inline;      /**< true when data should be embedded inline. */
  uint32_t imm_data;     /**< Immediate data for WRITE_WITH_IMM. */
};

/** @brief Provider-neutral atomic work request descriptor. */
struct AmoDescriptor {
  uintptr_t remote_addr; /**< Remote atomic target address. */
  uint32_t rkey;         /**< Remote memory-region key. */
  uint8_t opcode;        /**< Provider opcode for the atomic operation. */
  int64_t swap_add;      /**< Add or swap operand. */
  int64_t compare;       /**< Compare operand for compare-and-swap. */
  bool fetching;         /**< true when the operation returns old data. */
  uintptr_t fetch_addr;  /**< Local address for fetched atomic result. */
  uint32_t fetch_lkey;   /**< Local key for fetch_addr. */
};

/** @brief PCI vendor ID for Broadcom adapters. */
constexpr uint32_t VENDOR_ID_BROADCOM = 0x14E4;
/** @brief PCI vendor ID for Mellanox adapters. */
constexpr uint32_t VENDOR_ID_MELLANOX = 0x02C9;
/** @brief PCI vendor ID for Pensando adapters. */
constexpr uint32_t VENDOR_ID_PENSANDO = 0x1DD8;
/** @brief PCI vendor ID for AMD adapters. */
constexpr uint32_t VENDOR_ID_AMD = 0x1022;

/**
 * @brief Return the active-lane mask for the current wavefront.
 * @return Bit mask of active lanes.
 */
__device__ inline uint64_t get_active_lane_mask() {
  return __ballot(1);
}

/**
 * @brief Return the lane index within the current wavefront.
 * @return Lane ID in the range [0, WF_SIZE).
 */
__device__ inline int get_lane_id() {
  return __lane_id();
}

/**
 * @brief Check whether the current lane is lane zero.
 * @return true for lane zero in the current wavefront.
 */
__device__ inline bool is_thread_zero_in_wave() {
  return get_lane_id() == 0;
}

/**
 * @brief Count set bits in a 64-bit mask.
 * @param mask Mask to count.
 * @return Number of set bits.
 */
__device__ inline int popcount64(uint64_t mask) {
  return __popcll(mask);
}

/**
 * @brief Return the lowest set lane in a mask.
 * @param mask Active-lane mask.
 * @return First set bit index, or -1 when @p mask is zero.
 */
__device__ inline int first_lane(uint64_t mask) {
  return __ffsll(static_cast<long long>(mask)) - 1;
}

/**
 * @brief Return the highest set lane in a mask.
 * @param mask Active-lane mask.
 * @return Last set bit index; undefined when @p mask is zero.
 */
__device__ inline int last_lane(uint64_t mask) {
  return 63 - __clzll(static_cast<long long>(mask));
}

} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_VENDOR_OPS_HPP
