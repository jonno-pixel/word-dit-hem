import Foundation
import SQLite3

private enum SQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case data(Data)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ChatDatabase {
    private var connection: OpaquePointer?

    init(file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            file.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite openen mislukt."
            if let db { sqlite3_close(db) }
            throw JJSFailure(message: message)
        }

        connection = db
        sqlite3_busy_timeout(db, 5_000)

        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS chats(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            updated REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS messages(
            id TEXT PRIMARY KEY,
            chat TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL,
            created REAL NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            UNIQUE(chat, seq)
        );
        CREATE INDEX IF NOT EXISTS messages_order ON messages(chat, seq);
        CREATE TABLE IF NOT EXISTS jobs(
            message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            options BLOB NOT NULL
        );
        UPDATE messages SET state='stopped', note='Vorige sessie afgesloten.' WHERE state='running';
        """

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            sqlite3_close(db)
            connection = nil
            throw JJSFailure(message: message)
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    private func statement<T>(
        _ sql: String,
        _ values: [SQLValue] = [],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let connection else { throw JJSFailure(message: "Gespreksopslag is niet geopend.") }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else {
            throw JJSFailure(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(prepared) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text64(prepared, index, $0, UInt64(text.utf8.count), sqliteTransient, UInt8(SQLITE_UTF8))
                }
            case .integer(let number):
                result = sqlite3_bind_int64(prepared, index, number)
            case .real(let number):
                result = sqlite3_bind_double(prepared, index, number)
            case .data(let data):
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(prepared, index, 0)
                } else {
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob64(prepared, index, $0.baseAddress, UInt64($0.count), sqliteTransient)
                    }
                }
            case .null:
                result = sqlite3_bind_null(prepared, index)
            }
            guard result == SQLITE_OK else {
                throw JJSFailure(message: String(cString: sqlite3_errmsg(connection)))
            }
        }
        return try body(prepared)
    }

    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try statement(sql, values) { prepared in
            guard sqlite3_step(prepared) == SQLITE_DONE, let connection else {
                throw JJSFailure(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite uitvoeren mislukt.")
            }
        }
    }

    private func rows<T>(
        _ sql: String,
        _ values: [SQLValue] = [],
        _ decode: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try statement(sql, values) { prepared in
            var result: [T] = []
            while true {
                let code = sqlite3_step(prepared)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else {
                    throw JJSFailure(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite lezen mislukt.")
                }
                result.append(try decode(prepared))
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))),
            as: UTF8.self
        )
    }

    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let value = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func createChat(title: String = "Nieuw gesprek") throws -> String {
        let id = UUID().uuidString
        try execute(
            "INSERT INTO chats(id,title,updated) VALUES(?,?,?)",
            [.text(id), .text(title), .real(Date().timeIntervalSince1970)]
        )
        return id
    }

    func chats(search: String = "") throws -> [ChatSummary] {
        let summaries = try rows("SELECT id,title,updated FROM chats ORDER BY updated DESC") {
            ChatSummary(
                id: text($0, 0),
                title: text($0, 1),
                updated: Date(timeIntervalSince1970: sqlite3_column_double($0, 2))
            )
        }
        guard !search.isEmpty else { return summaries }
        var matches: [ChatSummary] = []
        for summary in summaries {
            if summary.title.localizedStandardContains(search) {
                matches.append(summary)
            } else if try messages(chat: summary.id).contains(where: {
                $0.content.localizedStandardContains(search)
            }) {
                matches.append(summary)
            }
        }
        return matches
    }

    func messages(chat: String) throws -> [ChatMessage] {
        try rows(
            "SELECT id,role,content,state,created,note FROM messages WHERE chat=? ORDER BY seq",
            [.text(chat)]
        ) { row in
            guard let role = MessageRole(rawValue: text(row, 1)),
                  let state = MessageState(rawValue: text(row, 3)) else {
                throw JJSFailure(message: "Gespreksbericht bevat een onbekende rol of status.")
            }
            return ChatMessage(
                id: text(row, 0),
                role: role,
                content: text(row, 2),
                state: state,
                created: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                note: text(row, 5)
            )
        }
    }

    func enqueue(chat: String, input: String, options: GenerationOptions) throws -> String {
        try transaction {
            let nextSequence = try rows(
                "SELECT COALESCE(MAX(seq),-1)+1 FROM messages WHERE chat=?",
                [.text(chat)]
            ) { sqlite3_column_int64($0, 0) }.first ?? 0

            let userID = UUID().uuidString
            let replyID = UUID().uuidString
            let now = Date().timeIntervalSince1970

            try execute(
                "INSERT INTO messages(id,chat,seq,role,content,state,created) VALUES(?,?,?,?,?,?,?)",
                [.text(userID), .text(chat), .integer(nextSequence), .text(MessageRole.user.rawValue),
                 .text(input), .text(MessageState.complete.rawValue), .real(now)]
            )
            try execute(
                "INSERT INTO messages(id,chat,seq,role,content,state,created) VALUES(?,?,?,?,?,?)",
                [.text(replyID), .text(chat), .integer(nextSequence + 1), .text(MessageRole.assistant.rawValue),
                 .text(MessageState.queued.rawValue), .real(now)]
            )
            try execute(
                "INSERT INTO jobs(message,options) VALUES(?,?)",
                [.text(replyID), .data(try JSONEncoder().encode(options))]
            )
            if nextSequence == 0 {
                let firstLine = input.components(separatedBy: .newlines).first ?? "Nieuw gesprek"
                try execute("UPDATE chats SET title=?,updated=? WHERE id=?", [
                    .text(firstLine), .real(now), .text(chat)
                ])
            } else {
                try execute("UPDATE chats SET updated=? WHERE id=?", [.real(now), .text(chat)])
            }
            return replyID
        }
    }

    func nextJob() throws -> (id: String, chat: String, options: GenerationOptions)? {
        let candidates = try rows(
            """
            SELECT message,chat,options FROM (
                SELECT m.id AS message,m.chat AS chat,j.options AS options,m.rowid AS rowid
                FROM messages m JOIN jobs j ON j.message=m.id
                WHERE m.state=?
            ) queued
            ORDER BY rowid
            LIMIT 1
            """,
            [.text(MessageState.queued.rawValue)]
        ) { row -> (String, String, Data) in
            (text(row, 0), text(row, 1), data(row, 2))
        }
        guard let candidate = candidates.first else { return nil }
        return (
            candidate.0,
            candidate.1,
            try JSONDecoder().decode(GenerationOptions.self, from: candidate.2)
        )
    }

    func history(chat: String, before messageID: String) throws -> [EngineTurn] {
        guard let sequence = try rows(
            "SELECT seq FROM messages WHERE id=? AND chat=?",
            [.text(messageID), .text(chat)],
            { sqlite3_column_int64($0, 0) }
        ).first else {
            throw JJSFailure(message: "De taak is niet meer beschikbaar.")
        }
        return try rows(
            "SELECT role,content FROM messages WHERE chat=? AND seq<? ORDER BY seq",
            [.text(chat), .integer(sequence)]
        ) { EngineTurn(role: text($0, 0), content: text($0, 1)) }
    }

    func setState(_ id: String, _ state: MessageState, note: String = "") throws {
        try execute("UPDATE messages SET state=?,note=? WHERE id=?", [
            .text(state.rawValue), .text(note), .text(id)
        ])
    }

    func append(_ id: String, text: String) throws {
        guard !text.isEmpty else { return }
        try execute("UPDATE messages SET content=content || ? WHERE id=?", [.text(text), .text(id)])
    }

    func complete(_ id: String, note: String) throws {
        try transaction {
            try execute("UPDATE messages SET state=?,note=? WHERE id=?", [
                .text(MessageState.complete.rawValue), .text(note), .text(id)
            ])
            try execute("DELETE FROM jobs WHERE message=?", [.text(id)])
        }
    }

    func retry(_ id: String, options: GenerationOptions) throws {
        try transaction {
            try execute(
                "UPDATE messages SET content='',state=?,note='' WHERE id=? AND state IN (?,?)",
                [.text(MessageState.queued.rawValue), .text(id),
                 .text(MessageState.stopped.rawValue), .text(MessageState.failed.rawValue)]
            )
            try execute(
                "INSERT INTO jobs(message,options) VALUES(?,?) ON CONFLICT(message) DO UPDATE SET options=excluded.options",
                [.text(id), .data(try JSONEncoder().encode(options))]
            )
        }
    }

    func renameChat(_ id: String, title: String) throws {
        try execute("UPDATE chats SET title=?,updated=? WHERE id=?", [
            .text(title), .real(Date().timeIntervalSince1970), .text(id)
        ])
    }

    func deleteChat(_ id: String) throws {
        try execute("DELETE FROM chats WHERE id=?", [.text(id)])
    }

    func exportArchive() throws -> Data {
        let archive = try chats().map { chat in
            ArchivedChat(
                id: chat.id,
                title: chat.title,
                updated: chat.updated,
                messages: try messages(chat: chat.id)
            )
        }
        return try JSONEncoder().encode(ArchivedLibrary(conversations: archive))
    }

    func importArchive(_ data: Data) throws {
        let archive = try JSONDecoder().decode(ArchivedLibrary.self, from: data)
        try transaction {
            for source in archive.conversations {
                let id = try createChat(title: source.title)
                for (sequence, message) in source.messages.enumerated() {
                    let importedID = UUID().uuidString
                    try execute(
                        "INSERT INTO messages(id,chat,seq,role,content,state,created,note) VALUES(?,?,?,?,?,?,?,?)",
                        [.text(importedID), .text(id), .integer(Int64(sequence)), .text(message.role.rawValue),
                         .text(message.content), .text(message.state == .running || message.state == .queued ? MessageState.stopped.rawValue : message.state.rawValue),
                         .real(message.created.timeIntervalSince1970), .text(message.note)]
                    )
                }
            }
        }
    }
}

struct ArchivedChat: Codable, Sendable {
    let id: String
    let title: String
    let updated: Date
    let messages: [ChatMessage]
}

struct ArchivedLibrary: Codable, Sendable {
    let conversations: [ArchivedChat]
}
