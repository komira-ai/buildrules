//! The Postgres fixture end to end. This package declares `postgres = { url-env = "PGDEMO_URL" }`, so the run of this test starts a private
//! server for it, names it in PGDEMO_URL, and stops it after the test; the test writes a row and reads it back. Without the fixture the
//! variable is not set, and the test fails saying so (ci/faulty: the same binary run without it).

use pgdemo::{Error, Host, Session, Url};

fn server() -> Url {
    let text = std::env::var("PGDEMO_URL").unwrap_or_else(|_| {
        panic!("PGDEMO_URL names no Postgres server: this test runs with the Postgres fixture (`postgres = {{ url-env = \"PGDEMO_URL\" }}` in [package.metadata.buildrules])")
    });
    Url::parse(&text).unwrap_or_else(|e| panic!("PGDEMO_URL is '{text}', which is not a server URL: {e:?}"))
}

#[test]
fn a_row_written_is_read_back() {
    let mut s = Session::connect(&server()).expect("the fixture's server answers");
    s.query("CREATE TABLE greeting (id integer PRIMARY KEY, text text NOT NULL)").expect("the table is made");
    s.query("INSERT INTO greeting VALUES (1, 'written by the fixture test')").expect("the row is written");
    let rows = s.query("SELECT id, text FROM greeting").expect("the row is read");
    assert_eq!(rows, vec![vec![Some("1".to_owned()), Some("written by the fixture test".to_owned())]]);
}

#[test]
fn the_server_listens_on_its_socket_only() {
    let url = server();
    let Host::Socket(dir) = &url.host else { panic!("the fixture's URL names a TCP host: {:?}", url.host) };
    let mut s = Session::connect(&url).expect("the fixture's server answers");
    let rows = s.query("SELECT current_setting('listen_addresses'), current_setting('unix_socket_directories')").expect("the settings are read");
    assert_eq!(rows, vec![vec![Some(String::new()), Some(dir.clone())]]);
}

#[test]
fn a_failed_statement_is_the_servers_error() {
    let mut s = Session::connect(&server()).expect("the fixture's server answers");
    match s.query("SELECT * FROM no_such_table") {
        Err(Error::Server(m)) => assert_eq!(m, "relation \"no_such_table\" does not exist"),
        other => panic!("not the server's error: {other:?}"),
    }
}
