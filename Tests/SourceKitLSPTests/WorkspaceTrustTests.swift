//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
@_spi(SourceKitLSP) import LanguageServerProtocol
@_spi(SourceKitLSP) import LanguageServerProtocolTransport
import SKOptions
import SKTestSupport
import SourceKitLSP
import SwiftExtensions
import Synchronization
@_spi(SourceKitLSP) import ToolsProtocolsSwiftExtensions
import XCTest

final class WorkspaceTrustTests: XCTestCase {

  // MARK: - Test fixtures

  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = URL(
      fileURLWithPath: NSTemporaryDirectory(),
      isDirectory: true
    )
    .appending(component: "WorkspaceTrustTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
    tempDir = nil
    try super.tearDownWithError()
  }

  /// Returns a fresh `WorkspaceTrust` whose persistence file is inside `tempDir`. Multiple instances
  /// returned from this method share the same storage path so they observe each other's grants.
  private func makeTrust() -> WorkspaceTrust {
    return WorkspaceTrust(trustedWorkspacesURL: tempDir.appending(component: "trusted-workspaces.json"))
  }

  /// Creates an empty workspace folder under `tempDir` and returns its URL.
  private func makeWorkspace(named name: String = "Workspace") throws -> URL {
    let url = tempDir.appending(component: name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Creates a `.bsp` subdirectory inside `workspace`.
  private func addDotBsp(to workspace: URL) throws {
    try FileManager.default.createDirectory(
      at: workspace.appending(component: ".bsp"),
      withIntermediateDirectories: true
    )
  }

  /// Creates a `.sourcekit-lsp` subdirectory inside `workspace`.
  private func addDotSourceKitLSP(to workspace: URL) throws {
    try FileManager.default.createDirectory(
      at: workspace.appending(component: ".sourcekit-lsp"),
      withIntermediateDirectories: true
    )
  }

  // MARK: - hasWorkspaceScopedConfig

  func testWorkspaceWithoutTrustGatedDirectoriesIsNotGated() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    XCTAssertFalse(trust.hasWorkspaceScopedConfig(workspaceRoot: workspace))
  }

  func testRegularFileNamedDotBspDoesNotGate() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try Data().write(to: workspace.appending(component: ".bsp"))
    XCTAssertFalse(trust.hasWorkspaceScopedConfig(workspaceRoot: workspace))
  }

