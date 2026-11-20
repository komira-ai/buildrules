//! pgdemo: the smallest client of the Postgres wire protocol (version 3, the simple query) that the Postgres fixture's example needs,
//! with std alone: the URL the fixture gives a test, a session with trust authentication, a query and the rows it answers.
//!
//! The fixture's URL names a Unix socket directory as a percent-encoded host, `postgresql://postgres@%2Fdir%2Fsub:5432/postgres`, which is
//! also how the `postgres` and `sqlx` crates read it. A host that does not start with `/` is a TCP host.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;

/// Where the server is.
#[derive(Debug, PartialEq, Eq)]
pub enum Host {
    /// The directory of the server's Unix socket (`<dir>/.s.PGSQL.<port>`).
    Socket(String),
    /// A TCP host name or address.
    Tcp(String),
}

/// A `postgresql://user@host:port/dbname` URL, the host percent-decoded.
#[derive(Debug, PartialEq, Eq)]
pub struct Url {
    pub user: String,
    pub host: Host,
    pub port: u16,
    pub dbname: String,
}

/// Why a URL, a connection or a query failed.
#[derive(Debug)]
pub enum Error {
    /// The URL is not of the form above; the text says what is wrong.
    Url(String),
    /// Reading or writing the connection failed.
    Io(std::io::Error),
    /// The server answered with an error: its message.
    Server(String),
    /// The server said something this client does not take: what.
    Protocol(String),
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Error {
        Error::Io(e)
    }
}

fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// `text` with every `%XX` replaced by the byte it names.
pub fn percent_decode(text: &str) -> Result<String, Error> {
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let pair = b.get(i + 1).copied().and_then(hex).zip(b.get(i + 2).copied().and_then(hex));
            let (h, l) = pair.ok_or_else(|| Error::Url(format!("'{text}' has a '%' that is not followed by two hex digits")))?;
            out.push(h * 16 + l);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| Error::Url(format!("'{text}' does not decode to UTF-8")))
}

impl Url {
    /// Reads `postgresql://user@host:port/dbname` (or `postgres://`).
    pub fn parse(url: &str) -> Result<Url, Error> {
        let rest = url
            .strip_prefix("postgresql://")
            .or_else(|| url.strip_prefix("postgres://"))
            .ok_or_else(|| Error::Url(format!("'{url}' does not start with postgresql://")))?;
        let (authority, dbname) = rest.split_once('/').ok_or_else(|| Error::Url(format!("'{url}' names no database")))?;
        let (user, hostport) = authority.split_once('@').ok_or_else(|| Error::Url(format!("'{url}' names no user")))?;
        let (host, port) = hostport.rsplit_once(':').ok_or_else(|| Error::Url(format!("'{url}' names no port")))?;
        let port: u16 = port.parse().map_err(|_| Error::Url(format!("'{url}' has the port '{port}', which is not a number")))?;
        let host = percent_decode(host)?;
        let host = if host.starts_with('/') { Host::Socket(host) } else { Host::Tcp(host) };
        Ok(Url { user: user.to_owned(), host, port, dbname: dbname.to_owned() })
    }
}

enum Stream {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl Stream {
    fn read_exact(&mut self, buf: &mut [u8]) -> std::io::Result<()> {
        match self {
            Stream::Unix(s) => s.read_exact(buf),
            Stream::Tcp(s) => s.read_exact(buf),
        }
    }

    fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()> {
        match self {
            Stream::Unix(s) => s.write_all(buf),
            Stream::Tcp(s) => s.write_all(buf),
        }
    }
}

/// One message as the protocol frames it: a type byte, then a length that counts itself and the body.
pub fn message(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![kind];
    out.extend_from_slice(&(body.len() as u32 + 4).to_be_bytes());
    out.extend_from_slice(body);
    out
}

/// The startup message: no type byte, the length, protocol 3.0, then `user` and `database` as NUL-terminated pairs.
pub fn startup(user: &str, dbname: &str) -> Vec<u8> {
    let mut body = 196_608_u32.to_be_bytes().to_vec();
    for s in ["user", user, "database", dbname] {
        body.extend_from_slice(s.as_bytes());
        body.push(0);
    }
    body.push(0);
    let mut out = (body.len() as u32 + 4).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    out
}

/// The `M` (message) field of an ErrorResponse body: NUL-terminated fields, each a type byte then text, ended by a NUL.
pub fn error_message(body: &[u8]) -> String {
    let mut fields = body.split(|&c| c == 0);
    let found = fields.find_map(|f| f.strip_prefix(b"M"));
    found.map(|m| String::from_utf8_lossy(m).into_owned()).unwrap_or_else(|| "an error with no message".to_owned())
}

/// The values of a DataRow body: a count, then each value as a length (-1: NULL) and its bytes.
pub fn data_row(body: &[u8]) -> Result<Vec<Option<String>>, Error> {
    let short = || Error::Protocol("a DataRow shorter than it says".to_owned());
    let count = u16::from_be_bytes(body.get(0..2).ok_or_else(short)?.try_into().map_err(|_| short())?);
    let mut at = 2;
    let mut row = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let len = i32::from_be_bytes(body.get(at..at + 4).ok_or_else(short)?.try_into().map_err(|_| short())?);
        at += 4;
        if len < 0 {
            row.push(None);
            continue;
        }
        let bytes = body.get(at..at + len as usize).ok_or_else(short)?;
        row.push(Some(String::from_utf8_lossy(bytes).into_owned()));
        at += len as usize;
    }
    Ok(row)
}

