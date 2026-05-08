/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_ENV_H
#define XIO_ENV_H

#include <cstdio>

namespace xio {

/** @brief Logging thresholds controlled by ROCXIO_LOG_LEVEL. */
enum LogLevel : int {
  LOG_NONE = 0,  /**< Disable rocm-xio logging. */
  LOG_ERROR = 1, /**< Print only error messages. */
  LOG_WARN = 2,  /**< Print warnings and errors. */
  LOG_INFO = 3,  /**< Print informational messages and above. */
  LOG_DEBUG = 4, /**< Print debug messages and above. */
  LOG_TRACE = 5  /**< Print trace-level messages and above. */
};

/**
 * @brief Read an integer environment variable.
 * @param name Environment variable name.
 * @param defaultVal Value returned when unset or invalid.
 * @return Parsed integer value, or @p defaultVal.
 */
int getEnvInt(const char* name, int defaultVal);

/**
 * @brief Read a string environment variable.
 * @param name Environment variable name.
 * @param defaultVal Value returned when unset.
 * @return Environment value pointer, or @p defaultVal.
 */
const char* getEnvStr(const char* name, const char* defaultVal);

/**
 * @brief Return the active rocm-xio log threshold.
 * @return One of LogLevel, parsed from ROCXIO_LOG_LEVEL.
 */
int rocxioLogLevel();

/**
 * @brief Check whether verbose mode is enabled.
 * @return true when ROCXIO_VERBOSE is set to a nonzero value.
 */
bool rocxioVerbose();

} // namespace xio

/** @brief Print an error log message when error logging is enabled. */
#define ROCXIO_LOG_ERROR(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_ERROR)                               \
      fprintf(stderr, "rocm-xio ERROR: " fmt, ##__VA_ARGS__);                  \
  } while (0)

/** @brief Print a warning log message when warning logging is enabled. */
#define ROCXIO_LOG_WARN(fmt, ...)                                              \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_WARN)                                \
      fprintf(stderr, "rocm-xio WARN: " fmt, ##__VA_ARGS__);                   \
  } while (0)

/** @brief Print an info log message when info logging is enabled. */
#define ROCXIO_LOG_INFO(fmt, ...)                                              \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_INFO)                                \
      fprintf(stdout, "rocm-xio INFO: " fmt, ##__VA_ARGS__);                   \
  } while (0)

/** @brief Print a debug log message when debug logging is enabled. */
#define ROCXIO_LOG_DEBUG(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_DEBUG)                               \
      fprintf(stderr, "rocm-xio DEBUG: " fmt, ##__VA_ARGS__);                  \
  } while (0)

/** @brief Print a trace log message when trace logging is enabled. */
#define ROCXIO_LOG_TRACE(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_TRACE)                               \
      fprintf(stderr, "rocm-xio TRACE: " fmt, ##__VA_ARGS__);                  \
  } while (0)

#endif // XIO_ENV_H
