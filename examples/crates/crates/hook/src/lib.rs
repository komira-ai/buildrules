//! What the hook program (tests/bin/example_hook.rs) prints for an event.

/// The line printed for `event`; `None` when the event is empty.
pub fn reply(event: &str) -> Option<String> {
    (!event.is_empty()).then(|| format!("handled {event}"))
}

#[cfg(test)]
mod tests {
    use super::reply;

    #[test]
    fn an_event_is_handled() {
        assert_eq!(reply("push").as_deref(), Some("handled push"));
    }

    #[test]
    fn an_empty_event_has_no_reply() {
        assert_eq!(reply(""), None);
    }
}
