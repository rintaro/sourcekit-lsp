//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// A single completion result.
public struct CompletionItem: Codable, Hashable {

  /// The display name of the completion.
  public var label: String

  /// An extended human-readable name (longer than `label`, but simpler than `documentation`).
  public var detail: String?

  /// The name to use for sorting the result. If `nil`, use `label.
  public var sortText: String?

  /// The name to use for filtering the result. If `nil`, use `label.
  public var filterText: String?

  /// The (primary) edit to apply to the document if this completion is accepted. This takes precedence over `insertText`.
  ///
  /// - note: the range of the edit must contain the completion position.
  public var textEdit: TextEdit?

  /// **Deprecated**: use `textEdit`
  ///
  /// The string to insert into the document. If `nil`, use `label.
  public var insertText: String?

  /// The format of the `textEdit.nextText` or `insertText` value.
  public var insertTextFormat: InsertTextFormat?

  /// Optional array of additional text edits that are applied when selecting this completion.
  public var additionalTextEdits: [TextEdit]?

  public var kind: CompletionItemKind

  public var deprecated: Bool?

  // TODO: remaining members

  public init(label: String, detail: String? = nil, sortText: String? = nil, filterText: String? = nil, textEdit: TextEdit? = nil, insertText: String? = nil, insertTextFormat: InsertTextFormat? = nil, additionalTextEdits: [TextEdit]? = nil, kind: CompletionItemKind, deprecated: Bool? = nil) {
    self.label = label
    self.detail = detail
    self.sortText = sortText
    self.filterText = filterText
    self.textEdit = textEdit
    self.insertText = insertText
    self.insertTextFormat = insertTextFormat
    self.additionalTextEdits = additionalTextEdits
    self.kind = kind
    self.deprecated = deprecated
  }
}


public enum InsertTextFormat: Int, Codable, Hashable {

  /// The text to insert is plain text.
  case plain = 1

  /// The text to insert is a "snippet", which may contain placheolders.
  case snippet = 2
}
