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
@_spi(SourceKitLSP) import SKLogging

/// Manages per-workspace trust decisions for SourceKit-LSP.
///
/// Trust is stored per workspace root in a JSON file (default: `~/.sourcekit-lsp/trusted-workspaces.json`).
/// A workspace must be trusted before SourceKit-LSP loads any workspace-scoped configuration
/// (`.sourcekit-lsp/config.json`, `.bsp/*.json`) that could be used to execute code or alter
/// behavior of subprocesses launched by SourceKit-LSP. This mirrors the model used by VS Code's
/// Workspace Trust feature.
///
/// The trust checks (``hasWorkspaceScopedConfig(workspaceRoot:)`` and
/// ``workspaceScopedConfigPathIsSafe(named:in:)``) are racy with respect to subsequent reads of
/// the same paths: the directory could appear, disappear, or be replaced with an escaping symlink
/// between the check and when the loaders open the config file. We accept that TOCTOU window
/// because the threat model here is a malicious workspace shipped as a poisoned repository (or a
/// user who clones one), not an attacker with concurrent write access on the user's machine while
/// sourcekit-lsp is initializing the workspace. Closing the window would require operating on a
/// file descriptor opened atomically with the check rather than re-resolving the path.
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
  ///
  /// A symlink whose realpath escapes `workspaceRoot` still counts as present here so that the
  /// user is shown a trust prompt. The actual loaders independently refuse to read through such
  /// symlinks via ``realpathStaysWithin(_:workspaceRoot:)`` — see the call sites that load
  /// `.sourcekit-lsp/config.json` and enumerate `.bsp/`.
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

  /// Returns `true` if the workspace-scoped config path `<workspaceRoot>/<name>` either does not
  /// exist or exists as a directory whose realpath remains within `workspaceRoot`.
  ///
  /// Returns `false` when the path exists but is not a plain directory inside the workspace —
  /// i.e. it's a regular file, or a symlink whose realpath escapes the workspace root. The caller
  /// must refuse to load through it. This is a defense-in-depth complement to the trust prompt:
  /// even a workspace the user has trusted can't be coerced into reading config from arbitrary
  /// paths elsewhere on the filesystem, and a stray non-directory at `.sourcekit-lsp` / `.bsp`
  /// can't be reinterpreted by the loaders.
  package func workspaceScopedConfigPathIsSafe(named name: String, in workspaceRoot: URL) -> Bool {
    let candidate = workspaceRoot.appending(component: name)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
      return true
    }
    guard isDirectory.boolValue else {
      return false
    }
    guard Self.realpathStaysWithin(candidate, workspaceRoot: workspaceRoot) else {
      logger.fault(
        """
        Refusing to load workspace-scoped config from \(candidate.path, privacy: .public): \
        its resolved path escapes the workspace root \(workspaceRoot.path, privacy: .public).
        """
      )
      return false
    }
    return true
  }

  /// Returns `true` if the realpath of `url` is `workspaceRoot` itself or strictly contained within
  /// it. Used to keep workspace-scoped config from being loaded through a symlink that points
  /// outside the workspace, since the user's "Trust this workspace" decision can't reasonably
  /// extend to arbitrary paths elsewhere on the filesystem.
  package static func realpathStaysWithin(_ url: URL, workspaceRoot: URL) -> Bool {
    let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
    let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path
    if candidate == root { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return candidate.hasPrefix(prefix)
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