  func testUnrelatedDotfileDoesNotGate() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try FileManager.default.createDirectory(
      at: workspace.appending(component: ".vscode"),
      withIntermediateDirectories: true
    )
    XCTAssertFalse(trust.hasWorkspaceScopedConfig(workspaceRoot: workspace))
  }

  func testDotBspDirectoryGates() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)
    XCTAssertTrue(trust.hasWorkspaceScopedConfig(workspaceRoot: workspace))
  }

  func testDotSourceKitLSPDirectoryGates() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotSourceKitLSP(to: workspace)
    XCTAssertTrue(trust.hasWorkspaceScopedConfig(workspaceRoot: workspace))
  }

  // MARK: - workspaceScopedConfigPathIsSafe

  func testConfigPathIsSafeWhenAbsent() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".bsp", in: workspace))
  }

  func testConfigPathIsSafeWhenRealDirectory() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotSourceKitLSP(to: workspace)
    try addDotBsp(to: workspace)
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".bsp", in: workspace))
  }

  func testConfigPathIsUnsafeWhenRegularFile() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try Data().write(to: workspace.appending(component: ".sourcekit-lsp"))
    XCTAssertFalse(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
  }

  func testConfigPathIsSafeWhenSymlinkStaysWithinWorkspace() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    let realConfig = workspace.appending(component: "config-storage")
    try FileManager.default.createDirectory(at: realConfig, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.appending(component: ".sourcekit-lsp"),
      withDestinationURL: realConfig
    )
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
  }

  func testConfigPathIsUnsafeWhenSymlinkEscapesWorkspace() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    // A directory outside the workspace under the same `tempDir` parent.
    let outside = tempDir.appending(component: "outside-config")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.appending(component: ".sourcekit-lsp"),
      withDestinationURL: outside
    )
    XCTAssertFalse(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
  }

  func testConfigPathIsUnsafeWhenSymlinkResolvesToFile() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    let regularFile = workspace.appending(component: "not-a-directory")
    try Data().write(to: regularFile)
    try FileManager.default.createSymbolicLink(
      at: workspace.appending(component: ".bsp"),
      withDestinationURL: regularFile
    )
    XCTAssertFalse(trust.workspaceScopedConfigPathIsSafe(named: ".bsp", in: workspace))
  }

  func testConfigPathIsSafeWhenDanglingSymlink() throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try FileManager.default.createSymbolicLink(
      at: workspace.appending(component: ".sourcekit-lsp"),
      withDestinationURL: workspace.appending(component: "missing-target")
    )
    // A dangling symlink doesn't resolve to anything, so there's nothing for the loaders to read.
    // It's "safe" in the same sense that an absent path is safe.
    XCTAssertTrue(trust.workspaceScopedConfigPathIsSafe(named: ".sourcekit-lsp", in: workspace))
  }

  // MARK: - requestTrust outcomes

  func testGrantingFromPromptReturnsTrue() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)
    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Trust Workspace"))

    let granted = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertTrue(granted)
    XCTAssertEqual(connection.requestCount, 1)
  }

  func testDecliningFromPromptReturnsFalse() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotSourceKitLSP(to: workspace)
    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Don't Trust"))

    let granted = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertFalse(granted)
    XCTAssertEqual(connection.requestCount, 1)
  }

  func testNilResponseFromClientIsTreatedAsDecline() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)
    let connection = StubShowMessageRequestConnection(answer: nil)

    let granted = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertFalse(granted)
  }

  func testClientErrorIsTreatedAsDecline() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)
    let connection = StubShowMessageRequestConnection(error: ResponseError.unknown("client failed"))

    let granted = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertFalse(granted)
  }

  // MARK: - Persistence

  func testGrantPersists() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)

    XCTAssertFalse(trust.isTrusted(workspaceRoot: workspace))
    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Trust Workspace"))
    _ = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertTrue(trust.isTrusted(workspaceRoot: workspace))
  }

  func testDecliningDoesNotPersist() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)

    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Don't Trust"))
    _ = await trust.requestTrust(workspaceRoot: workspace, connection: connection)
    XCTAssertFalse(trust.isTrusted(workspaceRoot: workspace))
  }

  func testGrantPersistsAcrossInstances() async throws {
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)

    let trust1 = makeTrust()
    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Trust Workspace"))
    _ = await trust1.requestTrust(workspaceRoot: workspace, connection: connection)

    // A fresh instance reading from the same storage should see the grant.
    let trust2 = makeTrust()
    XCTAssertTrue(trust2.isTrusted(workspaceRoot: workspace))
  }

  func testGrantingOneWorkspaceDoesNotTrustOthers() async throws {
    let trust = makeTrust()
    let trusted = try makeWorkspace(named: "Trusted")
    let unrelated = try makeWorkspace(named: "Unrelated")
    try addDotBsp(to: trusted)
    try addDotBsp(to: unrelated)

    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Trust Workspace"))
    _ = await trust.requestTrust(workspaceRoot: trusted, connection: connection)

    XCTAssertTrue(trust.isTrusted(workspaceRoot: trusted))
    XCTAssertFalse(trust.isTrusted(workspaceRoot: unrelated))
  }

  func testTrustChecksUseStandardizedPaths() async throws {
    let trust = makeTrust()
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)

    let connection = StubShowMessageRequestConnection(answer: MessageActionItem(title: "Trust Workspace"))
    _ = await trust.requestTrust(workspaceRoot: workspace, connection: connection)

    // A non-standardized URL pointing at the same path should be recognized as trusted.
    let nonStandardized = workspace.appending(component: ".").appending(component: "..")
      .appending(component: workspace.lastPathComponent)
    XCTAssertTrue(trust.isTrusted(workspaceRoot: nonStandardized))
  }

  // MARK: - Bypass via SourceKitLSPOptions

  func testBypassWorkspaceTrustSkipsPromptForWorkspaceWithDotBsp() async throws {
    let workspace = try makeWorkspace()
    try addDotBsp(to: workspace)

    var options = try await SourceKitLSPOptions.testDefault()
    options.bypassWorkspaceTrust = true

    let promptCount = ThreadSafeBox<Int>(initialValue: 0)
    let testClient = try await TestSourceKitLSPClient(
      options: options,
      workspaceFolders: [WorkspaceFolder(uri: DocumentURI(workspace))],
      preInitialization: { client in
        client.handleMultipleRequests { (_: ShowMessageRequest) -> MessageActionItem? in
          promptCount.withLock { $0 += 1 }
          return nil
        }
      }
    )

    // The trust prompt is fired in a detached `Task` during workspace creation.
    // Give it a brief window to (incorrectly) run.
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(
      promptCount.value,
      0,
      "Trust prompt fired even though bypassWorkspaceTrust is true"
    )
    _ = testClient
  }
}

// MARK: - Test helpers

/// A `Connection` that responds to every `ShowMessageRequest` with a configured answer or error.
private final class StubShowMessageRequestConnection: Connection, Sendable {
  private let answer: MessageActionItem?
  private let error: ResponseError?
  private let _requestCount = Atomic<UInt32>(0)
  var requestCount: UInt32 { _requestCount.load(ordering: .relaxed) }

  init(answer: MessageActionItem?) {
    self.answer = answer
    self.error = nil
  }

  init(error: ResponseError) {
    self.answer = nil
    self.error = error
  }

  func send(_ notification: some NotificationType) {}

  func nextRequestID() -> RequestID { .number(0) }

  func send<Request: RequestType>(
    _ request: Request,
    id: RequestID,
    reply: @escaping @Sendable (LSPResult<Request.Response>) -> Void
  ) {
    _ = _requestCount.wrappingAdd(1, ordering: .relaxed)
    if let error {
      reply(.failure(error))
      return
    }
    guard Request.method == ShowMessageRequest.method else {
      XCTFail("Unexpected non-ShowMessageRequest: \(Request.method)")
      reply(.failure(ResponseError.unknown("unexpected request")))
      return
    }
    // ShowMessageRequest's Response is `MessageActionItem?`. The cast is safe because we just
    // verified the request method.
    reply(.success(answer as! Request.Response))
  }
}
