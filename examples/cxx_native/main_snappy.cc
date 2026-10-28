// Links the archive of snappy 1.3.1, built from its pinned source archive, through snappy's C interface: compresses 4096 bytes of a repeating pattern, checks the
// result is smaller, decompresses it and compares.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {
int snappy_compress(const char *input, size_t input_length, char *compressed, size_t *compressed_length);
int snappy_uncompress(const char *compressed, size_t compressed_length, char *uncompressed, size_t *uncompressed_length);
size_t snappy_max_compressed_length(size_t source_length);
}

int main() {
    std::string in;
    for (int i = 0; i < 4096; i++) in.push_back(static_cast<char>('a' + (i % 7)));
    size_t clen = snappy_max_compressed_length(in.size());
    std::string comp(clen, '\0');
    if (snappy_compress(in.data(), in.size(), &comp[0], &clen) != 0) return 1;
    if (clen >= in.size()) return 2;
    std::string out(in.size(), '\0');
    size_t olen = out.size();
    if (snappy_uncompress(comp.data(), clen, &out[0], &olen) != 0) return 3;
    if (olen != in.size() || std::memcmp(in.data(), out.data(), olen) != 0) return 4;
    std::printf("snappy ok\n");
    return 0;
}
