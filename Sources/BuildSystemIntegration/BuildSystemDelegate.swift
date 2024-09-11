//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerProtocol
import LanguageServerProtocol

/// Handles build system events, such as file build settings changes.
package protocol BuildSystemManagerDelegate: AnyObject, Sendable {
  /// Notify the delegate that the given files' build settings have changed.
  func fileBuildSettingsChanged(_ changedFiles: Set<DocumentURI>) async

  /// Notify the delegate that the dependencies of the given files have changed
  /// and that ASTs may need to be refreshed. If the given set is empty, assume
  /// that all watched files are affected.
  ///
  /// The callee should refresh ASTs unless it is able to determine that a
  /// refresh is not necessary.
  func filesDependenciesUpdated(_ changedFiles: Set<DocumentURI>) async

  /// Notify the delegate that some information about the given build targets has changed and that it should recompute
  /// any information based on top of it.
  func buildTargetsChanged(_ changes: [BuildTargetEvent]?) async

  /// Log the given message to the client's index log.
  func logMessageToIndexLog(taskID: IndexTaskID, message: String)
}
