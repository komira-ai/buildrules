//! zdemo: compress and decompress with zstd, through `zstd-safe` and `zstd-sys`.
//!
//! The C library is not here: `zstd-sys` carries its sources and its build script compiles them. Under buildrules that script is a
//! cached remote action and the archive it makes is an input of this crate's link.

/// `data` compressed at level 3 and decompressed again; an error is the library's own name for what went wrong.
pub fn roundtrip(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut packed = vec![0u8; zstd_safe::compress_bound(data.len())];
    let n = zstd_safe::compress(&mut packed[..], data, 3).map_err(|c| zstd_safe::get_error_name(c).to_string())?;
    packed.truncate(n);
    let mut out = vec![0u8; data.len()];
    let m = zstd_safe::decompress(&mut out[..], &packed).map_err(|c| zstd_safe::get_error_name(c).to_string())?;
    out.truncate(m);
    Ok(out)
}

/// The size of `data` compressed at level 3.
pub fn packed_len(data: &[u8]) -> Result<usize, String> {
    let mut packed = vec![0u8; zstd_safe::compress_bound(data.len())];
    zstd_safe::compress(&mut packed[..], data, 3).map_err(|c| zstd_safe::get_error_name(c).to_string())
}

/// The version of the C library that was linked, as zstd numbers it (`1.5.5` is 10505).
pub fn library_version() -> u32 {
    zstd_safe::version_number()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_roundtrip_gives_the_input_back() {
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        assert_eq!(roundtrip(&data).unwrap(), data);
    }

    #[test]
    fn repetitive_data_gets_smaller() {
        let data = vec![b'a'; 4096];
        assert!(packed_len(&data).unwrap() < 100);
    }

    #[test]
    fn the_linked_library_is_the_one_the_crate_carries() {
        // zstd-sys 2.0.9+zstd.1.5.5 carries zstd 1.5.5: a different archive on the link line would report another number.
        assert_eq!(library_version(), 10505);
    }
}
