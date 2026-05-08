/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_ENDPOINT_REGISTRY_H
#define XIO_ENDPOINT_REGISTRY_H

#include <string>
#include <vector>

#include <hip/hip_runtime.h>

// Include auto-generated EndpointType enum
#include "xio-endpoint-registry-gen.h"
#include "xio-export.h"

/**
 * @brief Static metadata for one registered endpoint.
 */
struct EndpointInfo {
  std::string name;        /**< CLI and factory name for the endpoint. */
  std::string description; /**< Human-readable endpoint summary. */
  EndpointType type;       /**< Generated endpoint type identifier. */
};

/**
 * @brief Return the registry of endpoints compiled into the binary.
 * @return Immutable vector of endpoint metadata entries.
 */
XIO_API const std::vector<EndpointInfo>& getEndpointRegistry();

/**
 * @brief Convert an endpoint name to its generated type identifier.
 * @param name Endpoint name, matched case-insensitively.
 * @return Matching EndpointType, or EndpointType::UNKNOWN when absent.
 */
XIO_API EndpointType getEndpointType(const std::string& name);

/**
 * @brief Return the canonical endpoint name for a generated type.
 * @param type Endpoint type identifier.
 * @return Endpoint name string, or nullptr when @p type is unknown.
 */
XIO_API const char* getEndpointName(EndpointType type);

/**
 * @brief Print all registered endpoint names and descriptions to stdout.
 */
XIO_API void listAvailableEndpoints();

/**
 * @brief Check whether an endpoint name is registered.
 * @param name Endpoint name to validate, matched case-insensitively.
 * @return true when @p name resolves to a registered endpoint.
 */
XIO_API bool isValidEndpoint(const std::string& name);

/**
 * @brief Return metadata for an endpoint type.
 * @param type Endpoint type identifier.
 * @return Matching EndpointInfo, or an UNKNOWN entry when unsupported.
 */
XIO_API EndpointInfo getEndpointInfo(EndpointType type);

#endif // XIO_ENDPOINT_REGISTRY_H
