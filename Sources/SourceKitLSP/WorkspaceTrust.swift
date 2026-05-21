//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import Foundation
@_spi(SourceKitLSP) package import LanguageServerProtocol
@_spi(SourceKitLSP) import LanguageServerProtocolTransport

/// Manages per-workspace trust decisions for SourceKit-LSP.
///
/// Trust is stored per workspace root in a JSON file (default: `~/.sourcekit-lsp/trusted-workspaces.json`).
/// A workspace must be trusted before SourceKit-LSP loads any workspace-scoped configuration
/// (`.sourcekit-lsp/config.json`, `.bsp/*.json`) that could be used to execute code or alter
/// behavior of subprocesses launched by SourceKit-LSP. This mirrors the model used by VS Code's
/// Workspace Trust feature.
package struct WorkspaceTrust: Sendable {
  /// The file in which trusted workspace roots are persisted.
  private let trustedWorkspacesURL: URL

  /// Creates a `WorkspaceTrust` that persists decisions to `~/.sourcekit-lsp/trusted-workspaces.json`.
  package init() {
    self.trustedWorkspacesURL =
      FileManager.default.homeDirectoryForCurrentUser
      .appending(components: ".sourcekit-lsp", "trusted-workspaces.json")
  }

  /// Creates a `WorkspaceTrust` that persists decisions to a custom path. For tests.
  package init(trustedWorkspacesURL: URL) {
    self.trustedWorkspacesURL = trustedWorkspacesURL
  }

  /// Returns whether the workspace contains any directories whose contents require trust before
  /// SourceKit-LSP loads them: a `.sourcekit-lsp` or `.bsp` directory inside the workspace root.
  package func hasWorkspaceScopedConfig(workspaceRoot: URL) -> Bool {
    let candidates = [
      workspaceRoot.appending(component: ".sourcekit-lsp"),
      workspaceRoot.appending(component: ".bsp"),
    ]
    return candidates.contains { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
  }

  /// Returns whether the workspace rooted at `workspaceRoot` has previously been granted trust.
  package func isTrusted(workspaceRoot: URL) -> Bool {
    guard let data = try? Data(contentsOf: trustedWorkspacesURL),
      let trusted = try? JSONDecoder().decode([String].self, from: data)
    else {
      return false
    }
    return trusted.contains(workspaceRoot.standardizedFileURL.path)
  }

  /// Persists a trust grant for the workspace rooted at `workspaceRoot`.
  private func persistTrust(workspaceRoot: URL) {
    let key = workspaceRoot.standardizedFileURL.path
    var trusted: [String]
    if let data = try? Data(contentsOf: trustedWorkspacesURL),
      let existing = try? JSONDecoder().decode([String].self, from: data)
    {
      trusted = existing
    } else {
      trusted = []
    }
    guard !trusted.contains(key) else { return }
    trusted.append(key)
    guard let data = try? JSONEncoder().encode(trusted) else { return }
    try? FileManager.default.createDirectory(
      at: trustedWorkspacesURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: trustedWorkspacesURL)
  }

  /// Sends a `window/showMessageRequest` asking the user whether to trust the workspace,
  /// persists the decision on grant, and returns whether the user granted trust.
  ///
  /// Callers should run this in a background `Task` so that the trust prompt does not block
  /// the LSP request that triggered workspace creation. Until the user responds, the workspace
  /// must be operated in restricted mode.
  package func requestTrust(
    workspaceRoot: URL,
    connection: some Connection
  ) async -> Bool {
    precondition(workspaceRoot.isFileURL, "WorkspaceTrust requires a file URL")
    let folderName = workspaceRoot.lastPathComponent
    let response = try? await connection.send(
      ShowMessageRequest(
        type: .warning,
        message: """
          Do you trust the authors of the files in "\(folderName)"? \
          SourceKit-LSP found workspace-scoped configuration (.sourcekit-lsp/ or .bsp/) \
          that may launch external processes or alter how subprocesses are sandboxed. \
          Only trust workspaces from sources you trust.
          """,
        actions: [
          MessageActionItem(title: "Trust Workspace"),
          MessageActionItem(title: "Don't Trust"),
        ]
      )
    )
    if response?.title == "Trust Workspace" {
      persistTrust(workspaceRoot: workspaceRoot)
      return true
    }
    return false
  }
}
