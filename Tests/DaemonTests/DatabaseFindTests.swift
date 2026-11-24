import Core
import Foundation
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
