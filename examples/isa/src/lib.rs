//! One loop the vectorizer widens with the target's SIMD registers, and a function that is only correct to call on a
//! machine with AVX2. `examples/isa` builds it for x86-64-v1 and v3 (`//platforms:linux_x86_64_v3`).

/// Sums a slice. `inline(never)` keeps one out-of-line copy for the disassembly to find: with `target-cpu=x86-64-v3`
/// the loop is vectorized with `vpaddd ymm`, with the baseline it is `paddd xmm`.
#[inline(never)]
pub fn sum(a: &[u32]) -> u32 {
    a.iter().fold(0u32, |x, y| x.wrapping_add(*y))
}

/// What this build was compiled for.
pub fn level() -> &'static str {
    if cfg!(target_feature = "avx2") {
        "avx2"
    } else {
        "baseline"
    }
}

/// Executes an AVX2 instruction (256-bit integer add). Only exists when the build enabled AVX2, so a test that calls it
/// runs on a worker that has it or dies with SIGILL: which is why the run of a v3 test must be scheduled on a v3 worker.
#[cfg(all(target_arch = "x86_64", target_feature = "avx2"))]
pub fn avx2_add(a: [u32; 8], b: [u32; 8]) -> [u32; 8] {
    use core::arch::x86_64::{__m256i, _mm256_add_epi32, _mm256_loadu_si256, _mm256_storeu_si256};
    let mut out = [0u32; 8];
    // SAFETY: the arrays are 8 u32 = 256 bits each, the loads and the store are unaligned forms, and AVX2 is enabled by cfg.
    unsafe {
        let x = _mm256_loadu_si256(a.as_ptr() as *const __m256i);
        let y = _mm256_loadu_si256(b.as_ptr() as *const __m256i);
        _mm256_storeu_si256(out.as_mut_ptr() as *mut __m256i, _mm256_add_epi32(x, y));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums() {
        let v: Vec<u32> = (1..=1000).collect();
        assert_eq!(sum(&v), 500_500);
    }

    #[test]
    fn level_matches_the_cfg() {
        assert!(level() == "avx2" || level() == "baseline");
    }

    #[cfg(all(target_arch = "x86_64", target_feature = "avx2"))]
    #[test]
    fn avx2_instruction_runs() {
        assert_eq!(avx2_add([1, 2, 3, 4, 5, 6, 7, 8], [10; 8]), [11, 12, 13, 14, 15, 16, 17, 18]);
    }
}
