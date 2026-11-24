import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

// Reading a project's files for its databases, in the shapes real projects write them.

/// A compose file indented by four, with an env_file, `${VAR:?…}`, two unpublished services with one database name, and
/// images that only have "postgres" in their name.
@Test func composeIsReadAsComposeReadsIt() {
    let compose = """
        services:
            db:
                image: postgis/postgis:16-3.4
                ports:
                    - "5433:5432"
                env_file:
                    - path: ./db.env
                      required: false
                environment:
                    POSTGRES_DB: shop
            replica:
                image: bitnami/postgresql
                env_file: db.env
                environment:
                    POSTGRES_PASSWORD: ${REPLICA_PASSWORD:?set REPLICA_PASSWORD}
                    POSTGRES_DB: shop
            other:
                image: postgres:16
                environment:
                    POSTGRES_DB: shop
            rest:
                image: postgrest/postgrest
            metrics:
                image: prometheuscommunity/postgres-exporter
        """
    let found = DatabaseFind.unique(
        DatabaseFind.parse([("api/compose.yaml", compose)], root: "/p") {
            $0 == "api/db.env" ? "POSTGRES_USER=app\nPOSTGRES_PASSWORD=pw\n" : nil
        })
    #expect(found.map(\.service?.name) == ["db", "replica", "other"])
    #expect(found[0].database.port == 5433 && found[0].database.user == "app" && found[0].password == "pw")
    #expect(found[0].database.database == "shop")
    #expect(found[1].database.user == "app" && found[1].password == nil)   // never the text "${…:?…}"
    #expect(found[1].database.name == "shop-2" && found[2].database.name == "shop-3")
}

/// What compose fills in for each form of a variable; nil where compose would refuse to start.
@Test func composeVariablesFillInAsComposeFillsThem() {
    let env = ["SET": "x", "EMPTY": ""]
    let cases: [(String, String?)] = [
        ("${SET}", "x"), ("${UNSET}", ""), ("$SET-$$SET", "x-$SET"), ("${UNSET:-d}", "d"), ("${EMPTY:-d}", "d"),
        ("${EMPTY-d}", ""), ("${SET:?no}", "x"), ("${UNSET:?no}", nil), ("${EMPTY:?no}", nil), ("${EMPTY?no}", ""),
        ("${SET:+y}", "y"), ("${UNSET:+y}", "")
    ]
    for (text, filled) in cases {
        #expect(DatabaseFind.interpolated(text, env) == filled, "\(text)")
    }
}

/// Only a database's own image is a database: by the image's name, not a word in it.
@Test func aDatabaseImageIsKnownByItsName() {
    let images: [(String, DatabaseInfo.Engine?)] = [
        ("postgres:16", .postgres), ("postgis/postgis:16-3.4", .postgres),
        ("localhost:5000/bitnami/postgresql:16", .postgres),
        ("timescale/timescaledb-ha:pg16", .postgres), ("pgvector/pgvector:pg16", .postgres),
        ("ghcr.io/supabase/postgres@sha256:ab", .postgres), ("mysql:8", .mysql), ("mariadb:10.11", .mysql),
        ("percona/percona-server:8.0", .mysql), ("postgrest/postgrest", nil), ("postgres-exporter", nil),
        ("prom/mysqld-exporter", nil), ("redis:7", nil)
    ]
    for (image, engine) in images {
        #expect(DatabaseInfo.Engine(image: image) == engine, "\(image)")
    }
}

/// A database.yml as `rails new` writes it: the shared settings under an anchor, merged into each block.
@Test func railsDatabaseYAMLsAnchorsAreFollowed() {
    let text = """
        default: &default
          adapter: postgresql
          encoding: unicode
          host: db.local.test
          pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

        development:
          <<: *default
          database: shop_development

        test:
          <<: *default
          host: localhost
          database: shop_test
        """
    let found = DatabaseFind.rails(text, source: "config/database.yml", root: "/p")
    #expect(found.map(\.database.name) == ["shop_development", "shop_test"])
    #expect(found.allSatisfy { $0.database.engine == .postgres })
    #expect(found.map(\.database.host) == ["db.local.test", "localhost"])   // a block's own key wins over the merge
}

/// A file whose aliases nest ten to a level ("billion laughs", from a cloned repo) is read as it is, rather than
/// written out to 10⁸ lines in kelpd's memory; its database is still found.
@Test(.timeLimit(minutes: 1)) func nestedAliasesArentWrittenOutPastALimit() {
    let levels = "abcdefghi".map(String.init)
    var text = "a: &a\n" + (0..<10).map { "  x\($0): lol" }.joined(separator: "\n") + "\n"
    for (inner, outer) in zip(levels, levels.dropFirst()) {
        text += "\(outer): &\(outer)\n" + (0..<10).map { "  k\($0): *\(inner)" }.joined(separator: "\n") + "\n"
    }
    text += "development:\n  adapter: postgresql\n  database: shop_dev\n  extra: *i\n"
    let out = DatabaseFind.expandingAnchors(text)
    #expect(out.utf8.count <= DatabaseFind.expandedBytes + text.utf8.count)
    #expect(DatabaseFind.rails(text, source: "config/database.yml", root: "/p").map(\.database.name) == ["shop_dev"])
}

/// Laravel's and Django's .env give a database in separate variables, libpq's PG* too; SQLAlchemy names its driver in
/// the URL's scheme.
@Test func aDatabaseInSeparateVariablesIsFound() {
    typealias Seen = (engine: DatabaseInfo.Engine, host: String?, database: String?, user: String?, password: String?)
    let cases: [(String, [Seen])] = [
        (
            "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=laravel\nDB_USERNAME=root\nDB_PASSWORD=s",
            [(.mysql, "127.0.0.1", "laravel", "root", "s")]
        ),
        ("DB_CONNECTION=pgsql\nDB_DATABASE=shop\nDB_PASSWORD=", [(.postgres, "localhost", "shop", nil, nil)]),
        (
            "DB_ENGINE=django.db.backends.postgresql\nDB_NAME=app\nDB_USER=u\nDB_HOST=db.example.com",
            [(.postgres, "db.example.com", "app", "u", nil)]
        ),
        ("DB_HOST=localhost\nDB_PORT=5432\nDB_NAME=app", [(.postgres, "localhost", "app", nil, nil)]),
        (
            "PGHOST=localhost\nPGDATABASE=shop\nPGUSER=app\nPGPASSWORD=pw",
            [(.postgres, "localhost", "shop", "app", "pw")]
        ),
        ("DATABASE_URL=postgresql+psycopg://app:pw@localhost/shop", [(.postgres, "localhost", "shop", "app", "pw")]),
        ("DB_CONNECTION=sqlite\n# DB_HOST=127.0.0.1", []),
        ("DB_HOST=redis.internal", [])
    ]
    for (text, seen) in cases {
        let found = DatabaseFind.env(text, source: ".env", root: "/p")
        #expect(found.count == seen.count, "\(text)")
        for (one, want) in zip(found, seen) {
            let db = one.database
            #expect(db.engine == want.engine && db.host == want.host && db.database == want.database, "\(text)")
            #expect(db.user == want.user && one.password == want.password, "\(text)")
        }
    }
    let sqlite = DatabaseFind.env("DB_CONNECTION=sqlite\nDB_DATABASE=database/app.sqlite", source: ".env", root: "/p")
    #expect(sqlite.first?.database.path == "/p/database/app.sqlite")
}
