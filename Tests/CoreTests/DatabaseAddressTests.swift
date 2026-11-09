import Core
import Testing

private func parsed(_ text: String) throws -> DatabaseAddress { try DatabaseAddress.parse(text) }

/// Whatever form an address is pasted in, the same database comes out, its password apart.
@Test func addressesPastedInEachFormReadAlike() throws {
    let url = try parsed("postgres://app:s%40cret@db.example.com:6543/app_dev?sslmode=require")
    #expect(url.database.engine == .postgres && url.database.host == "db.example.com" && url.database.port == 6543)
    #expect(url.database.database == "app_dev" && url.database.user == "app" && url.database.name == "app_dev")
    #expect(url.password == "s@cret" && url.database.ssl == "require")

    let jdbc = try parsed("jdbc:postgresql://db.example.com/app_dev?user=app&password=pw")
    #expect(jdbc.database.port == 5432 && jdbc.database.user == "app" && jdbc.password == "pw")

    let env = try parsed(#"export DATABASE_URL="mysql://root@127.0.0.1/shop""#)
    #expect(env.database.engine == .mysql && env.database.port == 3306 && env.database.database == "shop")

    let words = try parsed("host=db.example.com port=5433 dbname=app user=app password='it\\'s' sslmode=disable")
    #expect(words.database.host == "db.example.com" && words.database.port == 5433 && words.database.database == "app")
    #expect(words.password == "it's" && words.database.ssl == "disable")

    let psql = try parsed("psql -h db.example.com -p 5433 -U app app_dev")
    #expect(psql.database.host == "db.example.com" && psql.database.port == 5433 && psql.database.user == "app")
    #expect(psql.database.database == "app_dev" && psql.password == nil)
    #expect(try parsed("psql 'postgres://a@h/d'").database.database == "d")

    let mysql = try parsed("mysql -h 10.0.0.2 -P 3307 -u root -psecret shop")
    #expect(mysql.database.engine == .mysql && mysql.database.port == 3307 && mysql.password == "secret")
    #expect(mysql.database.database == "shop" && mysql.database.user == "root")

    #expect(try parsed("~/data/app.duckdb").database.engine == .duckdb)
    #expect(try parsed("sqlite:///tmp/x.db").database.path == "/tmp/x.db")
    #expect(try parsed("/tmp/shop.sqlite3").database.name == "shop")
}

/// What can't be read says why, in words the sheet shows under the field.
@Test func whatIsntAnAddressSaysWhy() {
    #expect(
        throws: DatabaseAddress.Problem(message: "Kelp doesn't speak redis:// yet: Postgres, MySQL, SQLite and DuckDB.")
    ) {
        try parsed("redis://localhost:6379")
    }
    #expect(throws: DatabaseAddress.Problem(message: "The address names no host.")) { try parsed("postgres:///db") }
    #expect(throws: DatabaseAddress.Problem.self) { try parsed("hello") }
}
