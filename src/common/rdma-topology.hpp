/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/topology.hpp, adapted for rocm-xio.
 * Simplified for the single-endpoint model (no full-mesh PE topology).
 * Provides NIC-GPU proximity detection and GID selection.
 */

#ifndef ROCM_XIO_RDMA_TOPOLOGY_HPP
#define ROCM_XIO_RDMA_TOPOLOGY_HPP

#include <cstdint>
#include <set>
#include <string>
#include <vector>

#include "ibv-core.hpp"

namespace xio {
namespace rdma_ep {

/** @brief GID type preference order for RoCE address selection. */
enum GidPriority {
  GID_UNKNOWN = -1,      /**< Unknown or unsupported GID type. */
  ROCEV1_LINK_LOCAL = 0, /**< RoCEv1 link-local IPv6 GID. */
  ROCEV2_LINK_LOCAL = 1, /**< RoCEv2 link-local IPv6 GID. */
  ROCEV1_IPV6 = 2,       /**< RoCEv1 routable IPv6 GID. */
  ROCEV2_IPV6 = 3,       /**< RoCEv2 routable IPv6 GID. */
  ROCEV1_IPV4 = 4,       /**< RoCEv1 IPv4-mapped GID. */
  ROCEV2_IPV4 = 5,       /**< RoCEv2 IPv4-mapped GID. */
};

/** @brief Device classes used by topology enumeration helpers. */
enum DeviceType {
  DEV_CPU = 0, /**< CPU NUMA node. */
  DEV_GPU = 1, /**< HIP GPU device. */
  DEV_NIC = 2, /**< RDMA NIC device. */
};

/** @brief Node in the PCIe topology tree used for proximity scoring. */
struct PCIeNode {
  std::string address;             /**< PCI address component for this node. */
  mutable std::string description; /**< Human-readable sysfs description. */
  std::set<PCIeNode> children;     /**< Child PCIe devices or bridges. */

  /** @brief Construct an empty topology node. */
  PCIeNode() = default;

  /**
   * @brief Construct a node with only a PCI address.
   * @param addr PCI address string.
   */
  PCIeNode(std::string const& addr) : address(addr) {
  }

  /**
   * @brief Construct a node with a PCI address and description.
   * @param addr PCI address string.
   * @param desc Human-readable device description.
   */
  PCIeNode(std::string const& addr, std::string const& desc)
    : address(addr), description(desc) {
  }

  /**
   * @brief Order nodes by PCI address for set storage.
   * @param other Node to compare against.
   * @return true when this address sorts before @p other.
   */
  bool operator<(PCIeNode const& other) const {
    return address < other.address;
  }
};

/**
 * @brief Extract the bus number from a PCI address string.
 * @param pcieAddress PCI address such as 0000:03:00.0.
 * @return Bus number, or -1 if parsing fails.
 */
int ExtractBusNumber(std::string const& pcieAddress);

/**
 * @brief Compute absolute bus-number distance between two PCI addresses.
 * @param pcieAddress1 First PCI address.
 * @param pcieAddress2 Second PCI address.
 * @return Absolute bus distance, or -1 if either address is invalid.
 */
int GetBusIdDistance(std::string const& pcieAddress1,
                     std::string const& pcieAddress2);

/**
 * @brief Find the least common ancestor for two PCIe nodes.
 * @param root Root of the topology tree.
 * @param node1Address First target PCI address.
 * @param node2Address Second target PCI address.
 * @return Pointer to the LCA node, or nullptr when not found.
 */
PCIeNode const* GetLcaBetweenNodes(PCIeNode const* root,
                                   std::string const& node1Address,
                                   std::string const& node2Address);

/**
 * @brief Find the depth of a PCI address under a topology node.
 * @param targetBusID PCI address to locate.
 * @param node Current search node.
 * @param depth Current tree depth.
 * @return Node depth, or -1 if the address is absent.
 */
int GetLcaDepth(std::string const& targetBusID, PCIeNode const* const& node,
                int depth = 0);

/**
 * @brief Insert one sysfs PCIe path into the topology tree.
 * @param pcieAddress PCI address path component.
 * @param description Human-readable device description.
 * @param root Tree root to update.
 * @return 0 on success, negative value on parse failure.
 */
int InsertPCIePathToTree(std::string const& pcieAddress,
                         std::string const& description, PCIeNode& root);

/**
 * @brief Return nearest candidate devices using the discovered PCIe tree.
 * @param targetBusId PCI address of the target device.
 * @param candidateBusIdList Candidate PCI addresses to score.
 * @return Candidate indices with minimum topology distance.
 */
std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList);

/**
 * @brief Return nearest candidate devices using an explicit PCIe tree.
 * @param targetBusId PCI address of the target device.
 * @param candidateBusIdList Candidate PCI addresses to score.
 * @param root Root of the topology tree to use.
 * @return Candidate indices with minimum topology distance.
 */
std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList, PCIeNode const* root);

/**
 * @brief Find the CPU NUMA node closest to a HIP GPU.
 * @param gpuIndex HIP GPU device index.
 * @return NUMA node ID, or -1 on failure.
 */
int GetClosestCpuNumaToGpu(int gpuIndex);

/**
 * @brief Find the CPU NUMA node closest to an RDMA NIC.
 * @param nicIndex Index in the IBV device list.
 * @return NUMA node ID, or -1 on failure.
 */
int GetClosestCpuNumaToNic(int nicIndex);

/**
 * Find the NIC closest to the given GPU via PCIe topology.
 *
 * @param gpuIndex  HIP device index of the GPU
 * @param hca_list  Comma-separated include/exclude list (^prefix to exclude),
 *                  or nullptr for auto-detect
 * @param dev_name  Output: device name of the selected NIC
 * @return Index of the selected NIC in the IBV device list, or -1 on failure
 */
int GetClosestNicToGpu(int gpuIndex, const char* hca_list,
                       const char** dev_name);

/**
 * @brief Count devices of a topology class.
 * @param type Device class to count.
 * @return Number of devices detected, or negative value on failure.
 */
int GetNumDevices(DeviceType type);

/**
 * Select the best GID index for the given IB context and port.
 * Prefers RoCEv2 IPv4-mapped, falls back through priority list.
 *
 * @param ctx       IB verbs context
 * @param port_num  Port number (1-based)
 * @return GID index, or -1 on failure
 */
int SelectBestGid(struct ibv_context* ctx, uint8_t port_num);

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_RDMA_TOPOLOGY_HPP