/// A session with the server.
pub struct Session {
    stream: Stream,
}

impl Session {
    /// Connects and starts a session as the URL's user on its database (the fixture's server trusts its local user).
    pub fn connect(url: &Url) -> Result<Session, Error> {
        let stream = match &url.host {
            Host::Socket(dir) => Stream::Unix(UnixStream::connect(format!("{dir}/.s.PGSQL.{}", url.port))?),
            Host::Tcp(host) => Stream::Tcp(TcpStream::connect((host.as_str(), url.port))?),
        };
        let mut session = Session { stream };
        session.stream.write_all(&startup(&url.user, &url.dbname))?;
        loop {
            let (kind, body) = session.next()?;
            match kind {
                b'R' if body.get(0..4) == Some(&[0, 0, 0, 0]) => {}
                b'R' => return Err(Error::Protocol(format!("the server asks for authentication {:?}; only trust is spoken here", body.get(0..4)))),
                b'E' => return Err(Error::Server(error_message(&body))),
                b'Z' => return Ok(session),
                _ => {}
            }
        }
    }

    fn next(&mut self) -> Result<(u8, Vec<u8>), Error> {
        let mut head = [0u8; 5];
        self.stream.read_exact(&mut head)?;
        let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]);
        if len < 4 {
            return Err(Error::Protocol(format!("a message of length {len}")));
        }
        let mut body = vec![0u8; len as usize - 4];
        self.stream.read_exact(&mut body)?;
        Ok((head[0], body))
    }

    /// Runs `sql` (one or more statements) and returns every row it answered, in order; the server's error, if any, by its message.
    pub fn query(&mut self, sql: &str) -> Result<Vec<Vec<Option<String>>>, Error> {
        let mut text = sql.as_bytes().to_vec();
        text.push(0);
        self.stream.write_all(&message(b'Q', &text))?;
        let mut rows = Vec::new();
        let mut failed = None;
        loop {
            let (kind, body) = self.next()?;
            match kind {
                b'D' => rows.push(data_row(&body)?),
                b'E' => failed = Some(error_message(&body)),
                b'Z' => break,
                _ => {}
            }
        }
        match failed {
            Some(m) => Err(Error::Server(m)),
            None => Ok(rows),
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // Terminate: the server ends the session at once instead of waiting for the connection to drop.
        let _ = self.stream.write_all(&message(b'X', &[]));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fixtures_url_names_a_socket_directory() {
        let url = Url::parse("postgresql://postgres@%2Frun%2Fpg.1a2b:5432/postgres").unwrap();
        assert_eq!(url, Url { user: "postgres".to_owned(), host: Host::Socket("/run/pg.1a2b".to_owned()), port: 5432, dbname: "postgres".to_owned() });
    }

    #[test]
    fn a_host_that_is_not_a_path_is_tcp() {
        let url = Url::parse("postgres://app@127.0.0.1:6543/shop").unwrap();
        assert_eq!(url, Url { user: "app".to_owned(), host: Host::Tcp("127.0.0.1".to_owned()), port: 6543, dbname: "shop".to_owned() });
    }

    #[test]
    fn a_malformed_url_is_refused_saying_why() {
        let text = |r: Result<Url, Error>| match r {
            Err(Error::Url(t)) => t,
            other => panic!("not a URL refusal: {other:?}"),
        };
        assert_eq!(text(Url::parse("mysql://a@h:1/d")), "'mysql://a@h:1/d' does not start with postgresql://");
        assert_eq!(text(Url::parse("postgresql://a@h:1")), "'postgresql://a@h:1' names no database");
        assert_eq!(text(Url::parse("postgresql://h:1/d")), "'postgresql://h:1/d' names no user");
        assert_eq!(text(Url::parse("postgresql://a@h/d")), "'postgresql://a@h/d' names no port");
        assert_eq!(text(Url::parse("postgresql://a@h:x/d")), "'postgresql://a@h:x/d' has the port 'x', which is not a number");
        assert_eq!(text(Url::parse("postgresql://a@%2:1/d")), "'%2' has a '%' that is not followed by two hex digits");
        assert_eq!(text(Url::parse("postgresql://a@%FF:1/d")), "'%FF' does not decode to UTF-8");
    }

    #[test]
    fn messages_are_framed_as_the_protocol_says() {
        assert_eq!(message(b'Q', b"SELECT 1\0"), b"Q\0\0\0\x0dSELECT 1\0".to_vec());
        assert_eq!(startup("u", "d"), b"\0\0\0\x1b\0\x03\0\0user\0u\0database\0d\0\0".to_vec());
    }

    #[test]
    fn an_error_response_is_read_for_its_message() {
        assert_eq!(error_message(b"SERROR\0C42P01\0Mrelation \"missing\" does not exist\0\0"), "relation \"missing\" does not exist");
        assert_eq!(error_message(b"SERROR\0\0"), "an error with no message");
    }

    #[test]
    fn a_data_row_holds_values_and_nulls() {
        assert_eq!(data_row(b"\0\x02\0\0\0\x02hi\xff\xff\xff\xff").unwrap(), vec![Some("hi".to_owned()), None]);
        assert!(matches!(data_row(b"\0\x01\0\0\0\x05hi"), Err(Error::Protocol(m)) if m == "a DataRow shorter than it says"));
    }
}
