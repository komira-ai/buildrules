//! What each derive and attribute macro made, used as a caller would.

use clap::Parser;
use clap::error::ErrorKind;
use macros::{Args, Family, Host, sum_on_tasks};

#[test]
fn a_host_is_read_and_written_under_its_renamed_field() {
    let text = r#"{"name":"node-a","os":"linux","slots":8}"#;
    let host: Host = serde_json::from_str(text).unwrap();
    assert_eq!(host, Host { name: "node-a".to_owned(), family: Family::Linux, slots: 8 });
    assert_eq!(serde_json::to_string(&host).unwrap(), text);
}

#[test]
fn a_host_without_slots_has_one() {
    let host: Host = serde_json::from_str(r#"{"name":"mac-a","os":"macos"}"#).unwrap();
    assert_eq!(host, Host { name: "mac-a".to_owned(), family: Family::Macos, slots: 1 });
}

#[test]
fn an_unknown_field_is_refused_by_name() {
    let err = serde_json::from_str::<Host>(r#"{"name":"a","os":"linux","cores":2}"#).unwrap_err();
    assert_eq!(
        err.to_string(),
        format!("unknown field `cores`, expected one of `name`, `os`, `slots` at line 1 column {}", err.column())
    );
}

#[test]
fn an_unknown_family_is_refused_with_the_known_ones() {
    let err = serde_json::from_str::<Host>(r#"{"name":"a","os":"windows"}"#).unwrap_err();
    assert_eq!(
        err.to_string(),
        format!("unknown variant `windows`, expected `linux` or `macos` at line 1 column {}", err.column())
    );
}

#[test]
fn the_options_left_out_take_their_defaults() {
    let args = Args::try_parse_from(["fixture", "--host", "node-a"]).unwrap();
    assert_eq!(args, Args { host: "node-a".to_owned(), jobs: 4, dry_run: false });
}

#[test]
fn every_option_given_is_read() {
    let args = Args::try_parse_from(["fixture", "--host", "node-b", "--jobs", "9", "--dry-run"]).unwrap();
    assert_eq!(args, Args { host: "node-b".to_owned(), jobs: 9, dry_run: true });
}

#[test]
fn a_missing_required_option_is_refused() {
    let err = Args::try_parse_from(["fixture", "--jobs", "2"]).unwrap_err();
    assert_eq!(err.kind(), ErrorKind::MissingRequiredArgument);
}

#[test]
fn a_jobs_value_that_is_no_number_is_refused() {
    let err = Args::try_parse_from(["fixture", "--host", "a", "--jobs", "many"]).unwrap_err();
    assert_eq!(err.kind(), ErrorKind::ValueValidation);
}

#[test]
fn an_unknown_option_is_refused() {
    let err = Args::try_parse_from(["fixture", "--host", "a", "--cores", "2"]).unwrap_err();
    assert_eq!(err.kind(), ErrorKind::UnknownArgument);
}

#[test]
fn tokio_main_runs_the_tasks_and_sums_them() {
    assert_eq!(sum_on_tasks(vec![1, 2, 3, 4]), 10);
}

#[test]
fn tokio_main_sums_no_tasks_to_zero() {
    assert_eq!(sum_on_tasks(Vec::new()), 0);
}

#[tokio::test]
async fn a_tokio_test_awaits_a_spawned_task() {
    let task = tokio::spawn(async { 6 * 7 });
    assert_eq!(task.await.unwrap(), 42);
}
