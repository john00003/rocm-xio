/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/endian.hpp, adapted for rocm-xio.
 * Canonical location for endian conversion helpers used by rdma-ep.
 */

#ifndef ROCM_XIO_ENDIAN_HPP
#define ROCM_XIO_ENDIAN_HPP

#include <type_traits>

#include <hip/hip_runtime.h>

namespace xio {
namespace rdma_ep {

/**
 * @brief Reverse byte order for an integral value.
 * @tparam T Integral value type.
 * @param val Value to byte-swap.
 * @return Value with bytes in reverse order.
 */
template <typename T, std::enable_if_t<std::is_integral_v<T>, bool> = true>
constexpr inline __host__ __device__ T byteswap(T val) {
  if constexpr (sizeof(T) == 1) {
    return val;
  } else if constexpr (sizeof(T) == 2) {
    return __builtin_bswap16(val);
  } else if constexpr (sizeof(T) == 4) {
    return __builtin_bswap32(val);
  } else if constexpr (sizeof(T) == 8) {
    return __builtin_bswap64(val);
  } else {
    static_assert(sizeof(T) == 0, "byteswap not implemented for this type");
  }
}

namespace endian {

/** @brief Endian order used by conversion helpers. */
enum class Order {
  Big = __ORDER_BIG_ENDIAN__,       /**< Big-endian byte order. */
  Little = __ORDER_LITTLE_ENDIAN__, /**< Little-endian byte order. */
  Native = __BYTE_ORDER__           /**< Compile-target native order. */
};

/**
 * @brief Convert an integral value between endian orders.
 * @tparam To Destination byte order.
 * @tparam From Source byte order.
 * @tparam T Integral value type.
 * @param val Value to convert.
 * @return Converted value, or @p val when orders match.
 */
template <Order To, Order From, typename T,
          std::enable_if_t<std::is_integral_v<T>, bool> = true>
__host__ __device__ constexpr inline T convert(T val) {
  if constexpr (To == From) {
    return val;
  } else {
    return byteswap(val);
  }
}

/**
 * @brief Convert from a specified endian order to native order.
 * @tparam From Source byte order.
 * @tparam T Integral value type.
 * @param val Value to convert.
 * @return Native-order value.
 */
template <Order From, typename T>
__host__ __device__ constexpr inline T to_native(T val) {
  return convert<Order::Native, From, T>(val);
}

/**
 * @brief Convert from native order to a specified endian order.
 * @tparam To Destination byte order.
 * @tparam T Integral value type.
 * @param val Value to convert.
 * @return Value in destination order.
 */
template <Order To, typename T>
__host__ __device__ constexpr inline T from_native(T val) {
  return convert<To, Order::Native, T>(val);
}

/**
 * @brief Convert a native-order value to big-endian order.
 * @tparam T Integral value type.
 * @param val Native-order value.
 * @return Big-endian value.
 */
template <typename T>
__host__ __device__ constexpr inline T to_be(T val) {
  return convert<Order::Big, Order::Native, T>(val);
}

/**
 * @brief Convert a big-endian value to native order.
 * @tparam T Integral value type.
 * @param val Big-endian value.
 * @return Native-order value.
 */
template <typename T>
__host__ __device__ constexpr inline T from_be(T val) {
  return convert<Order::Native, Order::Big, T>(val);
}

/**
 * @brief Convert a native-order value to little-endian order.
 * @tparam T Integral value type.
 * @param val Native-order value.
 * @return Little-endian value.
 */
template <typename T>
__host__ __device__ constexpr inline T to_le(T val) {
  return convert<Order::Little, Order::Native, T>(val);
}

/**
 * @brief Convert a little-endian value to native order.
 * @tparam T Integral value type.
 * @param val Little-endian value.
 * @return Native-order value.
 */
template <typename T>
__host__ __device__ constexpr inline T from_le(T val) {
  return convert<Order::Native, Order::Little, T>(val);
}

} // namespace endian

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_ENDIAN_HPP
