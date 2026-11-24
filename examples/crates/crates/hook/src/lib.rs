//! What the hook program (tests/bin/example_hook.rs) prints for an event, and how it says it is called.

/// What the hook prints when it has no event: the text of tests/fixtures/usage.txt, which the integration test holds it to too. The library
/// reads a file under tests/, which only an integration test sees by itself, so the package declares it in `extra_srcs` (BUCK).
pub const USAGE: &str = include_str!("../tests/fixtures/usage.txt");

/// The line printed for `event`; `None` when the event is empty.
pub fn reply(event: &str) -> Option<String> {
    (!event.is_empty()).then(|| format!("handled {event}"))
}

#[cfg(test)]
mod tests {
    use super::{USAGE, reply};

    #[test]
    fn an_event_is_handled() {
        assert_eq!(reply("push").as_deref(), Some("handled push"));
    }

    #[test]
    fn an_empty_event_has_no_reply() {
        assert_eq!(reply(""), None);
    }

    #[test]
    fn the_usage_is_the_fixture_text() {
        assert_eq!(USAGE, "usage: example_hook <event>\n");
    }
}
