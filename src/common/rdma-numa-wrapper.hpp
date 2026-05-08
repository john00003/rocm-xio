/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/numa_wrapper.hpp, adapted for rocm-xio.
 * NUMA API wrapper loaded via dlopen -- no link dependency on libnuma.
 */

#ifndef ROCM_XIO_RDMA_NUMA_WRAPPER_HPP
#define ROCM_XIO_RDMA_NUMA_WRAPPER_HPP

#include <cstddef>

struct bitmask;

namespace xio {
namespace rdma_ep {

/** @brief Runtime-loaded libnuma facade used by topology helpers. */
class NUMAWrapper {
public:
  /** @brief Load libnuma and resolve required symbols. */
  explicit NUMAWrapper();

  /** @brief Close the libnuma handle. */
  virtual ~NUMAWrapper();

  bool is_initialized{false}; /**< true when required symbols are resolved. */

  /**
   * @brief Forward to numa_bitmask_isbitset().
   * @param bmp NUMA bitmask to inspect.
   * @param n Bit index to test.
   * @return Nonzero if the bit is set.
   */
  int bitmask_isbitset(const struct bitmask* bmp, unsigned int n);
  /**
   * @brief Forward to numa_get_mems_allowed().
   * @return Current memory-node allowance mask, or nullptr on failure.
   */
  struct bitmask* get_mems_allowed();
  /**
   * @brief Forward to numa_set_preferred().
   * @param node Preferred NUMA node ID.
   */
  void set_preferred(int node);
  /**
   * @brief Forward to numa_num_configured_nodes().
   * @return Number of configured NUMA nodes.
   */
  int num_configured_nodes();
  /**
   * @brief Forward to numa_num_configured_cpus().
   * @return Number of configured CPUs.
   */
  int num_configured_cpus();
  /**
   * @brief Forward to numa_node_of_cpu().
   * @param cpu CPU index to query.
   * @return NUMA node ID, or negative value on failure.
   */
  int node_of_cpu(int cpu);
  /**
   * @brief Forward to numa_max_node().
   * @return Maximum configured NUMA node ID.
   */
  int max_node();
  /**
   * @brief Forward to numa_move_pages().
   * @param pid Process ID, or 0 for the current process.
   * @param count Number of pages in @p pages.
   * @param pages Page-aligned addresses to query or move.
   * @param nodes Desired nodes, or nullptr for query.
   * @param status Output page status array.
   * @param flags NUMA move_pages flags.
   * @return 0 on success, negative value on failure.
   */
  long move_pages(int pid, unsigned long count, void** pages, const int* nodes,
                  int* status, int flags);
  /**
   * @brief Forward to numa_distance().
   * @param node1 First NUMA node ID.
   * @param node2 Second NUMA node ID.
   * @return Relative NUMA distance.
   */
  int distance(int node1, int node2);

private:
  /** @cond INTERNAL */
  struct numa_funcs_t {
    int (*bitmask_isbitset)(const struct bitmask* bmp, unsigned int n);
    struct bitmask* (*get_mems_allowed)();
    void (*set_preferred)(int node);
    int (*num_configured_nodes)();
    int (*num_configured_cpus)();
    int (*node_of_cpu)(int cpu);
    int (*max_node)();
    long (*move_pages)(int pid, unsigned long count, void** pages,
                       const int* nodes, int* status, int flags);
    int (*distance)(int node1, int node2);
  };

  struct numa_funcs_t funcs_ {};
  void* numa_handle_{nullptr};

  int init_function_table();
  /** @endcond */
};

extern NUMAWrapper numa;

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_RDMA_NUMA_WRAPPER_HPP
